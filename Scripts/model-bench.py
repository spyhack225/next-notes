#!/usr/bin/env python3
"""Repeatable local-model bake-off (POSITIONING-AND-LOCAL-MODEL PL-02), scripts only.

Cycles every candidate model through the existing self-tests, one at a time, and writes
Tests/Reports/floor/<date>-bakeoff.md and .jsonl. It adds no Swift, no store and no
second harness: every number comes from a self-test flag that already exists.

  agent    --selftest-toolloop-live --model <id|apple> --quick|(full) --report <md>
  cleanup  --selftest-cleanup app-llm-compare --compare-only "<name>"   (GGUF)
           --selftest-cleanup apple-grammar                              (Apple)
           --selftest-cleanup s1                                         (S1-mini)
  notes    --selftest-notes <wav> --notes-model <id|apple>
  speed    --selftest-llm-metal --floor --floor-model <id> --floor-asr <wav> [--floor-sustain N]

Every run goes through Scripts/run-selftest.sh (NEXTNOTES_APP honoured), in the foreground,
never two at once. The app's own harness isolates its stores; the only per-process choices
are the --model / --notes-model / --floor-model / --compare-only flags. This script checks,
before and after every run, that the saved model roles, the model library selection and
library.json did not change, and stops the matrix if they did.

Guardrails live in shared/model-guardrails.json and are meant to be edited by the owner.

Usage:
  Scripts/model-bench.py --dry-run                      # plan + exact commands, runs nothing
  Scripts/model-bench.py --quick                        # every candidate, every role
  Scripts/model-bench.py --models minicpm,qwen3,apple --roles agent,cleanup --quick
  make bench-models BENCH_ARGS='--dry-run'

Exit codes: 0 report written, 2 usage, 3 preflight refused, 4 isolation violated, 130 interrupted.
"""
from __future__ import annotations

import argparse
import atexit
import ctypes
import datetime as dt
import hashlib
import json
import os
import plistlib
import re
import shlex
import shutil
import signal
import struct
import subprocess
import sys
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RUN_SELFTEST = ROOT / "Scripts" / "run-selftest.sh"
DEFAULT_APP = "/Applications/Next Notes.app"
MODELS_DIR = Path.home() / "Library/Application Support/Next Notes/Models"
ALL_ROLES = ["agent", "cleanup", "notes", "speed"]

# ---------------------------------------------------------------------------------------
# small helpers


def sh(argv, timeout=15):
    """(returncode, stdout) of a short read-only command; never raises."""
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout
    except Exception as exc:  # noqa: BLE001 - diagnostics must not break the bench
        return 127, f"{type(exc).__name__}: {exc}"


def quote(argv):
    return " ".join(shlex.quote(str(a)) for a in argv)


def gb(n):
    return n / 1e9


def fmt(v, digits=2):
    if v is None:
        return "NA"
    if isinstance(v, float):
        return f"{v:.{digits}f}"
    return str(v)


def slug(text):
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


def swap_used_mb():
    rc, out = sh(["sysctl", "-n", "vm.swapusage"], 5)
    m = re.search(r"used = ([\d.]+)M", out) if rc == 0 else None
    return float(m.group(1)) if m else None


# ---------------------------------------------------------------------------------------
# guardrails


def load_guardrails(path):
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    if data.get("schema") != 1:
        raise SystemExit(f"model-bench: unsupported guardrails schema in {path}")
    return data


def compare(op, value, threshold):
    if op == ">=":
        return value >= threshold
    if op == "<=":
        return value <= threshold
    if op == "==":
        return value == threshold
    raise ValueError(f"unknown operator {op}")


def make_check(gr, key, value, mode, note="", unmeasured_reason=None):
    """One guardrail evaluated. result: pass | fail | unmeasured | info | n/a."""
    g = gr["guardrails"][key]
    only = g.get("only_when")
    if only and only != mode:
        return None
    check = {
        "guardrail": key, "label": g["label"], "op": g["op"], "threshold": g["value"],
        "unit": g.get("unit", ""), "gated": bool(g.get("gated")), "status": g.get("status", ""),
        "value": value, "note": note,
    }
    if unmeasured_reason is not None or value is None:
        check["result"] = "unmeasured"
        check["note"] = (unmeasured_reason or note or "not measured by this run")
        check["value"] = None
    else:
        ok = compare(g["op"], value, g["value"])
        if g.get("gated"):
            check["result"] = "pass" if ok else "fail"
        else:
            check["result"] = "info"
            check["met"] = ok
    return check


def na_check(gr, key, why):
    g = gr["guardrails"][key]
    return {"guardrail": key, "label": g["label"], "op": g["op"], "threshold": g["value"],
            "unit": g.get("unit", ""), "gated": bool(g.get("gated")), "status": g.get("status", ""),
            "value": None, "result": "n/a", "note": why}


# ---------------------------------------------------------------------------------------
# candidates


def pinned_digests():
    """file name -> sha256 pinned in Sources (ModelSpec.expectedSHA256). Read-only grep."""
    pins = {}
    src = ROOT / "Sources"
    if not src.is_dir():
        return pins
    rc, out = sh(["grep", "-rl", "expectedSHA256", str(src)], 20)
    for name in out.split():
        try:
            text = Path(name).read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for m in re.finditer(r'fileName:\s*"([^"]+)"[\s\S]{0,1800}?expectedSHA256:\s*"([0-9a-fA-F]{64})"', text):
            pins[m.group(1)] = m.group(2).lower()
    return pins


def discover_candidates(gr):
    cfg = gr["candidates"]
    pins = pinned_digests()
    cands = []
    seen_files = set()

    def compare_name(filename):
        low = filename.lower()
        for frag, name in cfg["cleanup_compare_names"].items():
            if frag in low:
                return name
        return None

    def add(cid, display, filename, size, library_sha, kind="gguf", roles=None, compare=None):
        sha, src = (library_sha, "library.json") if library_sha else (pins.get(filename), "pinned in Sources")
        cands.append({
            "id": cid, "display": display, "file": filename, "bytes": size, "kind": kind,
            "sha256": sha, "sha256_source": src if sha else None,
            "roles": roles or list(ALL_ROLES),
            "compare_name": compare if compare is not None else compare_name(filename or ""),
            "in_library": True,
        })
        if filename:
            seen_files.add(filename)

    lib_path = MODELS_DIR / "library.json"
    rows = []
    if lib_path.is_file():
        try:
            rows = json.loads(lib_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            rows = []
    bg = cfg["builtin_gemma"]
    gp = MODELS_DIR / bg["file"]
    if gp.is_file():
        add(bg["id"], bg["display"], bg["file"], gp.stat().st_size, None)
    for row in rows:
        fname = Path(re.sub(r"^file://", "", str(row.get("fileURL", "")))).name
        fname = fname.replace("%20", " ")
        fpath = MODELS_DIR / fname
        low = (fname + row.get("id", "")).lower()
        if not fpath.is_file() or fname in seen_files:
            continue
        if any(bad in low for bad in cfg["not_language_models"]):
            continue
        va = row.get("verifiedArtifact") or {}
        add(row["id"], row.get("displayName", fname), fname, fpath.stat().st_size,
            va.get("sha256"))
    for fname, display in cfg["cleanup_only_files"].items():
        fp = MODELS_DIR / fname
        if fp.is_file():
            add("s1-mini", display, fname, fp.stat().st_size, None, kind="cleanup-only",
                roles=["cleanup"], compare="")
    # Any other GGUF on disk with no library row: listed so the gap is visible.
    if MODELS_DIR.is_dir():
        for fp in sorted(MODELS_DIR.glob("*.gguf")):
            low = fp.name.lower()
            if fp.name in seen_files or any(bad in low for bad in cfg["not_language_models"]):
                continue
            cands.append({
                "id": f"file:{fp}", "display": fp.stem, "file": fp.name, "bytes": fp.stat().st_size,
                "kind": "gguf", "sha256": pins.get(fp.name), "sha256_source": "pinned in Sources" if pins.get(fp.name) else None,
                "roles": ["agent"], "compare_name": compare_name(fp.name), "in_library": False,
            })
    cands.append({"id": "apple", "display": "Apple Foundation Models", "file": None, "bytes": None,
                  "kind": "apple", "sha256": None, "sha256_source": None,
                  "roles": ["agent", "cleanup", "notes"], "compare_name": None, "in_library": True})
    return cands


def select_candidates(cands, tokens):
    if not tokens or tokens == ["all"]:
        return list(cands)
    chosen = []
    for tok in tokens:
        low = tok.lower()
        exact = [c for c in cands if low in (c["id"].lower(), c["display"].lower(), (c["file"] or "").lower())]
        hits = exact or [c for c in cands
                         if low in (c["id"] + " " + c["display"] + " " + (c["file"] or "")).lower()]
        if not hits:
            raise SystemExit(f"model-bench: --models '{tok}' matches no installed candidate "
                             f"(have: {', '.join(c['display'] for c in cands)})")
        for c in hits:
            if c not in chosen:
                chosen.append(c)
    return chosen


def sha256_file(path, chunk=8 << 20):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        while True:
            block = fh.read(chunk)
            if not block:
                break
            h.update(block)
    return h.hexdigest()


# ---------------------------------------------------------------------------------------
# plan


class Step:
    def __init__(self, cand, role, argv, timeout, out_file=None, report=None, abort_if=None,
                 gap=None, na=None, info_only=False, label=None):
        self.cand, self.role, self.argv, self.timeout = cand, role, argv, timeout
        self.out_file, self.report = out_file, report
        self.abort_if = abort_if or []   # [(compiled regex, reason)]
        self.gap, self.na, self.info_only = gap, na, info_only
        self.label = label or role


def build_plan(cands, roles, mode, opts, gr, logdir):
    runs = gr["runs"]
    scale = opts.timeout_scale
    tmo = {k: int(v * scale) for k, v in runs["timeouts_s"].items()}
    steps = []

    def selftest(out_file, *args):
        return [str(RUN_SELFTEST), "--out", str(out_file), *args]

    def fixture(arg, key):
        p = Path(arg or gr["fixtures"][key])
        return str(p if p.is_absolute() else ROOT / p)

    notes_wav, asr_wav = fixture(opts.notes_wav, "notes_wav"), fixture(opts.asr_wav, "asr_wav")

    for c in cands:
        s = slug(c["display"])
        for role in roles:
            out_file = logdir / f"{s}-{role}.out.txt"
            if role not in c["roles"]:
                steps.append(Step(c, role, None, 0, na=_na_reason(c, role)))
                continue
            if role == "agent":
                report = logdir / f"{s}-agent-toolloop.md"
                argv = selftest(out_file, "--selftest-toolloop-live", "--model", c["id"],
                                *(["--quick"] if mode == "quick" else []), "--report", str(report))
                if runs.get("agent_planner"):
                    argv += ["--planner", str(runs["agent_planner"])]
                steps.append(Step(c, role, argv, tmo["agent_quick" if mode == "quick" else "agent_full"],
                                  out_file, report))
            elif role == "cleanup":
                if c["kind"] == "apple":
                    argv = selftest(out_file, "--selftest-cleanup", "apple-grammar", "--selftest-timeout", str(tmo["cleanup"]))
                    steps.append(Step(c, role, argv, tmo["cleanup"], out_file))
                elif c["kind"] == "cleanup-only":
                    argv = selftest(out_file, "--selftest-cleanup", "s1", "--selftest-timeout", str(tmo["cleanup"]))
                    steps.append(Step(c, role, argv, tmo["cleanup"], out_file))
                elif not c.get("compare_name"):
                    steps.append(Step(c, role, None, 0, gap=(
                        "--selftest-cleanup app-llm-compare only knows four hard-coded file names; this file is not "
                        "one of them, and no other cleanup mode takes a model choice. Needs a Swift change.")))
                else:
                    name = c["compare_name"]
                    argv = selftest(out_file, "--selftest-cleanup", "app-llm-compare", "--compare-only", name,
                                    "--selftest-timeout", str(tmo["cleanup"]))
                    # A build without --compare-only ignores it and walks every file; stop at the
                    # first header that is not ours instead of paying for four models.
                    pat = re.compile(r"^--- (?!" + re.escape(name) + r" \()\S.* \(.*\) ---$", re.M)
                    steps.append(Step(c, role, argv, tmo["cleanup"], out_file, abort_if=[(pat,
                                      "the app build ignores --compare-only (it started a different model); "
                                      "install a build that has it")]))
            elif role == "notes":
                if c["kind"] == "gguf" and not c["in_library"]:
                    steps.append(Step(c, role, None, 0, gap="--notes-model needs a model library row; this file has none."))
                    continue
                argv = selftest(out_file, "--selftest-notes", notes_wav, "--notes-model", c["id"],
                                "--selftest-timeout", str(tmo["notes"]))
                steps.append(Step(c, role, argv, tmo["notes"], out_file))
            elif role == "speed":
                if c["kind"] == "apple":
                    steps.append(Step(c, role, None, 0, na="Apple's model runs inside the OS; --floor only measures a GGUF library artifact, "
                                      "so there is no decode tok/s probe for it (recorded gap, not a fail)."))
                    continue
                if not c["in_library"]:
                    steps.append(Step(c, role, None, 0, gap="--floor-model needs a model library row; this file has none."))
                    continue
                conds = (["C0"] if opts.with_c0 else []) + ["C1"]
                for cond in conds:
                    key = "speed_c0" if cond == "C0" else ("speed_c1_sustain" if mode == "full" else "speed_c1")
                    f = logdir / f"{s}-speed-{cond.lower()}.out.txt"
                    argv = selftest(f, "--selftest-llm-metal", "--floor", "--floor-model", c["id"],
                                    "--floor-runs", str(runs["floor_runs"]))
                    if cond == "C1":
                        argv += ["--floor-asr", asr_wav]
                        if mode == "full":
                            argv += ["--floor-sustain", str(runs["floor_sustain_s"])]
                    argv += ["--selftest-timeout", str(tmo[key])]
                    steps.append(Step(c, "speed" if cond == "C1" else "speed-c0", argv, tmo[key], f,
                                      info_only=(cond == "C0"), label=f"speed {cond}"))
    return steps


def _na_reason(c, role):
    if c["kind"] == "cleanup-only":
        return "S1-mini is a punctuation normaliser used for cleanup only; it is not an agent or notes model."
    if c["kind"] == "apple" and role == "speed":
        return "Apple's model has no decode tok/s probe in --floor."
    return f"{c['display']} is not a candidate for the {role} role."


# ---------------------------------------------------------------------------------------
# machine state, preflight, isolation


def conditions_now():
    c = {"time": dt.datetime.now().astimezone().isoformat(timespec="seconds")}
    c["load_avg"] = [round(x, 2) for x in os.getloadavg()]
    c["swap_used_mb"] = swap_used_mb()
    try:
        c["free_disk_gb"] = round(shutil.disk_usage("/").free / 1e9, 2)
    except OSError:
        c["free_disk_gb"] = None
    rc, out = sh(["sysctl", "-n", "hw.model", "machdep.cpu.brand_string", "hw.memsize"], 5)
    parts = out.strip().splitlines() if rc == 0 else []
    if len(parts) == 3:
        c["hardware"], c["chip"], c["memory_gb"] = parts[0], parts[1], round(int(parts[2]) / 2**30, 1)
    rc, out = sh(["sw_vers", "-productVersion"], 5)
    c["macos"] = out.strip() if rc == 0 else None
    rc, out = sh(["pmset", "-g", "therm"], 5)
    c["thermal"] = " ".join(l.strip() for l in out.splitlines() if "limit" in l.lower() or "thermal" in l.lower())[:160] or "no thermal warning recorded" if rc == 0 else None
    rc, out = sh(["pmset", "-g", "batt"], 5)
    c["power"] = out.splitlines()[0].strip() if rc == 0 and out else None
    rc, out = sh(["pmset", "-g"], 5)
    m = re.search(r"lowpowermode\s+(\d)", out) if rc == 0 else None
    c["low_power_mode"] = (m.group(1) == "1") if m else None
    rc, out = sh(["memory_pressure", "-Q"], 8)
    m = re.search(r"free percentage: (\d+)%", out) if rc == 0 else None
    c["memory_free_pct"] = int(m.group(1)) if m else None
    c["contention"] = contention_list()
    rc, out = sh(["ps", "-axo", "command="], 8)
    apps = set(re.findall(r"/Applications/([^/]+)\.app/Contents/MacOS/", out)) if rc == 0 else set()
    c["open_apps"] = sorted(apps)
    return c


CONTENTION_RE = re.compile(
    r"swift-build|swift-frontend|swift-driver|swiftc|xcodebuild|clang(?!d)|ld64|\bmake\b|"
    r"NextNotes.*--selftest|run-selftest\.sh|with-install-lock|model-bench\.py|xctest")


def contention_list():
    """Other heavy work visible on the machine (builds, self-tests, another bench)."""
    rc, out = sh(["ps", "-axo", "pid=,command="], 8)
    mine = {os.getpid(), os.getppid()}
    found = set()
    for line in out.splitlines() if rc == 0 else []:
        pid_s, _, cmd = line.strip().partition(" ")
        if not pid_s.isdigit() or int(pid_s) in mine:
            continue
        m = CONTENTION_RE.search(cmd)
        if m and "grep" not in cmd and "ps -axo" not in cmd:
            found.add(m.group(0))
    return sorted(found)


def relay_gate():
    rc, out = sh(["agent-relay", "gate"], 20)
    try:
        return json.loads(out)
    except ValueError:
        return {"ok": False, "reasons": [f"agent-relay gate unreadable (rc={rc}): {out[:120]}"]}


class Claim:
    """The machine-wide `heavy` claim; released on every exit path."""

    def __init__(self, ident):
        self.ident, self.joined, self.held = ident, False, False
        atexit.register(self.release)

    def acquire(self):
        rc, out = sh(["agent-relay", "join", "--as", self.ident, "--runner", "claude"], 20)
        self.joined = rc == 0
        rc, out = sh(["agent-relay", "claim", "--as", self.ident, "--scope", "machine", "--gate", "heavy"], 30)
        self.held = rc == 0
        return self.held, out.strip()[:400]

    def release(self):
        if self.held:
            sh(["agent-relay", "release", "--as", self.ident, "--scope", "machine", "heavy"], 20)
            self.held = False
        if self.joined:
            sh(["agent-relay", "leave", "--as", self.ident], 20)
            self.joined = False


def isolation_snapshot(gr):
    iso = gr["isolation"]
    snap = {"defaults": {}, "library_sha256": None}
    rc, out = sh(["defaults", "export", iso["defaults_domain"], "-"], 10)
    if rc == 0 and out.strip():
        try:
            plist = plistlib.loads(out.encode("utf-8"))
            rx = re.compile(iso["watch_key_regex"])
            ignore = set(iso.get("ignore_keys", []))
            snap["defaults"] = {k: repr(v) for k, v in sorted(plist.items()) if rx.search(k) and k not in ignore}
        except Exception as exc:  # noqa: BLE001
            snap["defaults_error"] = f"{type(exc).__name__}: {exc}"
    lib = Path(os.path.expanduser(iso["library_json"]))
    if lib.is_file():
        snap["library_sha256"] = hashlib.sha256(lib.read_bytes()).hexdigest()
    return snap


def snapshot_diff(a, b):
    diffs = []
    for k in sorted(set(a["defaults"]) | set(b["defaults"])):
        if a["defaults"].get(k) != b["defaults"].get(k):
            diffs.append(f"defaults {k}: {a['defaults'].get(k)} -> {b['defaults'].get(k)}")
    if a["library_sha256"] != b["library_sha256"]:
        diffs.append(f"library.json hash {a['library_sha256']} -> {b['library_sha256']}")
    return diffs


def app_identity(app):
    exe = Path(app) / "Contents/MacOS/NextNotes"
    info = {"app": str(app), "executable": str(exe), "exists": exe.is_file()}
    if not exe.is_file():
        return info
    st = exe.stat()
    info["executable_bytes"] = st.st_size
    info["executable_mtime"] = dt.datetime.fromtimestamp(st.st_mtime).astimezone().isoformat(timespec="seconds")
    info["executable_sha256"] = sha256_file(exe)
    rc, out = sh(["defaults", "read", str(Path(app) / "Contents/Info"), "CFBundleVersion"], 5)
    info["bundle_version"] = out.strip() if rc == 0 else None
    rc, out = sh(["codesign", "-dvvv", str(app)], 15)
    m = re.search(r"CDHash=([0-9a-f]+)", out)
    info["cdhash"] = m.group(1) if m else None
    # Positive finds are conclusive; a miss is not (Swift stores literals of 15 bytes or fewer inline).
    data = exe.read_bytes()
    info["flag_strings_found"] = {f: (f.encode() in data) for f in
                                  ["--floor-model", "--floor-sustain", "--floor-asr", "--notes-model",
                                   "--compare-only", "LLM_FLOOR", "NOTES_ABSENT"]}
    rc, out = sh(["git", "-C", str(ROOT), "rev-parse", "--short", "HEAD"], 5)
    info["source_head"] = out.strip() if rc == 0 else None
    return info


# ---------------------------------------------------------------------------------------
# footprint sampling


class Sampler(threading.Thread):
    """Polls the self-test app process once a second with proc_pid_rusage.

    Deliberately not the `footprint` command: PERFORMANCE-STANDARDS records that tool
    timing out under paging. phys_footprint is the figure the task asks for; resident
    size is kept beside it because the two are different observations.
    """

    def __init__(self, root_pid, interval, abort_swap_gb):
        super().__init__(daemon=True)
        self.root_pid, self.interval = root_pid, interval
        self.abort_swap_mb = abort_swap_gb * 1024
        self.stop = threading.Event()
        self.pid = None
        self.peak_footprint = self.peak_resident = 0
        self.samples = 0
        self.swap_start = swap_used_mb()
        self.swap_peak = self.swap_start
        self.swap_end = self.swap_start
        self.swap_over_limit = False
        self._libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)

    def _descendant_app_pid(self):
        rc, out = sh(["ps", "-axo", "pid=,ppid=,command="], 8)
        if rc != 0:
            return None
        kids, cmds = {}, {}
        for line in out.splitlines():
            parts = line.strip().split(None, 2)
            if len(parts) < 3 or not parts[0].isdigit() or not parts[1].isdigit():
                continue
            pid, ppid = int(parts[0]), int(parts[1])
            kids.setdefault(ppid, []).append(pid)
            cmds[pid] = parts[2]
        todo, seen = [self.root_pid], set()
        while todo:
            p = todo.pop()
            if p in seen:
                continue
            seen.add(p)
            if "/Contents/MacOS/NextNotes" in cmds.get(p, ""):
                return p
            todo.extend(kids.get(p, []))
        return None

    def _rusage(self, pid):
        buf = ctypes.create_string_buffer(512)
        if self._libproc.proc_pid_rusage(pid, 0, buf) != 0:  # RUSAGE_INFO_V0
            return None
        raw = buf.raw
        return struct.unpack_from("<Q", raw, 72)[0], struct.unpack_from("<Q", raw, 64)[0]

    def run(self):
        last_swap = 0.0
        while not self.stop.wait(self.interval):
            if self.pid is None:
                self.pid = self._descendant_app_pid()
            if self.pid is not None:
                usage = self._rusage(self.pid)
                if usage is None:
                    self.pid = None
                else:
                    self.samples += 1
                    self.peak_footprint = max(self.peak_footprint, usage[0])
                    self.peak_resident = max(self.peak_resident, usage[1])
            if time.monotonic() - last_swap >= 5:
                last_swap = time.monotonic()
                s = swap_used_mb()
                if s is not None:
                    self.swap_end = s
                    self.swap_peak = max(self.swap_peak or s, s)
                    if s > self.abort_swap_mb:
                        self.swap_over_limit = True

    def finish(self):
        self.stop.set()
        self.join(timeout=5)
        s = swap_used_mb()
        if s is not None:
            self.swap_end = s
            self.swap_peak = max(self.swap_peak or s, s)

    def result(self):
        growth = None if self.swap_start is None or self.swap_end is None else round(self.swap_end - self.swap_start, 1)
        return {"samples": self.samples, "peak_footprint_bytes": self.peak_footprint or None,
                "peak_resident_bytes": self.peak_resident or None, "swap_start_mb": self.swap_start,
                "swap_end_mb": self.swap_end, "swap_peak_mb": self.swap_peak, "swap_growth_mb": growth,
                "swap_over_abort_limit": self.swap_over_limit}


# ---------------------------------------------------------------------------------------
# running one step


class Interrupted(BaseException):
    pass


def _terminate(proc):
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except (ProcessLookupError, PermissionError):
        return
    try:
        proc.wait(timeout=20)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
        proc.wait(timeout=10)


CURRENT = {"proc": None}


def run_step(step, gr, env):
    runs = gr["runs"]
    step.out_file.parent.mkdir(parents=True, exist_ok=True)
    log_path = step.out_file.with_suffix(".log")
    for p in (step.out_file, log_path):
        if p.exists():
            p.unlink()
    started = time.monotonic()
    result = {"status": "complete", "exit_code": None, "reason": None}
    with open(log_path, "wb") as logf:
        proc = subprocess.Popen(step.argv, stdout=logf, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                                start_new_session=True, env=env)
        CURRENT["proc"] = proc
        sampler = Sampler(proc.pid, runs["sample_interval_s"], runs["abort_swap_gb"])
        sampler.start()
        limit = step.timeout + runs["wall_clock_grace_s"]
        read_pos = 0
        try:
            while True:
                try:
                    result["exit_code"] = proc.wait(timeout=1.0)
                    break
                except subprocess.TimeoutExpired:
                    pass
                if time.monotonic() - started > limit:
                    result.update(status="timeout", reason=f"no result within {limit}s wall clock; terminated")
                    _terminate(proc)
                    break
                if sampler.swap_over_limit:
                    result.update(status="aborted", reason=f"system swap passed {runs['abort_swap_gb']} GB; terminated to protect the Mac")
                    _terminate(proc)
                    break
                if step.abort_if:
                    try:
                        with open(log_path, "rb") as rf:
                            rf.seek(read_pos)
                            chunk = rf.read().decode("utf-8", "replace")
                    except OSError:
                        chunk = ""
                    if chunk and not chunk.endswith("\n"):
                        chunk = chunk[: chunk.rfind("\n") + 1]
                    read_pos += len(chunk.encode("utf-8"))
                    hit = next((why for rx, why in step.abort_if if rx.search(chunk)), None)
                    if hit:
                        result.update(status="gap", reason=hit)
                        _terminate(proc)
                        break
        finally:
            CURRENT["proc"] = None
            if proc.poll() is None:
                _terminate(proc)
            sampler.finish()
    result["elapsed_s"] = round(time.monotonic() - started, 1)
    result["process"] = sampler.result()
    text = ""
    seen = set()
    for p in (step.out_file, log_path):
        try:
            for line in p.read_text(encoding="utf-8", errors="replace").splitlines():
                if line not in seen:
                    seen.add(line)
                    text += line + "\n"
        except OSError:
            pass
    result["text"] = text
    result["log"] = str(log_path)
    if result["status"] == "complete" and "SELFTEST_TIMEOUT" in text:
        result.update(status="timeout", reason="the app's own self-test watchdog fired (SELFTEST_TIMEOUT)")
    return result


# ---------------------------------------------------------------------------------------
# parsing and evaluation per role


def kv_line(text, marker):
    for line in text.splitlines():
        if line.startswith(marker + ":") or line.startswith(marker + " "):
            return dict(re.findall(r"(\w+)=(\S*)", line))
    return None


def to_float(s):
    try:
        v = float(s)
        return v if v == v else None
    except (TypeError, ValueError):
        return None


def evaluate(step, run, gr, mode):
    """-> (metrics, checks, incomplete_reason|None, contended, harness_violation)"""
    text, role, cand = run["text"], step.role, step.cand
    proc = run["process"]
    metrics, checks, incomplete, contended, violation = {}, [], None, False, False

    if run["status"] != "complete":
        incomplete = run["reason"] or run["status"]

    def common(role_key):
        pf = proc.get("peak_footprint_bytes")
        peak_gb = gb(pf) if pf else None
        why = None if pf else "the process was never sampled (no app pid found)"
        for key in ("peak_footprint_gb", "memory_target_gb"):
            if role_key in gr["guardrails"][key]["roles"]:
                c = make_check(gr, key, round(peak_gb, 2) if peak_gb is not None else None, mode, unmeasured_reason=why)
                if c:
                    checks.append(c)
        if "artifact_disk_gb" in gr["guardrails"] and role_key in gr["guardrails"]["artifact_disk_gb"]["roles"]:
            if cand["kind"] == "apple":
                checks.append(na_check(gr, "artifact_disk_gb", "Apple's model is OS-resident; nothing to ship"))
            else:
                checks.append(make_check(gr, "artifact_disk_gb", round(gb(cand["bytes"]), 2), mode))

    role_key = "speed" if role.startswith("speed") else role

    if role == "agent":
        sc = re.search(r"TOOLLOOP_LIVE_SCORE (\d+)/(\d+)", text)
        pa = re.search(r"TOOLLOOP_LIVE_PARTIAL (\d+)/(\d+)", text)
        ow = re.search(r"TOOLLOOP_LIVE_OWNER (\d+)/(\d+)", text)
        el = re.search(r"TOOLLOOP_LIVE_ELAPSED ([\d.]+)", text)
        rp = re.search(r"TOOLLOOP_LIVE_REPORT (\S+)", text)
        metrics.update(owner_cases=ow.group(0).split()[-1] if ow else None, elapsed_s_app=to_float(el.group(1)) if el else None,
                       toolloop_report=rp.group(1) if rp else None)
        if "TOOLLOOP_LIVE_ABSENT" in text:
            incomplete = incomplete or "ABSENT: " + re.search(r"TOOLLOOP_LIVE_ABSENT:?(.*)", text).group(1).strip()
        if re.search(r"TOOLLOOP_LIVE_FAILED: the run changed", text):
            violation = True
        if pa:
            incomplete = incomplete or f"run interrupted after {pa.group(1)}/{pa.group(2)} (TOOLLOOP_LIVE_PARTIAL)"
        if sc and not pa:
            passed, total = int(sc.group(1)), int(sc.group(2))
            metrics["score"] = f"{passed}/{total}"
            key = "agent_quick_score_min" if mode == "quick" else "agent_full_score_min"
            checks.append(make_check(gr, key, passed, mode))
        elif not incomplete:
            incomplete = "no TOOLLOOP_LIVE_SCORE line (the run did not finish)"
        rpt = metrics.get("toolloop_report")
        if rpt and Path(rpt).is_file():
            m = re.search(r"App peak RSS: (\d+) bytes", Path(rpt).read_text(encoding="utf-8", errors="replace"))
            if m:
                metrics["app_peak_rss_bytes_report"] = int(m.group(1))
        common("agent")

    elif role == "cleanup":
        failed = total = med = cold = None
        if cand["kind"] == "gguf":
            name = re.escape(cand["compare_name"] or "")
            m = re.search(r"^MODEL_COMPARE " + name + r": [^,\n]*, assertions (\d+)/(\d+), median=([\d.]+)s max=([\d.]+)s",
                          text, re.M)
            if m:
                failed, total, med = int(m.group(1)), int(m.group(2)), float(m.group(3))
                metrics["max_s"] = float(m.group(4))
            elif re.search(r"^MODEL_COMPARE " + name + r": (absent|unopenable)", text, re.M):
                incomplete = incomplete or re.search(r"^MODEL_COMPARE " + name + r": (.*)$", text, re.M).group(1)
            if "CLEANUP_MODEL_COMPARE_ABSENT" in text:
                incomplete = incomplete or "CLEANUP_MODEL_COMPARE_ABSENT: no model file found by the self-test"
            cases = [float(t) for t in re.findall(r"^\S+\t([\d.]+)s\t(?:ok|FAIL \d+)$", text, re.M)]
            if cases:
                metrics["cases_seen"] = len(cases)
                metrics["cold_first_case_s"] = cases[0]
                warm = sorted(cases[1:])
                metrics["warm_median_s"] = warm[len(warm) // 2] if warm else None
        else:
            engine = "apple-grammar" if cand["kind"] == "apple" else "s1"
            m = re.search(r"CLEANUP_SUMMARY " + engine + r": n=(\d+) cold=([\d.]+)s median=([\d.]+)s warm-median=([\d.]+)s warm-max=([\d.]+)s", text)
            if m:
                total, cold, med = int(m.group(1)), float(m.group(2)), float(m.group(3))
                metrics.update(cold_first_case_s=cold, warm_median_s=float(m.group(4)), warm_max_s=float(m.group(5)))
                f = re.search(r"CLEANUP_FAILED: (\d+) assertion", text)
                if re.search(r"^CLEANUP_OK", text, re.M):
                    failed = 0
                elif f:
                    failed = int(f.group(1))
        if failed is not None:
            metrics.update(failed_assertions=failed, cases=total, median_s=med)
            checks.append(make_check(gr, "cleanup_failed_assertions_max", failed, mode))
            checks.append(make_check(gr, "cleanup_p50_s", med, mode))
        elif not incomplete:
            incomplete = "no cleanup result line (the run did not reach its summary)"
        common("cleanup")

    elif role == "notes":
        m = re.search(r"NOTES_OK: (.+?)(?: \(map-reduce\))?, (\d+) segment\(s\) from ([\d.]+)s audio, (\d+) tokens in ([\d.]+)s "
                      r"\(([\d.]+) tok/s\), peak RSS (\d+) MB", text)
        for marker in ("NOTES_ABSENT", "NOTES_FAILED"):
            mm = re.search(marker + r":?(.*)", text)
            if mm:
                incomplete = incomplete or f"{marker}:{mm.group(1).strip()}"
        if m:
            tps = float(m.group(6))
            metrics.update(model_reported=m.group(1), map_reduce="(map-reduce)" in m.group(0), segments=int(m.group(2)),
                           audio_s=float(m.group(3)), tokens=int(m.group(4)), duration_s=float(m.group(5)), tok_per_s=tps,
                           app_peak_rss_mb_reported=int(m.group(7)))
            missing = re.search(r"NOTES_HEADINGS_MISSING: (.*)", text)
            names = [s.strip() for s in missing.group(1).split(",")] if missing else []
            metrics["headings_missing"] = names
            checks.append(make_check(gr, "notes_headings_missing_max", len(names), mode,
                                     note=", ".join(names)))
            checks.append(make_check(gr, "notes_tps_min", tps, mode))
            checks.append({**na_check(gr, "notes_quality_rubric", "notes content is not graded here; read the notes (SB-07 rubric absent)"),
                           "result": "unmeasured", "gated": False})
        elif not incomplete:
            incomplete = "no NOTES_OK line (the run did not finish)"
        common("notes")

    elif role.startswith("speed"):
        floor = kv_line(text, "LLM_FLOOR")
        if "LLM_FLOOR_ABSENT" in text:
            incomplete = incomplete or "LLM_FLOOR_ABSENT: " + re.search(r"LLM_FLOOR_ABSENT:?(.*)", text).group(1).strip()
        if floor is None and not incomplete:
            incomplete = "no LLM_FLOOR line: this app build does not have the --floor modifier, or the run stopped early"
        if floor is not None:
            status = floor.get("status", "?")
            contended = status == "CONTENDED"
            metrics.update(floor_status=status, condition=floor.get("condition"), decode_median=to_float(floor.get("decode_median")),
                           decode_p10=to_float(floor.get("decode_p10")), prefill_tps_ttft=to_float(floor.get("prefill_tps_ttft")),
                           artifact_sha256=floor.get("artifact_sha256"), artifact_proof=floor.get("artifact_proof"),
                           executable_sha256=floor.get("executable_sha256"), contention=floor.get("contention"),
                           peak_rss_bytes_app=to_float(floor.get("peak_rss_bytes")), asr_workload_qualified=floor.get("asr_workload_qualified"),
                           fixed256_10=floor.get("fixed256_10"), pressure_worst=floor.get("pressure_worst_observed"),
                           pressure_history_gap=floor.get("pressure_history_gap"), c2=floor.get("C2"),
                           external_contention=floor.get("external_contention"))
            cond = floor.get("condition", "?")
            qualified = status in ("MEASURED", "CONTENDED") and floor.get("fixed256_10") == "true" and \
                (cond != "C1" or floor.get("asr_workload_qualified") == "true")
            why = None if qualified else (f"floor run is {status}, fixed256_10={floor.get('fixed256_10')}, "
                                          f"asr_workload_qualified={floor.get('asr_workload_qualified')}")
            if step.info_only:  # C0: recorded, never a gate
                metrics["note"] = "C0 (model alone) is recorded for comparison; it never passes a gate."
            else:
                p10, med = to_float(floor.get("decode_p10")), to_float(floor.get("decode_median"))
                checks.append(make_check(gr, "decode_tps_p10", p10, mode, unmeasured_reason=why))
                checks.append(make_check(gr, "decode_tps_median_target", med, mode, unmeasured_reason=why))
                # sustained
                sus = None
                for line in text.splitlines():
                    if line.startswith("LLM_FLOOR_SUSTAIN:") and "interval=last_requested_minute" in line:
                        sus = dict(re.findall(r"(\w+)=(\S*)", line))
                if mode == "full":
                    v = to_float(sus.get("decode_tps")) if sus else None
                    ok10 = sus and sus.get("ten_minutes") == "true"
                    checks.append(make_check(gr, "sustained_last_minute_tps", v if ok10 else None, mode,
                                             unmeasured_reason=None if (v is not None and ok10) else "no qualified 10 minute sustained window"))
                # warm first token: C2 only. C1 rounds shown for information.
                warm = sorted(float(m.group(1)) for m in re.finditer(r"^LLM_FLOOR_ROUND:.* warm=true .*?ttft_ms=(\d+)", text, re.M))
                if warm:
                    metrics["c1_warm_ttft_median_s"] = round(warm[len(warm) // 2] / 1000, 3)
                checks.append(make_check(gr, "warm_ttft_s", None, mode,
                                         unmeasured_reason="needs the C2 voice-turn condition; --floor reports C2=UNMEASURED"
                                         + (f" (C1 warm rounds median {metrics['c1_warm_ttft_median_s']} s, for information)" if warm else "")))
                sg = to_float(floor.get("swap_growth"))
                swap_mb = round(sg / 1e6, 1) if sg is not None else proc.get("swap_growth_mb")
                checks.append(make_check(gr, "swap_growth_mb", swap_mb, mode,
                                         note="" if sg is not None else "app did not report it; the bench script's vm.swapusage samples used"))
                worst, gap = floor.get("pressure_worst_observed"), floor.get("pressure_history_gap") == "true"
                checks.append(make_check(gr, "pressure_worst", None if (gap or not worst or worst == "NA") else worst, mode,
                                         unmeasured_reason="pressure history had a gap or was unavailable" if (gap or not worst or worst == "NA") else None))
        common("speed" if not step.info_only else "speed")
        if step.info_only:
            checks = [c for c in checks if c["guardrail"] not in ("artifact_disk_gb",)]

    checks = [c for c in checks if c]
    contended = contended or bool(run.get("contended_flag"))
    if step.info_only:
        for c in checks:
            if c["result"] in ("pass", "fail"):
                c["result"] = "info"
    return metrics, checks, incomplete, contended, violation


def verdict_for(checks, incomplete, contended, info_only):
    if info_only:
        return "recorded"
    if incomplete:
        return "incomplete"
    gated = [c for c in checks if c["gated"] and c["result"] in ("pass", "fail", "unmeasured")]
    if any(c["result"] == "fail" for c in gated):
        v = "fail"
    elif any(c["result"] == "unmeasured" for c in gated):
        v = "incomplete"
    else:
        v = "pass"
    if contended and v in ("pass", "fail"):
        v = "diagnostic-" + v
    return v


# ---------------------------------------------------------------------------------------
# report


def check_line(c):
    val = "not measured" if c["value"] is None else f"{fmt(c['value'])}"
    thr = "" if c["op"] == "n/a" else f"{c['op']} {c['threshold']}"
    unit = f" {c['unit']}" if c["unit"] else ""
    gate = "gate" if c["gated"] else "info"
    extra = f" ({c['note']})" if c.get("note") else ""
    res = c["result"].upper()
    if c["result"] == "info" and "met" in c:
        res = "MET (not a gate)" if c["met"] else "NOT MET (not a gate)"
    return f"| {c['label']} | {val}{unit} | {thr}{unit if thr else ''} | {gate} | {res}{extra} |"


def failed_text(row):
    parts = []
    for c in row["checks"]:
        if c["gated"] and c["result"] == "fail":
            parts.append(f"{c['label'].split(' (')[0].lower()} {fmt(c['value'])} {c['unit']} (needs {c['op']} {c['threshold']} {c['unit']})".replace("  ", " "))
    return "; ".join(parts)


def unmeasured_text(row):
    return "; ".join(c["label"].split(" (")[0].lower() for c in row["checks"] if c["gated"] and c["result"] == "unmeasured")


def summarise(rows, roles, mode):
    lines = []
    for role in roles:
        rr = [r for r in rows if r["role"] == role]
        if not rr:
            continue
        lines.append(f"### {role}")
        passing = [r["candidate"]["display"] for r in rr if r["verdict"] == "pass"]
        diag = [r["candidate"]["display"] for r in rr if r["verdict"] == "diagnostic-pass"]
        lines.append("- Meets every guardrail: " + (", ".join(passing) if passing else "none.")
                     + (f" Would meet them, but ran under contention so it counts only as a diagnostic: {', '.join(diag)}." if diag else ""))
        for r in rr:
            name, v = r["candidate"]["display"], r["verdict"]
            if v in ("fail", "diagnostic-fail"):
                lines.append(f"- {name} falls short: {failed_text(r)}." + (" Contended run, so treat as a diagnostic." if v.startswith("diagnostic") else ""))
            elif v == "incomplete":
                un = unmeasured_text(r)
                near = [c for c in r["checks"] if c["gated"] and c["result"] == "pass"]
                lines.append(f"- {name} is incomplete: {r['incomplete_reason'] or ('not measured: ' + un)}."
                             + (f" Everything that was measured passes ({len(near)} gate(s))." if not r["incomplete_reason"] and near and not failed_text(r) else ""))
            elif v == "gap":
                lines.append(f"- {name}: cannot be run yet. {r['incomplete_reason']}")
            elif v == "not_applicable":
                lines.append(f"- {name}: not applicable. {r['incomplete_reason']}")
        if role == "notes":
            lines.append("- Notes are checked for structure, size and speed only; their facts are not graded (no SB-07 rubric yet), so read them before trusting a pass.")
        lines.append("")
    one_brain = []
    cands = {}
    for r in rows:
        if r["verdict"] in ("not_applicable", "recorded"):
            continue
        cands.setdefault(r["candidate"]["display"], []).append(r["verdict"])
    for name, vs in cands.items():
        if vs and all(v == "pass" for v in vs) and len(vs) >= len([x for x in roles if x != "speed"]):
            one_brain.append(name)
    lines.append("### One brain for every role")
    lines.append("- " + (", ".join(one_brain) if one_brain else
                 "No candidate passed every role it was run for, so none can be named as the single local model from this report."))
    return lines


def write_report(path_md, path_jsonl, meta, rows, roles, mode, gr_path, gr, plan_commands):
    L = []
    L.append(f"# Model bake-off {meta['date']}")
    L.append("")
    L.append(f"Run `{meta['run_id']}`, {mode} mode, roles: {', '.join(roles)}. Generated by `Scripts/model-bench.py` "
             f"from `{gr_path.relative_to(ROOT) if gr_path.is_relative_to(ROOT) else gr_path}`. "
             "Timeouts, absent models and unmeasured gates are shown as incomplete, never as a score.")
    if meta.get("contended"):
        L.append("")
        L.append(f"**CONTENDED RUN.** Other heavy work was visible ({', '.join(meta['contention']) or 'see conditions'}), so "
                 "nothing here can pass a gate; every row is a diagnostic.")
    L.append("")
    L.append("## Summary")
    L.extend(summarise(rows, roles, mode))
    L.append("")
    L.append("## Matrix")
    L.append("")
    L.append("| Candidate | Role | Verdict | Key numbers | Peak footprint |")
    L.append("|---|---|---|---|---|")
    for r in rows:
        m = r["metrics"]
        key = ", ".join(f"{k} {fmt(v)}" for k, v in m.items()
                        if k in ("score", "failed_assertions", "median_s", "decode_p10", "decode_median", "tok_per_s", "owner_cases")
                        and v is not None)
        pf = r["process"].get("peak_footprint_bytes") if r.get("process") else None
        L.append(f"| {r['candidate']['display']} | {r['label']} | {r['verdict']} | {key or '-'} | {fmt(gb(pf)) + ' GB' if pf else '-'} |")
    L.append("")
    L.append("## Details")
    for r in rows:
        L.append("")
        L.append(f"### {r['candidate']['display']} / {r['label']} : {r['verdict']}")
        if r.get("incomplete_reason"):
            L.append(f"- Why not scored: {r['incomplete_reason']}")
        if r.get("command"):
            L.append(f"- Command: `{r['command']}`")
        if r.get("elapsed_s") is not None:
            L.append(f"- Elapsed {r['elapsed_s']} s, process samples {r['process'].get('samples')}, swap growth {fmt(r['process'].get('swap_growth_mb'))} MB (system-wide), log `{r.get('log')}`")
        if r["checks"]:
            L.append("")
            L.append("| Guardrail | Value | Needs | Kind | Result |")
            L.append("|---|---|---|---|---|")
            L.extend(check_line(c) for c in r["checks"])
    L.append("")
    L.append("## Artifacts")
    L.append("")
    L.append("| Candidate | File | Bytes | SHA-256 | Source of digest |")
    L.append("|---|---|---|---|---|")
    for c in meta["candidates"]:
        L.append(f"| {c['display']} | {c['file'] or 'OS-resident'} | {c['bytes'] or '-'} | {c['sha256'] or 'not recorded (run with --hash)'} | {c['sha256_source'] or '-'} |")
    b = meta["build"]
    L.append("")
    L.append("## Build and conditions")
    L.append("")
    L.append(f"- App: `{b.get('app')}` bundle version {b.get('bundle_version')}, executable sha256 `{b.get('executable_sha256')}`, "
             f"cdhash `{b.get('cdhash')}`, built {b.get('executable_mtime')}; repo HEAD {b.get('source_head')}.")
    found = b.get("flag_strings_found", {})
    L.append("- Flags found in the binary (a miss is not proof of absence for short flags): "
             + ", ".join(f"{k}={'yes' if v else 'not found'}" for k, v in found.items()))
    for key, cond in (("start", meta["conditions_start"]), ("end", meta["conditions_end"])):
        if cond:
            L.append(f"- Machine at {key}: {cond.get('hardware')} {cond.get('chip')}, {cond.get('memory_gb')} GB, macOS {cond.get('macos')}; "
                     f"load {cond.get('load_avg')}, swap used {cond.get('swap_used_mb')} MB, free disk {cond.get('free_disk_gb')} GB, "
                     f"free memory {cond.get('memory_free_pct')}%, power {cond.get('power')}, low power mode {cond.get('low_power_mode')}, "
                     f"thermal: {cond.get('thermal')}; heavy work seen: {', '.join(cond.get('contention') or []) or 'none'}; "
                     f"open apps: {', '.join(cond.get('open_apps') or []) or 'none'}.")
    L.append(f"- Relay gate at start: {json.dumps(meta.get('gate'))}; heavy claim: {meta.get('claim')}.")
    L.append(f"- Isolation: {'UNCHANGED (saved model roles, model library selection, cleanup engine, library.json)' if not meta['isolation_diffs'] else 'VIOLATED: ' + '; '.join(meta['isolation_diffs'])}.")
    L.append(f"- Guardrails file sha256 `{meta['guardrails_sha256']}`.")
    L.append("")
    L.append("## Commands")
    L.append("")
    L.append("```")
    L.extend(plan_commands)
    L.append("```")
    L.append("")
    L.append("## Known gaps in what the self-tests can measure")
    L.append("")
    L.append("- Warm first-token time under a full voice turn (C2) is not produced by `--floor`; PL-01 item 3 is open.")
    L.append("- Notes are checked for structure, size and speed only. There is no factual-quality rubric (SB-07), so read the notes before trusting a notes pass.")
    L.append("- The cleanup comparison knows four file names; other files have no cleanup row.")
    L.append("- Apple Foundation Models has no decode tok/s probe, so it has no speed row.")
    L.append("- Peak footprint is the self-test process only (not the Needle helper or other apps), sampled once a second.")
    path_md.write_text("\n".join(L) + "\n", encoding="utf-8")
    with open(path_jsonl, "w", encoding="utf-8") as fh:
        for r in rows:
            fh.write(json.dumps(r, sort_keys=True) + "\n")


# ---------------------------------------------------------------------------------------
# main


def parse_args(argv):
    ap = argparse.ArgumentParser(description="Local model bake-off over the existing self-tests.",
                                 formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__)
    ap.add_argument("--models", default="all", help="comma list: library id, display name, file name or fragment, 'apple', 's1-mini'; default every installed candidate plus apple")
    ap.add_argument("--roles", default=",".join(ALL_ROLES), help="agent,cleanup,notes,speed (default all four)")
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--quick", action="store_true", help="fast subset: agent --quick, C1 speed without a sustained window (default)")
    g.add_argument("--full", action="store_true", help="full agent run, C0 plus C1 speed with a 10 minute sustained window")
    ap.add_argument("--dry-run", action="store_true", help="print the plan and exact commands; run nothing and write nothing")
    ap.add_argument("--report-dir", help="default Tests/Reports/floor")
    ap.add_argument("--allow-contended", action="store_true", help="run despite a failed gate or visible heavy work; rows become diagnostics")
    ap.add_argument("--hash", action="store_true", help="SHA-256 each selected model file that has no recorded digest (reads GBs)")
    ap.add_argument("--app", default=os.environ.get("NEXTNOTES_APP", DEFAULT_APP), help="app bundle (default $NEXTNOTES_APP or /Applications/Next Notes.app)")
    ap.add_argument("--guardrails", default=str(ROOT / "shared/model-guardrails.json"))
    ap.add_argument("--notes-wav", help="notes fixture (default from the guardrails file)")
    ap.add_argument("--asr-wav", help="C1 speech fixture fed during the speed run")
    ap.add_argument("--with-c0", action="store_true", help="also record the model-alone condition (always on with --full)")
    ap.add_argument("--timeout-scale", type=float, default=1.0)
    ap.add_argument("--as", dest="agent_id", default=f"claude-model-bench-{os.getpid()}", help="agent-relay id for the heavy claim")
    ns = ap.parse_args(argv)
    if ns.full:
        ns.with_c0 = True
    ns.mode = "full" if ns.full else "quick"
    ns.roles_list = [r.strip() for r in ns.roles.split(",") if r.strip()]
    if ns.roles_list == ["all"]:
        ns.roles_list = list(ALL_ROLES)
    bad = [r for r in ns.roles_list if r not in ALL_ROLES]
    if bad:
        ap.error(f"unknown role(s): {', '.join(bad)} (use {', '.join(ALL_ROLES)})")
    return ns


def print_plan(steps, env_prefix):
    print("\nPLAN (sequential; one self-test at a time)")
    n = 0
    for st in steps:
        tag = f"{st.cand['display']} / {st.label}"
        if st.argv is None:
            kind = "N/A " if st.na else "GAP "
            print(f"  [{kind}] {tag}: {st.na or st.gap}")
            continue
        n += 1
        print(f"  [{n:02d}] {tag}  (timeout {st.timeout}s + grace)")
        print(f"       {env_prefix}{quote(st.argv)}")
        for rx, why in st.abort_if:
            print(f"       watch: stops early and records a gap if {why}")
    print(f"\n{n} run(s) planned.")


def main(argv=None):
    ns = parse_args(argv if argv is not None else sys.argv[1:])
    gr_path = Path(ns.guardrails)
    gr = load_guardrails(gr_path)
    cands_all = discover_candidates(gr)
    tokens = [t.strip() for t in ns.models.split(",") if t.strip()]
    cands = select_candidates(cands_all, tokens)
    today = dt.date.today().isoformat()
    report_dir = Path(ns.report_dir) if ns.report_dir else ROOT / "Tests/Reports/floor"
    if not ns.dry_run:
        stem = f"{today}-bakeoff"
        k = 1
        while (report_dir / f"{stem}.md").exists():
            k += 1
            stem = f"{today}-bakeoff-{k}"
    else:
        stem = f"{today}-bakeoff"
    logdir = report_dir / f"{stem}-logs"
    steps = build_plan(cands, ns.roles_list, ns.mode, ns, gr, logdir)
    env = dict(os.environ)
    env_prefix = ""
    if ns.app != DEFAULT_APP:
        env["NEXTNOTES_APP"] = ns.app
        env_prefix = f"NEXTNOTES_APP={shlex.quote(ns.app)} "

    print(f"model-bench: {len(cands)} candidate(s), roles {','.join(ns.roles_list)}, {ns.mode} mode")
    for c in cands:
        size = f"{gb(c['bytes']):.2f} GB" if c["bytes"] else "OS-resident"
        print(f"  - {c['display']}  id={c['id']}  file={c['file']}  {size}  roles={','.join(c['roles'])}")

    if ns.dry_run:
        print_plan(steps, env_prefix)
        print(f"\nReport would be: {report_dir / (stem + '.md')} and .jsonl (logs in {logdir})")
        print("\nPREFLIGHT (read-only probes shown for information; a real run enforces them)")
        gate = relay_gate()
        print(f"  agent-relay gate: ok={gate.get('ok')}  swapGb={gate.get('swapGb')} load={gate.get('load')} freeGb={gate.get('freeGb')}"
              + (f"  reasons={gate.get('reasons')}" if gate.get("reasons") else ""))
        print("  heavy claim: would run `agent-relay claim --as %s --scope machine --gate heavy` and release it on exit" % ns.agent_id)
        cond = conditions_now()
        print(f"  heavy work visible now: {', '.join(cond['contention']) or 'none'}")
        verdict = "would REFUSE (use --allow-contended for a diagnostic run)" if (not gate.get("ok") or cond["contention"]) else "would proceed"
        print(f"  => {verdict}")
        iso = isolation_snapshot(gr)
        print(f"  isolation watch: {len(iso['defaults'])} defaults key(s) + library.json hash recorded before and after every run")
        app = Path(ns.app) / "Contents/MacOS/NextNotes"
        print(f"  app: {ns.app} ({'present' if app.is_file() else 'MISSING'}); runner: {RUN_SELFTEST} "
              f"({'present' if RUN_SELFTEST.is_file() else 'MISSING'})")
        if app.is_file():
            found = app_identity(ns.app)["flag_strings_found"]
            print("  flags found in binary: " + ", ".join(f"{k}={'yes' if v else 'not found*'}" for k, v in found.items()))
            print("  * short Swift string literals are stored inline, so 'not found' does not prove absence;"
                  " a real run detects an ignored flag from the output and records a gap.")
        print("\nGuardrails (shared/model-guardrails.json):")
        for key, g in gr["guardrails"].items():
            if g["op"] == "n/a":
                continue
            print(f"  {'GATE' if g['gated'] else 'info'}  {key:34s} {g['op']} {g['value']} {g.get('unit', '')}  [{', '.join(g['roles'])}] {g.get('status', '')}")
        return 0

    # ---------------------------------------------------------------- real run
    if not (Path(ns.app) / "Contents/MacOS/NextNotes").is_file():
        print(f"model-bench: app not found: {ns.app}", file=sys.stderr)
        return 2
    if not RUN_SELFTEST.is_file():
        print(f"model-bench: missing {RUN_SELFTEST}", file=sys.stderr)
        return 2
    gate = relay_gate()
    cond_start = conditions_now()
    contended = False
    if not gate.get("ok") or cond_start["contention"]:
        why = (gate.get("reasons") or []) + ([f"heavy work visible: {', '.join(cond_start['contention'])}"] if cond_start["contention"] else [])
        if not ns.allow_contended:
            print("model-bench: refusing to start: " + "; ".join(why) + "\n(use --allow-contended for a diagnostic run)", file=sys.stderr)
            return 3
        contended = True
    claim = Claim(ns.agent_id)
    claim_text = "skipped (--allow-contended)"
    if not ns.allow_contended:
        held, note = claim.acquire()
        claim_text = "held" if held else f"NOT obtained: {note}"
        if not held:
            print(f"model-bench: could not obtain the machine heavy claim: {note}", file=sys.stderr)
            return 3
    else:
        claim_text = "not requested (--allow-contended); rows are diagnostics"

    def on_signal(signum, _frame):
        raise Interrupted(signum)

    for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, on_signal)

    run_id = f"{today}-{dt.datetime.now().strftime('%H%M%S')}-{os.getpid()}"
    report_dir.mkdir(parents=True, exist_ok=True)
    logdir.mkdir(parents=True, exist_ok=True)
    build = app_identity(ns.app)
    iso_before = isolation_snapshot(gr)
    guardrails_sha = hashlib.sha256(gr_path.read_bytes()).hexdigest()
    if ns.hash:
        for c in cands:
            if c["file"] and not c["sha256"] and (MODELS_DIR / c["file"]).is_file():
                print(f"model-bench: hashing {c['file']} ...", flush=True)
                c["sha256"], c["sha256_source"] = sha256_file(MODELS_DIR / c["file"]), "computed by --hash"
    meta = {"date": today, "run_id": run_id, "build": build, "candidates": cands, "conditions_start": cond_start,
            "conditions_end": None, "gate": gate, "claim": claim_text, "contended": contended,
            "contention": cond_start["contention"], "isolation_diffs": [], "guardrails_sha256": guardrails_sha}
    rows, exit_code = [], 0
    md, jsonl = report_dir / f"{stem}.md", report_dir / f"{stem}.jsonl"
    plan_commands = [env_prefix + quote(st.argv) for st in steps if st.argv]

    def base_row(st):
        return {"run_id": run_id, "date": today, "candidate": {k: st.cand[k] for k in ("id", "display", "file", "bytes", "sha256", "sha256_source", "kind")},
                "role": "speed" if st.role.startswith("speed") else st.role, "label": st.label, "mode": ns.mode,
                "build": {k: build.get(k) for k in ("bundle_version", "cdhash", "executable_sha256", "source_head")},
                "command": env_prefix + quote(st.argv) if st.argv else None, "conditions_start": cond_start,
                "checks": [], "metrics": {}, "process": {}, "incomplete_reason": None, "contended": contended}

    try:
        for st in steps:
            row = base_row(st)
            if st.argv is None:
                row.update(verdict="not_applicable" if st.na else "gap", incomplete_reason=st.na or st.gap)
                rows.append(row)
                continue
            print(f"model-bench: [{st.cand['display']} / {st.label}] starting ({st.timeout}s budget)", flush=True)
            before = isolation_snapshot(gr)
            run = run_step(st, gr, env)
            after = isolation_snapshot(gr)
            run["contended_flag"] = contended
            if run["status"] == "gap":
                row.update(verdict="gap", incomplete_reason=run["reason"], process=run["process"], elapsed_s=run["elapsed_s"], log=run["log"])
            else:
                metrics, checks, incomplete, was_contended, violation = evaluate(st, run, gr, ns.mode)
                row.update(metrics=metrics, checks=checks, incomplete_reason=incomplete, contended=was_contended,
                           process=run["process"], elapsed_s=run["elapsed_s"], log=run["log"], exit_code=run["exit_code"],
                           run_status=run["status"])
                row["verdict"] = verdict_for(checks, incomplete, was_contended, st.info_only)
                if violation:
                    meta["isolation_diffs"].append(f"{st.cand['display']}/{st.label}: the self-test itself reported that the run changed owner state")
            diffs = snapshot_diff(before, after)
            if diffs:
                meta["isolation_diffs"] += [f"{st.cand['display']}/{st.label}: {d}" for d in diffs]
            rows.append(row)
            print(f"model-bench:   -> {row['verdict']}" + (f" ({row['incomplete_reason']})" if row.get("incomplete_reason") else ""), flush=True)
            if meta["isolation_diffs"]:
                print("model-bench: ISOLATION VIOLATED, stopping the matrix: " + "; ".join(meta["isolation_diffs"]), file=sys.stderr)
                exit_code = 4
                break
    except Interrupted as exc:
        proc = CURRENT.get("proc")
        if proc is not None and proc.poll() is None:
            _terminate(proc)
        print(f"model-bench: interrupted (signal {exc.args[0]}); writing what finished", file=sys.stderr)
        exit_code = 130
    finally:
        meta["conditions_end"] = conditions_now()
        final = snapshot_diff(iso_before, isolation_snapshot(gr))
        for d in final:
            if not any(d in x for x in meta["isolation_diffs"]):
                meta["isolation_diffs"].append(f"end of run: {d}")
        if meta["isolation_diffs"] and exit_code == 0:
            exit_code = 4
        if rows:
            write_report(md, jsonl, meta, rows, ns.roles_list, ns.mode, gr_path, gr, plan_commands)
            print(f"model-bench: report {md}\nmodel-bench: rows   {jsonl}")
        claim.release()
    return exit_code


if __name__ == "__main__":
    sys.exit(main())

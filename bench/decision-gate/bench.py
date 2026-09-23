#!/usr/bin/env python3
"""
Decision-gate benchmark: laya vs Needle (Cactus) on the System-One sub-task the
Next Notes function-calling watcher actually needs a small model for.

Neither model is being asked to do the other's job. The point of this harness is
stated in README.md: the six "System One" alternatives are typed-decision models,
not function-calling models, so they cannot replace Needle's argument extraction.
What they CAN do is the decision gate -- "is this an actionable request?" and
"which catalogue tool (or none)?". This scores exactly that gate, on the app's own
fixtures and the app's own 8-tool catalogue, and puts Needle beside it as the
function-calling reference (Needle answers the same gate by whether it emits a
call, and is the only one of the two that also extracts arguments).

Measurements, identical for both backends:
  size      download bytes + parameters
  speed     per-decision wall clock (Needle's includes process launch + model
            load, exactly as the app measures it; laya's excludes a one-time load)
  memory    peak RSS
  accuracy  exact-tool, family, and is-request agreement with the gold labels

Run:
    python bench.py                       # both backends
    python bench.py --backends laya       # laya only
    python bench.py --backends needle     # Needle only
    python bench.py --laya-checkpoint multilingual|english|typed-decisions

Writes results.json and report.md next to this file. A backend that cannot load
(model absent, wrong hardware, import error) is recorded as status="absent" with
the reason, and the report says so plainly rather than passing it silently.
"""
from __future__ import annotations

import argparse
import json
import os
import resource
import statistics
import subprocess
import sys
import tempfile
import time
from datetime import date
from pathlib import Path

HERE = Path(__file__).resolve().parent

# laya checkpoints: id -> (subfolder, params, note). multilingual is the smallest.
LAYA_CHECKPOINTS = {
    "multilingual": ("multilingual", "322M", "mmBERT-base, 1024 ctx, smallest & fastest"),
    "english": ("", "421M", "ModernBERT-large, 512 ctx, English"),
    "typed-decisions": ("typed-decisions", "421M", "ModernBERT-large fine-tuned on typed decisions"),
}

# Needle, as the app ships it (NeedleEngine.swift). 121M params at ~2 bits.
NEEDLE_ENGINE_NAME = "needle3-macos-arm64"
NEEDLE_WEIGHTS_NAME = "needle3.cact"
NEEDLE_PARAMS = "121M"


# --------------------------------------------------------------------------- #
# loading
# --------------------------------------------------------------------------- #
def load_catalogue():
    cat = json.loads((HERE / "catalogue.json").read_text())
    return cat


def load_fixtures():
    data = json.loads((HERE / "fixtures.json").read_text())
    out = []
    fam = {}
    cat = load_catalogue()
    for t in cat["tools"]:
        fam[t["id"]] = t["family"]
    fam[cat["abstention"]["id"]] = "none"
    fam["none"] = "none"
    for f in data["fixtures"]:
        gold = f["gold_tool"]
        out.append({
            "name": f["name"],
            "utterance": f["utterance"],
            "window": f.get("window", ""),
            "gold_tool": gold,
            "gold_family": fam.get(gold, "none"),
            "gold_is_request": gold != "none",
        })
    return out


def needle_dir() -> Path:
    return Path.home() / "Library" / "Application Support" / "Next Notes" / "Models"


def needle_size_bytes() -> int:
    d = needle_dir()
    total = 0
    for n in (NEEDLE_ENGINE_NAME, NEEDLE_WEIGHTS_NAME):
        p = d / n
        if p.exists():
            total += p.stat().st_size
    return total


def laya_weight_bytes(subfolder: str) -> int:
    """Resolve the multilingual/english safetensors out of the HF cache, following
    the xet symlink to the real blob, so the number is the actual download size."""
    hub = Path.home() / ".cache" / "huggingface" / "hub"
    repo = hub / "models--convaiinnovations--laya"
    if not repo.exists():
        return 0
    best = 0
    for st in repo.glob("snapshots/*"):
        cand = st / subfolder / "model.safetensors" if subfolder else st / "model.safetensors"
        if cand.exists():
            best = max(best, cand.resolve().stat().st_size)
    return best


# --------------------------------------------------------------------------- #
# scoring
# --------------------------------------------------------------------------- #
def score(rows, fixtures):
    n = len(rows)
    if n == 0:
        return {}
    exact = sum(r["pred_tool"] == f["gold_tool"] for r, f in zip(rows, fixtures))
    fam = sum(r["pred_family"] == f["gold_family"] for r, f in zip(rows, fixtures))
    isreq = sum(r["pred_is_request"] == f["gold_is_request"] for r, f in zip(rows, fixtures))
    # silence on the 'none' fixtures is the safety-critical half
    none_rows = [(r, f) for r, f in zip(rows, fixtures) if f["gold_tool"] == "none"]
    silence = sum(r["pred_tool"] == "none" for r, _ in none_rows)
    req_rows = [(r, f) for r, f in zip(rows, fixtures) if f["gold_tool"] != "none"]
    fired = sum(r["pred_tool"] != "none" for r, _ in req_rows)
    lat = [r["latency_ms"] for r in rows]
    return {
        "n": n,
        "exact_tool_acc": round(exact / n, 3),
        "family_acc": round(fam / n, 3),
        "is_request_acc": round(isreq / n, 3),
        "silence_on_none": f"{silence}/{len(none_rows)}",
        "fired_on_request": f"{fired}/{len(req_rows)}",
        "latency_ms": {
            "p50": round(statistics.median(lat), 1),
            "mean": round(statistics.mean(lat), 1),
            "min": round(min(lat), 1),
            "max": round(max(lat), 1),
        },
    }


def fam_of(tool, cat):
    if tool == "none":
        return "none"
    for t in cat["tools"]:
        if t["id"] == tool:
            return t["family"]
    if tool == cat["abstention"]["id"]:
        return "none"
    return "other"


# --------------------------------------------------------------------------- #
# laya backend
# --------------------------------------------------------------------------- #
def run_laya(fixtures, cat, checkpoint):
    subfolder, params, note = LAYA_CHECKPOINTS[checkpoint]
    res = {
        "backend": "laya",
        "checkpoint": checkpoint,
        "detail": f"convaiinnovations/laya{'/' + subfolder if subfolder else ''} · {note}",
        "status": "ok",
    }
    try:
        import laya  # noqa
    except Exception as e:
        res.update(status="absent", reason=f"import failed: {e}", rows=[], metrics={})
        return res

    questions = {
        "is_request": {
            "type": "noul",
            "instructions": (
                "Is this an actionable request the app should perform itself: send an "
                "email, create a calendar event, or write/append to a document? Answer "
                "no for ordinary conversation, for a question, and for a command to a "
                "computer, browser, folder or media player."
            ),
        },
        "tool": {
            "type": "choice",
            "instructions": "Which single action should the app take? Choose none if it should do nothing.",
            "criteria": {t["id"]: t["criteria"] for t in cat["tools"]} | {"none": cat["abstention"]["description"]},
        },
    }

    t0 = time.time()
    try:
        agent = laya.load("convaiinnovations/laya", subfolder=subfolder) if subfolder \
            else laya.load("convaiinnovations/laya")
    except Exception as e:
        res.update(status="absent", reason=f"load failed: {e}", rows=[], metrics={})
        return res
    load_s = time.time() - t0

    # one throwaway call so the first timed row isn't paying graph warmup
    try:
        agent.predict({"text": "warmup"}, questions)
    except Exception as e:
        res.update(status="absent", reason=f"predict failed: {e}", rows=[], metrics={})
        return res

    rows = []
    for f in fixtures:
        state = {"utterance": f["utterance"]}
        if f["window"]:
            state = {"context": f["window"], "utterance": f["utterance"]}
        t0 = time.time()
        try:
            out = agent.predict(state, questions)
        except Exception as e:
            rows.append({"name": f["name"], "pred_tool": "none", "pred_family": "none",
                         "pred_is_request": False, "confidence": 0.0, "noul": 0.0,
                         "latency_ms": (time.time() - t0) * 1000, "error": str(e)})
            continue
        dt = (time.time() - t0) * 1000
        a = out["answers"]
        tool = a["tool"]["choice"]
        if tool == "none" or tool == cat["abstention"]["id"]:
            tool = "none"
        noul = float(a["is_request"]["noul"])
        rows.append({
            "name": f["name"],
            "pred_tool": tool,
            "pred_family": fam_of(tool, cat),
            "pred_is_request": noul >= 0.5,
            "confidence": round(float(a["tool"].get("confidence", 0.0)), 3),
            "noul": round(noul, 3),
            "latency_ms": dt,
        })

    rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss  # bytes on macOS
    res.update(
        rows=rows,
        metrics=score(rows, fixtures),
        size={"weight_bytes": laya_weight_bytes(subfolder), "params": params},
        load_seconds=round(load_s, 1),
        peak_rss_mb=round(rss / 1_048_576, 1),
    )
    return res


# --------------------------------------------------------------------------- #
# needle backend
# --------------------------------------------------------------------------- #
def needle_tools_json(cat):
    """The app declares the 8 catalogue tools plus the parameterless no_action
    abstention tool (FunctionCallRelevance.wireTools)."""
    tools = []
    for t in cat["tools"]:
        props = {p["name"]: {"type": "string", "description": p["description"]} for p in t["parameters"]}
        req = [p["name"] for p in t["parameters"] if p.get("required")]
        tools.append({
            "name": t["id"],
            "description": t["description"],
            "parameters": {"type": "object", "properties": props, "required": req},
        })
    ab = cat["abstention"]
    tools.append({
        "name": ab["id"],
        "description": ab["description"],
        "parameters": {"type": "object", "properties": {}, "required": []},
    })
    return tools


def run_needle(fixtures, cat):
    res = {"backend": "needle", "detail": "Needle 3 (Cactus Compute) · 121M @ ~2bit · CLI child process", "status": "ok"}
    d = needle_dir()
    engine = d / NEEDLE_ENGINE_NAME
    weights = d / NEEDLE_WEIGHTS_NAME
    if not engine.exists() or not weights.exists():
        res.update(status="absent",
                   reason=f"engine or weights not downloaded (looked in {d})",
                   rows=[], metrics={})
        return res
    if sys.platform != "darwin" or os.uname().machine != "arm64":
        res.update(status="absent", reason="Needle 3 ships a macos-arm64 runner only", rows=[], metrics={})
        return res

    tools = needle_tools_json(cat)
    tmp = Path(tempfile.mkdtemp(prefix="needle-bench-"))
    tools_file = tmp / "tools.json"
    tools_file.write_text(json.dumps(tools))
    sys_file = tmp / "system.txt"
    sys_file.write_text(f"Today is {date.today().isoformat()}.")

    def prompt_for(f):
        if f["window"]:
            return f"Earlier:\n{f['window']}\n\nJust said: {f['utterance']}"
        return f["utterance"]

    rows = []
    for f in fixtures:
        cmd = [str(engine), "--model", str(weights), "--tools", str(tools_file),
               "--system", str(sys_file), "--max", "512", "--prompt", prompt_for(f)]
        env = {"PATH": "/usr/bin:/bin", "NO_COLOR": "1", "LC_ALL": "C"}
        t0 = time.time()
        try:
            proc = subprocess.run(cmd, capture_output=True, text=True, timeout=60, env=env)
        except subprocess.TimeoutExpired:
            rows.append({"name": f["name"], "pred_tool": "none", "pred_family": "none",
                         "pred_is_request": False, "confidence": 0.0, "latency_ms": 60000.0,
                         "error": "timeout"})
            continue
        dt = (time.time() - t0) * 1000
        tool, conf, err = "none", 0.0, None
        if proc.returncode != 0:
            err = (proc.stderr.strip().splitlines() or [f"exit {proc.returncode}"])[0]
        else:
            line = None
            for ln in proc.stdout.splitlines():
                if ln.strip().startswith("{"):
                    line = ln
            if line:
                try:
                    obj = json.loads(line)
                    conf = float(obj.get("confidence") or 0.0)
                    calls = obj.get("function_calls") or []
                    neg = (obj.get("validation") or {}).get("negation", False)
                    if calls and not neg:
                        nm = calls[0].get("name", "none")
                        tool = "none" if nm == cat["abstention"]["id"] else nm
                except Exception as e:
                    err = f"parse: {e}"
            else:
                err = "no JSON on stdout"
        rows.append({
            "name": f["name"],
            "pred_tool": tool,
            "pred_family": fam_of(tool, cat),
            "pred_is_request": tool != "none",
            "confidence": round(conf, 3),
            "latency_ms": dt,
            **({"error": err} if err else {}),
        })

    child_rss = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss  # bytes on macOS
    res.update(
        rows=rows,
        metrics=score(rows, fixtures),
        size={"weight_bytes": needle_size_bytes(), "params": NEEDLE_PARAMS},
        peak_rss_mb=round(child_rss / 1_048_576, 1),
    )
    return res


# --------------------------------------------------------------------------- #
# report
# --------------------------------------------------------------------------- #
# Published figures for the candidates that cannot run on this machine (no CUDA,
# and/or won't fit beside a 19 GB free disk). Sources: each project's own README
# or Hugging Face model card, read 2026-09-22. NOT measured here.
PUBLISHED = [
    {"name": "NanoJev", "kind": "decision heads (Qwen3-0.6B)", "params": "0.6B",
     "size": "~1.2 GB bf16", "speed": "parallel; CUDA service", "acc": "ViZDoom Basic 128/128 (game tasks)",
     "why": "CUDA service only (serve_decisions.py); game/RL oriented, not text-tool gating", "run": False},
    {"name": "SemIf (ex-OpenJev)", "kind": "typed logits (Qwen3.5-4B)", "params": "4B",
     "size": "3.01 GB Q4 GGUF / ~8 GB bf16", "speed": "1.02 s for 21 decisions (RTX 3090); MPS ~133 ms-ish path exists",
     "acc": "authored decisions 0.813 bal-acc (4B BF16)", "why": "4B; MPS path exists but heavy for 19 GB disk", "run": False},
    {"name": "decider (Mapika)", "kind": "typed decisions (Qwen3.5)", "params": "2B / 4B / 35B",
     "size": "2B ~4 GB, 4B 8.4 GB, 35B 65 GB", "speed": "2B 133 ms MPS (M1 Pro); 43 ms B300",
     "acc": "held-out 0.755 (2B) / 0.788 (4B) regression set", "why": "2B has an MPS path but was out of the requested download budget", "run": False},
    {"name": "openjev", "kind": "NLI cross-encoder (Qwen3.5)", "params": "0.8B / 4B / 35B",
     "size": "0.8B ~1.6 GB … 35B MoE", "speed": "321 pairs/s SGLang (A6000)", "acc": "MNLI 86.6, ANLI r1 65.3 (0.8B)",
     "why": "NLI primitive, CUDA/SGLang oriented; not a tool gate", "run": False},
    {"name": "Bespoke-Nimble-9B", "kind": "LoRA over Qwen3.5-9B", "params": "9B (+165 MB adapter)",
     "size": "~18 GB base + adapter", "speed": "CUDA BF16 only", "acc": "Bespoke suite 0.757 (decider's re-run)",
     "why": "needs CUDA + the 9B base; won't fit on this disk", "run": False},
]


def fmt_size(b):
    if not b:
        return "n/a"
    if b >= 1_000_000_000:
        return f"{b/1_000_000_000:.2f} GB"
    return f"{b/1_000_000:.0f} MB"


def label(r):
    b = r.get("backend", "?")
    return f"laya-{r['checkpoint']}" if b == "laya" and r.get("checkpoint") else b


def render_report(results, fixtures, machine):
    L = []
    L.append("# Decision-gate benchmark: laya vs Needle (Cactus)\n")
    L.append(f"_Generated {date.today().isoformat()} on {machine}. "
             f"{len(fixtures)} fixtures from `FunctionCallSelfTest`, 8-tool catalogue "
             "from `FunctionCallCatalogue`._\n")
    L.append("> **Scope.** The six \"System One\" candidates are typed-decision models, not "
             "function-calling models. None can emit `to: \"sarah@acme.com\"`. This harness "
             "scores only the gate they *can* do -- is-it-a-request and which-tool -- and keeps "
             "Needle beside them as the function-calling reference. Argument extraction is "
             "Needle's job and is not compared here.\n")

    ran = [r for r in results if r.get("status") == "ok"]
    absent = [r for r in results if r.get("status") != "ok"]

    L.append("## Measured here\n")
    if not ran:
        L.append("_No backend could run._\n")
    else:
        L.append("| backend | params | weights | load | p50 latency | mean | peak RSS | exact-tool | family | is-request | silence on none | fired on request |")
        L.append("|---|---|---|---|---|---|---|---|---|---|---|---|")
        for r in ran:
            m = r["metrics"]; sz = r.get("size", {}); lat = m["latency_ms"]
            L.append(
                f"| {label(r)} | {sz.get('params','?')} | "
                f"{fmt_size(sz.get('weight_bytes',0))} | {r.get('load_seconds','-')}s | "
                f"{lat['p50']} ms | {lat['mean']} ms | {r.get('peak_rss_mb','?')} MB | "
                f"{m['exact_tool_acc']} | {m['family_acc']} | {m['is_request_acc']} | "
                f"{m['silence_on_none']} | {m['fired_on_request']} |"
            )
        L.append("")
        L.append("Needle's latency includes process launch + model load on every row, because "
                 "that is how the app runs it (one child process per proposal); laya's excludes "
                 "its one-time load, shown separately. The two are not the same measurement -- "
                 "see README. laya's peak RSS is the whole Python/torch runtime; when several "
                 "laya checkpoints run in one process it is a shared high-water mark, so read "
                 "the laya rows as one number.\n")

        # per-fixture grid
        L.append("### Per-fixture decisions\n")
        header = "| fixture | gold | " + " | ".join(label(r) for r in ran) + " |"
        L.append(header)
        L.append("|---|---|" + "---|" * len(ran))
        for i, f in enumerate(fixtures):
            cells = []
            for r in ran:
                row = r["rows"][i]
                mark = "✓" if row["pred_tool"] == f["gold_tool"] else "✗"
                extra = f" (noul {row['noul']})" if "noul" in row else f" (conf {row['confidence']})"
                cells.append(f"{mark} {row['pred_tool']}{extra}")
            L.append(f"| {f['name']} | `{f['gold_tool']}` | " + " | ".join(cells) + " |")
        L.append("")

    if absent:
        L.append("## Could not run here\n")
        for r in absent:
            L.append(f"- **{label(r)}**: {r.get('reason','absent')}")
        L.append("")

    L.append("## The other candidates (published, not measured here)\n")
    L.append("These need CUDA and/or won't fit beside a ~19 GB free disk, so they are reported "
             "from their own READMEs/model cards, read 2026-09-22. **Not run on this machine.**\n")
    L.append("| model | class | params | size | speed (published) | accuracy (published) | why not run |")
    L.append("|---|---|---|---|---|---|---|")
    for p in PUBLISHED:
        L.append(f"| {p['name']} | {p['kind']} | {p['params']} | {p['size']} | {p['speed']} | {p['acc']} | {p['why']} |")
    L.append("")
    return "\n".join(L)


def machine_description():
    try:
        chip = subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"],
                              capture_output=True, text=True).stdout.strip()
    except Exception:
        chip = "unknown"
    cores = os.cpu_count()
    try:
        total = int(subprocess.run(["sysctl", "-n", "hw.memsize"], capture_output=True, text=True).stdout.strip())
        ram_gb = total // 1_073_741_824
    except Exception:
        ram_gb = "?"
    return f"{chip} · {cores} cores · {ram_gb} GB"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--backends", default="laya,needle")
    ap.add_argument("--laya-checkpoint", "--laya-checkpoints", dest="laya_checkpoints",
                    default="multilingual",
                    help="comma-separated: multilingual,english,typed-decisions")
    args = ap.parse_args()

    cat = load_catalogue()
    fixtures = load_fixtures()
    backends = [b.strip() for b in args.backends.split(",") if b.strip()]
    laya_ckpts = [c.strip() for c in args.laya_checkpoints.split(",") if c.strip()]
    for c in laya_ckpts:
        if c not in LAYA_CHECKPOINTS:
            ap.error(f"unknown laya checkpoint {c!r}; choose from {list(LAYA_CHECKPOINTS)}")

    results = []
    for b in backends:
        if b == "laya":
            for ckpt in laya_ckpts:
                print(f"▸ laya-{ckpt} …", flush=True)
                results.append(run_laya(fixtures, cat, ckpt))
                _print_result(results[-1])
        elif b == "needle":
            print("▸ needle …", flush=True)
            results.append(run_needle(fixtures, cat))
            _print_result(results[-1])
        else:
            results.append({"backend": b, "status": "absent", "reason": "unknown backend"})
            _print_result(results[-1])

    (HERE / "results.json").write_text(json.dumps(
        {"machine": machine_description(), "results": results}, indent=2))
    report = render_report(results, fixtures, machine_description())
    (HERE / "report.md").write_text(report)
    print("\nwrote results.json and report.md")


def _print_result(r):
    if r.get("status") == "ok":
        m = r["metrics"]
        print(f"   exact {m['exact_tool_acc']}  family {m['family_acc']}  "
              f"is-req {m['is_request_acc']}  p50 {m['latency_ms']['p50']} ms  "
              f"size {fmt_size(r.get('size',{}).get('weight_bytes',0))}", flush=True)
    else:
        print(f"   ABSENT: {r.get('reason')}", flush=True)


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Authorized serial native runner; never builds/installs. Original and fixed fixtures must match.
Do not invoke until root grants native slot and the task-harness reader repair passes.
"""
import argparse, hashlib, json, os, re, signal, subprocess, time
from pathlib import Path
ROOT = Path(__file__).resolve().parents[5]
REPORT = Path(__file__).resolve().parent
APP = Path("/Applications/Next Notes.app")
TRANSPORT = "Sources/NextNotes/Agent/Backend/JSONRPCStdioClient.swift"
FIXTURE = "Sources/NextNotes/Agent/Backend/ACPStdioTerminationSelfTest.swift"

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def source_manifest():
    files = [p for folder in ("Sources", "Resources") for p in (ROOT/folder).rglob("*") if p.is_file()]
    files += [ROOT/p for p in ("Makefile", "Package.swift", "Package.resolved", "Scripts/run-selftest.sh", "Scripts/with-install-lock.sh") if (ROOT/p).is_file()]
    return {str(p.relative_to(ROOT)): sha(p) for p in sorted(files)}

def bundle_manifest():
    return {str(p.relative_to(APP)): sha(p) for p in sorted(APP.rglob("*")) if p.is_file()}

def dump(path, data):
    path.write_text(json.dumps(data, indent=2) + "\n")

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("original", "fixed"))
    parser.add_argument("--label", required=True)
    args = parser.parse_args()
    if not re.fullmatch(r"app[0-9]+", args.label):
        parser.error("label must be app plus build number")
    out = REPORT / (args.label + "-" + args.mode)
    out.mkdir(exist_ok=False)
    before = source_manifest()
    bundle_before = bundle_manifest()
    dump(out/"sources-before.json", before)
    dump(out/"bundle-before.json", bundle_before)
    # Never silently substitute a changed regression in the fixed run.
    if args.mode == "fixed":
        originals = sorted(REPORT.glob("app*-original/sources-before.json"), key=lambda p:p.stat().st_mtime_ns)
        if not originals or json.loads(originals[-1].read_text())[FIXTURE] != before[FIXTURE]:
            raise RuntimeError("No exact matching original fixture proof")
    verdicts = []
    flags = ["acp"] if args.mode == "original" else ["acp", "mcp", "acp-confirm", "task-worker-attempt", "store-isolation"]
    for flag in flags:
        cmd = [str(ROOT/"Scripts/run-selftest.sh"), "--out", str(out/(flag+".log")), "--selftest-"+flag]
        started = time.monotonic()
        timed_out = False
        with (out/(flag+".stdout")).open("wb") as stdout:
            process = subprocess.Popen(cmd, cwd=ROOT, stdout=stdout, stderr=subprocess.STDOUT, start_new_session=True)
            try:
                exit_code = process.wait(timeout=240)
            except subprocess.TimeoutExpired:
                # This session/group belongs entirely to this driver, including its fixture peers.
                timed_out = True
                os.killpg(process.pid, signal.SIGTERM)
                try: exit_code = process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    exit_code = process.wait(timeout=5)
        log = out/(flag+".log")
        contents = (log.read_text(errors="replace") if log.exists() else "") + "\n" + (out/(flag+".stdout")).read_text(errors="replace")
        markers = list(dict.fromkeys(line for line in contents.splitlines() if re.match(r"^[A-Z0-9_]+_(OK|FAILED|TIMEOUT)(:|$)", line)))
        if args.mode == "original":
            accepted = (not timed_out and exit_code == 1 and "ACP_FAILED: 1 rule(s) wrong" in contents
                and "ACP terminal: consumed prompt/peer EOF stayed pending until timeout or external close" in contents)
        else:
            expected = {"acp":"ACP_OK", "mcp":"MCP_OK", "acp-confirm":"ACP_CONFIRM_OK", "task-worker-attempt":"TASK_WORKER_ATTEMPT_OK: 531 cases", "store-isolation":"STORE_ISOLATION_OK"}[flag]
            accepted = (not timed_out and exit_code == 0 and expected in contents and not any("_FAILED" in m for m in markers))
        row = {"flag":flag,"command":cmd,"ownedPID":process.pid,"exit":exit_code,"seconds":round(time.monotonic()-started,3),"timedOut":timed_out,"markers":markers,"expectedVerdict":accepted}
        verdicts.append(row)
        dump(out/"verdicts.json",verdicts)
        print(json.dumps(row), flush=True)
        if not accepted: break
    after = source_manifest()
    bundle_after = bundle_manifest()
    dump(out/"sources-after.json",after)
    dump(out/"bundle-after.json",bundle_after)
    changes = [p for p in sorted(set(before)|set(after)) if before.get(p)!=after.get(p)]
    dump(out/"invariance.json",{"sourceChanges":changes,"installedBundleUnchanged":bundle_after==bundle_before,"allDriverAppProcessesReaped":True, "fixtureChildProcessCleanup":"requires post-run inventory; not inferred from app exit"})
    evidence = {str(p.relative_to(out)):sha(p) for p in sorted(out.rglob("*")) if p.is_file()}
    dump(out/"evidence-manifest.json",evidence)
    good = len(verdicts)==len(flags) and all(v["expectedVerdict"] for v in verdicts) and not changes and bundle_after==bundle_before
    raise SystemExit(0 if good else 1)

if __name__ == "__main__": main()

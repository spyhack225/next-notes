#!/usr/bin/env python3
"""Archive root-supplied completed installed evidence; never runs an app or test."""
import argparse, hashlib, json, re, shutil
from pathlib import Path
parser = argparse.ArgumentParser()
parser.add_argument("--build", type=int, required=True)
args = parser.parse_args()
base = Path(__file__).resolve().parent
repo = base.parents[3]
source_manifest = Path(f"/private/tmp/nextnotes-agent-closure-build{args.build}-source-manifest.json")
checks = Path(f"/private/tmp/nextnotes-agent-closure-checks-{args.build}")
manifest = json.loads(source_manifest.read_text())
assert manifest["phase"] == "installed", "No installed source/binary pin"
summary = json.loads((checks / "summary.json").read_text())
worker = next(row for row in summary if row["flag"] == "task-worker-attempt")
assert worker["marker"] != "ABSENT", "No worker verdict"
archive = base / f"current-app{args.build}"
archive.mkdir(exist_ok=True)
files = []
absent = []
def retain(source, name=None):
    if not source.exists():
        absent.append(str(source))
        return
    target = archive / (name or source.name)
    shutil.copyfile(source, target)
    files.append({"source": str(source), "archive": str(target.relative_to(base)),
                  "sha256": hashlib.sha256(target.read_bytes()).hexdigest(), "bytes": target.stat().st_size})
retain(source_manifest)
retain(Path(f"/private/tmp/nextnotes-agent-closure-install-{args.build}.log"))
retain(checks / "summary.json")
for row in summary:
    for suffix in ["out", "log"]:
        retain(checks / ("selftest-" + row["flag"] + "." + suffix))
for path in json.loads((base / "candidate-worker-manifest.json").read_text())["files"]:
    source = repo / path
    assert hashlib.sha256(source.read_bytes()).hexdigest() == manifest["sources"][path], "Source moved since installed pin: " + path
    retain(source, "installed-" + source.name + ".txt")
for path in ["Sources/NextNotes/Agent/Tasks/Durable/TaskWorkerAttemptSelfTest.swift", "Sources/NextNotes/NextNotesApp.swift"]:
    source = repo / path
    assert hashlib.sha256(source.read_bytes()).hexdigest() == manifest["sources"][path], "Registered source moved: " + path
    retain(source, "installed-" + source.name + ".txt")
count = re.search(r"TASK_WORKER_ATTEMPT_OK: (\d+) cases", worker["marker"])
result = {"status": "actual completed installed evidence supplied by root", "build": args.build,
          "binary_sha256": manifest["installedBinarySHA256"], "worker": worker,
          "actual_worker_cases": int(count.group(1)) if count else None,
          "checks": summary, "files": files, "absent_companions": absent,
          "limits": "No process-crash/power-loss/heartbeat/retry/receipt join/IM16 or rendered UI proof. Quick aggregate separately pending unless supplied."}
(base / f"current-app{args.build}-evidence-manifest.json").write_text(json.dumps(result, indent=2) + "\n")
print(json.dumps({"build": args.build, "worker": worker, "actual_worker_cases": result["actual_worker_cases"], "archived_files": len(files)}))

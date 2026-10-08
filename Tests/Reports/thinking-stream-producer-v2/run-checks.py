#!/usr/bin/env python3
"""Run only inside ../heavy.sh; serial native checks, with retained exact verdicts."""
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

phase = sys.argv[1]
assert phase in ("red", "green")
report = Path(__file__).resolve().parent
repo = report.parents[2]
binary = Path.home() / "Library/Caches/NextNotesBuild/wt-scratch/thinking-review/debug/NextNotes"
assert (repo / "Sources/NextNotes/Formatting/LLM/ChatTemplateSelfTest.swift").read_bytes() == (report / "ChatTemplateSelfTest-v2.swift.fixture").read_bytes()
producer = repo / "Sources/NextNotes/Formatting/LLM/ChatTemplate.swift"
pins = json.loads((report / "source-pins.json").read_text())
if phase == "red":
    assert hashlib.sha256(producer.read_bytes()).hexdigest() == pins["redProducerSHA256"]
flags = ["chat-template"] if phase == "red" else [
    "chat-template", "notes-truncation", "llm-prefix-cache", "store-isolation"
]
summary = {
    "phase": phase,
    "binarySHA256": hashlib.sha256(binary.read_bytes()).hexdigest(),
    "fixtureSHA256": hashlib.sha256((repo / "Sources/NextNotes/Formatting/LLM/ChatTemplateSelfTest.swift").read_bytes()).hexdigest(),
    "producerSHA256": hashlib.sha256((repo / "Sources/NextNotes/Formatting/LLM/ChatTemplate.swift").read_bytes()).hexdigest(),
    "checks": [],
}
for flag in flags:
    diagnostic = report / f"{phase}-{flag}.log"
    process_log = report / f"{phase}-{flag}.process.log"
    diagnostic.unlink(missing_ok=True)
    with tempfile.TemporaryDirectory(prefix="thinking-review-") as temp:
        env = dict(os.environ, TMPDIR=temp + "/")
        command = [str(binary), "--selftest-" + flag, "--selftest-out", str(diagnostic)]
        with process_log.open("wb") as output:
            result = subprocess.run(command, stdout=output, stderr=subprocess.STDOUT, env=env)
    lines = diagnostic.read_text().splitlines() if diagnostic.exists() else []
    markers = [line for line in lines if re.match(
        r"^(CHAT_TEMPLATE|NOTES_TRUNCATION|LLM_PREFIX_CACHE|STORE_ISOLATION)_(OK|FAILED|ABSENT)(:|$)", line)]
    record = {"flag": flag, "command": command, "exitCode": result.returncode,
              "marker": markers[-1] if markers else "NO_FINAL_MARKER",
              "embeddedFailureMarkers": [line for line in process_log.read_text(errors="replace").splitlines()
                                         if re.match(r"^[A-Z_]+_FAILED(:|$)", line)]}
    summary["checks"].append(record)
    (report / f"{phase}-summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(record), flush=True)
sys.exit(0 if all(c["exitCode"] == 0 and "_OK" in c["marker"] for c in summary["checks"]) else 1)

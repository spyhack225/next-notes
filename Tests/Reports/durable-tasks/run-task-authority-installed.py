#!/usr/bin/env python3
"""Serial installed regression checks; require both the named verdict and exit zero."""
from pathlib import Path
import json
import re
import subprocess

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / 'Tests/Reports/durable-tasks/2026-10-01-p6-04a-2'
NAMES = [
    'task-authority', 'task-recovery', 'task-durability', 'tasks', 'tool-review',
    'guided', 'agent-panes', 'activity', 'realtime', 'toolloop-production',
    'voice-session-reducer', 'voice-duplex-work', 'store-isolation',
]
OUT.mkdir(parents=True, exist_ok=True)
rows = []
for name in NAMES:
    command = ['Scripts/run-selftest.sh', '-ApplePersistenceIgnoreState', 'YES',
               '-NSQuitAlwaysKeepsWindows', 'NO', '--selftest-' + name]
    result = subprocess.run(command, cwd=ROOT, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True)
    (OUT / ('installed-final-' + name + '.log')).write_text(result.stdout)
    marker = name.upper().replace('-', '_')
    passed = result.returncode == 0 and len(re.findall(
        r'^' + marker + r'_OK(?:$|:)', result.stdout, re.MULTILINE)) == 1
    passed = passed and not re.search(
        r'^' + marker + r'_FAILED(?:$|:)|^SELFTEST_TIMEOUT',
        result.stdout, re.MULTILINE)
    rows.append({'name': name, 'exit': result.returncode, 'passed': bool(passed)})
    (OUT / 'installed-final-summary.json').write_text(json.dumps(rows, indent=2) + '\n')
    print(name, 'PASS' if passed else 'FAIL', 'exit', result.returncode, flush=True)
    if not passed:
        raise SystemExit('Unexpected installed verdict: ' + name)

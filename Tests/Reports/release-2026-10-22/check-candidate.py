"""Serial non-model release checks through the signed-bundle launcher."""
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import time

report = Path(__file__).resolve().parent
repo = report.parents[2]
app = Path(sys.argv[1]).resolve()
binary = app / 'Contents/MacOS/NextNotes'
flags = [
    'asr-settings', 'stream', 'dictation-segments', 'usage-log',
    'tts-source', 'chat-template', 'google-connect', 'gws',
    'calendar', 'mac-accounts', 'capability-manifest', 'ui-strings',
    'task-durability', 'task-recovery', 'task-authority', 'task-restoration',
    'task-history-repair', 'task-worker-attempt', 'receipt-persistence',
    'agent-presentation', 'routine-authority', 'voice-session-reducer',
    'voice-playback-projection', 'voice-playback-resume-receipt', 'playback-ledger',
    'meeting-frame-layout', 'meeting-frame-shape', 'audio-conversion-stream',
    'meeting-capture-coverage', 'notes-coverage', 'notes-truncation',
    'diarize-eligibility', 'meeting-title-match', 'store-isolation',
]
results = []
logs = report / 'candidate'
logs.mkdir(exist_ok=True)
for flag in flags:
    path = logs / (flag + '.log')
    command = ['bash', 'Scripts/run-selftest.sh', '--selftest-' + flag, '--selftest-timeout', '90']
    if flag == 'calendar':
        command += ['--calendar-google-errors']
    start = time.monotonic()
    with path.open('wb') as output:
        child = subprocess.Popen(command, cwd=repo, env=dict(os.environ, NEXTNOTES_APP=str(app)),
                                 stdout=output, stderr=output, start_new_session=True)
        timeout = False
        try:
            code = child.wait(timeout=105)
        except subprocess.TimeoutExpired:
            timeout = True
            os.killpg(child.pid, signal.SIGTERM)
            try:
                code = child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                code = child.wait()
    text = path.read_text(errors='replace')
    markers = re.findall(r'^([A-Z][A-Z0-9_]*_(?:OK|FAILED|TIMEOUT|MISSING|SILENT))\b', text, re.M)
    accepted = code == 0 and not timeout and bool(markers) and markers[-1].endswith('_OK')
    result = dict(flag=flag, exit=code, timeout=timeout, seconds=round(time.monotonic()-start, 3),
                  final_marker=markers[-1] if markers else None, accepted=accepted,
                  nested_failure_markers=sorted({x for x in markers[:-1] if not x.endswith('_OK')}))
    results.append(result)
    print(json.dumps(result), flush=True)
summary = dict(app=str(app), binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest(),
               runs=results, accepted=all(x['accepted'] for x in results))
(report / 'candidate-summary.json').write_text(json.dumps(summary, indent=2) + '\n')
sys.exit(0 if summary['accepted'] else 1)

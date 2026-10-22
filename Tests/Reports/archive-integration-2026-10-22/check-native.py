"""Bounded serial native fixture slot; run only after the explicit agent-relay handoff."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import tempfile
import time

report = Path(__file__).resolve().parent
repo = report.parents[2]
binary = Path(sys.argv[1]).resolve()
domain = plistlib.loads((repo / 'Resources/Info.plist').read_bytes())['CFBundleIdentifier']

def defaults_witness():
    result = subprocess.run(['defaults', 'export', domain, '-'], capture_output=True)
    if result.returncode:
        return {'export_exit': result.returncode, 'keys': 0, 'sha256': None}
    data = plistlib.loads(result.stdout)
    return {'export_exit': 0, 'keys': len(data), 'sha256': hashlib.sha256(plistlib.dumps(data, fmt=plistlib.FMT_BINARY, sort_keys=True)).hexdigest()}

summary = {'binary': str(binary), 'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(), 'owner_domain': domain, 'defaults_before': defaults_witness(), 'runs': []}
deadline = time.monotonic() + 115
with tempfile.TemporaryDirectory(prefix='nextnotes-archive-native-') as temporary:
    env = dict(os.environ, TMPDIR=str(Path(temporary).resolve()) + '/')
    def run(name, arguments, expected):
        with (report / (name + '.stdout.log')).open('wb') as output:
            start = time.monotonic()
            child = subprocess.Popen(arguments, cwd=repo, env=env, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
            timed_out = False
            try:
                code = child.wait(timeout=max(1, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                timed_out = True
                os.killpg(child.pid, signal.SIGTERM)
                try:
                    code = child.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL)
                    code = child.wait()
            summary['runs'].append({'name': name, 'arguments': arguments, 'exit': code, 'seconds': time.monotonic() - start, 'timeout': timed_out, 'expected': expected})
            if timed_out:
                raise TimeoutError('Bounded native slot exhausted; owned group joined')
    try:
        run('google-batch', ['sh', 'Tests/GoogleOptionCChecks.sh', 'restored', str(binary), str(report / 'native-google')], 'seven root fixture flags')
        for name, args, marker in [
            ('chat-template', ['--selftest-chat-template'], 'CHAT_TEMPLATE_OK'),
            ('notes-truncation', ['--selftest-notes-truncation'], 'NOTES_TRUNCATION_OK'),
            ('clock', ['--selftest-toolloop-live', '--model', 'scripted-clock', '--only', 'C01,C04', '--fixture-now', '2026-10-05T09:00:00-04:00'], 'TOOLLOOP_LIVE_OK'),
        ]:
            run(name, [str(binary), *args, '--selftest-timeout', '60', '--selftest-out', str(report / (name + '.log'))], marker)
    except Exception as error:
        summary['runner_error'] = str(error)
summary['defaults_after'] = defaults_witness()
summary['owner_defaults_unchanged'] = summary['defaults_before'] == summary['defaults_after']
(report / 'native-summary.json').write_text(json.dumps(summary, indent=2) + '\n')
accepted = len(summary['runs']) == 4 and all(r['exit'] == 0 and not r['timeout'] for r in summary['runs']) and summary['owner_defaults_unchanged']
for entry in summary['runs'][1:]:
    paths = [report / (entry['name'] + suffix) for suffix in ['.stdout.log', '.log']]
    output = ''.join(path.read_text(errors='replace') for path in paths if path.exists())
    accepted = accepted and entry['expected'] in output
print('ARCHIVE_NATIVE_OK' if accepted else 'ARCHIVE_NATIVE_FAILED')
sys.exit(0 if accepted else 1)

"""Once-only, bounded cached S1 companion; coordinate the model slot before running."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import subprocess
import sys
import tempfile
import time

report = Path(__file__).resolve().parent
repo = report.parents[2]
binary = Path(sys.argv[1]).resolve()
support = Path.home() / 'Library/Application Support/Next Notes'
model = support / 'Models/s1-mini-q4_k_m.gguf'
text = (repo / 'Sources/NextNotes/Support/SelfTestStoreGuard.swift').read_text()
block = text.split('static let fileNames: [String] = [', 1)[1].split('\n    ]', 1)[0]
# Comments contain quoted examples; only actual array entries are watched.
names = re.findall(r'^\s*"([^"]+)",', block, re.M) + ['Models/library.json']

def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            result.update(chunk)
    return result.hexdigest()

def witness():
    files = {}
    for name in names:
        path = support / name
        files[name] = dict(size=path.stat().st_size, mtime_ns=path.stat().st_mtime_ns, sha256=digest(path)) if path.is_file() else None
    exported = subprocess.run(['defaults', 'export', 'ai.pivotstudio.nextnotes', '-'], capture_output=True)
    values = plistlib.loads(exported.stdout) if exported.returncode == 0 else {}
    return dict(files=files, defaults_exit=exported.returncode, defaults_keys=len(values), defaults_sha256=hashlib.sha256(plistlib.dumps(values, fmt=plistlib.FMT_BINARY, sort_keys=True)).hexdigest())

summary = dict(binary_sha256=digest(binary), model_sha256=digest(model) if model.is_file() else None, before=witness())
start = time.monotonic()
with tempfile.TemporaryDirectory(prefix='nextnotes-archive-prefix-') as temporary:
    command = [str(binary), '--selftest-llm-prefix-cache', '--selftest-timeout', '75', '--selftest-out', str(report / 'prefix-cache.log')]
    with (report / 'prefix-cache.stdout.log').open('wb') as output:
        child = subprocess.Popen(command, cwd=repo, env=dict(os.environ, TMPDIR=str(Path(temporary).resolve()) + '/'), stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = child.wait(timeout=85)
        except subprocess.TimeoutExpired:
            summary['timeout'] = True
            os.killpg(child.pid, signal.SIGTERM)
            try:
                code = child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                code = child.wait()
summary.update(exit=code, seconds=time.monotonic() - start, after=witness(), command=command)
summary['owner_unchanged'] = summary['before'] == summary['after']
summary['model_unchanged'] = summary['model_sha256'] == (digest(model) if model.is_file() else None)
(report / 'prefix-cache-summary.json').write_text(json.dumps(summary, indent=2) + '\n')
passed = code == 0 and summary['owner_unchanged'] and summary['model_unchanged'] and 'LLM_PREFIX_CACHE_OK' in (report / 'prefix-cache.stdout.log').read_text(errors='replace')
print('ARCHIVE_PREFIX_CACHE_OK' if passed else 'ARCHIVE_PREFIX_CACHE_FAILED')
sys.exit(0 if passed else 1)

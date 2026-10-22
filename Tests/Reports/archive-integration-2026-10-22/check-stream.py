"""Frozen decoded-piece regression; native model/actor setup is explicitly substituted."""
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time

report = Path(__file__).resolve().parent
repo = report.parents[2]
fixture = report / 'stream-fixture.swift'
summary = {'fixture_sha256': hashlib.sha256(fixture.read_bytes()).hexdigest(), 'substitutions': 'Minimal LLMChatMessage/SelfTest and scripted stream creation; native decoding, model/actor setup absent. Baseline adapter mechanically exposes the old decoded-piece loop. Fixed code is current ChatTemplate.swift.', 'runs': []}

def run(command, log):
    start = time.monotonic()
    with log.open('wb') as output:
        child = subprocess.Popen(command, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = child.wait(timeout=12)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait()
            raise RuntimeError('Component exceeded its bounded slot; process group joined')
    return code, time.monotonic() - start

with tempfile.TemporaryDirectory(prefix='nextnotes-stream-regression-') as temporary:
    root = Path(temporary)
    for arm in ['original', 'fixed']:
        source = root / 'ChatTemplate.swift'
        source.write_bytes(subprocess.check_output(['git', 'show', '0dbba940:Sources/NextNotes/Formatting/LLM/ChatTemplate.swift'], cwd=repo) if arm == 'original' else (repo / 'Sources/NextNotes/Formatting/LLM/ChatTemplate.swift').read_bytes())
        binary = root / 'stream-check'
        arguments = ['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library', str(source), str(fixture)]
        if arm == 'original':
            arguments.append(str(report / 'original-stream-adapter.swift'))
        compile_code, compile_seconds = run(arguments + ['-o', str(binary)], report / f'{arm}-stream-build.log')
        assert compile_code == 0, f'{arm} component did not compile; see build log'
        binary_sha = hashlib.sha256(binary.read_bytes()).hexdigest()
        code, seconds = run([str(binary)], report / f'{arm}-stream.log')
        summary['runs'].append({'arm': arm, 'exit': code, 'seconds': seconds, 'compile_seconds': compile_seconds, 'source_sha256': hashlib.sha256(source.read_bytes()).hexdigest(), 'binary_sha256': binary_sha})
    (report / 'stream-component-summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    assert [r['exit'] for r in summary['runs']] == [1, 0], summary
print('ARCHIVED_STREAM_COMPONENT_OK: unchanged 658-case fixture fails before / passes after; native model and full-app checks separate')

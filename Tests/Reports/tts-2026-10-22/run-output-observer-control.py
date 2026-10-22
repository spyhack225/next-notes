"""Focused native control of the exact diagnostic observer; no model or microphone.
AudioChunk's owned-buffer carrier is substituted; actual observer/clock/grader unchanged.
Run only in a coordinated native window. The full-app --selftest-tts-source also calls it.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--maximum-latency', action='store_true')
parser.add_argument('--original-ref')
args = parser.parse_args()
report = Path(__file__).resolve().parent
repo = report.parents[2]
source = repo/'Sources/NextNotes/Agent/Speech/TTSOutputProbe.swift'
fixture = report/('output-observer-maximum-latency-control.swift' if args.maximum_latency else 'output-observer-control.swift')
name = ('output-maximum-latency-' + ('original' if args.original_ref else 'fixed')) if args.maximum_latency else 'output-observer-control'
original = subprocess.check_output(['git','show',args.original_ref+':Sources/NextNotes/Agent/Speech/TTSOutputProbe.swift'],cwd=repo) if args.original_ref else None
with tempfile.TemporaryDirectory(prefix='nextnotes-tts-observer-') as temporary:
    binary = Path(temporary)/'observer-control'
    if original is not None:
        source = Path(temporary)/'TTSOutputProbe.swift'
        source.write_bytes(original)
    compile_result = subprocess.run(['swiftc','-swift-version','6',str(fixture),str(source),'-o',str(binary)],capture_output=True,text=True)
    result = {'sourceSHA256':hashlib.sha256(source.read_bytes()).hexdigest(),
              'fixtureSHA256':hashlib.sha256(fixture.read_bytes()).hexdigest(),
              'compileExit':compile_result.returncode,'compileLog':compile_result.stdout+compile_result.stderr,
              'scope':'Authored correlated pickup, silence and overflow controls; no physical measurement.'}
    if compile_result.returncode == 0:
        run = subprocess.run([str(binary)],capture_output=True,text=True,timeout=15)
        result.update(exit=run.returncode,log=run.stdout+run.stderr)
    (report/(name+'.json')).write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result))
    raise SystemExit(result.get('exit',1))

#!/usr/bin/env python3
"""Prepare exact copied protocol + actor dispatch fixture; compile only with --run.

Snapshots are frozen review inputs. This script never reads/writes owner stores,
changes Sources, loads models or builds the app. Parent owns serial compiler use.
"""
import argparse
import hashlib
import json
import pathlib
import subprocess
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
parser = argparse.ArgumentParser()
parser.add_argument('--mode', choices=['original', 'current'], required=True)
parser.add_argument('--run', action='store_true', help='explicitly compile/run after serial slot grant')
parser.add_argument('--output', type=pathlib.Path)
args = parser.parse_args()
output = args.output or HERE / ('prepared-' + args.mode)
output.mkdir(parents=True, exist_ok=True)
snapshot = HERE / (('original' if args.mode == 'original' else 'proposed') + '-TranscriptionEngine.swift.txt')
protocol = output / 'TranscriptionEngine.swift'
driver = output / 'LaneWaitDriver.swift'
protocol.write_bytes(snapshot.read_bytes())
driver.write_bytes((HERE / 'LaneWaitDriver.swift').read_bytes())
manifest = {
    'state': 'PREPARED ONLY; no compiler or run',
    'mode': args.mode,
    'inputs': {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in [snapshot, protocol, driver]},
    'scope': 'actual full production protocol/types; fixture actor and exact optional existential read, not actual Parakeet scheduling or usage persistence',
}
manifest_path = output / 'input-manifest.json'
manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')
if not args.run:
    print('LANE_WAIT_PREPARED_ONLY: ' + str(output))
    raise SystemExit(0)

with tempfile.TemporaryDirectory(prefix='NextNotes-LaneWaitDispatch-') as temporary:
    scratch = pathlib.Path(temporary)
    binary = scratch / 'lane-wait-driver'
    command = ['swiftc', '-swift-version', '6', '-parse-as-library',
               '-module-cache-path', str(scratch / 'module-cache'),
               str(protocol), str(driver), '-o', str(binary)]
    manifest['compileCommand'] = command
    compiled = subprocess.run(command, capture_output=True, text=True)
    (output / 'compile.log').write_text(compiled.stdout + compiled.stderr)
    manifest['compileExit'] = compiled.returncode
    if compiled.returncode:
        manifest['state'] = 'COMPILE FAILED; no test verdict'
        manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')
        print(compiled.stdout + compiled.stderr, end='')
        raise SystemExit(compiled.returncode)
    completed = subprocess.run([str(binary)], capture_output=True, text=True)
    (output / 'run.log').write_text(completed.stdout + completed.stderr)
    manifest['runExit'] = completed.returncode
    manifest['state'] = 'ACTUAL COMPILED DRIVER RUN; see runExit and raw log'
    manifest_path.write_text(json.dumps(manifest, indent=2) + '\n')
    print(completed.stdout + completed.stderr, end='')
    raise SystemExit(completed.returncode)

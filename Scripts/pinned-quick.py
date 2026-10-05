#!/usr/bin/env python3
"""Run the same pinned quick evaluation at least three times, keeping every raw round."""
import argparse
import datetime
import json
import os
from pathlib import Path
import re
import shutil
import statistics
import subprocess
import sys
import uuid


def machine_state(directory):
    load = os.getloadavg()[0]
    swap = subprocess.check_output(['sysctl', 'vm.swapusage'], text=True)
    match = re.search(r'used\s*=\s*([\d.]+)([MG])', swap)
    if not match:
        raise RuntimeError('Cannot read swap usage; no evaluation started.')
    swap_gib = float(match[1]) / (1024 if match[2] == 'M' else 1)
    free_gib = shutil.disk_usage(directory).free / 1024 ** 3
    state = {'load': load, 'swapGiB': swap_gib, 'freeGiB': free_gib}
    print('Machine: ' + json.dumps(state), flush=True)
    if load > 40 or swap_gib > 8 or free_gib < 10:
        raise RuntimeError('Evaluation held: require load <=40, swap <=8 GiB and free space >=10 GiB.')
    return state


def read_score(report, output, returncode, model_pin, fixture_now):
    rows = [json.loads(line) for line in Path(str(report) + '.jsonl').read_text().splitlines() if line.strip()]
    if len(rows) != 10 or len({row['id'] for row in rows}) != 10:
        raise RuntimeError('Incomplete or duplicate quick rows; this run is unscored.')
    if any('rawRounds' not in row for row in rows):
        raise RuntimeError('The application lacks complete raw-round instrumentation.')
    if any(row.get('modelPin') != model_pin or row.get('fixtureNow') != fixture_now for row in rows):
        raise RuntimeError('The report used a different model or fixture clock; this run is unscored.')
    clocks = re.findall(r'^TOOLLOOP_LIVE_CLOCK: (.+) timezone=(.+)$', output, re.M)
    if len(clocks) != 1 or clocks[0][0] != fixture_now:
        raise RuntimeError('Missing or mismatched fixture clock; this run is unscored.')
    models = re.findall(r'^TOOLLOOP_LIVE_MODEL: (.+)$', output, re.M)
    if len(models) != 1 or 'FALLBACK' in models[0]:
        raise RuntimeError('Missing, ambiguous or fallback model; this run is unscored.')
    passed = sum(row['verdict'].upper() == 'PASS' for row in rows)
    markers = re.findall(r'^TOOLLOOP_LIVE_(OK|FAILED): (\d+)/10(?:\D|$)', output, re.M)
    if len(markers) != 1 or int(markers[0][1]) != passed:
        raise RuntimeError('Quick rows and final verdict disagree; this run is unscored.')
    expected = 'OK' if passed >= 9 else 'FAILED'
    if markers[0][0] != expected or returncode != (0 if expected == 'OK' else 1):
        raise RuntimeError('Unexpected exit or verdict; this run is unscored.')
    return passed, models[0], clocks[0][1]


def binary_identity(binary):
    metadata = binary.stat()
    return (metadata.st_dev, metadata.st_ino, metadata.st_size, metadata.st_mtime_ns)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model', required=True, help='explicit installed model id or file pin')
    parser.add_argument('--fixture-now', required=True, help='fixed ISO8601 instant, including timezone')
    parser.add_argument('--runs', type=int, default=3)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--under-lock', action='store_true', help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.runs < 3:
        parser.error('--runs must be at least 3')
    try:
        instant = datetime.datetime.fromisoformat(args.fixture_now.replace('Z', '+00:00'))
    except ValueError:
        parser.error('--fixture-now must be an ISO8601 date and time')
    if instant.tzinfo is None:
        parser.error('--fixture-now must include a timezone')
    root = Path(__file__).resolve().parent.parent
    parent = Path.home() / 'Library/Caches/NextNotesBuild/quick'
    parent.mkdir(parents=True, exist_ok=True)
    output = args.output or parent / str(uuid.uuid4())
    output.parent.mkdir(parents=True, exist_ok=True)
    machine_state(output.parent)
    if not args.under_lock:
        wrapper = root / 'Scripts/with-install-lock.sh'
        lock = os.environ.get('NEXTNOTES_LOCK', str(Path.home() / 'Library/Caches/NextNotesBuild/install.lock'))
        os.execv(str(wrapper), [str(wrapper), lock, sys.executable, str(Path(__file__).resolve()),
                               *sys.argv[1:], '--under-lock'])
    app = Path(os.environ.get('NEXTNOTES_APP', '/Applications/Next Notes.app'))
    binary = app / 'Contents/MacOS/NextNotes'
    identity = binary_identity(binary)
    output.mkdir(exist_ok=False)
    summary = {'modelPin': args.model, 'fixtureNow': args.fixture_now, 'timezone': os.environ.get('TZ', 'system'), 'runs': []}
    resolved_model = None
    timezone = None
    for index in range(1, args.runs + 1):
        state = machine_state(output)
        if binary_identity(binary) != identity:
            raise RuntimeError('Installed binary changed; no aggregate score.')
        report = output / f'run{index}.md'
        command = [str(root / 'Scripts/run-selftest.sh'), '--under-lock', '--selftest-toolloop-live', '--quick',
                   '--model', args.model, '--fixture-now', args.fixture_now, '--report', str(report),
                   '--selftest-timeout', '1800']
        print(f'Run {index}/{args.runs}: model={args.model}, clock={args.fixture_now}', flush=True)
        with (output / f'run{index}.log').open('w') as log:
            process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
            lines = []
            try:
                for line in process.stdout:
                    log.write(line); log.flush(); lines.append(line)
                    if line.startswith(('TOOLLOOP_LIVE_', 'SELFTEST_')):
                        print(line.rstrip(), flush=True)
                code = process.wait()
            finally:
                if process.poll() is None:
                    process.terminate()
                    try: process.wait(timeout=10)
                    except subprocess.TimeoutExpired: process.kill(); process.wait()
        if binary_identity(binary) != identity:
            raise RuntimeError('Installed binary changed during evaluation; this run is unscored.')
        score, model, run_timezone = read_score(report, ''.join(lines), code, args.model, args.fixture_now)
        if resolved_model is not None and model != resolved_model:
            raise RuntimeError('Resolved model changed between runs; no aggregate score.')
        if timezone is not None and timezone != run_timezone:
            raise RuntimeError('Fixture time zone changed between runs; no aggregate score.')
        resolved_model = model
        timezone = run_timezone
        summary['timezone'] = timezone
        summary['runs'].append({'score': score, 'machine': state, 'report': str(report)})
        (output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    scores = [run['score'] for run in summary['runs']]
    summary.update(resolvedModel=resolved_model, minimum=min(scores), median=statistics.median(scores), maximum=max(scores))
    (output / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(f"Quick {args.model}: min {min(scores)}/10, median {statistics.median(scores):g}/10, max {max(scores)}/10; {output}")
    return 0 if summary['median'] >= 9 else 1


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, ValueError, RuntimeError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(2)

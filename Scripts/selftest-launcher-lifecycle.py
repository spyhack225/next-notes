#!/usr/bin/env python3
"""Portable launcher lifecycle regression; launches fake app/open/codesign only."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

parser = argparse.ArgumentParser()
parser.add_argument('--script', type=Path, default=Path(__file__).with_name('run-selftest.sh'))
parser.add_argument('--lock-script', type=Path)
parser.add_argument('--through-lock', action='store_true')
args = parser.parse_args()
failures = []

def check(condition, message):
    if not condition:
        failures.append(message)

def await_file(path):
    until = time.monotonic() + 5
    while not path.exists():
        if time.monotonic() > until:
            raise RuntimeError(f'fake process did not produce {path.name}')
        time.sleep(.01)

with tempfile.TemporaryDirectory(prefix='nextnotes-launcher-regression-') as scratch:
    root = Path(scratch)
    scripts = root / 'repo/Scripts'
    scripts.mkdir(parents=True)
    launcher = scripts / 'run-selftest.sh'
    launcher.write_text(args.script.read_text())
    launcher.chmod(0o755)
    if args.through_lock:
        lock_source = args.lock_script or args.script.with_name('with-install-lock.sh')
        lock_holder = scripts / 'with-install-lock.sh'
        lock_holder.write_text(lock_source.read_text())
        lock_holder.chmod(0o755)
    tools = root / 'bin'
    tools.mkdir()
    app = root / 'Fake.app'
    binary = app / 'Contents/MacOS/NextNotes'
    binary.parent.mkdir(parents=True)
    binary.write_text('#!' + sys.executable + '\n' + '''import json, os, signal, sys, time
from pathlib import Path
record = Path(os.environ['FAKE_RECORD'])
tmp = Path(os.environ['TMPDIR'])
(tmp / 'StartupTest-fake').mkdir(exist_ok=True)
(tmp / 'StartupTest-fake' / 'payload').write_text('disposable')
def ended(*unused):
    record.with_suffix('.closed').write_text('closed')
    raise SystemExit(143)
signal.signal(signal.SIGTERM, ended)
record.write_text(json.dumps({'tmp': str(tmp), 'pid': os.getpid(), 'parent': os.getppid()}))
args = sys.argv[1:]
if '--selftest-out' in args:
    out = Path(args[args.index('--selftest-out') + 1])
    out.write_text('FAKE_' + ('FAILED' if os.environ['FAKE_MODE'] == 'fail' else 'OK') + ': original verdict\\n')
while not record.with_suffix('.release').exists(): time.sleep(.01)
record.with_suffix('.closed').write_text('closed')
if os.environ['FAKE_MODE'] == 'crash': os.kill(os.getpid(), signal.SIGKILL)
raise SystemExit(1 if os.environ['FAKE_MODE'] == 'fail' else 0)
''')
    open_tool = tools / 'open'
    open_tool.write_text('#!' + sys.executable + '\n' + '''import json, os, subprocess, sys, time
from pathlib import Path
args = sys.argv[1:]
record = Path(os.environ['FAKE_RECORD'])
child_env = dict(os.environ)
if '--env' in args:
    key, value = args[args.index('--env') + 1].split('=', 1)
    child_env[key] = value
record.with_suffix('.open').write_text(json.dumps({'args': args, 'tmp': child_env['TMPDIR']}))
if os.environ['FAKE_MODE'] == 'launch-failure': raise SystemExit(1)
app = next(arg for arg in args if arg.endswith('.app'))
command = [str(Path(app) / 'Contents/MacOS/NextNotes')] + args[args.index('--args') + 1:]
if '-W' in args:
    os.execve(command[0], command, child_env)
child = subprocess.Popen(command, env=child_env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
while not record.exists(): time.sleep(.01)
raise SystemExit(0)
''')
    codesign = tools / 'codesign'
    codesign.write_text('#!/usr/bin/env bash\nexit 0\n')
    for path in (binary, open_tool, codesign):
        path.chmod(0o755)
    for label, via_open, mode, interrupt in (
        ('direct-pass', False, 'pass', False),
        ('direct-fail', False, 'fail', False),
        ('direct-crash', False, 'crash', False),
        ('open-verdict-before-exit', True, 'pass', False),
        ('open-fail', True, 'fail', False),
        ('open-launch-failure', True, 'launch-failure', False),
        ('direct-interrupt', False, 'pass', True),
        ('open-interrupt-retains', True, 'pass', True),
    ):
        caller = root / label
        caller.mkdir()
        sentinel = caller / 'caller-retained'
        sentinel.write_text('untouched')
        record = root / (label + '.json')
        env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ['PATH'],
                   TMPDIR=str(caller) + '/', NEXTNOTES_APP=str(app),
                   FAKE_RECORD=str(record), FAKE_MODE=mode, NEXTNOTES_LOCK=str(root / 'install.lock'))
        command = ['bash', str(launcher)]
        if not args.through_lock: command += ['--under-lock']
        if via_open: command += ['--via-open']
        command += ['--out', str(caller / 'supplied.out'), '--selftest-fake']
        process = subprocess.Popen(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        data = None
        try:
            if mode == 'launch-failure':
                stdout, stderr = process.communicate(timeout=5)
                data = json.loads(record.with_suffix('.open').read_text())
            else:
                await_file(record)
                data = json.loads(record.read_text())
                time.sleep(.15)
                check(process.poll() is None, label + ': launcher returned before actual diagnostic exit')
                if args.through_lock:
                    with (root / 'install.lock').open('a+') as lock:
                        try:
                            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                            check(False, label + ': install lock released before diagnostic join')
                            fcntl.flock(lock, fcntl.LOCK_UN)
                        except BlockingIOError:
                            pass
                if not args.through_lock and not via_open and data['pid'] != process.pid:
                    check(data['parent'] == process.pid, label + ': launcher did not stay exact live parent')
                if interrupt:
                    process.send_signal(signal.SIGTERM)
                else:
                    record.with_suffix('.release').write_text('release')
                try:
                    stdout, stderr = process.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    check(False, label + ': exact diagnostic left running after launcher signal')
                    try: os.kill(data['pid'], signal.SIGTERM)
                    except ProcessLookupError: pass
                    stdout, stderr = process.communicate(timeout=5)
            owned = Path(data['tmp'])
            check(owned != caller and owned.parent == caller, label + ': caller TMPDIR not isolated')
            check(caller.is_dir() and sentinel.read_text() == 'untouched', label + ': caller root changed')
            if via_open:
                launch = json.loads(record.with_suffix('.open').read_text())
                check('-W' in launch['args'] and '--env' in launch['args'], label + ': open lacks exact wait/env')
            if via_open and interrupt:
                check(owned != caller and owned.exists(), label + ': unjoined app temp not retained')
                check(b'app join unproven' in stderr, label + ': missing truthful interrupt warning')
            else:
                check(not owned.exists(), label + ': joined/failed diagnostic temp left behind')
            if mode != 'launch-failure':
                check((caller / 'supplied.out').exists(), label + ': supplied caller output removed')
            expected = 143 if interrupt else (1 if mode in ('fail', 'launch-failure') else (-1 if mode == 'crash' else 0))
            check(process.returncode != 0 if expected == -1 else process.returncode == expected,
                  label + ': status changed')
            if interrupt and not via_open:
                check(record.with_suffix('.closed').exists(), label + ': exact child not joined')
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate(timeout=5)
            if data and 'pid' in data and not record.with_suffix('.closed').exists():
                try: os.kill(data['pid'], signal.SIGTERM)
                except ProcessLookupError: pass
                await_file(record.with_suffix('.closed'))
            # Only fake authored process/data, after exact close; never an installed app.
            if data and Path(data['tmp']) != caller:
                shutil.rmtree(data['tmp'], ignore_errors=True)
for failure in failures:
    print('FAIL: ' + failure)
print(f'LAUNCHER_TMP_{"FAILED" if failures else "OK"}: 8 fake lifecycle cases; failures={len(failures)}')
raise SystemExit(bool(failures))

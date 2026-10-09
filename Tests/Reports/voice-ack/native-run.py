#!/usr/bin/env python3
"""Run one owned self-test and sample its process only; invoked inside heavy.sh."""
import ctypes, hashlib, json, os, signal, subprocess, sys, time
from datetime import datetime, timezone
from pathlib import Path
label, app, *args = sys.argv[1:]
report = Path('Tests/Reports/voice-ack')
class Usage(ctypes.Structure):
    _fields_ = [('uuid', ctypes.c_uint8 * 16)] + [(n, ctypes.c_uint64) for n in ['user_time', 'system_time', 'pkg_idle_wkups', 'interrupt_wkups', 'pageins', 'wired_size', 'resident_size', 'phys_footprint', 'start', 'exit']]
lib = ctypes.CDLL('/usr/lib/libproc.dylib')
lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
lib.proc_pid_rusage.restype = ctypes.c_int
def command(*args):
    return subprocess.run(args, text=True, capture_output=True).stdout.strip()
def binary_hash():
    digest = hashlib.sha256()
    with open(app, 'rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()
def environment():
    values = {key: command(*cmd) for key, cmd in {
        'os': ('sw_vers',), 'hardware': ('sysctl', '-n', 'machdep.cpu.brand_string'), 'memory_bytes': ('sysctl', '-n', 'hw.memsize'), 'power': ('pmset', '-g', 'batt'), 'thermal': ('pmset', '-g', 'therm'),
        'swap': ('sysctl', 'vm.swapusage'), 'disk': ('df', '-k', '.'), 'load': ('uptime',)
    }.items()}
    values['concurrent_target_processes'] = [line.strip() for line in command('ps', '-axo', 'pid,comm').splitlines() if any(name in line for name in ['NextNotes', 'swift-frontend', 'swift-build', 'llama', 'modelmanagerd', 'audiomxd'])]
    return values
child = None
def stop_owned(signum, _frame):
    if child is not None and child.poll() is None:
        os.killpg(child.pid, signal.SIGTERM)
        try: child.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL); child.wait()
    raise SystemExit(128 + signum)
for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
    signal.signal(signum, stop_owned)
started = time.monotonic()
started_utc = datetime.now(timezone.utc).isoformat()
before = environment()
binary_before = binary_hash()
rows = []
with (report / (label + '.stdout.log')).open('w') as stdout:
    child = subprocess.Popen([app, *args, '--selftest-out', str(report / (label + '.log')), '--selftest-timeout', '600'], stdout=stdout, stderr=subprocess.STDOUT, start_new_session=True)
    identity = None
    while child.poll() is None:
        usage = Usage()
        if lib.proc_pid_rusage(child.pid, 0, ctypes.byref(usage)) == 0:
            if identity is None: identity = usage.start
            if usage.start != identity: raise RuntimeError('owned process identity changed')
            rows.append({'t': round(time.monotonic()-started, 3), 'pid': child.pid, 'start': identity, 'rss': usage.resident_size, 'footprint': usage.phys_footprint, 'wired': usage.wired_size})
        if time.monotonic() - started > 660:
            os.killpg(child.pid, signal.SIGTERM)
            try: child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL); child.wait()
            break
        time.sleep(1)
    code = child.wait()
binary_after = binary_hash()
v = {'scope': 'one owned process; configuration in artifact pins; 1s sampled maxima, not continuous peaks; hosted services/children excluded', 'started_utc': started_utc, 'finished_utc': datetime.now(timezone.utc).isoformat(), 'args': args, 'pid': child.pid, 'exit': code, 'binary_sha256_before': binary_before, 'binary_sha256_after': binary_after, 'before': before, 'after': environment(), 'rows': rows, 'peak_rss': max((r['rss'] for r in rows), default=None), 'peak_footprint': max((r['footprint'] for r in rows), default=None)}
(report / (label + '.resources.json')).write_text(json.dumps(v, indent=2)+'\n')
log = report / (label + '.log')
lines = log.read_text().splitlines() if log.exists() else []
if not lines:
    lines = (report / (label + '.stdout.log')).read_text().splitlines()
with (report / 'batch-status.txt').open('a') as status:
    status.write(f'{label} exit={code} marker={lines[-1] if lines else "ABSENT"}\n')
print(f'{label} exit={code} marker={lines[-1] if lines else "ABSENT"}', flush=True)
if binary_before != binary_after:
    raise RuntimeError('owned binary identity changed; native result is unscored')
sys.exit(code)

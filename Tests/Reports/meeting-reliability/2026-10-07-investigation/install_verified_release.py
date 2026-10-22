"""Install the tested release under the existing install lock; retain a rollback.

Only the exact verified normal-data process is stopped. No other app process,
build directory, model, setting, recording, or old staging bundle is removed.
"""
import ctypes
import datetime
import hashlib
import json
import os
import pathlib
import signal
import subprocess
import sys
import time
import uuid

report = pathlib.Path(__file__).resolve().parent
release = json.loads((report / 'release-build.json').read_text())
source = pathlib.Path(release['bundle'])
target = pathlib.Path('/Applications/Next Notes.app')
owner_pid = int(sys.argv[1])
libproc = ctypes.CDLL('/usr/lib/libproc.dylib')
libproc.proc_pidpath.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint32]

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def executable(bundle):
    return bundle / 'Contents/MacOS/NextNotes'

def process_path(pid):
    value = ctypes.create_string_buffer(4096)
    if libproc.proc_pidpath(pid, value, len(value)) <= 0:
        return None
    return os.fsdecode(value.value)

assert digest(executable(source)) == release['binary_sha256']
assert process_path(owner_pid) == str(executable(source))
for path in (pathlib.Path.home() / 'Library/Application Support/Next Notes/Meetings').glob('*/meeting.json'):
    assert json.loads(path.read_text()).get('status', {}).get('state') != 'recording'

token = uuid.uuid4().hex
new = pathlib.Path('/Applications/Next Notes.app.meeting-fix-' + token)
retained = pathlib.Path.home() / 'Library/Caches/NextNotesBuild' / ('meeting-fix-install-' + token)
retained.mkdir()
rollback = retained / 'Next Notes.app'
assert not new.exists() and not rollback.exists()
subprocess.run(['ditto', str(source), str(new)], check=True)
assert digest(executable(new)) == release['binary_sha256']
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(new)], check=True)

assert process_path(owner_pid) == str(executable(source))
os.kill(owner_pid, signal.SIGTERM)
deadline = time.monotonic() + 25
while process_path(owner_pid) is not None and time.monotonic() < deadline:
    time.sleep(.1)
assert process_path(owner_pid) is None, 'Graceful quit did not finish; do not start a second normal app.'

original_hash = digest(executable(target))
target.rename(rollback)
try:
    new.rename(target)
    assert digest(executable(target)) == release['binary_sha256']
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(target)], check=True)
except BaseException:
    if not target.exists():
        rollback.rename(target)
    raise

with (report / 'installed-owner-launch.log').open('w') as output:
    app = subprocess.Popen([str(executable(target))], stdout=output, stderr=subprocess.STDOUT,
                           start_new_session=True)
with (report / 'installed-live-guard.log').open('w') as output:
    monitor_dir = report / ('installed-live-' + token)
    guard = subprocess.Popen([sys.executable, str(report / 'watch_live_memory.py'), str(app.pid),
                              str(monitor_dir)], stdout=output, stderr=subprocess.STDOUT,
                             start_new_session=True)
time.sleep(.25)
assert process_path(app.pid) == str(executable(target))
result = {
    'at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'target': str(target), 'source': str(source), 'source_commit': '422ba5f',
    'installed_binary_sha256': digest(executable(target)), 'matches_tested_release': True,
    'codesign_verified': True, 'pid': app.pid, 'guard_pid': guard.pid,
    'guard_output': str(monitor_dir), 'monitor_limit_bytes': 2_500_000_000,
    'rollback': str(rollback), 'original_binary_sha256': original_hash,
    'old_normal_process_exited': owner_pid,
    'mode': 'normal owner data; no fixture or preference override',
}
(report / 'installed-release.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result), flush=True)

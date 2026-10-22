"""Build and sign a candidate through make, without replacing the installed app."""
import datetime
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import time

report = Path(__file__).resolve().parent
repo = report.parents[2]
stage = Path.home() / 'Library/Caches/NextNotesBuild' / ('install-' + str(os.getpid()))
flags = '--jobs 2 -Xswiftc -no-whole-module-optimization -Xswiftc -enable-batch-mode -Xswiftc -driver-batch-count -Xswiftc 16 -Xswiftc -num-threads -Xswiftc 1'
command = ['make', 'app', 'CONFIG=release', 'STAMP_VERSION=1', 'VERSION=0.2.24',
           'STAGE_RUN=' + str(stage), 'SWIFT_BUILD_FLAGS=' + flags]
reason = None
start = time.monotonic()
path = report / 'candidate-build.log'
with path.open('w') as output, path.open() as observer:
    child = subprocess.Popen(command, cwd=repo, stdout=output, stderr=output, start_new_session=True)
    pending = ''
    try:
        while child.poll() is None:
            pending += observer.read()
            lines = pending.split('\n')
            pending = lines.pop()
            errors = [x for x in lines if ': error:' in x or x.startswith('error:')]
            if errors:
                reason = errors[0]
            elif shutil.disk_usage(repo).free < int(1.5 * 1024**3):
                reason = 'Less than 1.5 GiB free disk; only owned build process group stopped.'
            if reason:
                os.killpg(child.pid, signal.SIGINT)
                try:
                    child.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait()
                break
            time.sleep(.5)
    except BaseException:
        if child.poll() is None:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait()
        raise
result = dict(command=command, exit=child.wait(), stopped_reason=reason,
              seconds=time.monotonic()-start, app=str(stage/'Next Notes.app'),
              generated_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
              free_bytes=shutil.disk_usage(repo).free)
(report/'candidate-build.json').write_text(json.dumps(result, indent=2)+'\n')
print(json.dumps(result), flush=True)
raise SystemExit(0 if result['exit']==0 and not reason else 1)

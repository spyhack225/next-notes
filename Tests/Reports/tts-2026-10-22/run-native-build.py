"""Bounded native build: stop only our process group on a real error or low disk."""
import datetime, json, os, pathlib, shutil, signal, subprocess, time
report = pathlib.Path(__file__).resolve().parent
repo = report.parents[2]
command = ['swift','build','-c','release','--build-system','native','--jobs','2',
 '--scratch-path','/Users/sergekadjo/Library/Caches/NextNotesBuild/scratch',
 '-Xswiftc','-no-whole-module-optimization','-Xswiftc','-enable-batch-mode',
 '-Xswiftc','-driver-batch-count','-Xswiftc','16','-Xswiftc','-num-threads','-Xswiftc','1']
started = time.monotonic()
reason = None
path = report/'native-build-combined.log'
with path.open('w') as output, path.open() as observer:
 process = subprocess.Popen(command,cwd=repo,stdout=output,stderr=output,start_new_session=True)
 pending = ''
 try:
  while process.poll() is None:
   pending += observer.read()
   lines = pending.split('\n'); pending = lines.pop()
   errors = [line for line in lines if ': error:' in line or line.startswith('error:')]
   if errors: reason = errors[0]
   elif shutil.disk_usage(repo).free < int(1.5*1024**3): reason = 'Disk guard: less than1.5GiB free.'
   if reason:
    try: os.killpg(process.pid,signal.SIGINT)
    except ProcessLookupError: pass
    try: process.wait(timeout=10)
    except subprocess.TimeoutExpired:
     os.killpg(process.pid,signal.SIGKILL); process.wait()
    break
   time.sleep(.5)
 except BaseException:
  if process.poll() is None:
   os.killpg(process.pid,signal.SIGKILL); process.wait()
  raise
 result={'command':command,'exitCode':process.wait(),'stoppedReason':reason,
  'elapsedSeconds':time.monotonic()-started,'generatedAt':datetime.datetime.now(datetime.timezone.utc).isoformat(),
  'freeBytesAfter':shutil.disk_usage(repo).free}
if result['exitCode']==0 and reason is None:
 with (report/'metal-packaging-after-build.log').open('w') as log:
  metal=subprocess.run(['bash','Tools/build-mlx-metal.sh','/Users/sergekadjo/Library/Caches/NextNotesBuild/scratch','release'],cwd=repo,stdout=log,stderr=log)
 result['metalPackagingExit']=metal.returncode
 if metal.returncode: result['stoppedReason']='Post-link Metal packaging failed.'
(report/'native-build-result.json').write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps(result),flush=True)
raise SystemExit(0 if result['exitCode']==0 and result['stoppedReason'] is None else 1)

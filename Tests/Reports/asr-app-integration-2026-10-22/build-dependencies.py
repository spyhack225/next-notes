import subprocess,os,time,signal,json,shutil
from pathlib import Path
root=Path(__file__).resolve().parents[3];out=Path(__file__).resolve().parent
records=[]
for target in ['PhononCoreML','Voz','MLXAudioSTT']:
 command=['xcrun','swift','build','--scratch-path',str(Path.home()/'Library/Caches/NextNotesBuild/scratch'),'-c','release','--build-system','native','--jobs','2','--disable-automatic-resolution','--target',target]
 began=time.monotonic();log=out/f'build-native-{target}.log'
 with log.open('w') as output:
  child=subprocess.Popen(command,cwd=root,stdout=output,stderr=subprocess.STDOUT,start_new_session=True)
  stopped=None
  while child.poll() is None:
   if shutil.disk_usage(root).free<1280*1024**2:stopped='disk below1.25GiB'
   if time.monotonic()-began>480:stopped='bounded480s deadline'
   if stopped:
    os.killpg(child.pid,signal.SIGKILL);child.wait();break
   time.sleep(1)
 record=dict(target=target,command=command,exit=child.returncode,elapsedSeconds=time.monotonic()-began,stopped=stopped)
 records.append(record);(out/'dependency-native-builds.json').write_text(json.dumps(records,indent=2)+'\n');print(record,flush=True)
 if child.returncode:raise SystemExit(1)

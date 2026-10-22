"""Serial optimized-app ASR check; one candidate/process/temp root at a time."""
import argparse,fcntl,hashlib,json,os,shutil,signal,subprocess,time
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]

def main():
 parser=argparse.ArgumentParser(description=__doc__)
 parser.add_argument('--app',type=Path,required=True)
 parser.add_argument('--output',type=Path,required=True)
 parser.add_argument('--models',nargs='+',default=['phonon','voz','parakeet','whistle','redux','ultra','qwen-06b','qwen-17b'])
 args=parser.parse_args(); args.output.mkdir(parents=True,exist_ok=True)
 cache=Path.home()/'Library/Caches/NextNotesASRBench';cache.mkdir(parents=True,exist_ok=True)
 with (cache/'serial.lock').open('a') as lock:
  fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
  binarySHA=hashlib.sha256(args.app.read_bytes()).hexdigest();results=[]
  for model in args.models:
   output=args.output/f'{model}.json'
   if output.exists():raise RuntimeError(f'Review saved result before retry: {output}')
   beforeRoots=set(cache.glob('app-*'));before=shutil.disk_usage(cache).free
   command=[str(args.app.resolve()),'--selftest-asr-live','--asr-model',model,'--asr-fixtures',str(ROOT/'Tests/Fixtures/meetings'),'--asr-output',str(output.resolve())]
   began=time.monotonic();reason=None
   with (args.output/f'{model}.log').open('w') as log:
    child=subprocess.Popen(command,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
    try:
     while child.poll() is None:
      if shutil.disk_usage(cache).free<1536*1024**2:reason='disk below1.5GiB'
      if time.monotonic()-began>600:reason='bounded600s diagnostic deadline'
      if reason:
       os.killpg(child.pid,signal.SIGKILL);child.wait();break
      time.sleep(.5)
    except BaseException:
     if child.poll() is None:os.killpg(child.pid,signal.SIGKILL);child.wait()
     raise
   deleted=[]
   for folder in set(cache.glob('app-*'))-beforeRoots:
    marker=folder/'.pid'
    if marker.is_file() and marker.read_text().strip()==str(child.pid):
     shutil.rmtree(folder);deleted.append(str(folder))
   row=dict(model=model,appSHA256=binarySHA,command=command,exit=child.returncode,seconds=time.monotonic()-began,stopped=reason,freeBefore=before,freeAfter=shutil.disk_usage(cache).free,ownedFailureRootsDeleted=deleted,childJoined=child.poll() is not None)
   results.append(row);(args.output/'runner.json').write_text(json.dumps(results,indent=2)+'\n');print(json.dumps(row),flush=True)
   if child.returncode or not output.exists():raise SystemExit(1)
   result=json.loads(output.read_text());assert result['temporaryAssetsDeleted']
if __name__=='__main__':main()

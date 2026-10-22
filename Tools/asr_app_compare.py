"""Serial optimized-app ASR check; one candidate/process/temp root at a time."""
import argparse,fcntl,hashlib,importlib.util,json,os,shutil,signal,subprocess,time,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
from run_asr_live_serial import context

def memory_sampler(pid):
 spec=importlib.util.spec_from_file_location('asr_existing_model_bench',ROOT/'Scripts/model-bench.py')
 module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
 sampler=module.Sampler(pid,1,float('inf'));sampler.pid=pid;sampler.start()
 return sampler

def main():
 def interrupted(signum, frame): raise KeyboardInterrupt("diagnostic parent interrupted")
 signal.signal(signal.SIGTERM,interrupted)
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
   beforeContext=context();began=time.monotonic();reason=None
   with tempfile.TemporaryDirectory(prefix='app-http-',dir=cache) as http_temp, (args.output/f'{model}.log').open('w') as log:
    child=subprocess.Popen(command,stdout=log,stderr=subprocess.STDOUT,start_new_session=True,env={**os.environ,'TMPDIR':http_temp+os.sep})
    sampler=None
    try:
     sampler=memory_sampler(child.pid)
     while child.poll() is None:
      if shutil.disk_usage(cache).free<1536*1024**2:reason='disk below1.5GiB'
      if time.monotonic()-began>600:reason='bounded600s diagnostic deadline'
      if reason:
       os.killpg(child.pid,signal.SIGKILL);child.wait();break
      time.sleep(.5)
    except BaseException as error:
     if child.poll() is None:os.killpg(child.pid,signal.SIGKILL);child.wait()
     reason='parent interrupted: '+repr(error)
    finally:
     if sampler is not None:sampler.finish()
   deleted=[]
   for folder in set(cache.glob('app-*'))-beforeRoots:
    marker=folder/'.pid'
    if marker.is_file() and marker.read_text().strip()==str(child.pid):
     shutil.rmtree(folder);deleted.append(str(folder))
   row=dict(model=model,appSHA256=binarySHA,command=command,exit=child.returncode,seconds=time.monotonic()-began,stopped=reason,freeBefore=before,freeAfter=shutil.disk_usage(cache).free,ownedFailureRootsDeleted=deleted,childJoined=child.poll() is not None,httpTemporaryDeleted=not Path(http_temp).exists())
   (args.output/f'{model}-context.json').write_text(json.dumps(dict(before=beforeContext,after=context(),memory=sampler.result() if sampler else None),indent=2)+'\n')
   results.append(row);(args.output/'runner.json').write_text(json.dumps(results,indent=2)+'\n');print(json.dumps(row),flush=True)
   if child.returncode or not output.exists():raise SystemExit(1)
   result=json.loads(output.read_text());assert result['temporaryAssetsDeleted']
   from asr_live import fixture
   from asr_benchmark import error_rate
   quality=[]
   for trial in result['trials']:
    _, reference, identity=fixture(trial['language'])
    quality.append(dict(language=trial['language'],trial=trial['index'],fixture=identity,**error_rate(reference,trial['text'])))
   (args.output/f'{model}-quality.json').write_text(json.dumps(dict(scope='Literal parent-scored WER on actual app final;20EN/22FR authored reference words, number formatting can count as errors; not general accuracy.',trials=quality),indent=2)+'\n')
if __name__=='__main__':main()

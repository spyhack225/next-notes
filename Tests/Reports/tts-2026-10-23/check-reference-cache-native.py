"""Bounded native compiler interruption, no microphone/playback or model download."""
from pathlib import Path
import subprocess,time,signal,json,sys,shutil
repo=Path(__file__).resolve().parents[3];sys.path.insert(0,str(repo/'Tools'))
from tts_asr_workload import compiler_cache_entries
from tts_compare import save
out=Path(__file__).resolve().parent/'reference-cache-native'
assert not out.exists();out.mkdir()
cache=Path.home()/'Library/Caches/runtime-probe/com.apple.e5rt.e5bundlecache'
before=compiler_cache_entries(cache)
cmd=[sys.executable,str(repo/'Tools/tts_asr_workload.py'),'--probe',str(Path.home()/'Library/Caches/NextNotesASRBench/tts-reference-probe-fy9lx77h/runtime-probe'),'--output',str(out/'workload')]
with (out/'wrapper.log').open('w') as log:
 p=subprocess.Popen(cmd,stdout=log,stderr=log)
 reason='deadline';created=[];deadline=time.monotonic()+90
 try:
  while p.poll() is None and time.monotonic()<deadline:
   created=sorted(compiler_cache_entries(cache)-before)
   if created:reason='interrupt while external compiler bundle exists';break
   if shutil.disk_usage(repo).free<1.5*1024**3:reason='disk floor';break
   time.sleep(.1)
 finally:
  if p.poll() is None:p.send_signal(signal.SIGINT)
  p.wait(timeout=30)
receipt=json.loads((out/'workload/receipt.json').read_text())
result={'scope':'Native cancellation while compiler bundle exists, not timing/voice quality acceptance','reason':reason,'externalBundlesObserved':[str(x) for x in created],'remainingNewBundles':[str(x) for x in compiler_cache_entries(cache)-before],'wrapperExit':p.returncode,'nativeJoined':receipt['childJoined'],'temporaryAssetsDeleted':receipt['temporaryAssetsDeleted'],'compilerCacheDeleted':receipt['compilerCacheDeleted'],'ownerArtifactsUnchanged':receipt['ownerArtifactsUnchanged']}
result['pass']=bool(created) and p.returncode==0 and all(result[k] for k in ['nativeJoined','temporaryAssetsDeleted','compilerCacheDeleted','ownerArtifactsUnchanged']) and not result['remainingNewBundles']
save(out/'result.json',result);print(json.dumps(result,indent=2));raise SystemExit(0 if result['pass'] else 1)

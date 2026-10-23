"""Owner-authorized built-in route continuation; preserve levels and restore AirPods afterward."""
from pathlib import Path
import subprocess,json,hashlib,shutil
import audio_route as audio
repo=Path(__file__).resolve().parents[3];report=Path(__file__).resolve().parent
before=audio.snapshot();builtins={'input':90,'output':83}
assert all(audio.get(d,'tran')==audio.four('bltn') for d in builtins.values())
assert all(row['mute']==0 for row in before.values())
(report/'light-volume-before.json').write_text(json.dumps(before,indent=2)+'\n')
result=None
try:
 audio.route(builtins)
 audio.put(83,'volm',.6,'outp',0,audio.F)
 during=audio.snapshot();assert abs(during['output']['volumes']['0']-.6)<.001
 (report/'light-volume-during.json').write_text(json.dumps(during,indent=2)+'\n')
 app=Path.home()/'Library/Caches/NextNotesBuild/tts-output-diagnostic/Next Notes.app/Contents/MacOS/NextNotes'
 paths=['Sources/NextNotes/Agent/Speech/TTSOutputProbe.swift','Sources/NextNotes/Agent/Speech/TTSFirstAudioBenchmark.swift','Tests/Reports/tts-2026-10-22/final-controls/package-resource-accessors-candidate.py','Tools/tts_compare.py','Tools/tts_asr_workload.py']
 pins={'binarySHA256':hashlib.file_digest(app.open('rb'),'sha256').hexdigest(),'sourceSHA256':{x:hashlib.sha256((repo/x).read_bytes()).hexdigest() for x in paths},'hardwareLevels':during,'freeBytesBefore':shutil.disk_usage(repo).free,'admissionNote':'Existing swap rose to12.3GiB during the joined peer909-source build; this explicitly recorded diagnostic admission allows14GiB existing swap, with unchanged2GiB download reserve, per-model budgets and live1.5GiB stop. No compiler/inference competes. Not a low-pressure or cold-system result.','method':'Continuation only uncompleted Kokoro,Apple,Qwen; same f8 binary,60% built-in route,gain.75,30 varied warm+separate first-after-prepare. Same paced reference v3 after TTS preparation. Compiler artifact cleanup after join now verified. Phonon/Pocket completed earlier serial-speaker cohort retained without replacement.'}
 (report/'light-source-pins.json').write_text(json.dumps(pins,indent=2)+'\n')
 args=['python3',str(repo/'Tools/tts_compare.py'),'--app',str(app),'--output',str(report/'light-speaker'),'--engines','kokoro,apple','--trials','30','--speaker-output','--timeout','900','--relay-owner','codex-tts-20261022','--max-swap-gb','14','--reference-asr-probe',str(Path.home()/'Library/Caches/NextNotesASRBench/tts-reference-probe-fy9lx77h/runtime-probe'),'--workload',pins['method']]
 (report/'light-command.json').write_text(json.dumps(args,indent=2)+'\n')
 result=subprocess.run(args,cwd=repo)
finally:
 current=audio.snapshot()
 expected=audio.selected()==builtins and abs(current['output']['volumes'].get('0',0)-.6)<.001
 if expected:
  audio.restore_levels(before)
  # AirPods were disconnected by the owner before this continuation. Their
  # former IDs are restored only if still available; otherwise UI reconnect follows.
  available=all(audio.get(d,'tran') is not None for d in [101,95])
  if available:audio.route({'input':101,'output':95})
 else:available=False
 after={'levels':audio.snapshot(),'builtInLevelsRestored':expected,'airPodsRouteRestored':available,'manualRouteOrVolumeChangePreserved':not expected,'airPodsReconnectPending':expected and not available}
 (report/'light-volume-after.json').write_text(json.dumps(after,indent=2)+'\n')
print('AUTHORIZED_COHORT_EXIT',result.returncode if result else 'launch-failed')
raise SystemExit(result.returncode if result else 1)

"""One serial controlled cohort; restore the owner's speaker level on every exit."""
from pathlib import Path
import subprocess,json,hashlib,shutil
repo=Path(__file__).resolve().parents[3]
report=repo/'Tests/Reports/tts-2026-10-23'
helper='/tmp/nextnotes-tts-levels'
before=json.loads(subprocess.check_output([helper],text=True)); output=next(x for x in before if x['scope']=='output')
assert output['muted']==0 and 0<output['volume0']<=1
(report/'serial-volume-before.json').write_text(json.dumps(before,indent=2)+'\n')
try:
 calibrated=json.loads(subprocess.check_output([helper,'--set-output','.6'],text=True))
 assert abs(next(x for x in calibrated if x['scope']=='output')['volume0']-.6)<.001
 (report/'serial-volume-during.json').write_text(json.dumps(calibrated,indent=2)+'\n')
 app=Path('/Users/sergekadjo/Library/Caches/NextNotesBuild/tts-output-diagnostic/Next Notes.app/Contents/MacOS/NextNotes')
 pins={'binarySHA256':hashlib.file_digest(app.open('rb'),'sha256').hexdigest(),'sourceSHA256':{x:hashlib.sha256((repo/x).read_bytes()).hexdigest() for x in ['Sources/NextNotes/Agent/Speech/TTSOutputProbe.swift','Sources/NextNotes/Agent/Speech/TTSFirstAudioBenchmark.swift','Tests/Reports/tts-2026-10-22/final-controls/package-resource-accessors-candidate.py','Tools/tts_compare.py']},'hardwareLevels':calibrated,'freeBytesBefore':shutil.disk_usage(repo).free,'method':'All five same-binary;25-token joined decode,500ms immediate baseline,same4x/.001 RMS and.75 correlation,two10ms onset windows;30 varied warm requests plus separate first-after-prepare. Each model prepares before its own identical cached v3 reference decoder; ASR active throughout timing; both joined and temporary assets deleted before next.'}
 (report/'serial-source-pins.json').write_text(json.dumps(pins,indent=2)+'\n')
 args=['python3',str(repo/'Tools/tts_compare.py'),'--app',str(app),'--output',str(report/'serial-speaker'),'--engines','phonon,pocket,kokoro,apple,qwen','--trials','30','--speaker-output','--timeout','900','--relay-owner','codex-tts-20261022','--max-swap-gb','12','--reference-asr-probe','/Users/sergekadjo/Library/Caches/NextNotesASRBench/tts-reference-probe-fy9lx77h/runtime-probe','--workload',pins['method']]
 (report/'serial-command.json').write_text(json.dumps(args,indent=2)+'\n')
 result=subprocess.run(args,cwd=repo)
finally:
 current=json.loads(subprocess.check_output([helper],text=True)); level=next(x for x in current if x['scope']=='output')['volume0']
 if abs(level-.6)<.001:
  after=json.loads(subprocess.check_output([helper,'--set-output',str(output['volume0'])],text=True));restored=True
 else:after=current;restored=False
 (report/'serial-volume-after.json').write_text(json.dumps({'levels':after,'restored':restored,'manualChangePreserved':not restored},indent=2)+'\n')
print('SERIAL_COHORT_EXIT',result.returncode)
raise SystemExit(result.returncode)

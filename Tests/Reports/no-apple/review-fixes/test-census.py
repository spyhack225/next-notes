from pathlib import Path
import subprocess,tempfile,shutil,sys,json
scanner=Path(sys.argv[1]).resolve()
cases={'Sources/NextNotes/Renamed.swift':'let engine = NSSpeechSynthesizer()','Sources/NextNotes/Another.swift':'import class AVFoundation.AVSpeechUtterance','Sources/NextNotes/UI/Settings/ModelsSettingsTab.swift':'let engine = AVSpeechSynthesizer()','Tools/tts_benchmark.swift':'let surprise = NSSpeechSynthesizer()','Scripts/renamed.sh':'/usr/bin/say hello','Makefile':'voice:\n\tsay hello','Tools/voice.py':'subprocess.run(["/usr/bin/say", "hello"])'}
misses=[]
for path,body in cases.items():
    with tempfile.TemporaryDirectory(prefix='NextNotes-noapple-census-') as tmp:
        root=Path(tmp);p=root/path;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(body)
        location=root/'Tests/Reports/no-apple/check-sink.py';location.parent.mkdir(parents=True,exist_ok=True);shutil.copy(scanner,location)
        manifest=scanner.parent/'speech-source-allowlist.json'
        if manifest.exists():shutil.copy(manifest,location.parent/manifest.name)
        proc=subprocess.run([sys.executable,str(location)],capture_output=True,text=True)
        if proc.returncode==0:misses.append(path)
print(json.dumps({'undetected':misses,'cases':len(cases)}))
print('VOICE_CENSUS_MUTATIONS_FAILED' if misses else 'VOICE_CENSUS_MUTATIONS_OK')
sys.exit(bool(misses))

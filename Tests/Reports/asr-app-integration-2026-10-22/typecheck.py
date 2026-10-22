import json,subprocess,time,os,signal,shutil
from pathlib import Path
root=Path(__file__).resolve().parents[3];out=Path(__file__).resolve().parent
command=json.loads((root/'Tests/Reports/tts-2026-10-22/typecheck-command.json').read_text())
command=[x for x in command if not x.endswith('.swift')]
command += sorted(str(p) for p in (root/'Sources/NextNotes').rglob('*.swift'))
headers=root/'Vendor/PhononASR/Binaries/PhononTDT.xcframework/macos-arm64_x86_64/Headers'
command += ['-I',str(headers),'-Xcc','-I','-Xcc',str(headers)]
cache=Path.home()/'Library/Caches/NextNotesBuild/scratch'
command += ['-Xcc','-fmodule-map-file='+str(cache/'arm64-apple-macosx/release/CHostBridge.build/module.modulemap'),'-Xcc','-I','-Xcc',str(cache/'checkouts/desert-ant-core/Sources/CHostBridge/include')]
(out/'typecheck-command.json').write_text(json.dumps(command,indent=2)+'\n')
began=time.monotonic()
with (out/'typecheck.log').open('w') as log:
 child=subprocess.Popen(command,cwd=root,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
 while child.poll() is None:
  if time.monotonic()-began>240 or shutil.disk_usage(root).free<1280*1024**2:
   os.killpg(child.pid,signal.SIGKILL);child.wait();break
  time.sleep(.5)
result=dict(exit=child.returncode,seconds=time.monotonic()-began)
(out/'typecheck-result.json').write_text(json.dumps(result,indent=2)+'\n');print(result)
raise SystemExit(child.returncode)

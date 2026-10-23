"""Owner-authorized exact obsolete build cleanup; preserve runtime/reproduction builds."""
from pathlib import Path
import hashlib,json,plistlib,shutil,subprocess,zipfile,os
root=Path.home()/'Library/Caches/NextNotesBuild'
report=Path(__file__).resolve().parent
receipt={'freeBytesBefore':shutil.disk_usage(root).free,'removed':[],'compressed':[],'reason':'Owner explicitly requested obsolete build cleanup. Nine20October installer stages superseded by verified22October installed809. ModuleCache belongs to removed dictation-perf worktree. Old Xcode dSYMs compressed with verified hashes; executables/resources remain.'}
def digest(p):
 with p.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def idle(p):
 r=subprocess.run(['lsof','-nP','+D',str(p)],capture_output=True,text=True)
 assert r.returncode==1 and not r.stdout and not r.stderr,(p,r.stdout,r.stderr)
def inventory(p):
 return {str(f.relative_to(p)):{'bytes':f.stat().st_size,'sha256':digest(f)} for f in p.rglob('*') if f.is_file() and not f.is_symlink()}
protected=[Path('/Applications/Next Notes.app/Contents/MacOS/NextNotes'),root/'tts-output-diagnostic/Next Notes.app/Contents/MacOS/NextNotes']
protected += list((root/'rollback').glob('*/Next Notes.app/Contents/MacOS/NextNotes'))
receipt['protectedSHA256Before']={str(p):digest(p) for p in protected}
receipt_path=report/'cleanup-obsolete.json'
def save():receipt_path.write_text(json.dumps(receipt,indent=2)+'\n')
for name in ['install-91723','install-578','install-1412','install-1931','install-2614','install-3403','install-3959','install-4532','install-5111']:
 p=root/name
 if not p.exists():continue
 assert set(c.name for c in p.iterdir())=={'Next Notes.app'}
 idle(p)
 info=plistlib.loads((p/'Next Notes.app/Contents/Info.plist').read_bytes())
 row={'path':str(p),'bundleVersion':info.get('CFBundleVersion'),'inventory':inventory(p),'freeBytesBefore':shutil.disk_usage(root).free,'openFiles':0}
 receipt['removed'].append(row);save()
 shutil.rmtree(p);row['removed']=not p.exists();row['freeBytesAfter']=shutil.disk_usage(root).free;save()
p=root/'claude-scratch/arm64-apple-macosx/release/ModuleCache'
if p.exists():
 idle(p);row={'path':str(p),'logicalBytes':sum(f.stat().st_size for f in p.rglob('*') if f.is_file()),'openFiles':0};receipt['removed'].append(row);save();shutil.rmtree(p);row['removed']=not p.exists();save()
archive=root/'tts-output-diagnostic/legacy-xcode-symbols.zip'
assert not archive.exists()
symbols=[root/x for x in ['claude-scratch/out/Products/Release/NextNotes.dSYM','wt-scratch/voice-ack/out/Products/Release/NextNotes.dSYM','scratch/out/Products/Release/NextNotes.dSYM'] if (root/x).exists()]
for p in symbols:idle(p)
expected={str(f.relative_to(root)):digest(f) for p in symbols for f in p.rglob('*') if f.is_file()}
with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED,compresslevel=6) as z:
 for name in expected:z.write(root/name,name)
with zipfile.ZipFile(archive) as z:
 assert z.testzip() is None
 for name,value in expected.items():assert hashlib.sha256(z.read(name)).hexdigest()==value
receipt['compressed'].append({'archive':str(archive),'archiveBytes':archive.stat().st_size,'archiveSHA256':digest(archive),'originalFiles':expected,'allArchivedHashesVerified':True});save()
for p in symbols:idle(p);shutil.rmtree(p)
receipt['protectedSHA256After']={str(p):digest(p) for p in protected}
assert receipt['protectedSHA256After']==receipt['protectedSHA256Before']
receipt['freeBytesAfter']=shutil.disk_usage(root).free
receipt['observedFreeGainBytes']=receipt['freeBytesAfter']-receipt['freeBytesBefore'];save()
print(json.dumps({k:v for k,v in receipt.items() if k in ['freeBytesBefore','freeBytesAfter','observedFreeGainBytes']}))

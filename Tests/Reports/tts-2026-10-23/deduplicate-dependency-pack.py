"""Share blocks of identical, idle vendor dSYMs; preserve paths, bytes and metadata."""
from pathlib import Path
import hashlib,json,os,stat,subprocess,shutil,uuid
base=Path.home()/'Library/Caches/NextNotesBuild'
paths=[base/'scratch/repositories/FluidAudio-08d244c7/objects/pack/pack-9812aaab96ae66285aa541a501b1683b675fef57.pack',base/'wt-scratch/voice-ack/repositories/FluidAudio-08d244c7/objects/pack/pack-9812aaab96ae66285aa541a501b1683b675fef57.pack']
def digest(p):
 with p.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def attrs(p):
 keys=subprocess.check_output(['/usr/bin/xattr',str(p)],text=True).splitlines()
 # macOS assigns new per-inode provenance to a normal copy. Do not modify it.
 return tuple((key,subprocess.check_output(['/usr/bin/xattr','-p',key,str(p)])) for key in sorted(keys) if key!='com.apple.provenance')
seen={};rows=[];free=shutil.disk_usage(base).free
for p in paths:
 before=p.stat(); x=attrs(p); h=digest(p)
 key=(h,before.st_size,stat.S_IMODE(before.st_mode),before.st_uid,before.st_gid,before.st_flags,x)
 if key not in seen:seen[key]=p;continue
 canonical=seen[key]
 # Do not replace an in-use symbol file, even with identical data.
 opened=subprocess.run(['lsof','-t','--',str(p),str(canonical)],capture_output=True,text=True)
 if opened.stdout.strip():rows.append({'path':str(p),'skipped':'open'});continue
 tmp=p.with_name('.tts-cow-'+uuid.uuid4().hex)
 try:
  subprocess.run(['/bin/cp','-c','-p',str(canonical),str(tmp)],check=True)
  shutil.copystat(p,tmp)
  assert digest(tmp)==h and attrs(tmp)==x
  now=p.stat();assert (now.st_ino,now.st_size,now.st_mtime_ns)==(before.st_ino,before.st_size,before.st_mtime_ns)
  oldfree=shutil.disk_usage(base).free
  os.replace(tmp,p)
  after=p.stat();assert after.st_size==before.st_size and after.st_mtime_ns==before.st_mtime_ns and attrs(p)==x
  rows.append({'path':str(p),'canonical':str(canonical),'sha256':h,'bytes':before.st_size,'bytesTimesModesAndOrdinaryAttributesPreserved':True,'availableBytesDelta':shutil.disk_usage(base).free-oldfree})
 finally:
  if tmp.exists():tmp.unlink()
result={'scope':'Exact-content APFS cloning of one idle identical FluidAudio dependency Git pack into the removed-worktree cache; no repository, reference, model, user file or app executable removed. Original paths, bytes, timestamps, modes and ordinary attributes retained; macOS assigns per-inode provenance for clones. Available-space change may also include OS pressure recovery.','freeBytesBefore':free,'freeBytesAfter':shutil.disk_usage(base).free,'files':rows}
Path(__file__).with_suffix('.json').write_text(json.dumps(result,indent=2)+'\n');print({k:result[k] for k in ('freeBytesBefore','freeBytesAfter')});print('Preserved cloned Git packs',len(rows))

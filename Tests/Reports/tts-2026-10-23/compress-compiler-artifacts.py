"""Transparent compression of idle project compiler artifacts, preserving logical bytes."""
from pathlib import Path
import hashlib,json,os,stat,subprocess,shutil,uuid
base=Path.home()/'Library/Caches/NextNotesBuild/scratch/arm64-apple-macosx/release'
tool=Path.home()/'Library/Caches/NextNotesBuild/tts-output-diagnostic/compression-tool/afsctool/1.7.3/bin/afsctool'
idle=subprocess.run(['lsof','-t','+D',str(base)],capture_output=True,text=True);assert idle.returncode==1 and not idle.stdout
paths=list((base/'ModuleCache').rglob('*.pcm'))+list((base/'ModuleCache').glob('*.swiftmodule'))+list((base/'Modules').glob('*.swiftmodule'))
for folder in base.glob('*.build'):paths+=list(folder.rglob('*.o'))
paths=sorted(set(paths),key=lambda p:p.stat().st_size)
result={'scope':'Idle NextNotes compiler objects and module cache only; preserve logical bytes, original paths, modes and nanosecond mtime. No source, linked executable, framework runtime, dSYM, model or owner file changed. APFS compression/provenance metadata naturally changes; no global compiler cache touched.','toolSource':'https://github.com/RJVB/afsctool','homebrewBottleSHA256':'2062dc7cb1f0f2ecf20071f0ba204c58adace79e59c033146db513a454d83964','freeBytesBefore':shutil.disk_usage(base).free,'files':[]}
report=Path(__file__).with_suffix('.json')
def digest(p):
 with p.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
for p in paths:
 before=p.stat()
 if p.is_symlink() or before.st_nlink!=1 or not 100_000<=before.st_size<=64_000_000 or before.st_flags&0x20:continue
 h=digest(p);tmp=p.with_name('.tts-compress-'+uuid.uuid4().hex)
 try:
  subprocess.run(['/bin/cp','-c','-p',str(p),str(tmp)],check=True)
  r=subprocess.run([str(tool),'-c','-T','LZFSE',str(tmp)],capture_output=True,text=True)
  assert r.returncode==0,(str(p),r.stderr)
  assert digest(tmp)==h,'Compression changed logical bytes'
  os.utime(tmp,ns=(before.st_atime_ns,before.st_mtime_ns))
  after=tmp.stat();assert (after.st_size,after.st_mtime_ns,stat.S_IMODE(after.st_mode),after.st_uid,after.st_gid)==(before.st_size,before.st_mtime_ns,stat.S_IMODE(before.st_mode),before.st_uid,before.st_gid)
  if after.st_blocks>=before.st_blocks:continue
  now=p.stat();assert (now.st_ino,now.st_size,now.st_mtime_ns)==(before.st_ino,before.st_size,before.st_mtime_ns)
  os.replace(tmp,p)
  result['files'].append({'path':str(p),'sha256':h,'logicalBytes':before.st_size,'allocatedBefore':before.st_blocks*512,'allocatedAfter':after.st_blocks*512,'mtimeUnchanged':True,'modeUnchanged':True})
  if len(result['files'])%50==0:report.write_text(json.dumps(result,indent=2)+'\n');print('Compressed verified artifacts',len(result['files']),flush=True)
 finally:
  if tmp.exists():tmp.unlink()
result['freeBytesAfter']=shutil.disk_usage(base).free
result['sumAllocatedReduction']=sum(r['allocatedBefore']-r['allocatedAfter'] for r in result['files'])
report.write_text(json.dumps(result,indent=2)+'\n');print({k:result[k] for k in ['freeBytesBefore','freeBytesAfter','sumAllocatedReduction']})

"""Retain old idle Xcode reproduction executables as verified compact archives."""
from pathlib import Path
import hashlib,json,os,shutil,stat,subprocess,zipfile
root=Path.home()/'Library/Caches/NextNotesBuild'
out=root/'retired-executables';out.mkdir(exist_ok=True)
report=Path(__file__).with_suffix('.json');rows=[]
result={'scope':'Old Xcode Products executables only. Runtime resources stay at original paths; exact executables remain recoverable from individual verified archives. Current SwiftPM output, installed app, rollback and current TTS diagnostic untouched. No unique source/repository/model/owner file deleted.','freeBytesBefore':shutil.disk_usage(root).free,'files':rows}
for name in ['claude-scratch/out/Products/Debug/NextNotes','claude-scratch/out/Products/Release/NextNotes','wt-scratch/voice-ack/out/Products/Release/NextNotes','scratch/out/Products/Debug/NextNotes','scratch/out/Products/Release/NextNotes']:
 p=root/name
 if not p.exists():continue
 assert not p.is_symlink()
 idle=subprocess.run(['lsof','-t','--',str(p)],capture_output=True,text=True);assert idle.returncode==1 and not idle.stdout
 def digest(f):
  with f.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()
 h=digest(p);before=p.stat();archive=out/(name.replace('/','-')+'.zip');assert not archive.exists()
 with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED,compresslevel=3) as z:z.write(p,name)
 with archive.open('rb') as stream:os.fsync(stream.fileno())
 with zipfile.ZipFile(archive) as z:
  assert z.testzip() is None
  with z.open(name) as stream:assert hashlib.file_digest(stream,'sha256').hexdigest()==h
 row={'originalPath':str(p),'originalSHA256':h,'originalBytes':before.st_size,'originalMode':stat.S_IMODE(before.st_mode),'archive':str(archive),'archiveBytes':archive.stat().st_size,'archiveSHA256':digest(archive),'verifiedRecoverable':True};rows.append(row)
 report.write_text(json.dumps(result,indent=2)+'\n')
 assert digest(p)==h;p.unlink();row['uncompressedRetired']=not p.exists()
result['freeBytesAfter']=shutil.disk_usage(root).free;report.write_text(json.dumps(result,indent=2)+'\n');print({k:v for k,v in result.items() if k.startswith('freeBytes')})

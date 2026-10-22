"""Prepared test-only observer. No native launch or file-content reads.
Call snapshot() only with the exact disposable TMPDIR assigned to one fixture.
"""
import os,time,pathlib,ctypes,struct
class OwnedTempMetadata:
 def __init__(self,root,limit=2000):
  self.root=pathlib.Path(root).resolve(); self.limit=limit; self.previous={}; self.events=[]
  assert self.root.name.startswith('DictationASRAttribution-'), 'exact owned fixture temp root required'
 def snapshot(self):
  stack=[self.root]; current={}; seen=0; denied=0; truncated=False
  while stack:
   base=stack.pop()
   try:entries=list(os.scandir(base))
   except OSError:denied+=1;continue
   for e in entries:
    seen+=1
    if seen>self.limit:truncated=True;stack.clear();break
    try:
     if e.is_symlink():continue
     if e.is_dir(follow_symlinks=False):stack.append(pathlib.Path(e.path));continue
     if not e.is_file(follow_symlinks=False):continue
     st=e.stat(follow_symlinks=False)
     current[str(pathlib.Path(e.path).relative_to(self.root))]=(st.st_size,st.st_blocks*512,st.st_ino,st.st_mtime_ns)
    except OSError:denied+=1
  changed={name:list(meta) for name,meta in current.items() if self.previous.get(name)!=meta}
  removed=[name for name in self.previous if name not in current] if not truncated and denied==0 else []
  v=os.statvfs('/')
  frame={'monotonic':time.monotonic(),'changedFiles':changed,'removedFiles':removed,'observedLogicalBytes':sum(x[0] for x in current.values()),'observedAllocatedBytes':sum(x[1] for x in current.values()),'freeDiskBytes':v.f_bavail*v.f_frsize,'entriesSeen':seen,'unreadableDirectories':denied,'truncated':truncated}
  self.previous=current;self.events.append(frame);return frame
 def compiler_metadata(self):
  # Services belong to the OS. Observation does not imply ownership or exclusive cost.
  import subprocess
  rows=[];lib=ctypes.CDLL('/usr/lib/libproc.dylib')
  for line in subprocess.check_output(['ps','-axo','pid=,args='],text=True).splitlines():
   parts=line.strip().split(None,1)
   if len(parts)!=2 or not parts[1].startswith('/System/Library/PrivateFrameworks/AppleNeuralEngine.framework/XPCServices/ANECompilerService.xpc/'):continue
   pid=int(parts[0]);buf=ctypes.create_string_buffer(1024);ok=lib.proc_pid_rusage(pid,4,ctypes.byref(buf))==0
   if ok:
    v=struct.unpack_from('10Q',buf.raw,16);rows.append({'pid':pid,'processStart':v[8],'footprintBytes':v[7],'residentBytes':v[6],'scope':'OS service; not owned or exclusively attributed'})
   else:rows.append({'pid':pid,'countersUnavailable':True,'scope':'OS service; not owned or exclusively attributed'})
  return rows

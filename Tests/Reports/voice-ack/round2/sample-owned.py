"""Read-only one-second samples of this batch's owned native processes."""
import ctypes,json,subprocess,time
from pathlib import Path
r=Path(__file__).resolve().parent
scratch=str(Path.home()/'Library/Caches/NextNotesBuild/wt-scratch/voice-ack/release/NextNotes')
class Usage(ctypes.Structure):
    _fields_=[('uuid',ctypes.c_uint8*16)]+[(n,ctypes.c_uint64) for n in ['user_time','system_time','pkg_idle_wkups','interrupt_wkups','pageins','wired_size','resident_size','phys_footprint','start','exit']]
lib=ctypes.CDLL('/usr/lib/libproc.dylib');lib.proc_pid_rusage.argtypes=[ctypes.c_int,ctypes.c_int,ctypes.c_void_p];lib.proc_pid_rusage.restype=ctypes.c_int
samples={};started=time.time()
while time.time()-started<1800:
    lines=subprocess.check_output(['ps','-axo','pid=,command='],text=True).splitlines()
    drivers=[x for x in lines if 'python3 Tests/Reports/voice-ack/round2/run-batch.py' in x and 'heavy.sh' not in x and 'exec_command' not in x]
    for line in lines:
        parts=line.strip().split(None,1)
        if len(parts)<2 or not parts[1].startswith(scratch+' --selftest-'):continue
        pid=int(parts[0]);u=Usage()
        if lib.proc_pid_rusage(pid,0,ctypes.byref(u))!=0:continue
        key=str(pid)+':'+str(u.start)
        if key not in samples:samples[key]=dict(pid=pid,start=u.start,command=parts[1],rows=[])
        samples[key]['rows'].append(dict(utc=time.time(),rss=u.resident_size,footprint=u.phys_footprint,wired=u.wired_size))
    (r/'owned-process-samples.json').write_text(json.dumps(dict(scope='1s sampled own processes only; hosted services/children excluded; not continuous peaks',runs=samples),indent=2)+'\n')
    if not drivers and (r/'batch-finished.json').exists():break
    time.sleep(1)

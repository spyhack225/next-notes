"""Bounded live diagnostic: process metadata only; SIGSTOP on rapid large growth.

Use on the explicitly authorized live reproduction. Never kills/restarts the app.
"""
import ctypes,datetime,itertools,json,os,pathlib,re,signal,subprocess,sys,time
pid=int(sys.argv[1])
out=pathlib.Path(sys.argv[2]);out.mkdir(parents=True,exist_ok=False)
limit=int(sys.argv[3]) if len(sys.argv)>3 else 2_500_000_000
duration=float(sys.argv[4]) if len(sys.argv)>4 else 600
assert 0 < duration <= 7200
class ResourceUsage(ctypes.Structure):
    # SDK sys/resource.h rusage_info_v0, queried without task suspension/VM scans.
    _fields_=[('uuid',ctypes.c_uint8*16)]+[(name,ctypes.c_uint64) for name in (
        'user','system','idle','wakeups','pageins','wired','resident','footprint','start','exit')]
libproc=ctypes.CDLL('/usr/lib/libproc.dylib')
libproc.proc_pid_rusage.argtypes=[ctypes.c_int,ctypes.c_int,ctypes.c_void_p]
libproc.proc_pid_rusage.restype=ctypes.c_int
def usage():
    value=ResourceUsage()
    if libproc.proc_pid_rusage(pid,0,ctypes.byref(value))!=0:
        raise RuntimeError('process resource query unavailable')
    return value
identity=usage().start
def utc():return datetime.datetime.now(datetime.timezone.utc).isoformat()
def command(args,path,timeout=8):
    with path.open('w') as f:
        try:return subprocess.run(args,stdout=f,stderr=subprocess.STDOUT,timeout=timeout).returncode
        except subprocess.TimeoutExpired:return 'timeout'
print(json.dumps({'event':'armed','pid':pid,'limit_bytes':limit,'duration_seconds':duration,'at':utc(),'output':str(out)}),flush=True)
baseline=None;previous=None;snapshot_done=False
deadline=time.monotonic()+duration
with (out/'samples.jsonl').open('w',buffering=1) as f:
    for iteration in itertools.count():
        if time.monotonic()>=deadline:break
        began=time.monotonic()
        try:
            value=usage()
            if value.start!=identity:raise RuntimeError('process identity changed')
            size=value.footprint;baseline=baseline or size
            row={'at':utc(),'footprint_bytes':size,'resident_bytes':value.resident,
                 'user_ns':value.user,'system_ns':value.system,'pageins':value.pageins}
            f.write(json.dumps(row)+'\n')
            if previous is None or abs(size-previous)>100_000_000 or iteration%50==0:
                print(json.dumps({'at':row['at'],'bytes':size,'delta_baseline':size-baseline}),flush=True)
            previous=size
            if size>=limit:
                # Reversible emergency boundary; preserve the allocation state.
                os.kill(pid,signal.SIGSTOP)
                (out/'paused.json').write_text(json.dumps({'at':utc(),'pid':pid,'bytes':size,'signal':'SIGSTOP','resume_required':True},indent=2)+'\n')
                print(json.dumps({'event':'PAUSED_NEXT_NOTES','pid':pid,'bytes':size,'at':utc()}),flush=True)
                command(['/usr/bin/footprint','-p',str(pid),'-f','bytes'],out/'paused-footprint.txt')
                command(['/usr/bin/vmmap','-summary',str(pid)],out/'paused-vmmap.txt')
                command(['/usr/bin/sample',str(pid),'2','1','-file',str(out/'paused-stacks.txt')],out/'paused-sample-status.txt')
                break
            if not snapshot_done and size-baseline>250_000_000:
                # Do not block the memory guard on diagnostic collection.
                with (out/'growth-footprint.txt').open('w') as target:
                    subprocess.Popen(['/usr/bin/footprint','-p',str(pid),'-f','bytes'],stdout=target,stderr=subprocess.STDOUT)
                with (out/'growth-vmmap.txt').open('w') as target:
                    subprocess.Popen(['/usr/bin/vmmap','-summary',str(pid)],stdout=target,stderr=subprocess.STDOUT)
                subprocess.Popen(['/usr/bin/sample',str(pid),'2','1','-file',str(out/'growth-stacks.txt')],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
                snapshot_done=True
        except (ProcessLookupError,RuntimeError,subprocess.TimeoutExpired) as error:
            print(json.dumps({'event':'monitor_failed','error':str(error),'at':utc()}),flush=True);break
        time.sleep(max(0,0.1-(time.monotonic()-began)))
print(json.dumps({'event':'monitor_finished','at':utc()}),flush=True)

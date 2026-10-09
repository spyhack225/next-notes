#!/usr/bin/env python3
"""Owned measurement supervisor; no app/source/settings changes."""
import ctypes, json, os, re, shutil, subprocess, sys, time, signal
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
PROJECT='/Users/sergekadjo/Documents/Claude/Projects/speechify'
OUT=Path(sys.argv[1]); LARGE=sys.argv[2]=='large'; COMMAND=sys.argv[3:]
def relay(*args):
    return subprocess.run(['agent-relay', *args, '--project', PROJECT], capture_output=True, text=True)
def state():
    swap=subprocess.check_output(['sysctl','vm.swapusage'],text=True)
    m=re.search(r'used\s*=\s*([\d.]+)([MG])',swap)
    if not m: raise RuntimeError('swap unreadable')
    return dict(utc=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()), load=os.getloadavg(),swapGiB=float(m[1])/(1024 if m[2]=='M' else 1), freeGiB=shutil.disk_usage(ROOT).free/1024**3)
# Darwin's rusage_info_v0: physical footprint is distinct from resident size.
class RI0(ctypes.Structure):
    _fields_=[('uuid',ctypes.c_uint8*16)]+[(name,ctypes.c_uint64) for name in
        ('userTime','systemTime','idleWakeups','interruptWakeups','pageins','wiredBytes','residentBytes','footprintBytes','startAbstime','exitAbstime')]
libproc=ctypes.CDLL('/usr/lib/libproc.dylib',use_errno=True)
libproc.proc_pid_rusage.argtypes=[ctypes.c_int,ctypes.c_int,ctypes.c_void_p]
libproc.proc_pid_rusage.restype=ctypes.c_int
def owned_usage(census,ancestor):
    rows={}
    for line in census.splitlines():
        fields=line.split(None,3)
        if len(fields)==4: rows[int(fields[0])]=(int(fields[1]),fields[3])
    observed=[]
    for pid,(parent,name) in rows.items():
        current=pid;seen=set()
        while current in rows and current not in seen and current!=ancestor:
            seen.add(current);current=rows[current][0]
        if current!=ancestor: continue
        info=RI0();result=libproc.proc_pid_rusage(pid,0,ctypes.byref(info))
        observed.append(dict(pid=pid,name=name,available=result==0,
            residentBytes=info.residentBytes if result==0 else None,
            footprintBytes=info.footprintBytes if result==0 else None,
            startAbstime=info.startAbstime if result==0 else None))
    return observed
initial=state()
# Apply the owner's 4–5 GB artifact rule to bytes, not parameter counts.
if '--model' in COMMAND:
    pin=COMMAND[COMMAND.index('--model')+1]
    if pin!='apple':
        basename=pin.rsplit('/',1)[-1]
        candidates=[r['path'] for r in json.loads((ROOT/'evidence/2026-10-09/artifact-stats.json').read_text())
                    if Path(r['path']).name==basename or Path(r['path']).name.endswith('--'+basename)]
        if len(candidates)==1:
            artifact=Path(candidates[0]);size=artifact.stat().st_size
            initial.update(artifactPath=str(artifact),artifactBytes=size)
            LARGE=size>=4_000_000_000
initial['swapLimitGiB']=6 if LARGE else 8
(OUT/'admission.json').write_text(json.dumps(initial,indent=2)+'\n')
if initial['freeGiB']<10 or initial['swapGiB']>(6 if LARGE else 8):
    print('BAKEOFF_RESOURCE_REFUSED: '+json.dumps(initial),flush=True);sys.exit(75)
claim=relay('claim','--as','claude2-bakeoff2','--scope','machine','model-evaluation')
(OUT/'model-claim.json').write_text(claim.stdout+claim.stderr)
try:
    if claim.returncode or json.loads(claim.stdout).get('ok') is not True:
        print('BAKEOFF_CLAIM_REFUSED',flush=True);sys.exit(75)
    census=subprocess.check_output(['ps','-axo','pid=,ppid=,etime=,comm='],text=True)
    (OUT/'processes-before.txt').write_text(census)
    process=subprocess.Popen(COMMAND,start_new_session=True)
    def stop(signum, frame):
        try: os.killpg(process.pid,signal.SIGTERM)
        except ProcessLookupError: pass
    signal.signal(signal.SIGTERM,stop);signal.signal(signal.SIGINT,stop)
    refused=False
    with (OUT/'machine.jsonl').open('w') as log:
        while process.poll() is None:
            sample=state()
            sample['processes']=subprocess.check_output(['ps','-axo','pid=,ppid=,rss=,comm='],text=True)
            sample['ownedUsage']=owned_usage(sample['processes'],process.pid)
            log.write(json.dumps(sample)+'\n');log.flush()
            if sample['freeGiB']<10:
                print('BAKEOFF_DISK_STOP: '+str(sample['freeGiB']),flush=True);stop(None,None);refused=True
                break
            try: process.wait(timeout=5)
            except subprocess.TimeoutExpired: pass
    try: code=process.wait(timeout=30)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid,signal.SIGKILL);code=process.wait()
    (OUT/'finish.json').write_text(json.dumps(state(),indent=2)+'\n')
    (OUT/'exit.json').write_text(json.dumps({'command':COMMAND,'returncode':code,'diskStop':refused})+'\n')
    sys.exit(75 if refused else code)
finally:
    result=relay('release','--as','claude2-bakeoff2','--scope','machine','model-evaluation')
    (OUT/'model-release.json').write_text(result.stdout+result.stderr)

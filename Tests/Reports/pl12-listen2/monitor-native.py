#!/usr/bin/env python3
"""Read-only 1s rusage-v0 samples of exactly one owned diagnostic process."""
import ctypes, json, subprocess, sys, time
from pathlib import Path
exe, output = sys.argv[1:]
class Usage(ctypes.Structure):
    _fields_ = [('uuid', ctypes.c_uint8 * 16)] + [(n, ctypes.c_uint64) for n in ['user_time','system_time','pkg_idle_wkups','interrupt_wkups','pageins','wired_size','resident_size','phys_footprint','start','exit']]
lib = ctypes.CDLL('/usr/lib/libproc.dylib')
lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
lib.proc_pid_rusage.restype = ctypes.c_int
started=time.monotonic(); pid=None; identity=None; rows=[]
def command(*args):
    return subprocess.run(args, text=True, capture_output=True).stdout.strip()
environment={'sw_vers':command('sw_vers'),'power':command('pmset','-g','batt'),'thermal_start':command('pmset','-g','therm'),'swap_start':command('sysctl','vm.swapusage'),'disk_start':command('df','-k','.'),'load_start':command('uptime')}
while time.monotonic()-started < 1200:
    if pid is None:
        for line in command('ps','-axo','pid=,command=').splitlines():
            fields=line.strip().split(None,1)
            if len(fields)==2 and fields[1].startswith(exe+' --selftest-voice-latency'):
                pid=int(fields[0]); environment['native_launch']={'swap':command('sysctl','vm.swapusage'),'load':command('uptime'),'thermal':command('pmset','-g','therm')}; break
        if pid is None: time.sleep(1); continue
    u=Usage()
    if lib.proc_pid_rusage(pid,0,ctypes.byref(u))!=0: break
    if identity is None: identity=u.start
    if u.start != identity: break
    rows.append({'t':round(time.monotonic()-started,3),'pid':pid,'start':identity,'rss':u.resident_size,'footprint':u.phys_footprint,'wired':u.wired_size})
    time.sleep(1)
environment.update({'thermal_end':command('pmset','-g','therm'),'swap_end':command('sysctl','vm.swapusage'),'load_end':command('uptime')})
v={'scope':'one owned process, including warmup; 1s sampled maxima, not continuous peaks; Apple service/child costs excluded','pid':pid,'environment':environment,'rows':rows,'peak_rss':max((r['rss'] for r in rows),default=None),'peak_footprint':max((r['footprint'] for r in rows),default=None)}
Path(output).write_text(json.dumps(v,indent=2)+'\n')
print('LISTEN2_NATIVE_SAMPLES_'+('OK' if rows else 'ABSENT'),len(rows))

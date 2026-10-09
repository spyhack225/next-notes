#!/usr/bin/env python3
"""One owned subprocess at a time; private metadata capture and sampled resources."""
import ctypes,hashlib,json,os,re,shutil,subprocess,sys,time
from pathlib import Path
report=Path(__file__).resolve().parent
app=Path('/Users/sergekadjo/Library/Caches/NextNotesBuild/wt-scratch/voice/debug/NextNotes')
class Usage(ctypes.Structure):
    _fields_=[('uuid',ctypes.c_uint8*16)]+[(n,ctypes.c_uint64) for n in ['user_time','system_time','pkg_idle_wkups','interrupt_wkups','pageins','wired_size','resident_size','phys_footprint','start','exit']]
lib=ctypes.CDLL('/usr/lib/libproc.dylib');lib.proc_pid_rusage.argtypes=[ctypes.c_int,ctypes.c_int,ctypes.c_void_p]
def command(*args):return subprocess.run(args,text=True,capture_output=True).stdout.strip()
def state():return {k:command(*v) for k,v in {'os':['sw_vers'],'power':['pmset','-g','batt'],'thermal':['pmset','-g','therm'],'swap':['sysctl','vm.swapusage'],'load':['uptime'],'disk':['df','-k','.']}.items()}
label,*args=sys.argv[1:]
pins={'head':command('git','rev-parse','HEAD'),'binary_sha256':hashlib.sha256(app.read_bytes()).hexdigest(),'uuid':command('dwarfdump','--uuid',str(app)),'args':args,'source_sha256':{str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in [Path('Sources/NextNotes/Formatting/LLM/LocalVoiceFrontend.swift'),Path('Sources/NextNotes/Formatting/LLM/NotesModelRuntime.swift'),Path('Sources/NextNotes/Agent/VoiceConversationCoordinator.swift'),Path('Sources/NextNotes/Agent/Voice/VoiceResidentAnswerSelfTest.swift'),Path('Sources/NextNotes/Agent/Voice/VoiceDiagnosticSpeech.swift'),Path('Sources/NextNotes/Agent/Voice/VoiceLatencySelfTest.swift'),Path('Sources/NextNotes/Agent/Speech/AgentSpeechSynthesizer.swift'),Path('Sources/NextNotes/Agent/VoiceCapabilityConversationSelfTest.swift'),Path('Sources/NextNotes/Activation/AgentCaptureController.swift')]}}
before=state();samples=[];started=time.monotonic()
with (report/(label+'.stdout.log')).open('w') as output:
    proc=subprocess.Popen([str(app),*args,'--selftest-out',str(report/(label+'.log')),'--selftest-timeout','600'],stdout=output,stderr=subprocess.STDOUT)
    native_start=None
    while proc.poll() is None:
        u=Usage()
        if lib.proc_pid_rusage(proc.pid,0,ctypes.byref(u))==0:
            if native_start is None:native_start=u.start
            if u.start==native_start:samples.append({'t':round(time.monotonic()-started,3),'rss':u.resident_size,'footprint':u.phys_footprint,'wired':u.wired_size,'cpu_user_ns':u.user_time,'cpu_system_ns':u.system_time})
        time.sleep(1)
    status=proc.returncode
# Only the exact finished child PID's isolated diagnostic store. Owner logs excluded.
root=Path(os.environ.get('TMPDIR','/tmp'))/('NextNotesSelfTest-'+str(proc.pid))
usage=[];unloads=[]
for p in root.glob('usage*.jsonl'):
    for line in p.read_text().splitlines():
        try:r=json.loads(line)
        except json.JSONDecodeError:continue
        if r.get('feature')=='agent.voice':usage.append({k:r.get(k) for k in ['turnID','pass','provider','modelID','warm','loadMs','ttftMs','promptTokens','cachedTokens','completionTokens','countsEstimated','finishReason','errorClass']})
for p in root.glob('metrics*.jsonl'):
    for line in p.read_text().splitlines():
        try:r=json.loads(line)
        except json.JSONDecodeError:continue
        if r.get('name')=='model.unload':unloads.append({k:r.get(k) for k in ['name','note','durationSeconds']})
pins.update({'pid':proc.pid,'exit':status,'scope':'debug/file-fed diagnostic; 1s sampled own app only, excludes Apple service; no release/mic/ears or continuous peaks','before':before,'after':state(),'samples':samples,'peak_rss_sampled':max((r['rss'] for r in samples),default=None),'peak_footprint_sampled':max((r['footprint'] for r in samples),default=None),'usage_metadata':usage,'unloads':unloads,'private_root':str(root)})
if root.is_dir():shutil.rmtree(root);pins['private_root_removed']=True
(report/(label+'-pins.json')).write_text(json.dumps(pins,indent=2)+'\n')
with (report/'status.txt').open('a') as f:f.write(f'{label} exit={status}\n')
for line in (report/(label+'.stdout.log')).read_text(errors='replace').splitlines():
    if re.match(r'^[A-Z][A-Z0-9_]*_(OK|FAILED|ABSENT)(?:$|[:= ])',line):print(line)
print(f'{label} exit={status}',flush=True)
sys.exit(status)

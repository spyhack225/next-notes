from pathlib import Path
import subprocess,os,json,hashlib,time,ctypes,struct,re,datetime,signal
from OwnedCompilerProcess import observe, drain
repo=Path('/Users/sergekadjo/Documents/Claude/Projects/speechify')
r=repo/'Tests/Reports/meeting-reliability/2026-10-07-quality-loop'
scratch=Path.home()/'Library/Caches/NextNotesBuild/scratch'
def pins():
 return {str(p.relative_to(repo)):hashlib.sha256(p.read_bytes()).hexdigest() for base in ['Sources','Resources'] for p in sorted((repo/base).rglob('*')) if p.is_file()}
def listing():
 rows=[]
 for line in subprocess.check_output(['ps','-axo','pid=,ppid=,pgid=,stat=,args='],text=True).splitlines():
  p=line.split(None,4)
  if len(p)==5:rows.append((int(p[0]),int(p[1]),int(p[2]),p[3],p[4]))
 return rows
lib=ctypes.CDLL('/usr/lib/libproc.dylib')
def usage(pid):
 b=ctypes.create_string_buffer(1024)
 if lib.proc_pid_rusage(pid,4,ctypes.byref(b))!=0:return None
 v=struct.unpack_from('10Q',b.raw,16)
 return {'processStart':v[8],'footprintBytes':v[7],'residentBytes':v[6]}
def machine():
 sm=re.search(r'used = ([0-9.]+)M',subprocess.check_output(['sysctl','vm.swapusage'],text=True))
 fm=re.search(r'System-wide memory free percentage: ([0-9]+)%',subprocess.check_output(['memory_pressure','-Q'],text=True))
 dk=subprocess.check_output(['df','-k','/'],text=True).splitlines()[-1].split()[3]
 assert sm and fm and dk.isdigit(),'machine observation unavailable'
 return {'swapGiB':float(sm[1])/1024,'reportedFreePercent':int(fm[1]),'diskFreeGiB':int(dk)*1024/2**30}
assert machine()['reportedFreePercent']>=55,'compiler start reported free55 refused'
gate=subprocess.run(['/opt/homebrew/bin/agent-relay','gate','--max-swap-gb','8','--min-free-gb','6.5','--path','/'],capture_output=True,text=True)
admission=json.loads(gate.stdout);(r/'seventh-compiler-admission.json').write_text(json.dumps(admission,indent=2)+'\n')
gate.check_returncode();assert admission.get('ok') is True
before=pins();(r/'seventh-build-source-pins-before.json').write_text(json.dumps(before,indent=2)+'\n')
start=time.monotonic();samples=[];frames=[];guard=None;ordinaryCross=False;owned={};remaining=[]
phaseReceipts=[];rc=125
for phase,argv in [('compile',['swift','build','-c','release','--scratch-path',str(scratch),'--jobs','1']),('bundle',['make','app','CONFIG=release'])]:
 if guard:break
 child=None;phaseError=None;drainReceipt=None;rootRefused=False;observationDetails=[]
 try:
  assert pins()==before,'source changed before next phase'
  with (r/('seventh-'+phase+'-build.log')).open('w') as out:
   child=subprocess.Popen(argv,cwd=repo,stdout=out,stderr=subprocess.STDOUT,start_new_session=True)
   while True:
    live,unresolved,problems=observe(child,owned,listing,usage,root_refused=rootRefused,details=observationDetails)
    if child.pid in unresolved:rootRefused=True
    if problems or unresolved:guard=guard or ' / '.join(problems or ['ownership unresolved'])
    total=sum(u['footprintBytes'] for pid,group,u in live)
    for pid,group,u in live:samples.append({'phase':phase,'elapsed':time.monotonic()-start,'pid':pid,**u})
    try:frame=machine()
    except Exception:guard=guard or 'machine observation unavailable';frame={}
    frames.append({'phase':phase,'elapsed':time.monotonic()-start,'summedOwnedFootprintBytes':total,**frame})
    if frame.get('swapGiB',10)>8:ordinaryCross=True
    if frame.get('swapGiB',10)>9:guard=guard or 'reviewed compiler swap9 exception exceeded'
    if frame.get('diskFreeGiB',0)<6.5:guard=guard or 'disk free below6.5'
    if frame.get('reportedFreePercent',0)<50:guard=guard or 'reported free below50'
    if total>3_000_000_000:guard=guard or 'summed owned footprint above3GB'
    if time.monotonic()-start>1200:guard=guard or 'owned full compiler/bundle budget exceeded'
    if len(frames)%10==0 and pins()!=before:guard=guard or 'source freeze changed'
    if guard:break
    rc=child.poll()
    if rc is not None and not live and not unresolved:break
    if rc is not None:time.sleep(.1) # Disposable CLI join observation only.
    try:child.wait(timeout=1)
    except subprocess.TimeoutExpired:pass
 except BaseException as error:
  phaseError=type(error).__name__
  guard=guard or 'active compiler lifecycle exception: '+phaseError
 finally:
  if child is not None:
   drainReceipt=drain(child,owned,listing,usage,seconds=6,root_refused=rootRefused)
   if drainReceipt['remainingOwnedPIDs'] or drainReceipt['unresolvedPIDs'] or drainReceipt['errors']:
    guard=guard or 'owned compiler drain incomplete or attribution refused'
   rc=child.returncode if child.returncode is not None else 125
  phaseReceipts.append({'phase':phase,'errorType':phaseError,'exit':rc,'observationDetails':observationDetails,'drain':drainReceipt})
 if guard or rc:break
for pid,parent,group,stat,args in listing():
 if pid in owned and not stat.startswith('Z'):
  u=usage(pid)
  if u and u['processStart']==owned[pid]:remaining.append(pid)
after=pins();(r/'seventh-build-source-pins-after.json').write_text(json.dumps(after,indent=2)+'\n')
meta={'at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'exit':rc,'wallSeconds':time.monotonic()-start,'guardReason':guard,'sourceInvariant':before==after,'sourceCount':len(before),'remainingOwnedPIDs':remaining,'ordinarySwap8Crossed':ordinaryCross,'profile':'peer reviewed relay678 compiler-only initial normal8/min6.5/free55; ongoing explicit swap9 exception/min6.5/free50/summed3GB/1200s; no inference or owner app launch','phaseReceipts':phaseReceipts,'samples':len(samples),'peakSampledOwnedFootprintBytes':max((f['summedOwnedFootprintBytes'] for f in frames),default=None),'installed':False}
(r/'seventh-build-metadata.json').write_text(json.dumps(meta,indent=2)+'\n');(r/'seventh-build-memory.json').write_text(json.dumps(samples,indent=2)+'\n');(r/'seventh-build-machine-memory.json').write_text(json.dumps(frames,indent=2)+'\n')
print(json.dumps(meta),flush=True)
assert rc==0 and not guard and not remaining and before==after,'build incomplete; no automatic retry'
s=(r/'seventh-bundle-build.log').read_text();m=re.search(r'built (.*?)  \[signed:',s);assert m,'no signed stage'
app=Path(m[1]);binary=app/'Contents/MacOS/NextNotes'
verify=subprocess.run(['codesign','--verify','--deep','--strict',str(app)],capture_output=True,text=True)
candidate={'app':str(app),'sha256':hashlib.sha256(binary.read_bytes()).hexdigest(),'buildWallSeconds':meta['wallSeconds'],'sourceInvariant':True,'sourceCount':len(before),'codesignExit':verify.returncode,'installed':False}
(r/'seventh-candidate.json').write_text(json.dumps(candidate,indent=2)+'\n');print(json.dumps(candidate),flush=True);raise SystemExit(verify.returncode)

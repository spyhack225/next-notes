from pathlib import Path
import subprocess,os,json,hashlib,time,ctypes,struct,re,datetime,signal
import sys
sys.path.insert(0,str(Path(__file__).parent.parent))
from OwnedCompilerProcess import observe, drain
repo=Path('/Users/sergekadjo/Documents/Claude/Projects/speechify')
r=Path(__file__).parent
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

phases=[('run-naive',[str(r/'check')],10,0),('run-group',[str(r/'check-group')],10,0),('run-boundary',[str(r/'check-boundary')],10,0)]
before=pins(); receipts=[];start=time.monotonic()
try:
 for name,argv,limit,expected in phases:
  admission=subprocess.run(['agent-relay','gate','--max-swap-gb','8','--min-free-gb','6.5'],capture_output=True,text=True)
  gate=json.loads(admission.stdout);admission.check_returncode()
  initial=machine();assert gate.get('ok') is True and initial['reportedFreePercent']>=55,'ordinary slot preflight refused'
  assert pins()==before,'sources changed before phase'
  owned={}; samples=[];frames=[];guard=None;rootRefused=False;child=None;error=None;joined=None;observationDetails=[];began=time.monotonic()
  try:
   with (r/(name+'.log')).open('w') as out:
    child=subprocess.Popen(argv,cwd=r,stdout=out,stderr=subprocess.STDOUT,start_new_session=True)
    while True:
     live,unresolved,problems=observe(child,owned,listing,usage,root_refused=rootRefused,details=observationDetails)
     if child.pid in unresolved:rootRefused=True
     if unresolved or problems:guard=guard or 'ownership refused'
     total=sum(fact['footprintBytes'] for pid,group,fact in live)
     for pid,group,fact in live:samples.append({'seconds':time.monotonic()-began,'pid':pid,**fact})
     frame=machine();frames.append({'seconds':time.monotonic()-began,'summedOwnedFootprintBytes':total,**frame})
     if frame['swapGiB']>8:guard=guard or 'ordinary swap8 exceeded'
     if frame['diskFreeGiB']<6.5:guard=guard or 'ordinary disk6.5 refused'
     if frame['reportedFreePercent']<50:guard=guard or 'reported free50 refused'
     if total>1_000_000_000:guard=guard or 'owned summed footprint1GB exceeded'
     if time.monotonic()-began>limit or time.monotonic()-start>30:guard=guard or 'reviewed phase/whole limit exceeded'
     if len(frames)%10==0 and pins()!=before:guard=guard or 'source freeze changed'
     if guard:break
     rc=child.poll()
     if rc is not None and not live and not unresolved:break
     if rc is not None:time.sleep(.1)
     try:child.wait(timeout=.1)
     except subprocess.TimeoutExpired:pass
  except BaseException as e:
   error=type(e).__name__;guard=guard or 'owned lifecycle exception: '+error
  finally:
   if child is not None:joined=drain(child,owned,listing,usage,seconds=6,root_refused=rootRefused)
  code=child.returncode if child is not None else None
  receipt={'name':name,'argv':argv,'expectedExit':expected,'exit':code,'gate':gate,'initial':initial,'guard':guard,'error':error,'join':joined,'observationDetails':observationDetails,'wallSeconds':time.monotonic()-began,'samples':samples,'frames':frames}
  receipts.append(receipt);(r/'resource-receipt.json').write_text(json.dumps(receipts,indent=2)+'\n')
  print(json.dumps({k:v for k,v in receipt.items() if k not in ['samples','frames','argv']}),flush=True)
  assert code==expected and not guard and joined and not joined['remainingOwnedPIDs'] and not joined['unresolvedPIDs'] and not joined['errors'],'phase not accepted; no automatic retry'
finally:
 after=pins();(r/'source-invariance.json').write_text(json.dumps({'before':before,'after':after,'same':before==after,'count':len(before)},indent=2)+'\n')
assert before==after
print('STRUCTURE_PHASES_JOINED_SOURCE_INVARIANT')

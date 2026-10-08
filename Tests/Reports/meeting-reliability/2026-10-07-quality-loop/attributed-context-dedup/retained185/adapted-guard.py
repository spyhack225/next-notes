from pathlib import Path
import subprocess,os,json,hashlib,time,ctypes,struct,re,datetime,signal
from OwnedCompilerProcess import observe, drain
repo=Path('/Users/sergekadjo/Documents/Claude/Projects/speechify')
r=repo/'Tests/Reports/meeting-reliability/2026-10-07-quality-loop/attributed-context-dedup/retained185'
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

import sys,tempfile
here=Path('/Users/sergekadjo/Library/Caches/NextNotesBuild/action-intent-harness-90400946-c987-4404-80ad-4c6761ac7014/attributed-context-retained185')
phase=sys.argv[1];assert phase in ['compile','run']
assert hashlib.sha256((here/'manifest.json').read_bytes()).hexdigest()=='0ce8879505eef85a58886b5724abbc625aa7cbca20d055d5d12c69597e45a42d'
for row in json.loads((here/'manifest.json').read_text())['pins']:
 assert hashlib.sha256((here/row['path']).read_bytes()).hexdigest()==row['SHA256'],row['path']
assert hashlib.sha256((Path(__file__).parent/'OwnedCompilerProcess.py').read_bytes()).hexdigest()=='68e7971a1474ac8f15d70e6f38e6fd517cdf5b09150c17d726f5590181fd3a4f'
before=json.loads((r.parent/'current-source-freeze.json').read_text());assert pins()==before
initial=machine();(r/(phase+'-initial-machine.json')).write_text(json.dumps(initial,indent=2)+'\n');assert initial['reportedFreePercent']>=55,'model-free start reported free55 refused'
gate=subprocess.run(['/opt/homebrew/bin/agent-relay','gate','--max-swap-gb','8','--min-free-gb','6.5','--path','/'],capture_output=True,text=True)
admission=json.loads(gate.stdout);(r/('retained185-'+phase+'-admission.json')).write_text(json.dumps(admission,indent=2)+'\n');gate.check_returncode();assert admission.get('ok') is True
argv=json.loads((here/'commands.json').read_text())[phase]['argv'];budget=90 if phase=='compile' else 10
start=time.monotonic();owned={};samples=[];frames=[];guard=None;rootRefused=False;phaseError=None;child=None;rc=125;receipt=None;observationDetails=[]
temporary=tempfile.mkdtemp(prefix='NextNotesAttributedContextComponent-',dir='/private/tmp')
try:
 rawLog=here/('guarded-retained185-'+phase+'.log');rawLog.touch(mode=0o600);rawLog.chmod(0o600)
 with rawLog.open('w') as out:
  child=subprocess.Popen(argv,cwd=here,env={**os.environ,'TMPDIR':temporary+'/'},stdout=out,stderr=subprocess.STDOUT,start_new_session=True)
  while True:
   live,unresolved,problems=observe(child,owned,listing,usage,root_refused=rootRefused,details=observationDetails)
   if child.pid in unresolved:rootRefused=True
   if problems or unresolved:guard=guard or ' / '.join(problems or ['ownership unresolved'])
   total=sum(u['footprintBytes'] for pid,group,u in live)
   for pid,group,u in live:samples.append({'elapsed':time.monotonic()-start,'pid':pid,**u})
   frame=machine();frames.append({'elapsed':time.monotonic()-start,'summedOwnedFootprintBytes':total,**frame})
   if frame['swapGiB']>8:guard=guard or 'ordinary swap8 guard'
   if frame['diskFreeGiB']<6.5:guard=guard or 'disk free below6.5'
   if frame['reportedFreePercent']<50:guard=guard or 'reported free below50'
   if total>1_000_000_000:guard=guard or 'summed owned footprint above1GB'
   if time.monotonic()-start>budget:guard=guard or 'bounded phase elapsed'
   if guard:break
   rc=child.poll()
   if rc is not None and not live and not unresolved:break
   if rc is not None:time.sleep(.1)
   try:child.wait(timeout=.1)
   except subprocess.TimeoutExpired:pass
except BaseException as error:phaseError=type(error).__name__;guard=guard or 'active CLI lifecycle exception: '+phaseError
finally:
 if child is not None:
  receipt=drain(child,owned,listing,usage,seconds=6,root_refused=rootRefused)
  if receipt['remainingOwnedPIDs'] or receipt['unresolvedPIDs'] or receipt['errors']:guard=guard or 'CLI drain incomplete or attribution refused'
  rc=child.returncode if child.returncode is not None else 125
 # Never delete the temporary backing while any possibly-owned consumer is unjoined.
 if receipt and (receipt['remainingOwnedPIDs'] or receipt['unresolvedPIDs']):raise RuntimeError('unjoined CLI; no next phase or temporary cleanup admission')
import shutil
shutil.rmtree(temporary) # Only reached after explicit joined receipt; unresolved backing is retained.
after=pins()
meta={'at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'phase':phase,'exit':rc,'wallSeconds':time.monotonic()-start,'guardReason':guard,'observationDetails':observationDetails,'sourceInvariant':before==after,'sourceCount':len(before),'drain':receipt,'lifecycleErrorType':phaseError,'samples':len(samples),'peakSampledOwnedFootprintBytes':max((f['summedOwnedFootprintBytes'] for f in frames),default=None),'scope':'Retained actual ContextStore/parser/apply/atomic JSON save/fresh load;185 unchanged assertions; only extractor prefix replaced; retained boundary substitutions. Private copied owner-derived fixtures/raw logs. Normal8/min6.5/free55+50/1GB;90s compiler/10s run. No current App/native model/Session/semantic proof','installation':False}
(r/('retained185-'+phase+'-metadata.json')).write_text(json.dumps(meta,indent=2)+'\n');(r/('retained185-'+phase+'-memory.json')).write_text(json.dumps(samples,indent=2)+'\n')
print(json.dumps(meta),flush=True);raise SystemExit(1 if rc or guard or before!=after else 0)

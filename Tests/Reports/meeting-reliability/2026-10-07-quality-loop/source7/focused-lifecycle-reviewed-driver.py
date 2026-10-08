"""Model-free, signed-candidate meeting self-tests. Never signals an application."""
from pathlib import Path
import subprocess, os, json, hashlib, time, ctypes, struct, re, datetime, sys
from OwnedCompilerProcess import observe
repo=Path('/Users/sergekadjo/Documents/Claude/Projects/speechify')
r=repo/'Tests/Reports/meeting-reliability/2026-10-07-quality-loop'
private=Path.home()/'Library/Application Support/Next Notes/Diagnostics/MeetingQualityReview/3B92EA32-9D55-4622-A2D6-810B044792FF/quality-loop'
cases={
 'bounded-audio':(['--selftest-meeting-bounded-audio'],['MEETING_BOUNDED_AUDIO_OK']),
 'pause-experiment':(['--selftest-meeting-quiet-input','--meeting-quiet-pause-boundaries','--meeting-quiet-pause-experiment'],['MEETING_PAUSE_BOUNDARIES_OK']),
 'participant-contracts':(['--selftest-meeting-participant-observation','contracts'],['MEETING_PARTICIPANT_OBSERVATION_OK']),
 'meeting-context':(['--selftest-meeting-context'],['MEETING_SPEAKER_PROJECTION_OK','MEETING_CONTEXT_OK']),
 'owner-isolation':(['--selftest-store-isolation'],['STORE_ISOLATION_OK']),
}
name=sys.argv[1];assert name in cases
args,required=cases[name]
c=json.loads((r/'seventh-candidate.json').read_text());app=Path(c['app']);binary=app/'Contents/MacOS/NextNotes'
assert c['codesignExit']==0 and not c['installed']
assert hashlib.sha256(binary.read_bytes()).hexdigest()==c['sha256']
verify=subprocess.run(['codesign','--verify','--deep','--strict',str(app)],capture_output=True,text=True);verify.check_returncode()
before=json.loads((r/'seventh-build-source-pins-after.json').read_text())
def pins():
 return {str(p.relative_to(repo)):hashlib.sha256(p.read_bytes()).hexdigest() for base in ['Sources','Resources'] for p in sorted((repo/base).rglob('*')) if p.is_file()}
assert pins()==before
owner=Path.home()/'Library/Application Support/Next Notes/Meetings'
original=json.loads((r/'original-owner-and-fixture-pins.json').read_text())
def owner_pins():
 return {p:hashlib.sha256((owner/original['original_meeting_id']/p).read_bytes()).hexdigest() for p in original['owner_files']}
assert owner_pins()==original['owner_files'],'original owner evidence changed; no child'
statusCounts={}
for p in owner.glob('*/meeting.json'):
 row=json.loads(p.read_text());state=row.get('status',{});state=state.get('state') if isinstance(state,dict) else state
 statusCounts[state]=statusCounts.get(state,0)+1
assert not any(state!='done' for state in statusCounts),'active owner meeting; no test child'
lib=ctypes.CDLL('/usr/lib/libproc.dylib')
def usage(pid):
 b=ctypes.create_string_buffer(1024)
 if lib.proc_pid_rusage(pid,4,ctypes.byref(b))!=0:return None
 v=struct.unpack_from('10Q',b.raw,16)
 return {'processStart':v[8],'footprintBytes':v[7],'residentBytes':v[6]}
def listing():
 rows=[]
 for line in subprocess.check_output(['ps','-axo','pid=,ppid=,pgid=,stat=,args='],text=True).splitlines():
  p=line.split(None,4)
  if len(p)==5:rows.append((int(p[0]),int(p[1]),int(p[2]),p[3],p[4]))
 return rows
# Command arguments stay local; only numeric process identities are written publicly.
def machine():
 sm=re.search(r'used = ([0-9.]+)M',subprocess.check_output(['sysctl','vm.swapusage'],text=True))
 fm=re.search(r'System-wide memory free percentage: ([0-9]+)%',subprocess.check_output(['memory_pressure','-Q'],text=True))
 dk=subprocess.check_output(['df','-k','/'],text=True).splitlines()[-1].split()[3]
 assert sm and fm and dk.isdigit(),'machine observation unavailable'
 return {'swapGiB':float(sm[1])/1024,'reportedFreePercent':int(fm[1]),'diskFreeGiB':int(dk)*1024/2**30}
assert machine()['reportedFreePercent']>=55,'model-free native start55 refused; no child'
gate=subprocess.run(['/opt/homebrew/bin/agent-relay','gate','--max-swap-gb','8','--min-free-gb','6.5','--path','/'],capture_output=True,text=True)
admission=json.loads(gate.stdout);(r/('seventh-'+name+'-admission.json')).write_text(json.dumps(admission,indent=2)+'\n');gate.check_returncode();assert admission.get('ok') is True
private.mkdir(parents=True,exist_ok=True);os.umask(0o077)
log=private/('seventh-'+name+'.log');child=None;owned={};apps={};samples=[];frames=[];guard=None;errorType=None;rootRefused=False;sent=[];quitAttempted=set();drain=None;rc=125;started=time.monotonic()
def discover(rows):
 for pid,parent,group,stat,command in rows:
  if pid in owned and command.startswith(str(binary)+' '):apps[pid]=owned[pid]
def quit_apps():
 rows=listing();discover(rows);byPID={x[0]:x for x in rows}
 for pid,start in apps.items():
  if (pid,start) in quitAttempted or pid not in byPID or byPID[pid][3].startswith('Z'):continue
  fact=usage(pid)
  if not fact or fact['processStart']!=start or not byPID[pid][4].startswith(str(binary)+' '):
   raise RuntimeError('application quit identity unavailable or changed')
  script='ObjC.import("AppKit"); var a=$.NSRunningApplication.runningApplicationWithProcessIdentifier('+str(pid)+'); a.isNil() ? false : a.terminate;'
  quitAttempted.add((pid,start))
  q=subprocess.run(['osascript','-l','JavaScript','-e',script],capture_output=True,text=True,timeout=10)
  sent.append({'pid':pid,'processStart':start,'exit':q.returncode,'accepted':q.stdout.strip()=='true'})
  if q.returncode or q.stdout.strip()!='true':raise RuntimeError('owned application AppKit quit refused')
try:
 with log.open('w') as out:
  child=subprocess.Popen(['Scripts/run-selftest.sh',*args,'--selftest-timeout','150'],cwd=repo,env={**os.environ,'NEXTNOTES_APP':str(app)},stdout=out,stderr=subprocess.STDOUT,start_new_session=True)
  while True:
   live,unresolved,problems=observe(child,owned,listing,usage,root_refused=rootRefused)
   if child.pid in unresolved:rootRefused=True
   discover(listing())
   if problems or unresolved:guard=guard or ' / '.join(problems or ['ownership unresolved'])
   total=sum(x[2]['footprintBytes'] for x in live)
   for pid,group,fact in live:samples.append({'elapsed':time.monotonic()-started,'pid':pid,**fact})
   frame=machine();frames.append({'elapsed':time.monotonic()-started,'summedOwnedFootprintBytes':total,**frame})
   if frame['swapGiB']>8:guard=guard or 'ordinary swap8 exceeded'
   if frame['diskFreeGiB']<6.5:guard=guard or 'disk below6.5'
   if frame['reportedFreePercent']<50:guard=guard or 'reported free below50'
   if total>1_000_000_000:guard=guard or 'summed owned footprint above1GB'
   if time.monotonic()-started>90:guard=guard or 'model-free native90s exceeded'
   if pins()!=before:guard=guard or 'source freeze changed'
   if guard:break
   rc=child.poll()
   if rc is not None and not live and not unresolved:break
   try:child.wait(timeout=.5)
   except subprocess.TimeoutExpired:pass
except BaseException as error:errorType=type(error).__name__;guard=guard or 'native lifecycle exception: '+errorType
finally:
 if child is not None:
  # Always observe all owned descendants, even if the launcher already exited.
  drainStart=time.monotonic();remaining=[];unresolved=[];errors=[]
  while True:
   try:
    live,unresolved,problems=observe(child,owned,listing,usage,root_refused=rootRefused)
    if child.pid in unresolved:rootRefused=True
    errors.extend(problems);remaining=[x[0] for x in live]
    discover(listing())
   except BaseException as error:
    errors.append('drain observation: '+type(error).__name__)
    remaining=list(owned);unresolved=['observation unavailable']
   # Continue bounded cleanup after errors. Newly discovered late apps get their own
   # exact identity check and at most one quit request; no name or group signalling.
   if remaining or unresolved:
    try:quit_apps()
    except BaseException as error:errors.append('AppKit cleanup: '+type(error).__name__)
   child.poll()
   if child.returncode is not None and not remaining and not unresolved:break
   if time.monotonic()-drainStart>30:
    errors.append('AppKit drain not joined; no signals or further launch');break
   time.sleep(.1)
  rc=child.returncode if child.returncode is not None else 125
  drain={'remainingOwnedPIDs':remaining,'unresolvedPIDs':unresolved,'errors':sorted(set(errors)),'AppKitQuitRequests':sent,'seconds':time.monotonic()-drainStart}
  if remaining or unresolved or errors:guard=guard or 'owned native drain unproved; no further launch'
try:
 after=pins();ownerUnchanged=owner_pins()==original['owner_files'];raw=log.read_text() if log.exists() else ''
except BaseException as error:
 after={};ownerUnchanged=False;raw='';errorType=type(error).__name__;guard=guard or 'post-drain evidence unavailable: '+errorType
markers=re.findall(r'^([A-Z0-9_]+_(?:OK|FAILED|MISSING|SILENT|TIMEOUT|ABSENT))(?:$|:| )',raw,re.M)
meta={'at':datetime.datetime.now(datetime.timezone.utc).isoformat(),'case':name,'candidateSHA':c['sha256'],'exit':rc,'guardReason':guard,'errorType':errorType,'requiredMarkers':required,'markers':markers,'requiredMarkersPresent':all(x in markers for x in required),'negativeMarkers':[x for x in markers if not x.endswith('_OK')],'lastMarker':markers[-1] if markers else None,'wallSeconds':time.monotonic()-started,'originalOwnerEightUnchanged':ownerUnchanged,'ownerStatusCountsBefore':statusCounts,'sourceInvariant':before==after,'sourceCount':len(before),'drain':drain,'peakSampledOwnedFootprintBytes':max((x['summedOwnedFootprintBytes'] for x in frames),default=None),'scope':'Signed full-app entry; explicitly model-free declared test only; normal8/min6.5/start55/ongoing50/summed1GB/90s, sampled not continuous peak; no install/physical UI/ASR/voice proof','installed':False}
(r/('seventh-'+name+'-metadata.json')).write_text(json.dumps(meta,indent=2)+'\n');(r/('seventh-'+name+'-memory.json')).write_text(json.dumps(samples,indent=2)+'\n');(r/('seventh-'+name+'-machine.json')).write_text(json.dumps(frames,indent=2)+'\n')
print(json.dumps(meta),flush=True)
raise SystemExit(0 if rc==0 and not guard and before==after and meta['originalOwnerEightUnchanged'] and all(x in markers for x in required) and markers and markers[-1]==required[-1] and not meta['negativeMarkers'] else 1)

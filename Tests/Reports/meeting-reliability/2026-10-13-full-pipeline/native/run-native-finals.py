from pathlib import Path
import os,sys,subprocess as sp,json,hashlib,time,ctypes,struct,re,signal
sys.path.insert(0,str(Path.home()/"Library/Caches/NextNotesBuild"))
from OwnedCompilerProcess import observe
repo=Path.cwd();r=repo/"Tests/Reports/meeting-reliability/2026-10-13-full-pipeline/native"
private=Path.home()/"Library/Application Support/Next Notes/Diagnostics/MeetingQualityReview/2026-10-13-full-pipeline"
private.mkdir(parents=True,exist_ok=True,mode=0o700);private.chmod(0o700);os.umask(0o077)
binary=Path("/Applications/Next Notes.app/Contents/MacOS/NextNotes");expected="503e0e401409d05077cfe205c8b8312c1d3b13ec0d27146dfaef3ab2e9b3cbbe"
assert hashlib.sha256(binary.read_bytes()).hexdigest()==expected
sp.run(["codesign","--verify","--deep","--strict",str(binary.parent.parent.parent)],check=True,capture_output=True)
owner=Path.home()/"Library/Application Support/Next Notes/Meetings";selected=["3B92EA32-9D55-4622-A2D6-810B044792FF","32A8CD40-D2C1-4256-92AF-B1BCEF483481","26CB7A67-E354-4867-A16C-4CC1EC6974F2"]
def hashfile(p):
 h=hashlib.sha256()
 with p.open("rb") as f:
  for b in iter(lambda:f.read(1048576),b""):h.update(b)
 return h.hexdigest()
def ownerpins():return {id+"/"+p.name:hashfile(p) for id in selected for p in sorted((owner/id).iterdir()) if p.is_file()}
def sourcepins():return {str(p.relative_to(repo)):hashfile(p) for d in ["Sources","Resources"] for p in sorted((repo/d).rglob("*")) if p.is_file()}
assert all(json.loads(p.read_text()).get("status",{}).get("state") in ["done","failed"] for p in owner.glob("*/meeting.json")),"active recording/processing"
orig=ownerpins();source=sourcepins();lib=ctypes.CDLL("/usr/lib/libproc.dylib")
def usage(pid):
 b=ctypes.create_string_buffer(1024)
 if lib.proc_pid_rusage(pid,4,ctypes.byref(b))!=0:return None
 v=struct.unpack_from("10Q",b.raw,16);return {"processStart":v[8],"footprintBytes":v[7],"residentBytes":v[6]}
def listing():
 rows=[]
 for s in sp.check_output(["ps","-axo","pid=,ppid=,pgid=,stat=,args="],text=True).splitlines():
  p=s.split(None,4)
  if len(p)==5:rows.append((int(p[0]),int(p[1]),int(p[2]),p[3],p[4]))
 return rows
cases=[("finals-native",["--selftest-meeting-finals",str(repo/"Tests/Fixtures/meetings")],["MEETING_FINALS_OK"])]
results=[]
for name,args,required in cases:
 assert hashfile(binary)==expected and ownerpins()==orig and sourcepins()==source
 log=private/(name+".log");owned={};start=time.monotonic();samples=[];failure=None;child=None
 with log.open("w") as out:
  child=sp.Popen(["Scripts/run-selftest.sh",*args,"--selftest-timeout","180"],cwd=repo,stdout=out,stderr=sp.STDOUT,start_new_session=True)
  while True:
   live,unresolved,errors=observe(child,owned,listing,usage)
   if unresolved or errors:failure="ownership observation refused";break
   samples.append({"seconds":time.monotonic()-start,"summedOwnedFootprintBytes":sum(f["footprintBytes"] for _,_,f in live),"ownedPIDs":[pid for pid,_,_ in live]})
   if child.poll() is not None and not live:break
   if time.monotonic()-start>220:failure="native fixture deadline";break
   try:child.wait(timeout=.25)
   except sp.TimeoutExpired:pass
  if failure:
   # Only the exact unreaped owned CLI launcher receives TERM; its existing trap
   # forwards to its own disposable self-test child. Never owner app/name/group.
   row=usage(child.pid)
   if child.poll() is None and row and owned.get(child.pid)==row["processStart"]:child.terminate()
   try:child.wait(timeout=15)
   except sp.TimeoutExpired:failure+="; launcher not joined"
  live,unresolved,errors=observe(child,owned,listing,usage)
  joined=child.poll() is not None and not live and not unresolved and not errors
 raw=log.read_text();markers=re.findall(r"^([A-Z0-9_]+_(?:OK|FAILED|TIMEOUT|SILENT|MISSING))(?:$|:| )",raw,re.M)
 bad=[s for s in markers if not s.endswith("_OK")];unchanged=ownerpins()==orig;invariant=sourcepins()==source
 result={"case":name,"args":args,"installedSHA256":expected,"exit":child.returncode,"markers":markers,"required":required,"requiredPresent":all(s in markers for s in required),"negativeMarkers":bad,"guard":failure,"joined":joined,"seconds":time.monotonic()-start,"peakSampledOwnedFootprintBytes":max((s["summedOwnedFootprintBytes"] for s in samples),default=0),"originalOwner20FilesUnchanged":unchanged,"sourceInvariant":invariant,"sourceCount":len(source),"pass":child.returncode==0 and joined and not failure and not bad and all(s in markers for s in required) and unchanged and invariant}
 results.append(result);(r/"native-finals-results.json").write_text(json.dumps({"scope":"Signed current installed original meeting-finals native ASR fixture contract; actual three authored language audio files, no microphone/tap/device switch/cloud models. Explicit owner instruction removes prior arbitrary55%free and1GB/swap admission restrictions; footprints sampled, no physical call/model/voice or semantic acceptance implied. Existing fixture timeout/exact ownership retained.","results":results},indent=2)+"\n")
 print(json.dumps(result),flush=True)
 if failure or not joined or not unchanged or not invariant:break

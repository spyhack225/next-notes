"""Exact driver's AST drain/functions, external ownership/AppKit/time substituted; no OS child."""
import ast, hashlib, json, re
from pathlib import Path
from types import SimpleNamespace
DRIVER=Path('/Users/sergekadjo/Library/Caches/NextNotesBuild/meeting-seventh-focused-guarded.py')
REPORT=Path('/Users/sergekadjo/Documents/Claude/Projects/speechify/Tests/Reports/meeting-reliability/2026-10-07-quality-loop/source7')
raw=DRIVER.read_bytes(); tree=ast.parse(raw)
functions=[n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name in ('discover','quit_apps')]
outer=next(n for n in tree.body if isinstance(n,ast.Try) and n.finalbody)
block=outer.finalbody
assert len(functions)==2 and len(block)==1
program=compile(ast.fix_missing_locations(ast.Module(body=functions+block,type_ignores=[])),str(DRIVER),'exec')
loopSource=ast.get_source_segment(raw.decode(),block[0])
class Clock:
 def __init__(self):self.now=0
 def monotonic(self):return self.now
 def sleep(self,value):self.now+=value
class Child:
 pid=100
 returncode=None
 def poll(self):self.returncode=0;return 0
class World:
 def __init__(self,kind):self.kind=kind;self.tick=0;self.ended=set();self.requests=[];self.rootRefusal=[]
 def rows(self):
  if self.kind=='normal':return []
  if self.kind=='late':pid=101 if self.tick<=1 else 202
  else:pid=101
  if pid in self.ended:return []
  return [(pid,100,100,'S','/pinned/NextNotes --selftest-generic')]
 def usage(self,pid):return {'processStart':999 if self.kind=='recycled' else pid*10,'footprintBytes':1,'residentBytes':1}
 def observe(self,child,owned,listing,usage,root_refused=False):
  self.tick+=1;self.rootRefusal.append(root_refused)
  if self.kind=='observation-recovery' and self.tick==1:raise RuntimeError('substituted read failure')
  if self.kind=='root-refusal' and self.tick==1:return [],[100],['root unavailable']
  if self.kind=='root-refusal':return [],[],[]
  rows=self.rows()
  for pid,*_ in rows:owned.setdefault(pid,pid*10)
  return [(pid,100,{'processStart':owned[pid],'footprintBytes':1,'residentBytes':1}) for pid,*_ in rows],[],[]
 def run(self,args,**kwargs):
  assert args[:3]==['osascript','-l','JavaScript'];assert kwargs['timeout']==10
  pid=int(re.search(r'ProcessIdentifier\((\d+)\)',args[-1])[1]);self.requests.append(pid)
  if self.kind=='quit-refusal':return SimpleNamespace(returncode=0,stdout='false')
  self.ended.add(pid);return SimpleNamespace(returncode=0,stdout='true')
results=[]
for kind in ('normal','late','observation-recovery','quit-refusal','recycled','root-refusal'):
 world=World(kind);clock=Clock();ns={'child':Child(),'owned':{},'apps':{},'sent':[],'quitAttempted':set(),'rootRefused':False,'guard':None,'binary':Path('/pinned/NextNotes'),'time':clock,'listing':world.rows,'usage':world.usage,'observe':world.observe,'subprocess':SimpleNamespace(run=world.run)}
 exec(program,ns);drain=ns['drain']
 checks=[]
 def check(label,value):checks.append({'label':label,'pass':bool(value)})
 check('request-once-per-pinned-app',len(world.requests)==len(set(world.requests)))
 if kind=='normal':check('clean-join-no-quit',not world.requests and not drain['errors'] and not drain['remainingOwnedPIDs'] and ns['guard'] is None)
 if kind=='late':check('both-initial-and-late-app-quit',world.requests==[101,202]);check('late-app-joined',not drain['remainingOwnedPIDs'] and not drain['errors'] and ns['guard'] is None)
 if kind=='observation-recovery':check('recovered-exact-cleanup',world.requests==[101] and not drain['remainingOwnedPIDs']);check('error-remains-refusal',bool(drain['errors']) and ns['guard'] is not None)
 if kind=='quit-refusal':check('refused-request-at-most-once',world.requests==[101]);check('unjoined-blocks-launch',drain['remainingOwnedPIDs']==[101] and bool(drain['errors']) and ns['guard'] is not None)
 if kind=='recycled':check('no-quit-to-recycled-start',world.requests==[]);check('identity-refusal-retained',bool(drain['errors']) and ns['guard'] is not None)
 if kind=='root-refusal':check('root-refusal-stays-latched',ns['rootRefused'] and world.rootRefusal==[False,True]);check('root-error-remains-refusal',bool(drain['errors']) and ns['guard'] is not None)
 results.append({'case':kind,'checks':checks,'passed':all(c['pass'] for c in checks),'drain':drain,'substitutedQuitPIDs':world.requests})
result={'scope':'Exact AST discover/quit_apps/finally body from unlaunched driver; external observe/listing/usage/AppKit command/time/Child substituted. No OS child, native/compiler/model, Source edit or signal. This proves loop transitions only, not macOS identity APIs/osascript/AppKit/real descendants.', 'driverSHA256':hashlib.sha256(raw).hexdigest(),'extractedDrainSHA256':hashlib.sha256(loopSource.encode()).hexdigest(),'results':results,'passed':all(r['passed'] for r in results),'checks':sum(len(r['checks']) for r in results),'failures':sum(not c['pass'] for r in results for c in r['checks'])}
(REPORT/'focused-lifecycle-substituted-result.json').write_text(json.dumps(result,indent=2)+'\n')
(REPORT/'focused-lifecycle-reviewed-driver.py').write_bytes(raw)
print(json.dumps({k:result[k] for k in ['driverSHA256','extractedDrainSHA256','passed','checks','failures']}))
raise SystemExit(0 if result['passed'] else 1)

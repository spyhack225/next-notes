import importlib.util
from pathlib import Path
from types import SimpleNamespace
import json

def load(path,name):
    spec=importlib.util.spec_from_file_location(name,path)
    m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m

def run(m,kind):
    rows=[(101,1,101,'S','not recorded'),(202,1,444,'S','not recorded'),(303,202,555,'S','not recorded')]
    def usage(pid):
        if pid==101:return {'processStart':1001,'footprintBytes':1,'residentBytes':1}
        if pid==202 and kind=='recycled':return {'processStart':9999,'footprintBytes':1,'residentBytes':1}
        return None
    details=[]
    live,unresolved,errors=m.observe(SimpleNamespace(pid=101,returncode=None),{101:1001,202:2002},lambda:rows,usage,details=details)
    return {'live':[x[0] for x in live],'unresolved':unresolved,'errors':errors,'details':details}

p=Path(__file__).parent
old=load(p/'OwnedCompilerProcess.before-orphan-refusal.py','old_orphan')
new=load(p/'OwnedCompilerProcess.py','new_orphan')
results={kind:{'original':run(old,kind),'fixed':run(new,kind)} for kind in ['unreadable','recycled']}
checks=[]
for kind,value in results.items():
    checks.append((kind+' original false absence reproduced',not value['original']['errors'] and not value['original']['unresolved']))
    checks.append((kind+' fixed pinned orphan refusal',202 in value['fixed']['unresolved'] and bool(value['fixed']['errors'])))
    checks.append((kind+' foreign ancestry never admitted',value['fixed']['live']==[101] and bool(value['fixed']['details'])))
print(json.dumps({'scope':'Exact helper original/fixed, table/rusage substituted, no signals or OS children','results':results,'checks':checks,'passed':sum(ok for _,ok in checks),'total':len(checks)}))
raise SystemExit(0 if all(ok for _,ok in checks) else 1)

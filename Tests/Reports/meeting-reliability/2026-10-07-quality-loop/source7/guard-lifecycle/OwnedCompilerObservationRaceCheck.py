import importlib.util
from pathlib import Path
import json
from types import SimpleNamespace

def load(path, name):
    spec=importlib.util.spec_from_file_location(name,path)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    return module

def check(module, kind):
    root=(101,1,101,'S','not recorded')
    descendant=(202,101,101,'S','not recorded')
    foreign=(303,202,555,'S','not recorded')
    rows=[root] if kind=='root-disappears' else [root,descendant]
    if kind=='foreign-ancestry':rows.append(foreign)
    counts={'listing':0}
    def listing():
        counts['listing']+=1
        if counts['listing']==1:return rows
        if kind=='relist-fails':raise RuntimeError('authored confirmation refusal')
        if kind=='root-disappears':return []
        if kind=='descendant-disappears':return [root]
        if kind=='descendant-zombie':return [root,(202,101,101,'Z','not recorded')]
        return rows
    def usage(pid):
        if pid==101 and kind!='root-disappears':return {'processStart':1001,'footprintBytes':1,'residentBytes':1}
        if pid==202 and kind=='recycled':return {'processStart':9999,'footprintBytes':1,'residentBytes':1}
        return None
    details=[]
    if 'details' in module.observe.__code__.co_varnames:
        live,unresolved,errors=module.observe(SimpleNamespace(pid=101,returncode=None),{101:1001,202:2002},listing,usage,details=details)
    else:
        live,unresolved,errors=module.observe(SimpleNamespace(pid=101,returncode=None),{101:1001,202:2002},listing,usage)
    return {'live':[row[0] for row in live],'unresolved':unresolved,'errors':errors,'details':details,'listings':counts['listing']}

p=Path(__file__).parent
old=load(p/'OwnedCompilerProcess.before-observation-race.py','original_race')
new=load(p/'OwnedCompilerProcess.py','fixed_race')
cases=['root-disappears','descendant-disappears','descendant-zombie','present-unreadable','relist-fails','recycled','foreign-ancestry']
results={kind:{'original':check(old,kind),'fixed':check(new,kind)} for kind in cases}
checks=[]
for kind in cases[:3]:
    a=results[kind]['original'];b=results[kind]['fixed']
    checks.append((kind+' original refusal reproduced',bool(a['errors']) and bool(a['unresolved'])))
    checks.append((kind+' fixed confirmed retirement',not b['errors'] and not b['unresolved'] and b['listings']==2 and bool(b['details'])))
for kind in cases[3:]:
    b=results[kind]['fixed']
    checks.append((kind+' remains refused',bool(b['errors']) and 202 in b['unresolved']))
    checks.append((kind+' no foreign ancestry admission',303 not in b['live'] and b['listings']<=2))
print(json.dumps({'scope':'Exact copied helper original/fixed; process tables and rusage substituted, no OS child launched','results':results,'checks':checks,'passed':sum(ok for _,ok in checks),'total':len(checks)}))
raise SystemExit(0 if all(ok for _,ok in checks) else 1)

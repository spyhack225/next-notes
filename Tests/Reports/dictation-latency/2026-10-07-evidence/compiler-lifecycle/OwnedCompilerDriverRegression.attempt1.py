"""Execute the exact original/fixed phase loop; OS/process boundaries are substituted."""
from pathlib import Path
import json
import subprocess as real_subprocess
import tempfile
from types import SimpleNamespace
from OwnedCompilerProcess import observe, drain

class Process:
    pid = 101
    returncode = None
    def __init__(self, late=False, exception=False):
        self.rows = {101: (1, 101, 1001)}
        self.sent = []
        self.late = late
        self.exception = exception
        self.tick = 0.0
    def listing(self):
        if self.exception:
            self.exception = False
            raise RuntimeError('same injected listing exception')
        return [(pid, parent, group, 'S', 'authored compiler')
                for pid, (parent, group, start) in self.rows.items()]
    def usage(self, pid):
        row = self.rows.get(pid)
        return None if row is None else {'processStart':row[2], 'footprintBytes':1, 'residentBytes':1}
    def kill(self, pid, sig):
        if pid in self.rows:
            self.sent.append(pid)
            del self.rows[pid]
            if pid == 101 and self.late:
                self.rows[202] = (1, 101, 2002)
    def poll(self):
        if 101 not in self.rows:self.returncode = 0
        return self.returncode
    def wait(self, timeout=None):
        result = self.poll()
        if result is None:raise real_subprocess.TimeoutExpired('authored compiler', timeout)
        return result
    def pause(self, amount):self.tick += amount

def execute(path, scenario):
    source = path.read_text()
    code = source[source.index('for phase,argv in '):source.index('after=pins();')]
    f = Process(late=scenario=='late', exception=scenario=='exception')
    with tempfile.TemporaryDirectory(prefix='CompilerLifecycleControl-') as tmp:
        n = dict(scratch=Path(tmp),repo=Path(tmp),r=Path(tmp),before={},pins=lambda:{},
                 start=0,samples=[],frames=[],guard=None,ordinaryCross=False,owned={},remaining=[],
                 subprocess=SimpleNamespace(Popen=lambda *a,**k:f,TimeoutExpired=real_subprocess.TimeoutExpired),
                 listing=f.listing,usage=f.usage,machine=lambda:{'swapGiB':1,'reportedFreePercent':49,'diskFreeGiB':100},
                 time=SimpleNamespace(monotonic=lambda:f.tick,sleep=f.pause),
                 signal=__import__('signal'),os=SimpleNamespace(kill=f.kill),observe=observe,
                 drain=lambda child,owned,listing,usage,seconds:drain(child,owned,listing,usage,seconds=seconds,
                       signal_pid=f.kill,now=lambda:f.tick,pause=f.pause))
        error = None
        try:exec(compile(code,str(path),'exec'),n)
        except Exception as e:error = type(e).__name__
    return {'remainingActualFixturePIDs':sorted(f.rows),'reportedRemaining':n['remaining'],
            'sent':f.sent,'exception':error,'guard':n['guard'],
            'phaseReceipts':n.get('phaseReceipts')}

p = Path(__file__).parent
old = p/'meeting-seventh-release-guarded.before-lifecycle.py'
new = p/'meeting-seventh-release-guarded.py'
results = {scenario:{'original':execute(old,scenario),'fixed':execute(new,scenario)}
           for scenario in ['exception','late']}
checks = [results['exception']['original']['remainingActualFixturePIDs']==[101],
          results['exception']['original']['exception']=='RuntimeError',
          results['exception']['fixed']['remainingActualFixturePIDs']==[],
          results['exception']['fixed']['guard']=='active compiler lifecycle exception: RuntimeError',
          results['late']['original']['remainingActualFixturePIDs']==[202],
          results['late']['original']['reportedRemaining']==[],
          results['late']['fixed']['remainingActualFixturePIDs']==[],
          results['late']['fixed']['phaseReceipts'][0]['drain']['remainingOwnedPIDs']==[]]
print(json.dumps({'scope':'Exact original/fixed phase loops; Popen/table/usage/signals/clock replaced, no OS compiler launched',
                  'results':results,'checks':checks,'passed':sum(checks),'total':len(checks)}))
raise SystemExit(0 if all(checks) else 1)

import json
import signal
from OwnedCompilerProcess import observe, drain

class Fake:
    def __init__(self):
        self.pid = 101
        self.returncode = None
        self.t = 0.0
        self.rows = {101: (1, 101, 1001)}
        self.signals = []
        self.spawn = False
        self.fail_listing = 0
        self.refuse = False

    def listing(self):
        if self.fail_listing:
            self.fail_listing -= 1
            raise RuntimeError('authored observation failure')
        return [(pid, parent, group, 'S', 'disposable fixture')
                for pid, (parent, group, start) in self.rows.items()]

    def usage(self, pid):
        row = self.rows.get(pid)
        return None if row is None else {'processStart': row[2],
            'footprintBytes': 1, 'residentBytes': 1}

    def signal(self, pid, sig):
        self.signals.append((pid, self.rows[pid][2], int(sig)))
        if self.refuse:
            raise PermissionError('authored refusal')
        del self.rows[pid]
        if self.spawn and pid == self.pid:
            self.rows[202] = (1, self.pid, 2002) # Late child, now orphaned in owned group.

    def poll(self):
        if self.pid not in self.rows:
            self.returncode = 0
        return self.returncode

    def pause(self, seconds):
        self.t += seconds

def run(f, owned):
    return drain(f, owned, f.listing, f.usage, seconds=1,
                 signal_pid=f.signal, now=lambda: f.t, pause=f.pause)

checks = []
f = Fake(); f.rows = {}; f.returncode = 0
r = run(f, {101: 1001}); checks.append(('already joined', not r['sent'] and not r['remainingOwnedPIDs'] and not r['unresolvedPIDs'] and not r['errors']))
f = Fake(); r = run(f, {101: 1001}); checks.append(('pinned root joins', r['sent'][0]['processStart'] == 1001 and not r['remainingOwnedPIDs'] and not r['unresolvedPIDs']))
f = Fake(); f.spawn = True; r = run(f, {101: 1001}); checks.append(('late descendant observed and joined', {x['pid'] for x in r['sent']} == {101, 202} and not r['remainingOwnedPIDs']))
f = Fake(); f.rows[202] = (101, 101, 9999); r = run(f, {101: 1001, 202: 2002}); checks.append(('recycled group PID refused without signal', 202 in r['unresolvedPIDs'] and all(x['pid'] != 202 for x in r['sent']) and 'owned process start mismatch' in r['errors']))
f = Fake(); f.rows[202] = (1, 333, 9999); r = run(f, {101: 1001, 202: 2002}); checks.append(('recycled unrelated PID untouched', all(x['pid'] != 202 for x in r['sent']) and 202 in f.rows))
f = Fake(); f.fail_listing = 1; r = run(f, {101: 1001}); checks.append(('observation exception still drains pinned root but refuses acceptance', not r['remainingOwnedPIDs'] and any('observation failed' in x for x in r['errors'])))
f = Fake(); f.refuse = True; r = run(f, {101: 1001}); checks.append(('signal refusal remains unjoined', r['remainingOwnedPIDs'] == [101] and any('signal refused' in x for x in r['errors'])))
f = Fake(); f.rows[202] = (101, 444, 2002); live, unresolved, errors = observe(f, {}, f.listing, f.usage); checks.append(('different group descendant found by ancestry', {x[0] for x in live} == {101, 202} and not unresolved and not errors))
f = Fake(); f.rows[101] = (1, 101, 9999); f.rows[202] = (101, 101, 2002); r = run(f, {101: 1001}); checks.append(('recycled root cannot admit foreign group children', not r['sent'] and set(r['unresolvedPIDs']) == {101, 202} and not f.signals))
f = Fake(); f.rows[202] = (101, 444, 9999); f.rows[303] = (202, 555, 3003); r = run(f, {101: 1001, 202: 2002}); checks.append(('recycled descendant cannot seed foreign ancestry', all(x['pid'] not in {202, 303} for x in r['sent']) and 303 in f.rows))
f = Fake(); f.rows[101] = (1, 101, 9999); f.rows[202] = (101, 101, 2002)
def recycled_root_exits(seconds):
    f.t += seconds
    f.rows.pop(101, None)
r = drain(f, {101:1001}, f.listing, f.usage, seconds=1, signal_pid=f.signal,
          now=lambda:f.t, pause=recycled_root_exits)
checks.append(('root refusal persists after recycled root exits', not r['sent'] and r['unresolvedPIDs']==[202] and 202 in f.rows))
print(json.dumps({'scope': 'Authored table/usage/signals/clock; no native compiler or OS process launched', 'checks': checks, 'passed': sum(ok for _, ok in checks), 'total': len(checks)}))
raise SystemExit(0 if all(ok for _, ok in checks) else 1)

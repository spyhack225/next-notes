"""Disposable compiler CLI ownership only; never used by the application.

Observe the launched process group/ancestry and retain exact process start identities.
An observation error refuses acceptance. Drain re-observes after each signal so children
created during shutdown cannot disappear from the last snapshot's join accounting.
"""
import os
import signal
import time


def observe(child, owned, listing, usage, *, root_refused=False, details=None):
    rows = [row for row in listing() if not row[3].startswith('Z')]
    by_pid = {row[0]: row for row in rows}
    facts = {}
    problems = []
    unresolved = []
    retired = set()
    confirmation = None
    confirmation_error = None
    confirmed_once = False

    def note(pid, kind, observed=None):
        if details is not None and len(details) < 64:
            details.append({'pid': pid, 'kind': kind,
                            'expectedStart': owned.get(pid),
                            'observedStart': observed,
                            'isRoot': pid == child.pid})

    def read_fact(pid):
        nonlocal confirmation, confirmation_error, confirmed_once
        fact = usage(pid)
        if fact is not None and fact.get('processStart'):
            return fact
        if not confirmed_once:
            confirmed_once = True
            try:
                confirmation = {row[0]: row for row in listing()}
            except Exception as error:
                confirmation_error = type(error).__name__
        if confirmation is not None:
            row = confirmation.get(pid)
            if row is None or row[3].startswith('Z'):
                retired.add(pid)
                by_pid.pop(pid, None)
                note(pid, 'confirmed absent' if row is None else 'confirmed zombie')
                return None
        note(pid, 'live attribution unavailable' if confirmation is not None
             else 'confirmation listing failed: ' + str(confirmation_error))
        return None

    def admit(pid):
        fact = read_fact(pid)
        if pid in retired:
            return False
        if fact is None or not fact.get('processStart'):
            problems.append('owned attribution unavailable')
            unresolved.append(pid)
            return False
        if pid in owned and fact['processStart'] != owned[pid]:
            note(pid, 'process start mismatch', fact['processStart'])
            problems.append('owned process start mismatch')
            unresolved.append(pid)
            return False
        owned[pid] = fact['processStart']
        facts[pid] = fact
        return True

    # Independently pinned surviving descendants stay owned even after their root exits.
    # A recycled PID is never an ancestry seed and cannot admit its foreign children.
    for pid in list(owned):
        if pid in by_pid:
            fact = read_fact(pid)
            if fact and fact.get('processStart') == owned[pid]:
                facts[pid] = fact

    root_row = by_pid.get(child.pid)
    if root_refused:
        facts.pop(child.pid, None)
        group_allowed = False
        if root_row:
            problems.append('root admission already refused')
            unresolved.append(child.pid)
    elif root_row:
        # A launched unreaped Popen root may be admitted once. A recorded root must
        # match before its group or ancestry can admit any new process.
        group_allowed = child.pid in facts
        if not group_allowed:
            if child.pid in owned or child.returncode is None:
                group_allowed = admit(child.pid)
            else:
                problems.append('unbound reaped root present')
                unresolved.append(child.pid)
    else:
        # Existing group members may outlive their pinned leader. No positive leader
        # observation means this group was never admitted and must stay unbound.
        group_allowed = child.pid in owned

    for _ in range(len(rows) + 1):
        added = False
        for pid, parent, group, stat, args in rows:
            if pid in facts or pid in unresolved or pid in retired:
                continue
            if parent in facts or (group == child.pid and group_allowed):
                if admit(pid):
                    added = True
            elif group == child.pid and not group_allowed:
                problems.append('root group admission refused')
                unresolved.append(pid)
        if not added:
            break
    live = [(pid, by_pid[pid][2], fact) for pid, fact in facts.items()]
    return live, sorted(set(unresolved)), sorted(set(problems))


def drain(child, owned, listing, usage, *, seconds=6, root_refused=False,
          signal_pid=os.kill, now=time.monotonic, pause=time.sleep):
    began = now()
    errors = []
    sent = set()
    observation_details = []
    remaining = []
    unresolved = []
    while now() - began < seconds:
        try:
            live, unresolved, problems = observe(child, owned, listing, usage, root_refused=root_refused, details=observation_details)
            errors.extend(problems)
            if child.pid in unresolved:
                root_refused = True
        except Exception as error:
            errors.append('drain observation failed: ' + type(error).__name__)
            live = []
            # A failed listing cannot establish a join. Only already pinned starts
            # may be signalled; another scan must establish group absence.
            for pid, start in list(owned.items()):
                try:
                    fact = usage(pid)
                    if fact and fact['processStart'] == start:
                        live.append((pid, None, fact))
                except Exception:
                    pass
            unresolved = ['observation unavailable']
        sig = signal.SIGTERM if now() - began < seconds / 2 else signal.SIGKILL
        for pid, group, fact in live:
            key = (pid, fact['processStart'], sig)
            if key in sent:
                continue
            try:
                current = usage(pid)
                if current and current['processStart'] == owned.get(pid):
                    signal_pid(pid, sig)
                    sent.add(key)
            except ProcessLookupError:
                pass
            except Exception as error:
                errors.append('owned signal refused: ' + type(error).__name__)
        child.poll()  # Reap the owned direct child; never assume its children joined.
        remaining = [pid for pid, group, fact in live]
        if not remaining and not unresolved and child.returncode is not None:
            break
        pause(.1)  # Bounded disposable CLI drain, never a product-path wait.
    # One final rescan catches a child spawned during the previous signal interval.
    try:
        live, unresolved, problems = observe(child, owned, listing, usage, root_refused=root_refused, details=observation_details)
        errors.extend(problems)
        remaining = [pid for pid, group, fact in live]
    except Exception as error:
        remaining = list(owned)
        unresolved = ['observation unavailable']
        errors.append('final ownership observation failed: ' + type(error).__name__)
    child.poll()
    if child.returncode is None:
        unresolved.append(child.pid)
    return {'observationDetails': observation_details,
            'remainingOwnedPIDs': sorted(set(remaining)),
            'unresolvedPIDs': sorted(set(unresolved), key=str),
            'errors': sorted(set(errors)), 'seconds': now() - began,
            'sent': [{'pid': pid, 'processStart': start, 'signal': int(sig)}
                     for pid, start, sig in sorted(sent)]}

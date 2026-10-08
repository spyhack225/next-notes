"""Disposable compiler CLI ownership only; never used by the application.

Observe the launched process group/ancestry and retain exact process start identities.
An observation error refuses acceptance. Drain re-observes after each signal so children
created during shutdown cannot disappear from the last snapshot's join accounting.
"""
import os
import signal
import time


def observe(child, owned, listing, usage):
    rows = listing()
    facts = {}
    live_rows = [row for row in rows if not row[3].startswith('Z')]
    problems = []
    for pid, parent, group, stat, args in live_rows:
        if pid in owned:
            fact = usage(pid)
            if fact and fact['processStart'] == owned[pid]:
                facts[pid] = fact
    ids = {child.pid} | set(facts)
    for _ in range(len(rows) + 1):
        added = {pid for pid, parent, group, stat, args in live_rows
                 if parent in ids or group == child.pid}
        if added <= ids:
            break
        ids |= added
    live = []
    unresolved = []
    for pid, parent, group, stat, args in live_rows:
        if pid not in ids:
            continue
        fact = facts.get(pid) or usage(pid)
        if fact is None or not fact.get('processStart'):
            problems.append('owned attribution unavailable')
            unresolved.append(pid)
            continue
        if pid in owned and fact['processStart'] != owned[pid]:
            problems.append('owned process start mismatch')
            unresolved.append(pid)
            continue  # Never admit or signal a recycled/mismatched process.
        owned[pid] = fact['processStart']
        live.append((pid, group, fact))
    return live, unresolved, sorted(set(problems))


def drain(child, owned, listing, usage, *, seconds=6,
          signal_pid=os.kill, now=time.monotonic, pause=time.sleep):
    began = now()
    errors = []
    sent = set()
    remaining = []
    unresolved = []
    while now() - began < seconds:
        try:
            live, unresolved, problems = observe(child, owned, listing, usage)
            errors.extend(problems)
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
        live, unresolved, problems = observe(child, owned, listing, usage)
        errors.extend(problems)
        remaining = [pid for pid, group, fact in live]
    except Exception as error:
        remaining = list(owned)
        unresolved = ['observation unavailable']
        errors.append('final ownership observation failed: ' + type(error).__name__)
    child.poll()
    if child.returncode is None:
        unresolved.append(child.pid)
    return {'remainingOwnedPIDs': sorted(set(remaining)),
            'unresolvedPIDs': sorted(set(unresolved), key=str),
            'errors': sorted(set(errors)), 'seconds': now() - began,
            'sent': [{'pid': pid, 'processStart': start, 'signal': int(sig)}
                     for pid, start, sig in sorted(sent)]}

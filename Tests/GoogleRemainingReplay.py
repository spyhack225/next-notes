#!/usr/bin/env python3
"""Replay the reviewed successful-delivery and controller cache decisions.

Keep signatures and held fixtures byte-identical; remove only the new admission
checks/cache clearing. The snapshot is private scratch inside this worktree.
"""
import argparse
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
G = 'Sources/NextNotes/Calendar/Google/'
FILES = [G + name for name in ['GoogleAccessTokens.swift', 'GoogleTokenStore.swift',
    'GoogleCalendarProvider.swift', 'GoogleConnection.swift']] + [
    'Sources/NextNotes/Agent/GoogleWorkspaceCLI.swift', 'Sources/NextNotes/Calendar/CalendarService.swift']

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=['capture', 'green', 'remaining-red'])
    parser.add_argument('snapshot', type=Path)
    args = parser.parse_args()
    snapshot = args.snapshot.resolve()
    assert snapshot.is_relative_to(ROOT)
    if args.mode == 'capture':
        for path in FILES:
            target = snapshot / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes((ROOT / path).read_bytes())
        return
    for path in FILES:
        (ROOT / path).write_bytes((snapshot / path).read_bytes())
    if args.mode == 'green': return
    def replace(path, before, after):
        source = (ROOT / path).read_text()
        assert source.count(before) == 1, (path, before)
        (ROOT / path).write_text(source.replace(before, after))
    # Reviewed token producer checked only inside the child before completion.
    for line in [
        '        if let expectedGrantIdentity, grant?.identity != expectedGrantIdentity { throw GoogleCalendarError.signInChanged }\n',
        '            guard generation == joinedGeneration, try isCurrent(identity) else { throw GoogleCalendarError.signInChanged }\n',
        '        guard generation == started, try isCurrent(identity) else { throw GoogleCalendarError.signInChanged }\n']:
        replace(G+'GoogleAccessTokens.swift', line, '')
    # Reviewed launch admission did not bind identity at the existing process hop.
    replace('Sources/NextNotes/Agent/GoogleWorkspaceCLI.swift',
        '''                    if let grantIdentity {
                        try GoogleTokenStore.withMatchingGrant(grantIdentity) { try box.launch() }
                    } else { try box.launch() }''', '                    try box.launch()')
    # Reviewed controller skipped the service when the grant lacked Calendar;
    # disconnect entered that service but its disabled guard retained the list.
    replace(G+'GoogleConnection.swift', '            await refreshCalendars(granted)',
        '            if granted { await refreshCalendars(granted) }')
    replace('Sources/NextNotes/Calendar/CalendarService.swift',
        '''        guard enabledForTesting ?? (providersForTesting != nil || Settings.shared.calendarGoogleEnabled) else {
            googleCalendars = []
            return
        }''',
        '        guard enabledForTesting ?? (providersForTesting != nil || Settings.shared.calendarGoogleEnabled) else { return }')

if __name__ == '__main__': main()

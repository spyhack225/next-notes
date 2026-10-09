#!/usr/bin/env python3
"""Matched native review replay: retain new fixture signatures; restore six old decisions.

No accounts/private input. Build/run only through heavy.sh. Red keeps the HTTP/gate seams
but collapses failed Keychain reads, ignores launch cancellation, saves before invalidating,
clears unconditionally, invalidates every 401, ignores probing gaps and declined Calendar.
"""
import argparse
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
G = 'Sources/NextNotes/Calendar/Google/'
FILES = [G + n for n in ['GoogleTokenStore.swift', 'GoogleAccessTokens.swift', 'GoogleOAuthClient.swift',
    'GoogleCalendarProvider.swift', 'GoogleConnection.swift', 'GoogleConnectSelfTest.swift', 'GoogleAppClient.swift']] + [
    'Sources/NextNotes/Agent/GoogleWorkspaceCLI.swift', 'Sources/NextNotes/Agent/Mac/MacWorkspace.swift',
    'Sources/NextNotes/Agent/AgentCapabilityManifest.swift', 'Sources/NextNotes/Calendar/CalendarService.swift']

def replace(path, old, new):
    file = ROOT / path
    source = file.read_text()
    assert source.count(old) == 1, (path, old)
    file.write_text(source.replace(old, new))

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=['capture', 'green', 'review-red', 'withdrawal-red'])
    parser.add_argument('snapshot', type=Path)
    args = parser.parse_args()
    snapshot = args.snapshot.resolve()
    assert snapshot.is_relative_to(ROOT)
    if args.mode == 'capture':
        for path in FILES:
            out = snapshot / path; out.parent.mkdir(parents=True, exist_ok=True)
            out.write_bytes((ROOT / path).read_bytes())
        return
    for path in FILES:
        (ROOT / path).write_bytes((snapshot / path).read_bytes())
    if args.mode == 'green': return
    if args.mode == 'withdrawal-red':
        replace('Sources/NextNotes/Calendar/CalendarService.swift',
            '''        } else if case .disabled = state {
            // A successful replacement without Calendar also withdraws the old cached
            // entries. The existing refresh skips this disabled provider before reads.
            googleCalendars = []
            await refresh()
        }
        return state''',
            '''        }
        return state''')
        return
    # 1. Native SecItemCopyMatching failure decision, with the OSStatus seam retained.
    replace(G+'GoogleTokenStore.swift',
        'guard status == errSecSuccess, let data = item as? Data else { return .unavailable }',
        'guard status == errSecSuccess, let data = item as? Data else { return .absent }')
    replace(G+'GoogleTokenStore.swift', '        if !appSignInSelected { appSignInSelected = true }\n        return .available', '        return .available')
    # 2. Late cancellation was only checked inside the token actor, not launch admission.
    replace('Sources/NextNotes/Agent/GoogleWorkspaceCLI.swift',
        '        try Task.checkCancellation()\n        // Arguments, never the values', '        // Arguments, never the values')
    replace('Sources/NextNotes/Agent/GoogleWorkspaceCLI.swift',
        '        try Task.checkCancellation()\n        let box = ProcessBox', '        let box = ProcessBox')
    replace('Sources/NextNotes/Agent/GoogleWorkspaceCLI.swift',
        '        try Task.checkCancellation()\n        guard !cancelled else { throw CancellationError() }\n        try process.run()',
        '        try process.run()')
    # 3. Old sign-in save/actor-hop ordering; old invalid_grant has unconditional clear.
    replace(G+'GoogleOAuthClient.swift',
        '        try await GoogleAccessTokens.shared.replaceGrant(refreshToken: refreshToken, scopes: granted)\n        await afterGrantSaveForTesting?()',
        '        guard GoogleTokenStore.save(refreshToken: refreshToken, grantedScopes: granted) else { throw GoogleCalendarError.tokenStoreFailed }\n        await afterGrantSaveForTesting?()\n        await GoogleAccessTokens.shared.invalidate()')
    replace(G+'GoogleTokenStore.swift',
        '        guard let grant = try savedGrant(), grant.identity == identity else { return false }\n        let status = SecItemDelete(baseQuery as CFDictionary)\n        guard status == errSecSuccess || status == errSecItemNotFound else { throw GoogleCalendarError.tokenStoreFailed }\n        return true',
        '        // Original revocation uses the unconditional clear, including legacy route retention.\n        clear()\n        return true')
    replace(G+'GoogleAccessTokens.swift',
        'guard generation == started, !Task.isCancelled, try isCurrent(identity) else',
        'guard generation == started, !Task.isCancelled else')
    # 4. Retain exact 401 token/observer seam, restore old unconditional invalidation.
    replace(G+'GoogleAccessTokens.swift', '        guard cached?.token == rejectedToken else { return }\n        cached = nil',
        '        // Original stale rejection can cancel another caller\'s refresh.\n        invalidate()')
    # 5. The actual live-input producer remains .checking; restore signedIn-only gaps.
    replace('Sources/NextNotes/Agent/AgentCapabilityManifest.swift',
        '        case .workspace:\n            if let gap = inputs.workspaceGaps[tool.id] { return .needsSetup(gap) }\n            switch inputs.workspace {\n            case .signedIn:',
        '        case .workspace:\n            switch inputs.workspace {\n            case .signedIn:\n                if let gap = inputs.workspaceGaps[tool.id] { return .needsSetup(gap) }')
    # 6. Preserve scope/sign-in injection seams, restore the actual unconditional consumers.
    replace(G+'GoogleCalendarProvider.swift', '            return authorizationState()\n        } catch', '            return .authorized\n        } catch')
    replace(G+'GoogleCalendarProvider.swift',
        '        guard authorizationState().isAuthorized else { return [] }\n        let list: GoogleCalendarList', '        let list: GoogleCalendarList')
    replace(G+'GoogleConnection.swift', '            let granted = GoogleScopes.coversCalendar(scopes)', '            let granted = true')
    replace('Sources/NextNotes/Calendar/CalendarService.swift',
        '        guard await google.authorizationState().isAuthorized else {\n            googleCalendars = []\n            return\n        }\n', '')

if __name__ == '__main__': main()

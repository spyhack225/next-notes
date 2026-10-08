#!/usr/bin/env python3
"""Matched native producer replay. Run builds/tests separately through heavy.sh.

capture saves only these worktree source files; green restores them exactly. Original
retains new type/fixture signatures while restoring the pre-change decisions. The
Calendar provider is the actual HEAD producer plus the two required fixture seams.
No owner data, executable discovery, network fetch or private client file is used.
"""
import argparse
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
GOOGLE = "Sources/NextNotes/Calendar/Google/"
FILES = [GOOGLE + name for name in ["GoogleAppClient.swift", "GoogleTokenStore.swift",
    "GoogleOAuthClient.swift", "GoogleAccessTokens.swift", "GoogleCalendarProvider.swift",
    "ManagedWorkspaceTool.swift"]] + ["Sources/NextNotes/Agent/GoogleWorkspaceCLI.swift",
    "Sources/NextNotes/Agent/Mac/MacWorkspace.swift", "Sources/NextNotes/Agent/Mac/MailDatabase.swift"]


def replace(path, before, after):
    file = ROOT / path
    source = file.read_text()
    assert source.count(before) == 1, (path, before)
    file.write_text(source.replace(before, after))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", choices=["capture", "green", "original", "revocation", "unpinned", "mailbox"])
    parser.add_argument("snapshot", type=Path)
    args = parser.parse_args()
    snapshot = args.snapshot.resolve()
    assert snapshot.is_relative_to(ROOT), "snapshot must stay in this worktree"
    if args.mode == "capture":
        for path in FILES:
            target = snapshot / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes((ROOT / path).read_bytes())
        print("REPLAY_CAPTURED")
        return
    for path in FILES:
        saved = (snapshot / path).read_bytes()
        if (ROOT / path).read_bytes() != saved:
            (ROOT / path).write_bytes(saved)
    if args.mode == "original":
        replace(GOOGLE + "GoogleAppClient.swift",
                "mail, calendar, drive, documents, spreadsheets, presentations, tasks, contacts, forms,",
                "legacyCalendar,")
        replace(GOOGLE + "GoogleTokenStore.swift",
                "JSONEncoder().encode(Grant(refreshToken: refreshToken, scopes: grantedScopes.sorted()))",
                "Optional(Data(refreshToken.utf8))")
        replace(GOOGLE + "GoogleOAuthClient.swift",
                'let granted = Set((token.scope ?? scopes.joined(separator: " ")).split(separator: " ").map(String.init))',
                "let granted: Set<String> = [GoogleScopes.legacyCalendar]")
        replace("Sources/NextNotes/Agent/Mac/MacWorkspace.swift",
                "Dictionary(uniqueKeysWithValues: tools.compactMap { tool in\n            guard let capability = GoogleCapability.needed(byTool: tool),\n                  !capability.isGranted(by: granted, readOnly: tool == \"get_agenda\") else { return nil }\n            return (tool, capability.permissionSentence)\n        })", "[:]")
        token_file = ROOT / (GOOGLE + "GoogleAccessTokens.swift")
        tokens = token_file.read_text()
        tokens, matched = re.subn(
            r"        if let inFlight, inFlight.identity == identity \{[\s\S]*?        if inFlight != nil \{ invalidate\(\) \}",
            "        // Original refreshes are independent.", tokens)
        assert matched == 1
        token_file.write_text("".join(line for line in tokens.splitlines(True)
                                     if line.strip() != "try Task.checkCancellation()"))
        store_file = ROOT / (GOOGLE + "GoogleTokenStore.swift")
        store_file.write_text("".join(line for line in store_file.read_text().splitlines(True)
                                     if line.strip() != "if !forgetSelection, !appSignInSelected, hasRefreshToken { appSignInSelected = true }"))
        replace("Sources/NextNotes/Agent/GoogleWorkspaceCLI.swift",
                "usesAppAccount && (GoogleTokenStore.appSignInSelected || GoogleTokenStore.hasRefreshToken)", "false")
        # Preserve HEAD's actual cache/refresh/API-401 decisions, with admission for
        # the new exact fixture and the error case used by the sign-in return seam.
        original = subprocess.check_output(["git", "show", "713cbe8c:" + GOOGLE + "GoogleCalendarProvider.swift"], cwd=ROOT).decode()
        original = original.replace("(GoogleCalendarErrorSelfTest.isRequested\n", "((GoogleCalendarErrorSelfTest.isRequested || GoogleAccessTokens.testHooksAdmitted)\n")
        original = original.replace("case accessTokenRejected", "case tokenStoreFailed\n    case accessTokenRejected")
        original = original.replace("case .accessTokenRejected:\n", 'case .tokenStoreFailed:\n            "The sign-in could not be saved."\n        case .accessTokenRejected:\n')
        (ROOT / (GOOGLE + "GoogleCalendarProvider.swift")).write_text(original)
    elif args.mode == "revocation":
        replace(GOOGLE + "GoogleAccessTokens.swift", 'where status == 400 && code == "invalid_grant"', "where status == 400")
    elif args.mode == "unpinned":
        # Restore a forbidden alternate at the actual execution admission. The
        # admitted temporary executable stands in for the separate installed login;
        # no discovery or execution of the owner's binary is permitted in replay.
        replace("Sources/NextNotes/Agent/GoogleWorkspaceCLI.swift",
                "guard let managed = managedExecutable() else { throw WorkspaceCLIError.notInstalled }",
                "guard let managed = managedExecutable() ?? testingExecutable else { throw WorkspaceCLIError.notInstalled }")
    elif args.mode == "mailbox":
        replace("Sources/NextNotes/Agent/Mac/MailDatabase.swift",
                "let all = try mailboxes().filter(\\.isGoogleAccount)", "let all = try mailboxes()")
    print("REPLAY_" + args.mode.upper())


if __name__ == "__main__":
    main()

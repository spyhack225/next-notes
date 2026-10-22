# Google re-review: three remaining findings repaired

Read the full independent `review-google/REVIEW.md` at reviewed head `59b8bbba`.
One guarded FIFO slot used `RELAY_ID=claude2-google-c` and the recreated own scratch.
Native verification ran on arm64 macOS 27.2. No app install, push, merge, GUI,
private OAuth JSON or owner-store seeding was performed.

## Commits and producers

1. `27c24e23` — Bind Google scope admission and launch to the same grant.
   `GoogleWorkspaceCLI.run` carries its scope-approved record identity into token
   acquisition. `GoogleAccessTokens` checks generation and exact record identity after
   successful creator and joining-waiter delivery. The existing token-store lock admits
   identity comparison and `process.run()` together. A changed grant refuses before
   backing with “Your Google sign-in changed, try again.” No new store/save/timer/retry
   or production await was added.
2. `8a3aec0f` — Clear Google calendar lists through the connection controller.
   Grant application always reaches the existing list-refresh seam. Disabled entry clears
   the list before provider/token/network backing, including disconnect when already off.
   The live path reads the current enabled switch. Saved calendar selections are retained.
3. `08ffb2ec` — Require named Google behavioral RED failures.
   The six-finding gate requires six exact named behavioral assertions and native exit 1.
   Setup-only, each mixed five-behavior/one-setup case, broad-prefix, missing-finding,
   unrelated and wrong-exit controls refuse. All supported RED modes reject setup controls
   with their correct root markers. Full diff and per-commit secret scans are retained.

## Why earlier GREEN missed each

- R3 held failed refreshes and cancellation, leaving successful completed refresh delivery
  untested. It also never replaced the grant between scope admission/token acquisition or
  token delivery/launch. The new native fixtures hold both successful delivery paths across
  a real loopback reconnect; a separate identical-token/identical-scope replacement changes
  only the stored generation. Actual runner/spawn cases hold all three admission seams.
- R6 populated and withdrew through `CalendarService.connectGoogle`. The separate connection
  controller skipped list refresh after switching Calendar off; disconnect's enabled guard
  returned without clearing. New populated fixtures execute controller connect/disconnect,
  grant application and the actual service seam with an isolated disabled-switch input.
- The retained earlier RED logs had real failures, but the harness enforced only `FAIL Rn`
  prefixes. A setup-only negative control made the reviewed parser return 0 and the control
  test exit 1. The same control against the fixed parser exits 0 and rejects setup as RED.

## Actual verification

The matched reviewed-decision native replay fails exactly **13** assertions: 11 grant and
2 controller assertions, `GOOGLE_CONNECT_FAILED`, exit 1. All setup and positive controls
pass. The fixed and restored runs each pass **340** Google assertions with unchanged Swift
fixture hashes. Replay retains new hook/type signatures and restores reviewed bad decisions;
it is not an untouched historical binary.

The original six-finding replay fails 72 assertions, `GOOGLE_CONNECT_FAILED`, exit 1,
including every exact named gate target. Required mutations fail at their named assertions:
revocation 7 / `GOOGLE_CONNECT_FAILED` / exit 1; unpinned 1 /
`GOOGLE_CONNECT_FAILED` / exit 1; mailbox 7 / `MAC_ACCOUNTS_FAILED` / exit 1.

All seven requested flags pass both fixed and restored, each root exit 0:

| Flag | Marker |
| --- | --- |
| `--selftest-google-connect` | `GOOGLE_CONNECT_OK` (340 assertions) |
| `--selftest-gws` | `GWS_FIXTURES_OK: 10 cases`, `GWS_OK` (isolated executable) |
| `--selftest-calendar --calendar-google-errors` | `CALENDAR_OK: isolated Google error consumers behave` |
| `--selftest-mac-accounts` | `MAC_ACCOUNTS_OK` |
| `--selftest-capability-manifest` | `CAPABILITY_MANIFEST_OK` |
| `--selftest-ui-strings` | `UI_STRINGS_OK` |
| `--selftest-store-isolation` | `STORE_ISOLATION_OK: 21 files and 0 defaults unchanged` |

The isolation run's last nested marker remains **`TOOLLOOP_PRODUCTION_FAILED`**, with
18 `TOOLLOOP_PRODUCTION_WRONG` lines from the inherited A02 browser-fixture admission
wiring issue. It was retained unchanged and supplies no broader Agent readiness verdict.

Batch markers: `GOOGLE_OPTION_C_MUTATIONS_RESTORED_OK`, `GOOGLE_REMAINING_BATCH_OK`,
wrapper exit 0. Shell controls: `GOOGLE_RED_HARNESS_OK`. Injection:
`INJECTION_DESTINATION_ORIGINAL_RED_FIXED_OK`, `GOOGLE_OAUTH_INJECTION_OK`.
End-of-slot scans: `COMMITS_SECRET_SCAN_OK`, `DIFF_SECRET_SCAN_OK`, `WIP_SECRET_SCAN_OK`.
Only the existing deliberately synthetic numeric client ID is allowlisted; no recognizable
real client ID or secret match was found. Scans never open or compare the private OAuth JSON.

Raw native logs, exits, source/binary pins, fixture invariance, original/fixed harness controls
and patches are in [the V3 packet](Tests/Reports/google-option-c-repair-v3/README.md).

## Limits and integration

Real Google consent/unticked permissions, native UI clicks, actual gws token precedence,
Keychain prompts/locks, cross-process Keychain compare-and-swap, publisher/archive provenance
and private-client packaged app/install behavior were unavailable under this brief.
The launch proof ends at in-process executable admission; an already admitted action can
continue across reconnect. No model/default, roadmap phase or broader quality gate was promoted.

Files changed: `GoogleAccessTokens.swift`, `GoogleTokenStore.swift`, `GoogleCalendarProvider.swift`,
`GoogleWorkspaceCLI.swift`, `GoogleConnection.swift`, `CalendarService.swift`,
`GoogleConnectSelfTest.swift`, `GoogleGrantReplacementSelfTest.swift`, new `GoogleGrantLaunchSelfTest.swift`,
`GoogleCalendarScopeSelfTest.swift`, `GoogleCalendarWithdrawalSelfTest.swift`,
`Tests/GoogleOptionCChecks.sh`, `Tests/GoogleOptionCHarnessTest.py`, `Tests/GoogleCredentialScan.py`,
new `Tests/GoogleRemainingChecks.sh`, new `Tests/GoogleRemainingReplay.py`, this report and the V3 packet.

These changed files **will conflict with uncommitted work** in the canonical checkout:
`Sources/NextNotes/Agent/GoogleWorkspaceCLI.swift`,
`Sources/NextNotes/Calendar/CalendarService.swift`,
`Sources/NextNotes/Calendar/Google/GoogleTokenStore.swift`.
The integrator must reconcile them by hand. Canonical files/processes/claims were preserved.
The root RESULT.md remains the requested local handoff report (ignored by repository rules).
Own scratch and replay snapshots were removed after the joined batch; previous result/message
files are retained. Post-commit, post-cleanup secret greps were rerun and all three markers are OK.

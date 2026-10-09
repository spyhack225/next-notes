# Calendar list completion after withdrawal

Round-3 review identified an outstanding Calendar list response that could publish
after the controller cleared the cache. `CalendarService.refreshGoogleCalendars`
suspended at `google.calendars()` and assigned its result without checking whether
an account transition or newer list read had occurred. A late error could also erase
a replacement grant's successfully fetched list.

The repair uses one in-memory epoch on the existing service. A list request advances
it before checking the enabled switch or awaiting authorization. Direct service
connect/disconnect advances it before its first await; disconnect clears immediately.
Controller grant application and disconnect already call the list-service seam and
advance the same epoch there. Authorization, success and error completions publish
only while their captured epoch remains current. No new store, lock, timer, retry,
save, model pass or await is added. Saved calendar selections are unchanged.

The existing native fixture holds the first HTTP list response after token/backing
admission. The actual controller applies a Docs-only withdrawal, disconnects, or
reconnects with Calendar; the direct service routes are exercised too. Additional
cases replace Calendar with Calendar while it stays enabled and return an old HTTP
503 after the new list has arrived. Replacements deliberately reuse refresh-token
text, so equality of token text or enabled state cannot satisfy the cache contract.
Positive controls require the new list to arrive while the old response is still
held, zero extra backing for clearing, and no request/retry on old completion.

`Tests/GoogleCalendarListChecks.sh` runs through one normal-gate `../heavy.sh` FIFO
slot with `RELAY_ID=claude2-google-c`. It compiles the byte-identical reviewed
`08ffb2ec` CalendarService first, with the new fixture, and requires all seven exact
named behavioral RED assertions and native exit 1. It then applies the fixed service,
runs the seven requested flags, the three existing producer mutations, restored seven
flags, fixture-invariance checks and credential scans. This is an actual old service
producer replay in the current app, not an untouched historical app binary.

The earlier fixture fully awaited the list before withdrawing/disconnecting, so it
never exercised this reentrant completion. Original native replay now has 362 passing
assertions and exactly seven failures, `GOOGLE_CONNECT_FAILED`, exit 1. Six traces
show `old-calendar` restored after the transition; the old 503 trace shows an empty
cache where `new-calendar` was required. Fixed and restored each pass all 369
assertions, `GOOGLE_CONNECT_OK`, exit 0, with all 11 fixture hashes unchanged.

All seven requested flags pass both fixed and restored, each root exit 0:

| Flag | Marker |
| --- | --- |
| `--selftest-google-connect` | `GOOGLE_CONNECT_OK` (369 assertions) |
| `--selftest-gws` | `GWS_FIXTURES_OK: 10 cases`, `GWS_OK` (isolated executable) |
| `--selftest-calendar --calendar-google-errors` | `CALENDAR_OK: isolated Google error consumers behave` |
| `--selftest-mac-accounts` | `MAC_ACCOUNTS_OK` |
| `--selftest-capability-manifest` | `CAPABILITY_MANIFEST_OK` |
| `--selftest-ui-strings` | `UI_STRINGS_OK` |
| `--selftest-store-isolation` | `STORE_ISOLATION_OK: 21 files and 0 defaults unchanged` |

The isolation run's final nested marker remains `TOOLLOOP_PRODUCTION_FAILED`, with
18 `TOOLLOOP_PRODUCTION_WRONG` lines in both fixed/restored runs. This is the retained
inherited A02 browser-fixture admission wiring failure, not a broader Agent pass.

The three producer mutations fail at their required assertions with native exit 1:
revocation 7 / `GOOGLE_CONNECT_FAILED`, unpinned 1 / `GOOGLE_CONNECT_FAILED`, mailbox
7 / `MAC_ACCOUNTS_FAILED`. All nine mutation-snapshot source files are restored
byte-for-byte. Batch markers are `GOOGLE_OPTION_C_MUTATIONS_RESTORED_OK` and
`GOOGLE_CALENDAR_LIST_BATCH_OK`, wrapper exit 0. The shell controls report
`GOOGLE_RED_HARNESS_OK`; setup-only output and removal of any one of the seven held
behavior names are rejected.

End-of-slot scans report `COMMITS_SECRET_SCAN_OK`, `DIFF_SECRET_SCAN_OK` and
`WIP_SECRET_SCAN_OK`. Only the existing deliberately synthetic numeric client ID
is allowlisted; no recognizable real client ID or secret match was found or printed.
The scans do not open or compare the private OAuth JSON.

Retained logs, exits, source/binary hashes, exact producer patch, fixture hashes and
[verification summary](verification.json) are in this packet. Native runs used arm64
macOS 27.2. HTTP responses and sign-in/tool/workspace dependencies are supplied by
the existing isolated seams; the actual provider decode, controller grant application
and service publication execute in the compiled app. Original is the byte-identical
reviewed service in that current app, rather than an untouched historical binary.

No real Google consent/token/revocation service, visible UI lifecycle, private OAuth
JSON, owner-store migration, app install, push or merge is exercised. Synthetic debug
functional checks supply no live-meeting, full-duplex or latency acceptance and do
not promote any model, default, quality gate or roadmap phase.


Cleanup removed only the owned `wt-scratch/google-c` and replay/source snapshots,
with no binary holder remaining. Its pre-removal unique-inode allocation total was
2,112,339,968 bytes (`st_blocks*512`), not a global/APFS reclamation claim. All
matching fixture temporary paths are gone. Compact evidence remains; see
[cleanup manifest](cleanup.json).

Changed files: `CalendarService.swift`, `GoogleCalendarWithdrawalSelfTest.swift`,
`Tests/GoogleOptionCChecks.sh`, `Tests/GoogleOptionCHarnessTest.py`, new
`Tests/GoogleCalendarListChecks.sh`, `PERFORMANCE-STANDARDS.md` and this evidence packet.
`Sources/NextNotes/Calendar/CalendarService.swift` **will conflict with uncommitted
canonical work** and needs manual reconciliation by the integrator. Canonical files,
other agents' scratch/processes/claims and the installed app were preserved by this task.

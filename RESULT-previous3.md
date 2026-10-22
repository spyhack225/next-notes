# Google review repairs — verified native candidate

The independent review at `review-google/REVIEW.md` was read in full. This round
repairs findings 1–6 through the existing credential record, token actor, process
box, manifest and Calendar consumers. Work stays in `claude2/google-c`.
The final normal-gate FIFO native batch passed, including targeted REDs, all seven
required checks, three mutations and restoration. No app was installed, opened,
pushed or merged. Tested source equals the committed candidate through `c32bcc99`.

## Why the earlier green missed each finding

1. Tests exercised readable grants and token-endpoint failures. They never supplied
   a denied Keychain read together with a runnable alternate login. Every failed
   read became nil. The new typed read distinguishes not-found from unavailable,
   preserves legacy routing on adoption, and feeds one snapshot to each consumer.
   Unavailable credentials refuse routing, status, profile and executable backing
   with “Could not read your saved Google sign-in.”
2. Cancellation was injected during refresh. It missed cancellation after token
   delivery and inside the pre-launch window. The runner rechecks at executable
   entry; the existing ProcessBox coordinates remembered cancellation and launch.
   New fixtures pause after token return, inside spawn, and before entering spawn.
3. No refresh was held across reconnect. Sign-in saved first, then separately
   invalidated the actor; old invalid_grant could delete that new row. Replacement
   and invalidation now run without suspension on the existing token actor. The
   existing Keychain save/read admission also protects exact-generation deletion.
   Fixtures cover real loopback reconnect, newer different/same-token records and
   an unreadable record at revocation. This is in-process admission, not a claim of
   cross-process Keychain compare-and-swap.
4. Tests used successful concurrent reads and serial 401s. An unconditional stale
   401 invalidated another caller’s shared refresh. Calendar now passes the token
   that actually received 401. The actor evicts only that cached token and leaves
   pending refreshes alone. Fixtures overlap two real Calendar 401 consumers with
   Workspace and cover a late rejection during an ordinary expiry refresh.
5. Manifest fixtures forced signedIn. Live status probing actually supplies checking
   with cached gaps, which readiness ignored. Known gaps now precede optimistic
   checking/unknown readiness. A real AgentService status pass is held during its
   next probe; actual live inputs and allowed/selected planner entries are checked.
6. Tests retained partial grants but never followed them through Calendar authorize,
   service connect/list or the connection’s enable/list consumer. Successful sign-in
   always reported authorized and calendars() had no scope guard. Authorize now
   returns actual state; provider/service refuse list entry without Calendar, and
   the connection enables/lists only when granted. Native loopback exchanges cover
   Docs-only and empty grants; legacy permitted Calendar remains a positive control.

## Small items

The annual security-assessment comment now states the condition about restricted
Google data accessed from or through a third-party server. The duplicate nested
Info.plist placeholder pair is gone. Injection admits only the expected staged
bundle plist, rejecting unrelated destinations and hardlink/symlink redirection.
It uses synthetic input only. Bundle assertions require an exact placeholder pair
or a valid configured client; malformed values no longer pass via nil. All nine
unticked capabilities are independently tested through real Keychain round-trip
and CLI argument admission, including the five without planner tools.

The RED harness requires native exit1 plus the targeted failing assertion; the
six-finding RED requires a targeted R1–R6 assertion for every finding. Shell-only
negative checks prove unrelated failures, exit0 and a missing finding are rejected.

## Commits and native evidence

| Finding | Separate producer commit | Same-fixture native original failures |
| --- | --- | ---: |
| 1 unreadable saved sign-in | `db8b8fac` | 39 |
| 2 late launch cancellation | `d26a96c3` | 6 |
| 3 stale revocation / grant replacement | `35a0414d` | 5 |
| 4 concurrent stale 401 | `e2ea9f4d` | 5 |
| 5 probing manifest scope gaps | `10d6663f` | 2 |
| 6 Calendar grant consumers and withdrawal | `1c72fe09` | 12 |

Small items and replay/scan tooling: `c32bcc99`. Native evidence/reference commit:
`59b8bbba`. Every producer commit contains
its regression fixture. The candidate was built together; intermediate commits
were not individually rebuilt. The native RED is an explicit bad-producer replay
retaining new signatures and test gates, not an untouched earlier binary.

Final [V2 evidence](Tests/Reports/google-option-c/2026-10-08-review-withdrawal/README.md)
retains source/binary hashes, native exit codes, replay/mutation patches, compiler
logs and fixture hashes. The original replay fails 70 assertions / native exit 1 /
`GOOGLE_CONNECT_FAILED`, including all six targeted findings and legacy adoption.
Fixed and restored each pass **318** assertion lines / `GOOGLE_CONNECT_OK`.
Fixture hashes are unchanged; committed source matches the tested fixed pins.

The earlier repaired V1 passed 315 assertions but missed a new transition: after
returning the truthful disabled state for a replacement that declined Calendar,
CalendarService no longer refreshed, leaving previously cached calendars/events.
An additive native fixture seeds both through actual HTTP/provider/service reads.
The first repair fails that exact cache assertion (one failure / native exit 1 /
`GOOGLE_CONNECT_FAILED`); the final repair clears both through the existing refresh
without another token/Calendar call. [V1 evidence](Tests/Reports/google-option-c/2026-10-08-review/README.md)
remains separate and immutable in its original logs/hashes.

All final seven root native exits are **0**, in both fixed and restored batches:

- `--selftest-google-connect`: `GOOGLE_CONNECT_OK` (318 assertions).
- `--selftest-gws` with isolated backing: `GWS_FIXTURES_OK: 10 cases`; `GWS_OK`
  (gws 0.22.5 fixture, signed in; exact temporary path in raw log).
- `--selftest-calendar --calendar-google-errors`:
  `CALENDAR_OK: isolated Google error consumers behave`.
- `--selftest-mac-accounts`: `MAC_ACCOUNTS_OK`.
- `--selftest-capability-manifest`: `CAPABILITY_MANIFEST_OK`.
- `--selftest-ui-strings`: `UI_STRINGS_OK`.
- `--selftest-store-isolation`:
  `STORE_ISOLATION_OK: 21 files and 0 defaults unchanged`.

Required producer mutations each require native exit **1** and a specific failure:
revocation: 6 / `GOOGLE_CONNECT_FAILED`; unpinned executable: 1 /
`GOOGLE_CONNECT_FAILED`; mailbox filtering: 7 / `MAC_ACCOUNTS_FAILED`.
The restored batch finishes `GOOGLE_OPTION_C_MUTATIONS_RESTORED_OK`, then
`GOOGLE_WITHDRAWAL_BATCH_OK`; final wrapper exit 0. All of those final checks and
mutations used one FIFO slot. V1 was a separate earlier slot before the added case.

Synthetic checks: `INJECTION_DESTINATION_ORIGINAL_RED_FIXED_OK`,
`GOOGLE_OAUTH_INJECTION_OK`, and
`GOOGLE_RED_HARNESS_OK: targeted assertion plus native exit1 required`.
Post-commit scans finish `COMMITS_SECRET_SCAN_OK` and `WIP_SECRET_SCAN_OK`;
their exact log is retained in the V2 report. They compare no
private values and are pattern scans, not a guarantee against every possible leak.

Source/tooling changes are listed in the V2 [changed-files report](Tests/Reports/google-option-c/2026-10-08-review-withdrawal/changed-files.txt).
Evidence directories and the bounded reference in PERFORMANCE-STANDARDS.md are
additional documentation changes. Source/plist/scoped commit whitespace checks pass.

## Bounds and conflicts

Real Keychain lock/prompt behavior, real Google consent/scopes/endpoints, actual
release-asset provenance and gws token precedence, private-client packaging and
visible UI remain unverified. Synthetic native execution cannot establish those.
The inherited nested production browser tool-loop gate remains
`TOOLLOOP_PRODUCTION_FAILED`, with 18 WRONG lines in both final fixed/restored
store-isolation stdout. The root isolation watches 21 files and 0 defaults, so it
does not prove installed preference isolation. No model/default/phase or broader
Agent readiness is promoted. Actual bundled assertion execution remains unverified;
only synthetic staged-bundle injection was exercised. In-process grant admission
is not cross-process Keychain CAS; cancellation cannot undo already-launched work.

Will conflict with uncommitted canonical work:
`Sources/NextNotes/Agent/GoogleWorkspaceCLI.swift`,
`Sources/NextNotes/Calendar/CalendarService.swift`, and
`Sources/NextNotes/Calendar/Google/GoogleTokenStore.swift`.
The canonical checkout, private OAuth JSON, owner stores, foreign processes,
foreign scratch and prior handoff files are untouched. Relay broadcasts do not
prove they were read. Own scratch/replay/cache cleanup and final scan results are
retained in the report; prior handoff files are preserved.

Cleanup verified: own `wt-scratch/google-c`, both own replay snapshot directories
and generated Python cache removed; no Google fixture temporary folders remain.
Only the three pre-existing untracked handoff files remain in git status. RESULT.md
is an intentionally ignored local handoff file under the existing shared exclude;
its verified verdicts are also in the committed V2 report. Relay finish sent to the
orchestrator and all project agents; sending is not reading confirmation.

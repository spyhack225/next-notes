# Google review repairs — final native candidate

All six producer findings have separate commits, with native failing assertions
retained before the fixed verdict. The reviewed head was `ddf30b7b`; the tested
fixed code is committed through `c32bcc99`. This final V2 batch ran in **one**
normal-gate FIFO `heavy.sh` slot on macOS 27.2 / arm64. Debug builds use `-j 2`
and the agent's isolated scratch. No app install, GUI, model load, private OAuth
JSON, owner-store seeding, push or merge occurred.

| Finding | Producer commit | Native RED failures | Fixed |
| --- | --- | ---: | --- |
| 1 unreadable grant / alternate login | `db8b8fac` | 39 | pass |
| 2 cancellation at executable admission | `d26a96c3` | 6 | pass |
| 3 stale refresh / replacement grant | `35a0414d` | 5 | pass |
| 4 stale concurrent 401 / shared refresh | `e2ea9f4d` | 5 | pass |
| 5 actual probing planner / scope gap | `10d6663f` | 2 | pass |
| 6 declined Calendar consumers | `1c72fe09` | 12 | pass |

The matched six-finding replay exits 1 / `GOOGLE_CONNECT_FAILED`: 70 failures
including the table and one legacy-route adoption assertion. It restores the bad
producer decisions while retaining new signatures and gates; it is **not** an
untouched historical binary. No native intermediate commit build is claimed.

The additional Calendar withdrawal RED retains the first repair except its
cache-clearing branch. It seeds actual CalendarService calendars and upcoming
events, successfully replaces the grant with Docs-only, then fails the exact
cache assertion: one failure / native exit 1 / `GOOGLE_CONNECT_FAILED`.
Fixed and restored pass all **318** Google assertions with zero failures, clearing
both caches without another token or Calendar request. No fixture was weakened.

Fixed and restored root native exits are zero for all seven required checks:
`GOOGLE_CONNECT_OK`; `GWS_FIXTURES_OK: 10 cases` and `GWS_OK` (isolated gws 0.22.5
fixture); `CALENDAR_OK: isolated Google error consumers behave`;
`MAC_ACCOUNTS_OK`; `CAPABILITY_MANIFEST_OK`; `UI_STRINGS_OK`;
`STORE_ISOLATION_OK: 21 files and 0 defaults unchanged`.
All three mutations exit 1 with required specific failures: revocation 6,
unpinned backing 1, mailbox filtering 7. Final markers are
`GOOGLE_CONNECT_FAILED`, `GOOGLE_CONNECT_FAILED`, `MAC_ACCOUNTS_FAILED`.
Then `GOOGLE_OPTION_C_MUTATIONS_RESTORED_OK` and
`GOOGLE_WITHDRAWAL_BATCH_OK` / wrapper exit 0. Native fixtures hash identically
through RED, fixed, mutations and restoration. Committed source equals tested pins.

Synthetic packaging checks emit `INJECTION_DESTINATION_ORIGINAL_RED_FIXED_OK`
and `GOOGLE_OAUTH_INJECTION_OK`. RED-harness negative controls emit
`GOOGLE_RED_HARNESS_OK: targeted assertion plus native exit1 required`.
The injector refuses unrelated paths and source hardlink/symlink redirection;
only synthetic client input was used. Unbundled native runs do not exercise
private-client app assembly. The bundle assertion is stronger, but its actual
bundled branch was not run.

`verdict.json` has exact markers/counts. Source and binary SHA files, raw build
logs, replay/mutation patches and `fixture-invariance.log` pin the runs.
`changed-files.txt` lists this round's source/tooling; `manual-conflicts.txt`
identifies three files requiring manual integration. The earlier V1 batch's
315-case evidence is retained [separately](../2026-10-08-review/README.md).

Reproduce only through the shared wrapper: first run `make webrtc-audio` in the
same guarded slot, then `sh Tests/GoogleWithdrawalChecks.sh <own-scratch> <evidence>`.
Use the same committed fixture-hash file in that evidence directory. The script
restores fixed source on exit and performs its mutations under the same claim.

## Limits and remaining contracts

Both fixed/restored store-isolation outputs retain inherited
`TOOLLOOP_PRODUCTION_FAILED` with **18** WRONG lines. This gate stays open.
The root isolation result watches 21 files and **0 defaults**, not installed
preference isolation. No broader Agent or model/default/phase promotion follows.

Native tests use process-specific real Keychain records, injected OSStatus values,
loopback/synthetic HTTP and actual isolated process/Calendar/planner consumers.
Real Keychain prompts/locking, Google consent/endpoints, real gws token precedence,
release publisher provenance, private-client packaging and native UI remain
unverified. In-process record admission is not cross-process Keychain CAS.
Cancellation after an already-admitted launch cannot undo an action.
Scope eligibility/public verification and conditional restricted-data assessment
remain separate decisions. No latency/performance acceptance is asserted.

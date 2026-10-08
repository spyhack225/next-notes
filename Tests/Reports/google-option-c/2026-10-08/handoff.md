# google-c — native validation complete

Branch `claude2/google-c`, base `c6d850c6`. Backend and fixtures are committed.
The same final native fixture reports original49 failures, draft4 failures and
repaired `GOOGLE_CONNECT_OK` with210 passing assertion lines and zero failures.
All seven requested final markers are OK after all three mutations were restored.
The inherited nested browser tool-loop gate remains failed; this work does not
promote that gate, a model/default, a phase or broader Agent readiness.

## Commits

- `713cbe8c` — built-bundle client injection, already completed in the prior turn.
- `7de63841` — coordinated prerequisite `20d8f9b`: missing task-history reader only.
- `00ae3b03` — nine consent permissions, typed grants, shared refresh and cancellation/revocation producers.
- `c86ecf40` — managed app execution, independent capability gaps and plain status provider.
- `3b20f943` — isolated native Google fixtures, dispatch, replay and mutation harnesses.
- Native evidence and this handoff are retained in this directory’s commit; the root RESULT.md records its final ID.

The full native candidate was tested together before these scoped commits. These
are not claims that each intermediate commit was separately rebuilt.

## Confirmed causes and changes

Base consent requested only calendar.readonly, stored no granted scopes and supplied
no per-capability manifest gaps. One `GoogleScopes.connect` list now drives the
existing PKCE/loopback consent request with gmail.modify, calendar, drive, documents,
spreadsheets, presentations, tasks, contacts and forms.body. The checked Keychain
write binds refresh token and granted scopes in one record. Missing scope response
means the requested set; an explicitly empty response means no permissions. Raw
legacy records remain calendar-only. Native loopback sign-in exercises those exact
save/read consumers, not only a helper.

Partial grants feed the existing manifest gap seam and the actual execution scope
check. Docs stays available with a Docs-only grant while Mail says it needs one
more permission. A selected app route remains selected after refresh errors or
revocation; it cannot switch to the person's separate installed gws login.
Calendar and Workspace share one cached/in-flight refresh per client/grant identity.
Only HTTP400 invalid_grant revokes. Two actual Calendar API401s retain the grant
and report rejection. No timer, model pass or sequential refresh gate was added.

Matched draft RED exposed two remaining producer failures:

1. The shared refresh task returned a token to a cancelled caller, which then entered
   actual executable backing. `GoogleAccessTokens.token` now checks the caller's
   cancellation after its existing shared-task await. Another caller still uses
   that completed shared refresh; cancellation does not destroy its token.
2. Deleting a raw legacy grant also deleted the last evidence that the app route was
   selected. The following call launched the alternate fixture login.
   `GoogleTokenStore.clear` now retains that choice before deletion. Explicit
   Disconnect still forgets it.

`producer-fixes.patch` isolates those two repairs. `GoogleConnectSelfTest` uses
real refresh requests, actual Keychain records and actual temporary executable
entry to verify both the producer and consumer, including the following call.

The managed app route accepts only its retained executable after archive checksum,
version-local binary witness and unchanged-file identity admission. Cached admission
rejects later changed bytes and symlinks. Execution reuses the existing spawn seam
and app-token environment. Synthetic alternate executables remain unstarted after
missing permissions, refresh failures, missing managed admission and revocation.

`GoogleConnection.State` and pure `derive` provide plain label/detail/button copy
for the later Settings card. The adjacent backend controller is prepared, but its
live UI/sign-in lifecycle is unverified. No Settings/onboarding/UI file was changed.
The base Mac identity/write repairs in77b8141 were preserved, not reimplemented.

## Exact native verdicts

Retained evidence: `Tests/Reports/google-option-c/2026-10-08/README.md`,
`verdict.json`, build/native logs, source patches, fixture hashes and binary hashes.
All Swift builds and native runs used `RELAY_ID=claude2-google-c ../heavy.sh`,
`-c debug -j2 --disable-automatic-resolution` and own scratch `wt-scratch/google-c`.
The final slot waited for the preceding release build, then ran GREEN, three
explicit mutation builds and the restored batch under one machine claim. The
wrapper exited0 with `GOOGLE_OPTION_C_MUTATIONS_RESTORED_OK`.

| Check | Actual final marker (native exit0) |
|---|---|
| --selftest-google-connect | `GOOGLE_CONNECT_OK` |
| --selftest-gws, isolated fixture root | `GWS_OK: gws 0.22.5 at /var/folders/ht/g5rsvv5x27124qp6wn2sg27w0000gn/T/google-c-gws.YUnMoy/gws, signed in`; also `GWS_FIXTURES_OK: 10 cases` |
| --selftest-calendar --calendar-google-errors | `CALENDAR_OK: isolated Google error consumers behave` |
| --selftest-mac-accounts | `MAC_ACCOUNTS_OK` |
| --selftest-capability-manifest | `CAPABILITY_MANIFEST_OK` |
| --selftest-ui-strings | `UI_STRINGS_OK` |
| --selftest-store-isolation | `STORE_ISOLATION_OK: 21 files and 0 defaults unchanged` |

Both initial GREEN and restored batches have those seven markers and exit0.
Store isolation additionally emits18 `TOOLLOOP_PRODUCTION_WRONG` lines and
`TOOLLOOP_PRODUCTION_FAILED` in each run. The unchanged base nests the production
browser fixture under a requested flag its executor does not admit; the coordinator
reported this inherited fixture-wiring cause. Those two files are byte-unchanged
from base. The isolation marker proves its21 observed files, not nested tool-loop
quality or installed preference coverage: this unbundled executable watches0 defaults.

The coordinated reader also reports `TASK_AUTHORITY_OK: 63 cases` in the original
final-fixture run. It fixes the inherited missing-function compile failure only;
no owner task store was migrated or seeded. The synthetic injection test reports
`INJECTION_ORIGINAL_RED` then `GOOGLE_OAUTH_INJECTION_OK`, including silent injection,
malformed input, absent input and unchanged source placeholders.

| Mutation | Actual native RED, then reverted |
|---|---|
| Any HTTP400 revokes | `GOOGLE_CONNECT_FAILED`,6 assertions, exit1: rejected client wrongly clears the grant, with dependent failures |
| Unpinned fallback | `GOOGLE_CONNECT_FAILED`,1 assertion, exit1: alternate executable receives the app token |
| Remove Google-only mailbox filter | `MAC_ACCOUNTS_FAILED`,7 assertions, exit1: other-account mail becomes reachable |

An expected RED observation makes the harness exit0; the native product exit1 is
retained and is not a product pass. Final source matched the captured fixed bytes
exactly after restoration. Final binary SHA256:
`d67b64026d066522c5190d0dc9ff1e82bba234041712259f73d3ecf2db960dcf`.
Final Google fixture SHA256:
`fe7448fb7165479040df798cb1352e31791bd8f126870edc9b83b83f84de23ee`.

The original is a matched producer replay, not an untouched main binary: new
fixture/type signatures remain, with the actual pre-change Calendar producer from
713cbe8c plus necessary admission/error seams. Original49 and draft4 RED use the
same final Google fixture bytes as GREEN. Earlier draft diagnostics had13 false
fixture failures from querying the manifest's allowed-only lookup for unavailable
tools. The final fixture queries combined readiness and also asserts exclusion
from the allowed lookup. The safety allowlist and readiness expectations were not
weakened; both final RED runs were repeated after this fixture correction.

## What remains unverified

No real release asset was fetched. These inherited v0.22.5 archive candidates remain
unverified as publisher/release facts:

| Architecture | Candidate bytes | Candidate SHA256 |
|---|---|---|
| ARM | 6119841 | `1d2a9ffd5bc9b2c2c4b48630daf082fad13d9e57d741988a2c248eed562f7dac` |
| Intel | 6384868 | `51f9bd731404d4bba26c36e2e30dd68c56dccd1f834c01252cb0b14d6a6544b2` |

Exact open checks: release provenance, actual archive hashes/sizes, extracted native
contents/version/signature/license and real GOOGLE_WORKSPACE_CLI_TOKEN precedence.
Synthetic checksum/version/environment tests cannot verify those actual assets.
The local binary/witness admission is sequential integrity, not cross-process CAS
or protection against replacement of both binary and witness.

Real consent, real unticked boxes/test-user admission, Google verification/CASA,
real Workspace APIs, native Mail/calendar grants/writes, packaged injection using
the private client and visible Settings interaction remain unverified. The private
JSON was never opened, printed, copied or committed. Only synthetic client data was
used. The later UI agent must wire the plain provider; publisher verification and
real Google acceptance remain separate work, not implied by these native markers.

## Changed files and integration conflicts

All source paths below are under `Sources/NextNotes/`:

- `Calendar/Google/GoogleAppClient.swift`, `GoogleAccessTokens.swift`, `GoogleTokenStore.swift`,
  `GoogleOAuthClient.swift`, `GoogleCalendarModels.swift`, `GoogleCalendarProvider.swift`,
  `ManagedWorkspaceTool.swift`, `GoogleConnection.swift`, `GoogleConnectSelfTest.swift`.
- `Calendar/CalendarService.swift`, `Agent/GoogleWorkspaceCLI.swift`,
  `Agent/Mac/MacWorkspace.swift`, `NextNotesApp.swift`.
- Shared prerequisite only: `Agent/Tasks/AgentTaskStore.swift`.

Other files: `Makefile`, `Resources/Info.plist`, `THIRD-PARTY-NOTICES.md`,
`Tests/GoogleOAuthInjectionTest.py`, `Tests/GoogleOptionCReplay.py`,
`Tests/GoogleOptionCChecks.sh`, `Tests/GoogleOptionCMutations.sh`, and the retained
`Tests/Reports/google-option-c/2026-10-08/` evidence files.
The narrow source/status, Calendar client-resolution, app-dispatch, source placeholder
and third-party notice edits are necessary callers/disclosures beyond the core list.
No Mac EventKit/Mail backing or approval identity producer was changed.

**Will conflict with uncommitted work** in MAIN-DIRTY-SOURCES.txt:
`Sources/NextNotes/Agent/GoogleWorkspaceCLI.swift`,
`Sources/NextNotes/Calendar/CalendarService.swift`,
`Sources/NextNotes/Calendar/Google/GoogleTokenStore.swift`,
`Sources/NextNotes/NextNotesApp.swift`.
Also `Sources/NextNotes/Agent/Tasks/AgentTaskStore.swift` is the coordinated,
byte-identical shared prerequisite; integrate it once, preserving the canonical edits.
No canonical file was written or built. No GUI, install, push or merge occurred.
No owner store was seeded or changed; required isolation guards retain their real
unchanged-file verdict. Sending relay findings does not prove they were read.

## Cleanup and final scans

Removed only own2059224KiB scratch after the guarded command completed and no matching
active process remained; this is not a global reclaimed-space claim. Own replay
snapshot and Python cache were removed. Test cleanup is scoped to its own temporary
folders. Other agents' files/caches/processes and LAST-MESSAGE-previous.txt were preserved.
Final resource snapshot:12GiB free, swap7708.19MiB, load5.03, memory free64%; concurrent
shared-machine observations, not a performance or continuous-trace claim.
The root RESULT.md records the final post-commit scan verdicts and evidence commit ID.

Secret scans: `COMMITS_SECRET_SCAN_OK` and `WIP_SECRET_SCAN_OK` for both prohibited credential patterns; final scan is repeated after the evidence commit. Source/document whitespace checks pass. Verbatim native/compiler logs and unified patch context retain their emitted trailing blanks.

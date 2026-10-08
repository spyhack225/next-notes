# Google Option C native evidence

Own worktree `claude2/google-c`, base `c6d850c6`; debug arm64 builds and native
processes run only through the shared `heavy.sh` with relay identity
`claude2-google-c`. Nothing was installed, pushed or merged. The fixture uses
process-specific Keychain records, isolated temporary executables and loopback
HTTP; it never reads the private desktop-client JSON or discovers the owner's gws.

## Matched RED

`original-final-fixture/` is the final-fixture RED: `GOOGLE_CONNECT_FAILED`,
49 failed assertions. It also reports `TASK_AUTHORITY_OK: 63 cases`.
`draft-final-fixture/` uses the same fixture and reports `GOOGLE_CONNECT_FAILED`,
four failed assertions. These identify two confirmed remaining producers:

- A caller cancelled during a shared refresh receives the token and enters actual
  executable backing. The token actor now checks that caller's cancellation after
  its existing shared-task await, while preserving the refresh for other callers.
- Revoking a raw legacy Keychain grant deletes the last evidence of the selected
  app route. The next call executes the alternate fixture login. Token deletion
  now retains that route before deleting the credential; explicit Disconnect is
  still the operation that forgets it.

The original is a **producer replay**, not an untouched main binary. New types and
fixture injection signatures remain so the identical fixture compiles. The old
Calendar provider is read directly from commit `713cbe8c`, with only admission and
error-type seams. Other old decisions restore calendar-only consent, raw grant
storage, no scope gaps, independent refreshes and the alternate CLI route.
`Tests/GoogleOptionCReplay.py` and `original-producers.patch` retain the recipe.
Binary hashes and guarded build logs are retained next to each run.

Earlier `original/`, `original-expanded/` and `draft-red/` are diagnostic history,
not the final matched comparison. The first draft fixture had 13 false failures:
it queried the manifest's allowed-only `entry(named:)` lookup for unavailable
tools. The final fixture instead queries allowed + unavailable readiness **and**
checks exclusion from the allowed lookup. No manifest safety predicate or expected
readiness was relaxed. Both final RED runs use this corrected fixture.

## GREEN and mutations

The initial `green/` and final `restored/` batches each exit 0 on all seven flags:
`GOOGLE_CONNECT_OK`, `GWS_OK` (also `GWS_FIXTURES_OK: 10 cases`),
`CALENDAR_OK: isolated Google error consumers behave`, `MAC_ACCOUNTS_OK`,
`CAPABILITY_MANIFEST_OK`, `UI_STRINGS_OK`, and
`STORE_ISOLATION_OK: 21 files and 0 defaults unchanged`.
The final Google fixture emits 210 passing assertion lines and zero failures.

| Changed producer | Actual native RED |
|---|---|
| Any HTTP 400 revokes | `GOOGLE_CONNECT_FAILED`, 6 failures, exit 1 |
| Unpinned alternate execution | `GOOGLE_CONNECT_FAILED`, 1 failure, exit 1 |
| Remove Google-only mailbox filter | `MAC_ACCOUNTS_FAILED`, 7 failures, exit 1 |

`verdict.json`, per-run native logs, mutation patches and binary hashes retain
the exact comparison. The whole guarded command exits 0 with
`GOOGLE_OPTION_C_MUTATIONS_RESTORED_OK`; an exact-byte comparison confirms the
fixed source was restored. Native exit 1 with the
expected FAILED marker is a successful observation of RED, not a product pass.
After the initial seven GREEN flags, the `green` checks mode captures fixed source
and invokes `Tests/GoogleOptionCMutations.sh` in the same guarded slot. That script
restores exact captured source on exit, exercises the three explicit native builds
and runs all seven required flags again in `restored` mode.

The unchanged `StoreIsolationSelfTest` nests a production tool-loop fixture with
an inherited browser-admission requested-flag mismatch. Any nested WRONG lines
must be reported separately from its file/default isolation marker; the isolation
marker alone does not establish broader tool-loop quality. Both GREEN batches
have 18 `TOOLLOOP_PRODUCTION_WRONG` lines and `TOOLLOOP_PRODUCTION_FAILED`.
The existing fixture and executor files are unchanged from the base. The
unbundled executable observes zero watched defaults; installed preference
coverage is not established.

## Limits

Managed v0.22.5 archive pins are inherited candidates. Publisher attribution,
archive sizes/hashes, actual native version/signature and real token-environment
precedence were not verified; no release asset was fetched. Synthetic archive
checks establish checksum, witness, changed-binary and symlink admission only.
The retained binary/witness check is sequential integrity, not cross-process CAS.

Real Google accounts/APIs, restricted-scope verification, packaging with the
private client, native consent/Keychain prompts and a Settings card remain
unverified. `GoogleConnection.State` and `derive` provide plain status copy for
the later UI agent; no Settings/onboarding/UI file was changed. No model/default,
aggregate gate, phase or broader Agent readiness is promoted by these checks.

The inherited compile prerequisite is shared commit `20d8f9b`, cherry-picked as
`7de63841`; it only supplies `AgentTaskStore.recoveredReadHistory`, byte-identical
to the coordinated canonical reader. No canonical file was written.

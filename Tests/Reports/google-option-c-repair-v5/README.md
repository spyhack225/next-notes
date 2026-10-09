# Google Calendar grant publication repair, round 4

Repair commit: `1438254644598f7f91d9b06525988a24652eef13`.

The single normal-gate FIFO59 batch finishes with native wrapper exit 0 and
`GOOGLE_GRANT_PUBLICATION_BATCH_OK`. Original `6e490cec` producer replay has 393
passing assertions and nine targeted failures (`GOOGLE_CONNECT_FAILED`, exit 1).
Fixed and restored each pass all 402 assertions (`GOOGLE_CONNECT_OK`, exit 0).
The seven existing held fixtures remain green in all three runs.

The earlier seven green fixtures released A's response only after Calendar's
transition callback finished. Their installer returned immediately and succeeded;
none admitted a Settings read while direct service sign-in was suspended, and
none revoked the grant through the refresh actor while an independent list was held.
The entry epoch therefore passed those fixtures while leaving the actual grant
producer's save/delete windows open.

The repair binds the existing list cache and each admitted read to the exact
`GoogleTokenStore.StoredGrant`: its record bytes include the unique save generation
and granted scopes. Publication compares that same record under the existing
`withMatchingGrant` admission lock. The per-read sequence still arbitrates newer
same-grant reads; connect/disconnect no longer increment it. Record save, clear and
conditional invalid-grant delete send a credential-free notification that discards
mismatched MainActor cache contents. The getter also refuses the old cache before
that notification's actor hop. Queued notifications compare the current record,
so they cannot erase an already accepted replacement snapshot.

The unchanged seven held cases remain. Five additional native service/provider
cases retain a populated A cache, then hold an independently admitted HTTP response:
installer delayed after B save; installer failing after B save; Calendar-to-Calendar
save during the installer; Settings admission during direct sign-in followed by
Docs-only B; and actual shared token actor `invalid_grant` conditional deletion.
Each checks zero extra completion backing/retry. The installer cases pin zero
Calendar callbacks at the grant transition. No-result assertions inspect both the
public list and its actual stored backing through a read-only SelfTest accessor.

The original replay uses the round-4 head `6e490cec` service and token store. Only a
read-only actual-cache accessor is scaffolded onto that old service for compilation;
no decision or transition changes. The fixtures, controller, provider, token actor
and other dependencies are identical across original/fixed runs. HTTP/browser/tool
boundaries are isolated substitutions. This is an original producer replay in the
current compiled app, rather than an untouched historical app binary.

No new store, model pass, retry, timer or await is added to a user path. The existing
NotificationCenter/record-lock/MainActor seams carry cache invalidation. The app's
microphone/model/speaker path is unchanged. Functional debug tests do not establish
latency, full duplex, real consent, visible UI, cross-process Keychain atomicity or
installation acceptance. No private OAuth JSON is opened. No install/push/merge is
performed. Both CalendarService.swift and GoogleTokenStore.swift will conflict with
canonical uncommitted work and need manual reconciliation.


## Verification

All seven requested root flags pass both fixed and restored, each exit 0:

| Flag | Exact marker |
| --- | --- |
| `--selftest-google-connect` | `GOOGLE_CONNECT_OK` (402 assertions) |
| `--selftest-gws` | `GWS_FIXTURES_OK: 10 cases`, `GWS_OK` (isolated executable) |
| `--selftest-calendar --calendar-google-errors` | `CALENDAR_OK: isolated Google error consumers behave` |
| `--selftest-mac-accounts` | `MAC_ACCOUNTS_OK` (157 assertions) |
| `--selftest-capability-manifest` | `CAPABILITY_MANIFEST_OK` |
| `--selftest-ui-strings` | `UI_STRINGS_OK` |
| `--selftest-store-isolation` | `STORE_ISOLATION_OK: 21 files and 0 defaults unchanged` |

Store isolation's nested final marker is `TOOLLOOP_PRODUCTION_FAILED`; both runs
retain the inherited 18 `TOOLLOOP_PRODUCTION_WRONG` browser A02 assertions. Root
isolation success does not certify broader Agent readiness.

The three mutations each have native exit 1 at their required behavior:
revocation seven failures / `GOOGLE_CONNECT_FAILED`; unpinned one failure /
`GOOGLE_CONNECT_FAILED`; mailbox seven failures / `MAC_ACCOUNTS_FAILED`.
`GOOGLE_OPTION_C_MUTATIONS_RESTORED_OK` reports the restored seven-flag batch.
All nine snapshot source files and the two publication producers match their
fixed bytes afterward. All 11 fixture hashes match across original/fixed/mutations/
restoration. `GOOGLE_RED_HARNESS_OK` rejects setup-only RED and omission of any of
nine independently named grant-transition failures, as well as the prior controls.

`COMMITS_SECRET_SCAN_OK`, `DIFF_SECRET_SCAN_OK` and `WIP_SECRET_SCAN_OK` report
zero recognized non-allowlisted numeric Google client IDs or `GOCSPX-` secrets.
The existing synthetic ID is the only allowlist. Pattern scans do not certify
unknown credential formats; they never open or compare private OAuth JSON.

See [verification.json](verification.json), [original provenance](original-provenance.json),
[producer patch](producer.patch), [wrapper output](wrapper.log), build/source/binary
hashes, full native traces and [fixture invariance](fixture-invariance.log). Native
runs use arm64 macOS 27.2, debug compilation and the per-process isolated Keychain
service. No performance or installation acceptance follows from these results.


Owned scratch/replay cleanup is complete, with no app binary holder or remaining
matching fixture temporary paths. [Cleanup manifest](cleanup.json) retains the
2,133,331,968-byte pre-removal unique-inode allocation total; it does not claim
global/APFS reclaimed bytes. Other agents' dependencies, scratch and processes
remain untouched. Compact original/fixed sources are retained as review evidence.

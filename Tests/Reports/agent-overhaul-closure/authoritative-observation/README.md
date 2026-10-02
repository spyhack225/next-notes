# P6-05d: last primary-check observation

Prepared off-source on 2026-10-02 after P6-05c; root resumed after the actual receipt-source repair904af46. Original installed app42 contains only nonpersisted type/Equatable/nil-getter scaffolding and the original-compatible fixture registration. Original primary logic remains unchanged. Installed original42 reproduces15 missing-feature assertions; prior430 functional assertions remain green. Installed fixed43 passes491 worker cases and all14 related serial flags with the byte-identical fixture. This is a missing-feature prerequisite, not a reproduced stale/recovery bug or phase completion.

The existing validity path probes the bound authority and runs `SELECT state,durability FROM task WHERE id=?` in an existing-only read. The implementation retains that already decoded row as a nonpersisted result. The Bool interfaces and atomic writer consume the same result; there is no added SQL query, full-history read, await, timer, save, registry or store. Native file-binding validation must finish before the returned result reaches Manager. The SQL row's metadata is discarded and `unavailable` returned if source/generation/file-binding validation fails. A readable mismatched or absent row is `mismatch`; an admitted row is `accepted` under the unchanged state/attempt/owner predicate. This adds no start-time predicate or receipt completeness guarantee. Nil authority/generation mismatch returns unavailable while preserving the old Bool result of false and existing post-body file checks. Other native/read/lock failures retain their throwing contract.

Manager attaches the last result to its existing RunningWorker value. The primary callback uses O(1) map lookups and captured binding/uncancelled-handle checks before/after the synchronous read, rather than additional scans through tasks. Its existing production debug seam reads the cached map field and consumes bounded attempt/outcome metadata. The public getter defensively checks current in-memory binding and does no SQL read. Queued replacements start with no cache, and cancellation/release use the existing lifecycle. Obsolete context callbacks cannot stamp a successor.

This is explicitly the **last** primary check. Backend entry precedes the first probe and therefore has no cache. At backing entry the last probe precedes the tool-start/receipt-link commit, so it can honestly contain earlier progress or no joined receipt IDs. The getter does not refresh it, certify current authority/health, pair journal calls, establish complete receipt coverage, prove process death/no effect, change task state or permit retry. Missing receipt links remain unknown. Strict authority generation equality is unchanged.

## Original-compatible proof: original42 RED15, fixed43 GREEN491

`TaskWorkerPrimaryObservationSelfTest.swift.txt` uses actual Manager/LocalBackend/Executor/runtime and an injected task/receipt store. It holds only after the real fired/tool-start admission, then resumes the same restricted original temporary Filesystem read. Its five modes are normal completion, actual mirror NSLock contention, isolated row-boundary damage without an authority bump, another real Manager's generation-changing restart hold, and the actual missing-path explicit input successor.

The retained real `context.isStillValid` is invoked during held backing before comparing its last cache to fresh SQL, with no intervening producer commit. Existing authority-open instrumentation requires the same two existing opens; repeated getter calls require zero opens. Rows, journal, authority generation, export, receipts and owner stores/defaults must remain unchanged by observation. Lock contention produces unavailable unknown metadata; readable damaged state produces mismatch; a new restart generation produces unavailable before the row read. An old input-context validity callback refuses before SQL and must not overwrite successor metadata. Cleanup always resumes/joins the hold. Damage/restart deliberately stop the restricted read while retaining held evidence; normal/contention/input execute it once and complete normally.

`original-scaffold-*` supplies only the nonpersisted result type, condition Equatable conformance and a nil Manager getter. Original primary logic remains unchanged. The unchanged feature fixture fails15 missing observations in original42 while preserving the original execution path. `proposed-*` contains the exact compiled final producer adaptation. Original installed failure and same-fixture fixed verification are archived; all14 related worker/recovery/durability/authority/restoration/receipt/isolation/permission/scheduling regressions pass.

Limits: exact SQL query count is source-reviewed; the fixture counts existing opens, not every prepared statement. Late native file-movement mutation after row decoding is not independently exercised by this prepared fixture; current existing(...) post-body validation remains required. No ACP/session/process/stale-window/journal-quality/receipt-source completeness claim follows. The sequential receipt-writer source-revalidation repair is independently committed904af46. Original42/fixed43 bounded acceptance is complete; no model quality/default or recovery/retry promotion follows.

`source-identities.json` records the reviewed live inputs. `historical-proposal-generator.py.txt` retains the initial off-source generator as a nonexecuting historical artifact. Registration API: `try await TaskWorkerPrimaryObservationSelfTest.originalCases(root: root, input: input, text: text, check: check)`.


Original42 marker: `TASK_WORKER_ATTEMPT_FAILED: 15 assertions`. These are missing
cache observations, not a reproduced crash/stale/retry bug. Actual control, lock
refusal, damaged-row refusal, held restart and explicit-input successor still run
through their original Bool/backend/effect path. Original42 binary SHA256:
`ab41299c5c009e076d8c35aec9387c5e66ec9237126e2aa46303302c64b0afb0`.
Fixture SHA256: `1ace728984b0fc7380a61ad1ffb76b49756ff4207f5d2fd25c788369fb19c53d`.

`historical-proposal-generator.py.txt` is the historical off-source generator; root's reviewed candidate
corrects its output to preserve nil-authority/generation Bool false and to read the
actual cached map field at the production diagnostic. Do not regenerate over pinned
original/candidate/installed evidence. No extra getter scan was added to the hot path.


## Installed final verification

Actual unchanged fixture passes `TASK_WORKER_ATTEMPT_OK: 491 cases` in app43: prior430
plus61 actual primary-observation assertions. Same existing primary Bool/admission
contracts and temporary read/control flows remain. Contention yields unavailable with
nil metadata; genuine isolated damaged row yields mismatch with its decoded state;
real fresh-Manager restart generation rejects before reading a row, yielding unavailable.
Old real input-context callbacks refuse before SQL and cannot overwrite the successor's
cache. Normal/contention/input effects complete exactly once; damage/restart retain held
history without the temporary read. Every held backing is resumed/joined for cleanup.

The retained actual validity callback performs the same two existing authority opens.
Repeated LAST getter calls perform zero opens. State/journal/generation/export/receipt/
owner stores and defaults are invariant across observation. Backend entry has no cache;
backing cache predates tool-start/progress/receipt-link commits, so it is not compared to
later SQL without an explicitly invoked actual validity check at the held checkpoint.

The actual production diagnostic reads the just-cached RunningWorker value; the hot
callback adds no getter task-history scan. Original state/attempt/owner SQL predicate,
file-binding post-checks and Bool false for absent authority/generation mismatch remain.
No new SQL query, save, store, registry, timer, await, state change or dispatch policy.

Fixed43 binary SHA256:
`779022912fc519ea2fb2f338a487fecf6f97aa2990001d9a10831467bab11b7a`.
Source/resource/build input hashes and installed binary are unchanged through final
verification. All14 related serial markers and exits are archived:

| Flag | Actual markers | Exit |
|---|---|---|
| `--selftest-task-durability` | TASK_DURABILITY_OK: 37 cases | 0 |
| `--selftest-task-recovery` | TASK_RECOVERY_OK: 56 cases | 0 |
| `--selftest-task-authority` | TASK_AUTHORITY_OK: 58 cases | 0 |
| `--selftest-task-restoration` | TASK_RESTORATION_OK: 82 cases | 0 |
| `--selftest-task-history-repair` | TASK_HISTORY_REPAIR_OK: 58 cases | 0 |
| `--selftest-receipt-persistence` | RECEIPT_RUNTIME_OK: 5 cases | 0 |
| `--selftest-tool-review` | TOOL_REVIEW_OK | 0 |
| `--selftest-toolloop-production` | TOOLLOOP_PRODUCTION_OK | 0 |
| `--selftest-routine-authority` | ROUTINE_AUTHORITY_OK | 0 |
| `--selftest-schedule` | GOALS_OK, SCHEDULE_OK | 0 |
| `--selftest-usage-log` | USAGE_LOG_OK: 26 cases | 0 |
| `--selftest-store-isolation` | STORE_ISOLATION_OK: 21 files and 32 defaults unchanged, TOOLLOOP_PRODUCTION_OK | 0 |
| `--selftest-toolloop-live-grader` | TOOLLOOP_LIVE_GRADER_OK | 0 |
| `--selftest-voice-scheduling` | VOICE_SCHEDULING_OK | 0 |

Tool-review/routine-authority/schedule/usage-log use their actual stdout markers with
no companion app logs. Source-reviewed query reuse and counted existing opens are the
claim; exact prepared-statement counts/native late-file-mutation sensitivity remain
unproven. Four complete stale observations, live process/backend session health,
full receipt/journal coverage, runtime windows/periodic beats, recovery/retry and IM-16
remain open. Historical app13 quickFAILED3/10 is unchanged and is not an app43 model
verdict. No current-authority, no-effect, session death or broader readiness claim.

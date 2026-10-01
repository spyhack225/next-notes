# P6-04a-2 authority migration — 2026-10-01

The bounded authority migration is built, installed and verified. All 13 targeted installed flags pass with exit zero; CORE is 15/18 and remains red. P6-04a remains in progress. No automatic retry, worker recovery/reattachment, approval card restoration, lease/receipt fencing, remote/voice adoption or IM-16 hosting is claimed.

## Producer changes

The existing AgentTaskStore now reconciles strict canonical legacy JSON into the existing SQLite ledger. Schema 2 adds only the singleton task_authority(database_id,generation) marker. A versioned prepared envelope in the retained JSON records the same identity/generation and device/inode before the SQL reconciliation/marker transaction. Ordinary prepared+unmarked startup refuses visibly; matching identity never authorizes automatic repair. The explicit repair seam is guarded for injected temporary self-tests only; a product repair action remains open.

Read-only authority probes never create/schema-upgrade/chmod/change journal mode. They use an existing-only WAL-visible handle, busy_timeout 0, tryLock, one read transaction, and actual opened-file HAS_MOVED plus path device/inode checks. Unsupported/corrupt/removed/replaced stores are retained and rejected. Import preflight validates current task scalars/payload/order, contiguous artifact ordinals, known schema and foreign keys; extra mirror IDs or conflicting artifact paths refuse without guessed merges/deletes. The import transaction upgrades schema and UPSERTs exact fields while retaining event/dependency rows, raw artifact metadata/order/duplicates and future projection columns; no import compaction occurs.

After marking, SQL commits the snapshot, events and next generation first. JSON export failure is visible as exportFailed while the SQL history remains accessible. SQL failure keeps the previous primary snapshot/export and is visible as sqlFailed. Already-loaded writers must match the current marker generation; a fresh save discovers authority before any write. The full-snapshot API replaces rather than merges current task rows. A readable retained tag can detect known rollback/replacement; absent/corrupt export provides no proof against an unknown stale marked backup. There is no cross-file atomicity or power-loss/fsync guarantee, and the tagged export requires the updated decoder rather than an older array-only binary.

The original producer ignored persistence failure in submit and worker-start, so a failed primary write could still queue/acknowledge/dispatch work. AgentTaskManager now admits those paths only after primary commit, rejects and removes a new uncommitted submission, and guards input/approval/compatibility queued transitions. Rejected starts clear one-shot in-memory tokens. A guarded temporary-store backend-boundary observer makes negative installed fixtures safe even if a guard regresses; the positive local:nil case executes the real existing backend with no tool/model/account call. Other external runtime owners retain their existing behavior; this is not remote/scheduled runtime adoption.

## Evidence before integration

- [Original actual-source red](2026-10-01-p6-04a-2/original-source-red.log): 3 assertions. SQL created_at TEXT became a plausible date; actual Manager.submit returned queued and retained a row after the real atomic JSON writer failed. The synchronous fixture never yielded into a backend.
- [Final standalone green](2026-10-01-p6-04a-2/standalone-final-green.log): TASK_AUTHORITY_OK: 49 cases, compiling the actual store/schema/manager/journal producers. Backend/UI collaborators trap if reached; this proves synchronous production producers, not app routing.
- Four separate actual binary process exits (status 73), followed by fresh process readers: exclusive create before preparation refuses an orphan; prepared+unmarked refuses; committed marker reads SQL; committed primary before export reads newer SQL. These are process-exit guarantees only.
- [Wrapper compilation](2026-10-01-p6-04a-2/standalone-wrapper-compile-green.log): the real async fixture source type-checks; wrapper execution is reserved for the installed app. Its earlier matrix printed 48 before adding read-only default/shared coverage; the final synchronous matrix has 49.
- Matrix includes v1 transactional upgrade and raw child/future-column equality, appended artifact suffix/duplicates, strict malformed SQL/task/artifact/FK/JSON refusal, prepared repair isolation, schema-zero/orphan WAL, retained tagged export with deleted marked DB, corrupt/unsupported DB retention, usable header with damaged export payload, known generation/identity conflict, fresh save without load, second-writer contention <=50ms and explicit convergence, coherent snapshot plus cold committed-WAL read, removed/moved/ABA actual-file identity, submission/callback primary rejection and default/shared harness no writes.

An initial ABA fixture stopped at the early path check before restoring its files; it was corrected to restore the original pathname immediately after SQLite opens the alternate backing, exercising the native actual-handle check. This was a fixture defect, not product evidence.

## Installed integration

Root-owned --selftest-task-authority calls runIncludingSubmission: passed 54 actual app cases (49 synchronous + accepted exportFailed real local:nil completion + worker-start approval rejection/token clearing + compatibility callback rejection + real OpenCode delegation rejection under trigger and writer contention). Negative cases intercept and throw at the backend boundary before registry/CLI resolution if a producer regression occurs. No unsafe original installed ACP red will run.

Root integrated related durability/recovery expectation-only updates, registered the flag, built/installed serially and verified authority/durability/recovery/tasks/permission/isolation checks. Existing large-history synchronous snapshot latency has not been measured; <=50ms contention uses bounded temporary fixtures, not a general history-size claim.

The copied-source admission and import-transaction mutations below both failed the corresponding actual-source fixtures. Repository production source stayed frozen throughout.

## Integration fixture corrections

The first actual app build passed in 404.94 s with 658 watched source hashes unchanged. The initial authority run stopped at one positive-case assertion: it compared the actual manager's fractional Date() with the deliberately whole-second ISO canonical store payload. Backend entry/status checks before that assertion passed. The fixture now requires exact full canonical payload equality, explicit identity/status/result/failure preservation and createdAt equal to the floored in-memory date; it records the measured createdAt delta. Production timestamp precision was not changed. Original installed failure remains retained by root.

The first related recovery run had one fixture error: its unreadable legacy export shared a directory with an already marked database, so the new valid SQL authority correctly won. Parent corrected only fixture isolation to a fresh private subfolder with the same directory-at-history-path blocker, retaining no-SQL-creation and original-directory preservation assertions. This is a fixture correction, not an unreadable-store product fix. Root rebuilt those two test files; final installed authority54/recovery56 revalidation passed.

The first installed durability run passed all 37 cases. Actual production contention measured about 1.7 ms warm and 5.5 ms cold, below the unchanged 50 ms fixture bound. This does not establish large-history latency.

Copied actual-source mutations compiled and failed honestly (no app/model/backend execution):

- [Primary admission guard omitted](2026-10-01-p6-04a-2/mutation-primary-admission-red.log): exit 1, one assertion at real Manager.submit under the same SQL reject trigger (accepted queued row).
- [Importer transaction removed](2026-10-01-p6-04a-2/mutation-import-atomicity-red.log): exit 1, one assertion at the real v1 migration trigger (failed import left upgraded schema version).

Repository production source remained frozen; all mutations used copies outside the application source tree.

The optional [native opened-file-binding result omission](2026-10-01-p6-04a-2/mutation-opened-file-binding-not-sensitive.log) returned GREEN49, not red. The current fixture's alternate backing is still rejected through another existing SQLite/path boundary, so it does not uniquely prove sensitivity to the explicit HAS_MOVED result-enforcement branch. No native-omission failure is claimed. The explicit native check remains in production; coherent-snapshot/ABA/relocation behavior passed, but branch-specific mutation sensitivity is an evidence limitation. The two required primary-admission and import-atomicity mutations remain red. [Exact copied mutation driver](2026-10-01-p6-04a-2/copied-mutation-driver-source.txt) is retained as a report artifact; it uses this workspace's absolute root and never edits production source.

## Final installed evidence

The final build passed in 141.91 s; installation passed with OPEN=0. Both builds
watched 658 source files with zero changes during compilation. Comparing the two
manifests changes only TaskAuthoritySelfTest.swift and TaskRecoverySelfTest.swift;
production was identical. No model/default promotion or GUI launch occurred.

[Serial installed summary](2026-10-01-p6-04a-2/installed-final-summary.json) records
exit zero and exactly one named OK marker for all 13 flags: task-authority54,
task-recovery56, task-durability37, tasks, tool-review, guided, agent-panes,
activity, realtime, toolloop-production, voice-session-reducer, voice-duplex-work
and store-isolation. Isolation preserved21files/23defaults. The authority positive
case ran the real local:nil backend and preserved the full canonical completion;
createdAt delta0.976802945 s measured the existing whole-second ISO contract.
The other actual submission cases rejected dispatch before backend/CLI entry.
Voice comparisons observed121/61events and zero divergences; this remains scripted
shadow evidence, with legacy controllers still owning behavior.

[CORE summary](2026-10-01-p6-04a-2/core-summary.log) is **15/18, exit1, no skips**:
dictation reports key-down capture0.839247 s and superseded-start microphone
continuity17402/~40000frames; wake remains17/24hits and3/32false at sensitivity0.6;
computer inspect cannot see its self-test OK button. Earlier CORE16/18 dictation
passes do not resolve this recurring failure. Dictation and app/site UI have
external owners; this task preserves their source. No phase exit is claimed.
CORE used an exact catalogue/classifier copy with per-launch restoration flags
before each self-test flag, avoiding optional-argument parsing ambiguity.

The registered INTEGRATION flag is --selftest-task-authority (300 s). Its isolated
store proves the production migration seam; owner-history startup migration,
large-history latency, power-loss durability, older-binary rollback, live repair
and native-branch-specific mutation sensitivity remain open. Parent P6-04a and
IM-16 are not complete: pending cards, real attempts/leases/receipts, retry,
remote/voice/scheduled adoption and the single task/delivery owners still need work.

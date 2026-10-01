# P6-02a canonical existing-manager task mirror — 2026-10-01

The existing `AgentTaskManager.persist` now saves its normal JSON history first,
then mirrors that same canonical snapshot to the planned `agent-tasks.sqlite`.
JSON remains the only manager read authority. This is storage integration, not
crash recovery; P6-02b's evidence metadata/producers and UI remain open.

## Source contract

`AgentTaskStore.save` encodes with the existing sorted/pretty ISO-8601 encoder,
decodes that exact payload once, and writes the JSON atomically before passing
the canonical rows to `TaskStore`. This preserves JSON's existing whole-second
date precision in both representations. Failed JSON encoding/writing suppresses
the mirror; failed SQLite mirroring leaves successful JSON accessible. The real
manager exposes `lastPersistenceResult` and emits a plain diagnostic for either
failure. No cross-file atomicity or automatic retry is claimed.

The mirror caller explicitly requests fail-fast persistence: `NSLock.try` and
SQLite busy timeout zero, including initial connection/schema/WAL setup. The
general store connection's 2,000 ms allowance is restored after a mirror attempt.
Contention reports a failed mirror immediately; the next explicit save can
converge. There is no queue, hidden backoff or new asynchronous snapshot owner.

The schema stores every existing task field directly, including tool arguments,
meeting/schedule IDs, ACP compatibility fields, nil versus empty strings, and the
task array's original order. Artifact ordinals preserve original order and
duplicate paths. Existing requested action content and execution/history data
remain intact; no new raw read-tool response/evidence body collection is added.
No whole-row shadow blob or alternate execution ledger is introduced.

Tasks UPSERT by identity rather than REPLACE. Existing event/dependency rows and
unchanged artifact ordinal/path metadata survive an update. Removal occurs only
when the current canonical JSON snapshot removes the task/link. Snapshot changes
use one SQLite transaction; failed writes roll back the entire SQLite snapshot.

Absent optional task durability remains nil. Explicit partial durability payloads
decode with conservative legacy defaults: never auto-resume, waiting on a person,
zero retry cap. These are compatibility defaults, not P6-06's later explicitly
chosen retry cap of three. Future projection columns start empty/zero/nil without
fabricated instructions or authority. Legacy artifact metadata is neutral and
does not claim producing-tool provenance.

SQLite uses WAL, NORMAL synchronous mode, a general busy timeout of 2,000 ms,
and read-back foreign keys. Known version-one operation columns, child columns,
indexes, primary keys and foreign-key shapes are checked on reopen. Unknown
versions, malformed known schemas and corrupt files reject without deletion or
rebuild. An inode change reopens the connection. Main database, WAL and SHM owner
paths are registered by root in `SelfTestStoreGuard` in this same integration.

## Actual-source fixture evidence

The tiny driver compiles full production `AgentTask`, `AgentTaskStore`,
`AgentTaskManager` (including Observation), `TaskDurability`, `TaskStoreSchema`,
`TaskStore`, `TaskStoreSelfTest` and the actual `SelfTestStoreGuard`. Backend/UI/
announcement collaborators trap if reached. Its AppIdentity owner directory is
a disposable sentinel; the installed app test uses the guard's real owner paths.
Exact temporary locations are validated before any fixture seeding.

```sh
python3 Tests/Reports/durable-tasks/run-task-durability-driver.py
python3 Tests/Reports/durable-tasks/run-task-durability-driver.py --drop-compatibility-directory
python3 Tests/Reports/durable-tasks/run-task-durability-driver.py --omit-sqlite-mirror
python3 Tests/Reports/durable-tasks/run-task-durability-driver.py --wait-for-mirror-lock
```

Actual results:

- Normal producer: `TASK_DURABILITY_OK: 18 cases`, exit 0.
- Actual row-mapper mutation (compatibility directory bound NULL):
  `TASK_DURABILITY_FAILED: 7 assertions`, exit 1.
- Actual persistence-call-site mutation (mirror call omitted):
  `TASK_DURABILITY_FAILED: 8 assertions`, exit 1.
- Actual fail-fast caller mutation (general busy allowance used on the live path):
  `TASK_DURABILITY_FAILED: 2 assertions`, exit 1; warm/cold contention stalls
  were 2.100 s and 2.098 s.

Mutations compile temporary copies only; production sources are unchanged. The
mapper mutation fails canonical full-row equality and second-connection
visibility. The call-site mutation fails those plus real-manager failure
reporting under contention; the later FK fixture also correctly rejects absent
rows. These are deliberate mutation failures, not fabricated product bugs.
The fail-fast mutation breaks only the actual caller's option and fails both
real-manager timing assertions, proving that the general SQLite busy policy
cannot silently re-enter the foreground save path.

The 18 cases retain P6-01's five existing restart checks and add canonical full-
field mapping, old Codable defaults, second-connection visibility, integrity/
PRAGMA read-back, warm and cold writer contention, journal/dependency retention,
transaction rollback, JSON-first failure, SQLite failure, unknown version,
corruption, malformed known schema, and inode replacement. Initial warm/cold
real-manager contention measured 0.714 ms and 2.636 ms against the 50 ms bound;
JSON remained available, SQLite remained unchanged, and the next explicit save
converged. A repeated normal run also passed all 18 cases with warm/cold times
6.097 ms and 2.678 ms. Raw outputs are in `2026-10-01-p6-02a/` beside this report.

## Integration status

P6-02a's bounded storage implementation is verified. Focused Swift 6 compilation,
owned-path diff checks, serial app build/install and registered durability/tasks/
isolation checks pass. Parent P6-02 remains open for P6-02b. No recovery, retry,
JSON-read switch, TaskBridge hosting or IM-16 unblock is implemented.

## Root installed checks

The combined serial build/install succeeded. Registered installed checks pass:
`TASK_DURABILITY_OK: 18 cases`, `TASKS_OK`, and `STORE_ISOLATION_OK: 21 files
and 23 defaults unchanged`. Real-manager warm/cold contention measured 1.650 ms
and 1.924 ms; both stay below the 50 ms bound. The intentional failure cases
report static persistence diagnostics, preserving JSON authority.

Raw first installed logs are in `2026-10-01-p6-02a/installed-*.txt`. The final
restored build repeats all three registered checks successfully (`final-*.txt`),
with real-manager contention at 1.029 ms warm and 1.358 ms cold.

Final core is 16/18, exit 2, with the same two red flags as P6-01: wake accuracy
(17/24 hits, 3/32 false accepts) and unresolved dictation capture/retry behavior.
Dictation diagnostics vary: six capture/no-audio/retry/injection/outcome-count
assertions fail in this run. The actual conversation correction, action, task,
activity and iMessage approval/loop/watch checks pass. No builds ran alongside
this final core run. Full outputs are retained in `core/`; neither known failure
is relabelled green, and no core or phase readiness is claimed.

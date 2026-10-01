# P6-03 actual-manager event journal — 2026-10-01

The existing manager now supplies explicit event drafts alongside each canonical
JSON snapshot. `TaskStore.replaceSnapshot` writes the snapshot and event rows in
one SQLite transaction. JSON remains read authority: successful JSON may be newer
than SQLite after mirror contention, journal failure or a crash. There is no
cross-file atomicity, replay queue, implicit retry or recovery claim.

## Producer integration

- Actual manager creation, running, input wait/response, permission wait/response,
  terminal status and newly appended artifact producers emit factual kinds.
  Same-status terminal callbacks emit no second terminal transition. Input events
  contain no entered text; artifact events contain an added-reference count only.
- Creation of an already running scheduled/voice record records the supplied
  worker-start fact. Creation of an already terminal history row does not fabricate
  a completion event. Initialization's existing in-memory running/queued failure
  mapping remains the P6-01 baseline and emits no pretend recovery event.
- `AgentTaskManager.execute` scopes an ephemeral TaskLocal callback to its actual
  manager/store while submitting to the backend. The local backend already passes
  the exact task ID. Executor hooks run inside authorized final `fire`, after final
  argument validation and before backing execution. A bounded `returned`/`threw`
  outcome follows the backing; no arguments, result summaries or private errors
  enter event detail. The early pre-broker fake emits no execution events.
- A supplied task ID must match the bound task ID. Nil/unbound and mismatching
  calls are not routed into this manager. Nested calls lacking explicit task IDs,
  scheduled tools executed outside this context and ACP tool observability remain
  outside this demonstrated coverage. Missing events never prove an effect did
  not fire or authorize safe recovery.
- Existing durability attempt metadata is captured at the execution boundary and
  the same token accompanies completion after an await. Missing metadata is zero,
  unbound. This is informational metadata, not a real attempt/lease or receipt
  fence. No stale-attempt policy is introduced.

Isolated harness managers suppress presentation/announcement effects while still
executing the real local backend and executor. Production behavior and the shared
manager's existing task self-test activity/audit expectations remain unchanged.
Waiting-response and duplicate-creation business behavior was not altered.

Future enum kinds without current producers (heartbeat, retry, recovery,
revision, dependency, stale-attempt and outcome resolution) remain open. The
heartbeat rows in the sequence fixture are synthetic storage inputs, not proof
of a heartbeat worker. Actual in-place PermissionGate requests while the manager
stays running require root's separately owned boundary integration; manager wait
events alone do not claim complete permission observability.

## Retention and boundary handling

One set-based SQL compaction removes event rows only for a currently terminal task
whose last recorded terminal event is older than 30 days. Creation date is not the
completion date. Receipt-linked rows, current nonterminal work, recent terminal
events and unknown terminal ages stay. Task/artifact/dependency rows and JSON
history remain intact. This compaction guarantee does not change existing
canonical snapshot task-removal/cascade semantics.

Journal readers reject unknown kinds, non-integer timestamps/attempts, negative
attempts, invalid sequence identities and invalid representable time rather than
coercing malformed data into a plausible epoch or unbound attempt. Rejection does
not delete or rebuild the database or its siblings.

## Actual-source evidence

The original producer was reproduced before implementation using unchanged
P6-02a manager/store source and the new focused regression:

```text
TASK_DURABILITY_FAILED: 3 assertions                   # exit 1
actual manager creation/start/completion did not journal exact transitions
failed journal append was invisible to real manager
state committed without its event after injected journal failure
```

The real SQLite trigger fails event insertion after the snapshot writes. The
fixed producer reports `mirrorFailed`, leaves successful JSON readable/newer,
and an independent second connection sees both the old snapshot and old journal.
This tests rollback between the actual writes rather than a duplicated mapping.

The standalone Swift 6 driver compiles complete actual Task/Store/Manager/journal
sources and the real guard. It passes **28 storage/manager cases**, preserving
P6-02a's original 18. The additional cases exercise actual scheduled transitions,
duplicate terminals, input and denied-permission producers, metadata privacy,
stored attempts, atomic rollback, receipt/age retention, monotonic sequence and
malformed journal scalar rejection. Its disposable owner sentinel is unchanged.
Backend/UI collaborators trap if called; it does not claim tool execution.

```sh
python3 Tests/Reports/durable-tasks/run-task-durability-driver.py
python3 Tests/Reports/durable-tasks/run-task-durability-driver.py --non-atomic-journal
python3 Tests/Reports/durable-tasks/run-task-durability-driver.py --wrong-retention-age
python3 Tests/Reports/durable-tasks/run-task-durability-driver.py --compile-tool-wrapper
```

The atomicity mutation moves the real append outside the SQLite transaction:
`TASK_DURABILITY_FAILED: 2 assertions`, exit 1. The original state-without-event
assertion fails, proving the regression observes the transaction boundary.
The retention mutation uses creation time instead of the actual terminal-event
time: `TASK_DURABILITY_FAILED: 2 assertions`, exit 1. It wrongly keeps a recently
created old terminal journal and removes a recently finished old task's journal.
Mutations compile temporary source copies only; production source stays frozen.

`--compile-tool-wrapper` additionally syntax-checks the asynchronous installed
wrapper using minimal trapping tool types; its main still runs only actual store/
manager cases. This is compile evidence, not a substitute for executing the real
executor. The installed wrapper's primary test uses actual injected
`submit → execute → LocalAgentBackend → AgentToolExecutor` and the existing final
backing override after real authorization/validation. It checks a second
connection's tool/terminal/artifact sequence, then refusal, backing failure, early
fake and mismatched/unbound attribution boundaries. Installed execution remains
pending root integration.

One tiny compiler invocation exited 120 immediately with no output while the Mac
had about 152 MiB free. It supplied no test verdict. Subsequent isolated runs
compiled and passed; no data/model or app-build work was launched by this worker.

Raw outputs are in `2026-10-01-p6-03/`. Owned `git diff --check` passes. Worker
Swift source is frozen; root owns the PermissionGate boundary extension, registered
app build/install and durability/activity/voice-routing/core checks. P6-02b,
durable read authority, recovery/retry, real attempt/receipt fencing and IM-16
hosting remain open. No task or phase gate is marked complete by this report.

## Root installed integration

The frozen worker source and root's narrow in-place PermissionGate journal hooks
were compiled into the signed installed application. The original committed
executor (no execution journal hooks) and original approval boundary fail the
registered regression with **13 assertions**, exit 1
(`installed/original-boundaries-red.txt`). The restored final executor and Gate
pass **37 cases** (`installed/final-task-durability.txt`): 28 actual-store/manager
cases, five tool-boundary groups and four actual approval decisions.

The tool proof submits through the actual isolated manager, LocalAgentBackend,
ActionOrchestrator and executor's authorized, validated final fire. Only the
external backing is a fixture. An independent connection sees the exact tool,
terminal and artifact-count sequence. The additional Gate cases use that same
manager's context factory explicitly, so they are separate boundary proof rather
than substitutes for submit/execute. They cover approve, deny, cancellation and
refused incomplete review: only approval fires once; incomplete review remains
parked; false/cancel records bounded `notApproved`, not a claim of human denial.
Attempt 3 is fixture metadata; new real tasks remain attempt 0/unbound. All
owner-store sentinels are unchanged.

On the same installed build, tasks, activity, voice turn routing/conversation,
concurrent voice, work lifecycle, duplex work, playback ledger, delivery,
scheduling, tool loop, production tool loop and tool review pass their existing
assertions. Isolation passes **21 files and 23 defaults unchanged**. The shadow
observer reports disagreements in broader voice fixtures; its task remains open.
Those disagreements are not suppressed or counted as reducer equivalence.

Final SQLite/lock contention measurements are in the raw installed run; they
prove prompt refusal under contention, not large-history throughput. Every
journal fact still synchronously serializes canonical JSON and mirrors its full
snapshot on MainActor. Large-history latency is unmeasured. There is no additional
await, retry, queue or permission ceremony, but no claim of latency improvement.

ACP callback and scheduled-run context bridges, nested nil/mismatching task
attribution, real attempts/leases/checkpoints/receipts, durable read authority,
retry and recovery remain open. Journal absence never establishes never-fired;
IM-16 stays blocked. Final CORE results are recorded separately below.

CORE on this installed snapshot is **16/18**, exit 1 (`core-summary.txt`): wake
remains 17/24 hits and 3/32 false at sensitivity 0.6; computer inspection sees
`no focused window` and cannot find its harness button. Dictation passes this
particular run; its earlier intermittent capture/retry failures remain unresolved.
No aggregate gate, model choice, default, phase exit or remote hosting claim is
promoted. The computer recheck is recorded separately, not substituted into the
original CORE verdict.

LaunchServices recheck also fails with the same no-focused-window result
(`installed/computer-via-open-recheck.txt`). No privacy grant or computer producer
was changed; the focus/activation cause still needs verification. The standalone
wrapper compile is green after root's Gate extension, executing only the 28
store/manager cases; its permission collaborator traps if called. It remains
compile evidence, never substituted for the installed approval cases.

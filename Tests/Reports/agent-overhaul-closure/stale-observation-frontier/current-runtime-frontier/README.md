# Next P6-05 frontier: current owned ACP process/transport observation

**Read-only planning evidence.** Root subsequently verified installed app83 worker1092/all20 invariant and committed P6-06p as416fd44. This audit supplies no new native verdict. This worker ran no compiler/native/model/build and changed no Source/roadmap/index or owner payload. This proposal is not stale detection, a bug repair, phase completion or retry authority. Source pins are preparation snapshots only.

## Rechecked parent contract

`07-PHASE-6-DURABLE-JOBS.md` §2.4: a running ACP worker can reattach only if its child is alive; a dead child permits retry only if no tool was in flight. A silent heartbeat is evidence, never health. Receipt/file effects require verification rather than blind retry.

The exact four questions are enumerated at P6-05 step2 (lines1235–1236): process alive, backend session alive, tool call in flight, receipt already created. Steps1/3/4 require event-driven beats, no window for waitingOnPerson, and logging only with no state change. Periodic observation remains ACP/scheduled-only and no Timer per task. No combined stale detector currently exists.

| Question | Actual current producer/evidence | What remains missing |
| --- | --- | --- |
| Process alive? | Manager binding records positive attempt/start/app-process leaseOwner. The exact owned child `Process` is private inside `JSONRPCStdioClient`. | No current child Process observation reaches Session or actual task diagnostic. App leaseOwner is not the ACP child PID. Task existence/cancellation state proves neither process health nor death. |
| Backend session alive? | Session records didInitialize/sessionID; current optional client exists. Stdio owns closed/output-EOF state and exact outgoing pending requests. ACPBackend.health checks configured installed CLI, not this Session. | No current instance transport view. Handshake bits are historical; current transport-open is not a responsiveness or remote-session-health proof. |
| Tool call in flight? | Existing bound handle has LAST receipt-bound entry/return/throw. Session.prompt has an outstanding RPC; nested incoming-handler Tasks are separately launched. | No complete current active-effect coverage. An outgoing pending count is not active tool count, and an outer ACP session entry is not every external operation. LAST returned/nil cannot establish no effect or no active work. |
| Receipt already created? | Exact startup receipt joins and task primary receiptIDs; actual runtime retains fired/terminal receipts. Receipt source quality records historical load and LAST writer comparison. | No complete current source-bound receipt observation for an arbitrary silent worker. Missing/capped/unreadable receipt evidence cannot prove absence; LAST source match can predate replacement. |

Current fresh primary admission can reject the exact old worker while its uncancelled handle remains in memory, as existing held fixtures prove. Its LAST cached result remains historical. New Gate entry/request/decision/post-Gate checks preserve authority but do not answer these liveness/effect questions.

Additional parent blocker: nested ACP approval can wait on a person while stored runtimeClass remains acpWorker. A future detector must observe the actual pending/queued Gate ownership and honor waitingOnPerson's no-window contract rather than declaring such a task stale from an old heartbeat. This is separate from the proposed child-process observation; existing `hasRestoredRequest` covers restored entries only.

## Smallest next assignment: P6-05i prerequisite, not parent stale completion

P6-05i is not present in current STATUS. Add a **read-only current view of the existing exact owned stdio Process/transport through its actual Session**. This is a missing feature prerequisite, not a confirmed product failure. Original evidence should be missing current observations under actual owned peers; keep that label distinct from existing EOF bug already repaired by P6-05f.

Producer scope:

1. `JSONRPCStdioClient`: a synchronous metadata snapshot getter under its existing state lock, reading the same retained `Process` instance. Return actual child processIdentifier, observed running/exited state, existing closed/EOF state and outgoing RPC pending count. No `kill(pid,0)`, PID from leaseOwner, executable lookup, cached inferred alive flag or LAST event replay. Read terminationStatus only after the owned Process says exited, if useful. Exclude command/arguments/cwd/stderr/stdout/content.
2. `ACPSession`: an actor-isolated current observation method delegating to its current client and describing established-ID/initialized state separately. If client is nil, return unavailable/absent **as unknown**, not dead/healthy. It may include exact captured task/attempt/owner metadata for attribution; no routing switch or execution authority follows.
3. Connect the actual same Session to the existing bound RunningWorker slot through the already-MainActor tool-start fire seam, as described below. A helper-only stdio test or exit-only Backend trace is insufficient. Do not add per-task caching, a second runtime registry or a persisted pid/session schema solely to obtain a passing fixture.

The observation is a sample, not a lease: Process may exit immediately afterward, and Foundation/OS state is not atomically linearized with every stdio operation. Describe transport as open/closed, not healthy/unhealthy. Incoming tool requests and external child effects remain unknown even if outgoing RPC pendingCount is zero. EOF may close the transport while the process is still alive; close's existing terminate call does not join or prove death.

Current `ACPBackend.runSession` owns its Session as a local value until cleanup; Manager's running slot has no Session reference/provider. An exit-only trace would not close that access gap. The smallest grounded per-worker bridge is available at an EXISTING MainActor boundary:

- `runSessionWithReceipt` is MainActor. Its actual `fire` closure calls `TaskEventJournal.toolStarted` synchronously before awaiting `self.runSession`. That same admitted journal context already identifies the exact existing RunningWorker and prepared receipt.
- Construct the SAME unique `ACPSession` at this fire seam (construction starts no Process), attach a weak ACPSession reference to that exact existing RunningWorker slot through an optional context callback, then pass this Session to the private `runSession` function instead of creating a second instance there. Preserve subscribe→start→prompt→unsubscribe→close ordering and all existing catch paths. There is no new foreground await or execution Task.
- The optional callback is nil for unbound/compatibility/local paths. Its producer accepts only the same captured positive task/attempt/owner/start and current in-memory binding. It writes no SQL, receipt, heartbeat or LAST observation and changes no dispatch/permission decision. A mismatched/late attachment stays unavailable; it must not replace a successor's reference.
- Manager's nonmutating diagnostic method captures the weak actual Session reference, awaits its current observation, then verifies both the same RunningWorker binding AND same Session instance are still present after the actor observation. A released/switched binding gives unavailable, not old-current facts. A primary held by another Manager can coexist with an old live process: report both separately rather than equating process presence with primary authority. Fresh primary probing is a distinct existing read, never a LAST cache promotion.

This requires root ownership of the five actual files: JSONRPCStdioClient, ACPSession, ACPAgentBackend, TaskEventJournal and AgentTaskManager, plus an isolated fixture. It is not a second store/registry or a general runtime architecture. A weak concrete Session field is smaller than a general async-provider abstraction. The scoped same-instance attachment is necessary because the producer otherwise leaves no live access path from the existing per-worker owner. It should be explicitly reviewed before implementation; this artifact applies none of it. The original/fixed common scaffold can move the same Session construction and add unused nil hooks BEFORE both runs so native original missing-observation predicates do not substitute a different execution path.

## Proposed actual original/control fixture

Use safe temporary owned peers and the real Session/transport. Extend the real Manager→Backend owned-peer fixture through the exact attached existing Session, not a separately started Client or helper Session. No owner task seed/decode and no external effect/model/provider process.

- **Live silent prompt:** real initialize/session/new and real consumed prompt marker, peer held at bounded fixture barrier. Snapshot reads the actual same child's PID/running state, transport open and actual outstanding prompt. Repeated reads must change no rows, journal, export, receipt or choices and acquire no compute lane. Silent prompt remains unclassified; do not stamp heartbeat to make it look healthy.
- **EOF while still alive:** the owned peer closes stdout but remains briefly alive under a bounded fixture release/termination policy. EOF can settle prompt and trigger real Backend cleanup before a Manager diagnostic read; do not insert a product pause/delay to force this transient view. Supplementary same-owned Client/Session producer controls may be needed. A released/missing worker view must be unavailable, not dead. Observe transport closed separately from actual process running. Existing EOF continuation settlement stays unchanged. A deliberate SIGTERM-ignoring peer, if used, needs guaranteed targeted cleanup and bounded escape; this fixture must not leave a live child or change product close behavior.
- **Actual child exit:** controlled peer exits; read the same owned Process as exited rather than inferring from EOF. No global PID lookup or process-name kill. A missing Session/client observation is unknown and fails any assertion claiming observed death.
- **Actual completion and close:** valid response/notification ordering, exact prompt cleanup and no duplicate reply; nil client stays unknown. Verify ordinary MCP/ACP/permission/worker regressions because the shared transport is reused.

Before fixed source, mount only a clearly unused optional/nil diagnostic scaffold if required for identical fixture compilation; original fails missing-observation feature predicates, existing functional controls must pass. Fixed getter uses the actual existing instance. Freeze fixture before both runs and retain exact source/bundle/process evidence. Do not turn a peer timeout or malformed reply into the original red.

## Defer until current inputs exist

Do not implement a stale verdict from age + LAST caches, automatic retry, session reattachment or job-state transitions. No timer, periodic beats, new TaskHeartbeat layer, model pass, tool firing, UI host or remote delivery belongs in this prerequisite. Complete in-flight/effect coverage and current receipt-source quality remain explicit unknowns. A later combined log-only diagnostic must read fresh current primary/runtime inputs, exclude actual human waiting, represent unavailable/conflicting facts and leave every task/receipt unchanged.

Parent P6-05/P6-06, process/session health, reconciliation/recovery/retry, remote/voice/scheduled authority, IM-16 and quick/full/owner/privacy/permission/latency gates remain open.

## Coordination and frozen planning handoff

Root selected this bounded five-file proposal and owns common scaffold/source/native. `agent_closure_audit` is preparing the independent actual fixture in the separate `current-runtime-observation-review` directory. The worker reported the EOF/cleanup race and weak concrete reference simplification directly to both root and auditor. No smaller safe direct route to the isolated owner exists: using Manager.shared or Backend singleton lookup would lose the captured owner; placing Session in the durable event draft would complicate Equatable/persistence for a transient observation.

This report owns only `current-runtime-frontier` planning files. It edits no earlier evidence or roadmap and supplies no new fixture/native claim. The concrete proof must include a live silent actual Manager consumer, current same Process read, same binding/reference recheck after await, held-primary/current-live distinction, unavailable releases, unchanged history/receipts/choices and explicit cleanup. EOF and child death must remain distinct, and child death must never imply cessation of all descendant/external effects.

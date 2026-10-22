# Implementation milestones

All product milestones are **TODO**. Each must name one file owner, recheck current
source and retain its own production-path evidence. Dependencies are contracts, not
an invitation to overwrite current P3/P6 work. [Status ledger](STATUS.md).

## DS-00 — Characterize current producers and freeze the contracts

**Depends on:** isolated store/manager construction and current parent ownership check.
**Seams:** `AgentSession`, `AgentSessionBoundary`, `AgentTaskStore`, `TaskStoreSchema`,
`TaskRecoveryPlanner`, current P3/P6 tests and `KnowledgeIndexer`.

- Inventory every use of conversation/capture/session IDs in typed, voice, background,
  ACP, scheduled, meeting and remote routes. Include audit, usage, grounding, memory,
  task delivery, pending cards and playback. Classify actual meaning and authority.
- Trace new-chat → review/index enqueue → persistence → restart. Establish exactly
  what survives, including indexing disabled, failed indexing and the 121st message.
- Reproduce old/fixed candidates with unchanged real-source cases: JSON payload mismatch,
  silent corrupt-history load, capped-history loss, selected-chat late completion,
  sub-second attempt round-trip and task snapshot replacement. Some are hypotheses;
  do not claim a failure until observed.
- Record current inherited repeated-read, receipt-cost, ACP timing, native-model and
  voice/Island failures from the parent ledgers. Run only the relevant current tests
  in a coordinated window; historical counts are not current acceptance.
- Inventory saved receipt content and task deletion/retention cascades. Freeze exact
  migration inputs and expected retained fields before schema work.

**Exit:** source pins/call graph, ownership map, failing or characterization cases,
measurement baseline and scoped original verdicts in `Tests/Reports/durable-agent-sessions/`.
No owner-store seeding and no production behavior change.

## DS-01 — Separate conversation identity from live audio and context

**Depends on:** DS-00. **Seams:** `AgentSession`, `VoiceContracts`, capture/coordinator,
`TaskBridge`, manager task origin/delivery, audit and usage producers.

- Define typed durable conversation/context identity and an explicit optional task
  conversation link. Reuse UUIDs and existing IDs; do not create a parallel ID namespace.
- Capture ownership at submission and worker construction. Replace selected-singleton
  lookups in result delivery with the captured owner through existing contexts.
- Keep old capture IDs as capture IDs. Preserve decoding of legacy voice/task origins;
  unknown conversation links remain unknown and cannot gain playback authority.
- Define idle as context/resource management within the same durable chat. Preserve
  permitted memory review and current live voice closing behavior.

**Exit:** typed and voice production routes attribute the same request/result correctly;
late callbacks, chat changes and stale generations cannot cross-route; zero extra audio
gate/model call. A static ID helper test alone does not pass this milestone.

## DS-02 — Extend the existing SQLite authority and import legacy history

**Depends on:** DS-00, DS-01 data contract; exclusive task-schema ownership.
**Seams:** `TaskStoreSchema`, `TaskStore`, `AgentTaskStore`, `SelfTestStoreGuard`.

- Add the minimum conversation/entry/submission/boundary representation from the design.
  Extend schema validation, known migrations, authority checks and all snapshot saves.
- Add append/update/page operations with ordered sequences and precise metadata
  round-trips. Keep existing guarded primary writes and prompt contention refusal.
- Strictly import retained JSON once. Retain IDs, sources, speech delivery, grounding,
  citations and known sessions. Handle empty legacy array/object explicitly; damaged
  or unknown inputs stay intact with a visible held migration.
- Commit import marker and imported rows together. Test interruption before/after each
  transactional boundary in separate processes, including existing task data.
- Make SQL authority explicit; JSON is witness/export only after admission. Update
  store-isolation coverage for every new content-bearing artifact and WAL/SHM path.

**Exit:** fresh readers see exact retained content; repeated import makes no duplicates;
failure cannot erase original bytes or dispatch work. Existing task saves/compaction
preserve conversation records, pending questions, receipts and authority markers.
No owner migration is run to pass this task.

## DS-03 — Replace synchronous transcript rewrites with bounded projections

**Depends on:** DS-02. **Seams:** `AgentSession` append/update/read paths, task persistence
execution seam, existing stall probes and usage spans.

- Keep the facade observable on MainActor; execute blocking SQLite/file work outside
  MainActor and audio callbacks through the existing persistence owner/executor seam.
  If that seam is currently synchronous, refactor it rather than adding a second store
  actor, connection pool or work ledger. Preserve commit-before-effect admission.
- Feed the UI with a bounded current tail and paged older rows. Fetch immutable context
  snapshots for model work; do not enumerate every archived conversation per turn.
- Replace full-history writes with scoped mutations. Co-commit facts at existing
  admission/terminal boundaries; never split one transition into several awaited saves.
- Specify bounded pending persistence behavior under pressure. Use existing stream/task
  backpressure; no unbounded FIFO of deltas, swallowed failure or false “saved” state.
- Trace SQL wait, commit, UI publication and audio overlap. Archive reads must not hold
  the persistence lock while rendering or running the model.

**Exit:** large-history real producer/consumer test shows bounded working set, no
full-archive rewrite and no audio-thread storage. Contention/disk-full refuses affected
admission promptly while capture/playback remain live. Paired latency evidence is
required before calling this a performance improvement.

## DS-04 — New, reopen and switch conversations without losing work

**Depends on:** DS-01 through DS-03. **Seams:** `AgentView`, existing agent panes/navigation,
`AgentSession`, `TaskBridge`, task delivery and `KnowledgeIndexer`.

- “New conversation” transactionally creates/selects a new chat; retains the previous
  transcript independent of indexing. Start with one selected conversation and existing
  UI components. Reopen through the current history/search/navigation seam.
- Switching captures a presentation generation, loads a bounded tail and leaves tasks
  with their original owner. Restore last valid selection; handle deleted selection
  without inventing a blank replacement for damaged history.
- A task finishing in another chat updates that chat and existing work indicators;
  never inserts its result into the newly selected chat or speaks it automatically.
- Index original committed rows with source IDs using existing indexing. History remains
  available with indexing off. Search retrieves originals by stable references.

**Exit:** physical new/reopen/switch flow and isolated restart flow preserve originals,
corrections, task links and scroll paging. Inaccessible UI is reported unverified;
helper-only output does not satisfy physical acceptance.

## DS-05 — Retention, forgetting and migration rollback

**Depends on:** DS-02 through DS-04; existing memory/knowledge forgetting contract.
**Seams:** existing delete controls, memory review/index queue, store guard, task/receipt
retention and application shutdown/install compatibility checks.

- Define archive versus deletion in plain language. No automatic new history expiry.
  Confirm consequential forgetting once with exact scope, including saved memories.
- Invalidate in-flight writes by conversation/deletion generation; remove transcript,
  summaries, exports and derived search/review content according to the disclosed scope.
- Preserve minimum unresolved-action evidence and an honest work status. Deleting a chat
  does not establish native/remote effect cessation; define active-work handling before
  exposing the destructive control. Do not keep hidden text in audit metadata.
- Exercise forward repair and downgrade/export compatibility without losing writes
  accepted after migration. Unknown schemas/data remain intact and held.

**Exit / Slice A:** retained-history experience, deletion non-resurrection and tested
rollback contract; old capped JSON writer retired from product authority. No binary or
owner-data cleanup until exact ownership/usefulness is checked.

## DS-06 — Durable request identity at every accepted input

**Depends on:** DS-02, DS-03, DS-01 routing. **Seams:** typed submit, voice final commit,
manager admission and existing remote/scheduled adapters only where their contracts exist.

- Generate stable request IDs before admission and carry them through the actual model,
  tool and result producers. Repeated delivery returns the existing accepted submission.
- Bind canonical payload identity and source/principal scope. Reject same-ID different
  content. Preserve deliberate repetition, voice correction and multiple independent
  requests even when their words match.
- Use the existing ledger transaction to accept input/task linkage. Failed commit
  produces no accepted acknowledgement, model/tool worker or external action.
- Implement typed first, then voice. Remote/scheduled work needs its own current-origin
  proof; an added ID does not make IM-16 hosting ready.

**Exit:** process exits before/after admission, duplicate transport delivery, partial-ASR
replacement, correction and intentional repetition exercise actual dispatch counters
and show exactly one admitted request for a retry, without suppressing new requests.

## DS-07 — Persist semantic execution checkpoints and delivery facts

**Depends on:** DS-06 and existing exact attempt/receipt admission contracts.
**Seams:** manager, local backend/tool loop, `TaskEventJournal`, `ActionRuntime`, voice
delivery/output owners; ACP only after its provider-specific checkpoint contract exists.

- Store a versioned phase and durable input/result references on the existing task.
  Preserve original objective and ordered corrections; never rebuild from chat prose.
- Cover accepted input, admitted model request, received tool result, pending person,
  final result and interrupted response. Persist at existing semantic transitions.
- Distinguish generated, persisted, displayed and acknowledged spoken text. Startup
  never upgrades an interrupted answer to completed or generated words to heard words.
- Preserve cross-file receipt ordering and reconcile gaps. Do not claim transactionality
  across SQLite, `action-receipts.json`, external providers and speaker output.

**Exit:** fresh readers show the exact last committed phase; crashes at every gap retain
honest uncertainty. No per-token/PCM writes, extra model pass or second tool lifecycle.

## DS-08 — Restore pending interactions and qualify continuation

**Depends on:** DS-07; current P6-04/P6-05/P6-06 and P3 authority contracts for each route.
**Seams:** current recovery planner, restoration handlers, permission gate, receipts,
local backend and actual tool-result consumers.

- Extend current narrow recovered-read continuation rather than adding a generic resume
  engine. Resolve inherited repeated-read/timestamp failures at their responsible producer.
- Restore exact pending questions and review cards once. Answers commit the next owned
  attempt once; stale card IDs/revisions/callbacks cannot consume permission or dispatch.
- Classify model-only interruption, verified prior read, unknown result/effect, missing
  backend and unsupported checkpoint. Unsafe/uncertain categories remain held.
- Reconcile existing mail/calendar/filesystem evidence through actual runtime verifiers.
  Preserve the exact operation key/payload when supported; never retry a write based on
  a missing completion row or a model's assertion that it probably did not run.

**Exit / Slice B:** original interruption scenarios pass through producer and real
consumer, including separate-process crashes. No new auto-recovery policy is enabled;
receipt/current-origin/liveness gaps remain explicit rather than masked by restored UI.

## DS-09 — Durable compaction with retained originals

**Depends on:** DS-03, DS-05, DS-07. **Seams:** `AgentSessionBoundary`, reader budgets,
existing model scheduler, memory review and history retrieval.

- Persist deterministic summaries with covered sequence range, digest and version.
  Resume the same committed boundary after restart; originals remain paged/searchable.
- Test factual continuity using long discussions containing corrections, untrusted tool
  output, interrupted speech, unresolved effects and pending questions near boundaries.
- Only trial model summaries if deterministic fidelity fails a defined user need. Compare
  identical inputs, coverage, cost, model passes and voice overlap. Reuse existing resource
  scheduling and stored provider choices; no separate summarizer runtime.
- Cancel stale summary work on new source/deletion generation. Commit at a whole-turn
  boundary; never overwrite a newer tail or turn a summary into an executable request.

**Exit:** exact original retention, prompt-fit and semantic continuity pass. Any extra
model strategy remains off until its quality and reference-workload gates pass.

## DS-10 — Explicit background ownership and multiple active conversations

**Depends on:** DS-04, DS-07, DS-08 and actual P3/P6 delivery/cancellation contracts.
**Seams:** manager's existing worker map, `TaskBridge`, output scheduler and dependencies.

- Make conversation/foreground/background affiliation explicit using existing task
  fields. New/switch/idle/Done must not implicitly stop background objectives.
- First support one selected foreground conversation with independent background work.
  Permit multiple foreground model runs only if existing scheduler/native runtime truly
  supports them and measured ASR/voice capacity permits. No global audio serialization.
- Define Stop-task versus Stop-speaking and route precise cancellation through existing
  owners. Joined children follow qualified P6-10 behavior; do not invent a second tree.
- Child conversations are deferred until a real task needs one. No general forking or
  extension/hook framework is part of this slice.

**Exit:** two-chat concurrent completion/correction/cancellation tests preserve each
owner and shared audio arbitration; native/remote entered work has truthful stop evidence.

## DS-11 — Enable only qualified automatic recovery

**Depends on:** DS-08 through DS-10 plus backend-specific effect/liveness contracts.
**Seams:** existing planner, tool manifest/backend capabilities, runtime and scheduler.

- Add explicit replay eligibility through the existing tool/backend descriptors. Unknown
  defaults to held. Start with bounded model-only or qualified native read cases.
- Require valid checkpoint/source versions, exact revision/current ownership, supported
  contracts and existing retry budget. Prevent concurrent successor admission.
- Keep side effects, unsupported ACP, remote/scheduled origins and provider ambiguity
  held until each has evidence; no blanket “all read tools are safe” rule.
- Recovered model output may continue in its chat without automatically opening the
  microphone or speaking historical results. Preserve current user/provider choices.

**Exit / Slice C:** actual crash/relaunch and negative recovery matrix passes for each
enabled category. Do not enable a category by changing an enum default or a UI label.

## DS-12 — Qualify the reference workload and finish the lifecycle

**Depends on:** accepted release scope and [03-ACCEPTANCE.md](03-ACCEPTANCE.md).

- Run serial optimized native acceptance in a coordinated owner-machine window. Pin
  source/build/model/settings and retain inherited failures and unavailable checks.
- Exercise all four persona flows, long archive paging, crash recovery, data deletion,
  live barge-in, recording and background task completion together.
- Preserve ≥20 tok/s decode floor, 25–30 target and existing voice/receipt/stall budgets;
  measure whole-machine memory/swap/disk and live audio coverage. No invented threshold
  substitutes for the parent performance contracts.
- Integrate only reviewed owned changes and relevant tests/reports. Retire only owned
  obsolete code, binaries, fixtures and worktrees after unique work is integrated or
  explicitly retained. Record reclaimed bytes and necessary rollback/reproduction pins.

**Exit / Slice D:** scoped native/physical/semantic acceptance recorded; rollout and
recovery drills completed; parent/IM-16/model gates updated only with their own evidence.

## Dependency order and collision rules

`DS-00 → DS-01 → DS-02 → DS-03 → DS-04 → DS-05` delivers Slice A.
`DS-06 → DS-07 → DS-08` follows DS-03 and delivers Slice B.
`DS-09` follows DS-05/07; `DS-10` follows DS-08; `DS-11` follows DS-09/10.
`DS-12` qualifies the explicitly selected slices. No calendar dates are promised before
DS-00 resolves actual dependencies and native-machine availability.

One owner at a time for `RealtimeAgent.swift`, manager/store/schema, capture/coordinator,
`NextNotesApp.swift`, acceptance registration and shared settings. Disjoint fixture/docs
work can be prepared independently; no subagent work is required by this roadmap. Check
agent-relay and [BUILD-ORDER](../../BUILD-ORDER.md) immediately before claiming/editing.

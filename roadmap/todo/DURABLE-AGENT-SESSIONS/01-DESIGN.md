# Design contracts

Proposed design, not implemented. [Roadmap](00-README.md) · [milestones](02-IMPLEMENTATION.md)
· [verification](03-ACCEPTANCE.md).

## 1. Keep identities distinct

| Identity | Lifetime and responsibility | Restart behavior |
|---|---|---|
| Conversation UUID | Durable transcript and links to work; explicitly new chat creates one | Restore; selection is presentation only |
| Context epoch | A bounded prompt history and frozen memory snapshot within a conversation | Restore committed boundary/summary; refresh live model resources separately |
| Capture UUID | One microphone activation, owned by `AgentCaptureController` | Never reopen from saved metadata |
| Turn/request ID | One accepted input, stable through delivery retries and partial-ASR revisions | Deduplicate the same submission; new deliberate request gets a new ID |
| Task ID + revision | Existing objective, corrections, questions and results | Existing manager/store are authority |
| Attempt + process binding | One admitted worker execution | Never infer liveness from PID presence/absence alone or reuse a stale binding |
| Receipt ID / prepared action ID | Existing action intent, execution evidence and verification | Reconcile through `ActionRuntime`; transcript is not effect proof |
| Output token / delivery receipt | Existing playback ownership and acknowledged clauses | Saved heard-text evidence is history; never resume speaker output automatically |

`AgentSession.sessionID` currently combines some of these meanings. DS-01 must classify
every consumer before changing semantics. Keep its compatibility accessor temporarily
only where it has one documented meaning; do not mass-rename UUID fields or reinterpret
old `TaskOrigin.voice(sessionID:turn:)` rows as durable conversation references.

## 2. Existing owners and permitted changes

`AgentSession` remains the observable selected-conversation facade. Its message array
becomes a bounded projection fetched from durable history, not the archival authority.
The facade captures conversation/epoch/generation before asynchronous work begins.
The real manager/backend keeps task execution ownership; the facade does not gain a
worker queue. Add small typed store operations to `TaskStore` and its schema/authority
seams rather than a parallel persistence service.

`TaskBridge` continues routing work and questions. `AgentTaskManager` owns admission,
attempt changes and cancellation. `ActionRuntime` owns permissions, effect boundaries
and receipts. `OutputScheduler`, playback delivery, the voice reducer/coordinator and
capture controller retain audio ownership. `KnowledgeIndexer` is derived search;
`MemoryReviewScheduler` handles permitted memory review. `usage.jsonl` remains the only
usage source. A persistent conversation link is attribution, not a remote-origin grant.

## 3. Minimal data extension in `agent-tasks.sqlite`

These are logical records, not final DDL. DS-01 audits existing fields before adding
any column/table, and DS-02 implements one versioned schema migration. Do not reserve
another schema version until the live task-store owner agrees.

| Record | Minimum facts | Constraints |
|---|---|---|
| Conversation | UUID, created/updated time, user title if any, archive state, deletion generation, active context epoch | Stable UUID; no transcript in title/log metadata; selected ID is a disposable UI preference |
| Entry | Existing message UUID, conversation UUID, per-conversation sequence, role/source/text, existing grounding/citation/remembered-fact/speech-delivery fields, typed lifecycle and version | Unique ID and `(conversation, sequence)`; preserve unknown compatible fields; distinguish interrupted generated content from completed/heard output |
| Submission | Stable request ID, conversation UUID, input entry ID, source, exact canonical payload fingerprint, admission state, task link when relevant | Unique `(conversation, requestID)`; mismatched payload is rejected, never treated as a retry; avoid duplicating text already owned by entry/task |
| Execution checkpoint | Existing task/attempt/revision binding, request ID, version, phase, references to consumed entry/result/receipt IDs and pending interaction | Stored with the task in the same primary transaction; no copied task journal or complete prompt ledger |
| Context boundary | Conversation/epoch, covered start/end sequence, source digest, strategy/version, summary entry ID, retained tail start | Summary commits only against exactly covered source rows and valid generation |
| Task conversation link | Existing task ID, conversation ID, originating input/turn when known | Use one nullable canonical task field/relation; legacy unknown remains unknown, never attach it to selected chat |

Do not introduce per-token events, a second effect journal, a generic document store,
or saved tool-output copies where the original result/receipt already exists. Tool
results that truly have no durable owner need one bounded, privacy-reviewed representation
at the current result producer, with explicit truncation and provenance.

Atomic SQL units are: accepted input + submission identity + task reference/admission
when created together; checkpoint + matching task transition + existing journal drafts;
and summary + context boundary. Preserve primary-commit-before-dispatch ordering.
An observed result in another file is a reference, not part of these atomic units.

Use the existing authority marker, file-binding checks, fail-fast contention and strict
schema validation. Audit all replace/delete/reinsert snapshot operations. They must
preserve conversations, entries, submissions and links to retained task history. Task
compaction must not cascade-delete archived conversation facts. Index actual paged
queries and use keyset pagination; do not load the entire archive to select one chat.

Persist ordering with sequences, not timestamps. Keep precise date round-trips for
existing attempt-start equality, and test sub-second values through SQL and JSON
metadata. Wall-clock changes must not reorder or duplicate accepted input.

## 4. Submission and streaming protocol

1. Generate/reuse the request ID at the accepted-input producer. ASR hypotheses are
   provisional; only the committed utterance is a submission. A transport retry reuses
   the ID; saying “do it again” intentionally creates a new one.
2. Project provisional text immediately using existing UI/voice seams. Commit accepted
   input and identity through the responsible store operation. A durable acknowledgement
   and consequential dispatch require successful admission. Failure says the request
   could not be saved; no phantom task acknowledgement.
3. If the same request exists, return its existing work/result/question without a second
   model/tool dispatch. If its canonical payload differs, report a conflict. Deduplication
   includes source/principal scope for any later remote adapter.
4. Run model/audio streaming through existing owners. Render first deltas and play admitted
   clauses without awaiting a transcript rewrite. Persist semantic milestones using the
   existing delivery/turn lifecycle; no write/await per token or audio buffer.
5. Settle final/interrupted entry state against the captured conversation, task revision
   and generation. Only actual output acknowledgements update heard-text evidence.

Provisional visibility is not durable acceptance. A process may lose uncommitted deltas;
recover the last saved partial marked interrupted, or show no partial if none was saved.
Never invent a complete clause or a completed answer. Any added partial checkpoint cadence
must reuse a semantic stream boundary and prove bounded overhead; no fixed debounce in
the turn path. Speculative work retains existing cancellation/effect barriers and cannot
gain authority because its text happens to be visible.

## 5. Recovery policy

First classify persisted work using current primary task history, versioned checkpoint,
worker evidence and receipts. Do not derive execution decisions from the transcript.

| Observed state | Allowed behavior |
|---|---|
| Verified terminal result | Restore exact result and links; no rerun |
| Pending input or approval | Restore exact versioned card and payload; no execution token restored |
| Interrupted model-only response | Offer/perform continuation only under qualified policy; keep old partial visibly interrupted and bind replacement to same submission |
| Native read with complete qualified prior evidence | Reuse the existing narrow continuation path; execute only unfinished work after new-attempt admission |
| Replay-safe read without that evidence | Remain held until the backend/tool-specific contract and process-boundary proof exist |
| Known external effect with unresolved outcome | Verify through existing receipt/resource evidence; no automatic resend, rewrite or insert |
| Unsupported checkpoint, corrupt history, uncertain worker ownership | Preserve evidence and hold; no generic replay fallback |
| Missing account, model, permission or drive | Plain current-state explanation and existing setup/reconnect action; no settings reset or silent cloud substitution |

“Read” alone is not replay permission: a read can consume external state, cost money,
observe changed files or have undocumented side effects. Put replay eligibility in the
existing tool/backend contract, defaulting unknown to held. Bind a resume decision to
exact task revision, source versions, model/tool contract and effect evidence. A changed
file/result is new evidence, not a reason to reuse the prior successful answer silently.

Submissions can be deduplicated transactionally. External effects cannot be made atomic
with local SQLite by this plan. At the existing runtime boundary retain prepared intent,
the original provider operation key when supported, and receipt facts. After the gap
between remote effect and local completion, reconcile. A provider key does not replace
expiry/scope checks or proof of a matching payload and result.

## 6. Permissions and cancellation

A restored approval card retains the reviewed arguments, origin, task revision, pending
request ID and allowed choices. Revisions invalidate mismatched approvals. Current
authorization is revalidated at the real effect boundary. Do not import the reference
article's persisted approval memo as a live permission capability. Restore outstanding
questions once; accepting an answer commits the successor attempt once before backend
entry, through the existing continuation seam.

| User action | Meaning |
|---|---|
| Stop speaking output / barge in | Existing playback/turn behavior; does not silently cancel background objectives |
| Done with voice | Release capture/model-session/output resources through existing owners; durable conversation remains |
| Switch or create chat | Change presentation/context owner; background work retains its conversation |
| Stop this task | Commit cancellation intent through manager; invalidate later admissions/callbacks; report unresolved entered effects honestly |
| Archive chat | Hide from active list; retain history/work and provide ongoing-work visibility |
| Delete chat | Existing destructive approval boundary; invalidate conversation generation and define remaining work/receipt treatment before committing deletion |

Stopping a Swift task is not proof a native process or remote effect stopped. Preserve
current attempt fencing, process/session evidence and terminal receipt rules. No tree
scheduler is added. Existing `parentTaskID`/dependency semantics may represent child
work only after P6-10 contracts pass. Background ownership must remain explicit when a
turn ends; never cancel everything because a UI row disappeared.

## 7. Long history, memory and compaction

Archive every committed original entry; maintain only the selected tail and bounded
active task projections in RAM. Preserve current reader budgets initially. A long
archive must not cause whole-history JSON encoding, sorting or rendering per turn.

Keep deterministic compaction first. Persist its source range/digest and summary version
so restart restores the same committed context. A later model-generated summary is
optional only if measured factual continuity improves within resource/latency budgets.
Prepare off the interaction path using existing model scheduling; do not add a model
pass simply to reproduce Pi's architecture. Capture continues while summary work is
cancelled/yielded. Commit only at a whole-turn boundary against unchanged source/generation.

Summaries preserve source attribution, outstanding questions, decisions, corrections,
uncertain effects and omitted-coverage markers. Tool output stays untrusted. Summaries
are reference, never queued instructions or evidence of delivered speech. If no safe
summary fits, disclose context limits and retrieve bounded originals; never silently
lose an active request or add an automatic provider retry.

Idle may refresh the memory snapshot and release model resources without archiving the
chat or changing durable identity. Preserve review settings and ten-user-turn review
semantics, with committed watermarks to prevent duplicate harvesting after restart.
Deletion invalidates queued/in-flight summaries and review/index writes so they cannot
resurrect forgotten text. Already saved explicit memories follow the existing disclosed
forgetting controls; deleting one chat must state whether those memories are included.

## 8. Migration, deletion and rollback

Strictly validate the retained JSON before import; preserve original bytes and report
damaged/unknown formats. Recognize the intentionally empty legacy payload explicitly.
Import retained message IDs, sources, speech delivery and session groupings in one
transaction with an import digest/version marker. Reopening the same input is idempotent.
Do not claim to recover rows already evicted by the 120-message cap or new-chat clearing.
Search excerpts are not lossless originals and cannot recreate them.

SQL becomes the sole new conversation authority only after successful migration and a
fresh-reader check. Legacy JSON becomes a retained witness/export, never a second writer.
No automatic owner-store migration during tests. Preserve marked task-store identity;
missing or conflicting authority fails visibly without recreating an empty database.

Deletion uses conversation identity/generation to invalidate callbacks and existing
derived index/review work. Keep minimum existing effect/receipt evidence needed for
unresolved operations without preserving transcript text as a hidden backup. Define and
test all content-bearing copies, WAL/SHM, exports, backups and search chunks. Logical
deletion is not a forensic-erasure guarantee; do not promise secure erasure from SQLite
WAL/free pages or external backups. No automatic broad VACUUM on the voice path.

Rollback must retain new writes: prefer a compatible forward repair. Do not launch an
older JSON-only binary against migrated owner data. If a downgrade is necessary, stop
owned work cleanly, export a version the target actually reads, verify fresh-reader
parity and retain the authoritative database; otherwise refuse the downgrade visibly.

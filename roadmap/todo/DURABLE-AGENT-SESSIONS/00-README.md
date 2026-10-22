# Durable agent conversations through the existing Swift and SQLite seams

Owner-requested roadmap, 22 October 2026. **Planning complete; implementation not started.**
This is an extension of AGENT-OVERHAUL Phases 3 and 6, not a replacement harness.
The implementation ledger is [STATUS.md](STATUS.md).

## Outcome

A person can leave a conversation, return after a restart, and find the original words,
unfinished work, questions and verified results together. They can start another chat
without losing the first. The app explains interrupted work accurately, resumes only
qualified work, and never repeats an uncertain external action just because it crashed.
The microphone keeps listening while the model works and the speaker plays.

Four representative flows define the experience:

| Person | Flow | Required result |
|---|---|---|
| Parent | Ask about a school event, leave, then return tomorrow | Find the chat and its sources; no unsolicited replay of yesterday's voice output |
| Office manager | Research suppliers while answering a different question | Results stay with the originating conversation; changing chats does not stop background research |
| Legal-practice operations manager | Approve sending a message, then lose the app during delivery | Show verified delivery or an unresolved outcome; never send a second message on speculation |
| Filmmaker/editor | Sort footage by shoot/session/drive, then reconnect the drive after a restart | Keep the exact request, corrections and file references; unavailable drives are reported without guessing or repeating file mutations |

## What we borrow

[Pi Durable, Earendil, 1 October 2026](https://earendil.com/posts/pi-durable/) is the design
reference. Useful ideas are persistent conversations with bounded active state,
checkpointed execution, stable submission IDs, explicit replay eligibility, ownership
of foreground/background work, retained originals during compaction, and atomic local
state transitions. The article describes an experimental JavaScript harness. It is not
evidence of Swift integration, our performance, or external exactly-once effects.

The design and milestones below are our proposed contracts. We will retain Swift,
the existing task ledger, permission/runtime ownership and native audio path. No Pi
package, JavaScript worker, general workflow framework, second event bus, second tool
manifest, second usage log or new scheduling service is required.

## Current source baseline

Read-only inspection on 22 October at HEAD `6cf744cc` **with pre-existing working-tree
changes**. This is a source assessment, not a pinned native build or new test verdict.
Recheck call sites and hash the scoped files before implementation.

| Existing seam | What is present | Gap / consequence |
|---|---|---|
| `AgentSession` in `Agent/RealtimeAgent.swift` | Shared observable history; per-row session UUID; atomic JSON saves; source and speech-delivery metadata | One active singleton; at most 120 retained rows; save encodes the entire retained array synchronously on MainActor |
| `AgentSessionBoundary` and `AgentHistoryBudget` | Default 30-minute idle boundary; whole-turn deterministic compaction above 24,000 characters; reader-specific history budgets | Idle UUID also means conversation/memory boundary; summaries are bounded reminders, not faithful archival transcripts |
| `startNewConversation` / `forgetAllConversations` | Distinct callbacks for ordinary boundary versus forgetting; indexing/review hooks | New conversation removes in-memory rows and overwrites JSON after handing off hooks. Search handoff is not proof of durable full-transcript archival |
| JSON loader | Decodes `[Message]`; unreadable input becomes an empty array | Empty-start payload is an object (`{"sessions":[]}`); distinguish intended empty state, format mismatch and actual corruption in characterization |
| `TaskStore`, `TaskStoreSchema`, `AgentTaskStore` | Existing `agent-tasks.sqlite`, schema version 5 at inspection, authority identity/generation and migration checks | Extend this database; re-audit snapshot SQL, validators and migrations so conversation tables cannot be erased by task saves |
| `AgentTaskManager`, `TaskDurability`, `TaskEventJournal` | Attempt/process bindings, revisions, pending interactions, receipts and admitted transitions | Reuse them. Do not infer authoritative health, safe retry or complete checkpoints from metadata alone |
| `TaskRecoveryPlanner` | Held restart decisions; restored question/approval cards; narrowly qualified explicit read continuation | General automatic recovery is not established. Repeated-read and timing failures are retained in the parent roadmap |
| `ActionRuntime` / `ActionReceiptStore` | Existing effect admission and receipts; receipts currently in `action-receipts.json` | Receipt writes and task SQL are not one atomic transaction. Preserve reconciliation across that boundary |
| `AgentCaptureController`, voice coordinator/reducer, `OutputScheduler` | Separate capture UUID, turn/output ownership and live background work | Voice session is not durable conversation identity; no stale microphone/output authority survives restart |
| `KnowledgeIndexer`, memory review, usage projections | Existing derived search, guarded review and `usage.jsonl` attribution | Keep projections reconstructible; no invented sources, approvals, delivered speech or usage |

Paths above are relative to `Sources/NextNotes/`. See [design](01-DESIGN.md) for exact
ownership and persistence rules. Observed source patterns are investigation inputs;
no bug is declared repaired and no runtime failure is declared reproduced here.

## Scope and sequence

First deliver durable history and truthful recovery presentation with current conservative
execution policy. Then add qualified checkpoint continuation. Broader concurrency and
automatic read recovery follow only after their own contracts pass.

| Release slice | Milestones | User-visible value |
|---|---|---|
| A: conversations survive | DS-00 through DS-05 | Retained transcripts, new/reopen conversation, correct task/result routing, no MainActor history rewrite |
| B: interruption is understandable | DS-06 through DS-08 | Durable request identity, exact pending questions/approvals, truthful partial answers and qualified continuation |
| C: long-running continuity | DS-09 through DS-11 | Durable compaction, background ownership, restricted multi-conversation execution and proven recovery |
| D: acceptance and retirement | DS-12 | Reference-machine verification, rollback/recovery drills, removal of obsolete owned artifacts |

Detailed tasks and prerequisites: [02-IMPLEMENTATION.md](02-IMPLEMENTATION.md).
Fault matrix, native checks, performance and rollout: [03-ACCEPTANCE.md](03-ACCEPTANCE.md).
Each slice may integrate with its own evidence; completion never promotes an unrelated
model, parent phase, iMessage hosting or general Agent readiness.

## Non-negotiable contracts

1. Durable conversation ID, context epoch, capture ID, turn ID, task ID, attempt and
   receipt ID have different meanings. Restoring one supplies no authority for another.
2. Store new conversation/submission/checkpoint facts in the existing task SQLite
   authority. Keep existing receipts and usage owners; cross-file writes are reconciled,
   never described as atomic.
3. No disk, lock, archive load or model summary in audio callbacks. No new gate between
   microphone, model and speaker. Persistence admission for work uses the responsible
   existing boundary and yields the actor while waiting on storage.
4. One approval at the consequential boundary, with the exact reviewed payload.
   A persisted approval decision is history, not a reusable live execution token.
5. Unknown external outcome stays unknown until qualified evidence resolves it. Request
   deduplication cannot make email, filesystem or calendar effects exactly-once.
6. Histories retain original rows until the person's deletion/retention choice removes
   them. Compaction changes model context; it does not silently delete the transcript.
7. Stale callbacks may update only their still-valid original owner. They cannot append
   into the currently selected chat just because it is selected.
8. No arbitrary history length, idle deadline or new model pass is introduced as a
   substitute for bounded working memory and correct identity.

## Dependencies and decisions

This plan follows [AGENT-OVERHAUL §4.1](../../in-progress/AGENT-OVERHAUL/00-README.md#41-implementation-eligibility-and-quality-gates--owner-decision-2026-10-01),
[Phase 6](../../in-progress/AGENT-OVERHAUL/07-PHASE-6-DURABLE-JOBS.md),
[build coordination](../../BUILD-ORDER.md), and [PERFORMANCE-STANDARDS](../../../PERFORMANCE-STANDARDS.md).
P3 task/output ownership and P6 authority/receipts remain the controlling contracts.
Do not implement another retry, revision, receipt or worker lifecycle system here.

Decisions made for this plan: use the existing database; retain conversation IDs across
idle periods; refresh context/memory without silently creating a new archival chat;
keep one selected chat initially; preserve current automatic-recovery restrictions;
defer branching/forks, cloud sync, multi-user collaboration and general durable app
documents. Existing domain stores continue to own meetings, files and memory.

Before the first implementation slice, DS-00 must resolve: exact current source/test
pins; task schema/save compatibility; timestamp precision; cost of archive queries under
voice load; and available P3/P6 consumer contracts. DS-09 selects compaction strategy from
measured fidelity/cost, not from the reference article. Retention UI and deletion scope
must be explicit before owner migration; no new automatic expiry is assumed.

## Coordination and handoff

Roadmaps are intentionally local/git-ignored. Product changes and compact verification
reports belong in tracked source and `Tests/Reports/`. This folder remains `todo` until
an implementation task is claimed; planning is not implementation. No owner data,
installed app, model, grant or default changes in this documentation cycle.

Use agent-relay for file ownership and meaningful scope/evidence broadcasts. Check live
claims before edits; serialize native builds/model benchmarks with the current ASR/TTS
and meeting work. The development machine claim must never become a product audio gate.
At every handoff record source pins, unchanged regression inputs, verdicts including
inherited failures, remaining contracts and exact owned artifact cleanup. Broadcast
delivery does not prove another agent read or agreed with the plan.

# Agent implementation sequencing — owner decision 2026-10-01

The owner approved continued independently testable implementation below the
fixed 9/10 quick score. The previous blanket phase-entry rule prevented work
that can prove its own production contract without that aggregate model score.
Implementation now follows actual task prerequisites and coordinated ownership;
quality, safety and product-readiness requirements remain unchanged.

Authoritative policy: [Agent README §4.1](../../roadmap/in-progress/AGENT-OVERHAUL/00-README.md#41-implementation-eligibility-and-quality-gates--owner-decision-2026-10-01).
All planning files remain local/Git-ignored. The tracked AGENTS policy carries
this owner decision to other agents; this report records the review and bounds.

## Entry changes and next tasks

| Task | Entry prerequisites | First concrete work | Boundary |
|---|---|---|---|
| P2-01 | P0-06, P0-11, P0-20a, P4-01; all recorded done | Audit and rebaseline existing VoiceLatencyTimeline/MainActorStallProbe/VoiceLatencySelfTest and their production callers | Instrumentation and the flag already exist. Do not duplicate them. A model/audio absence cannot count as a latency success; a stall fix needs attribution and before/after evidence. |
| P3-01 | P0-07, P0-11; both recorded done | Put regressions on the actual coordinator/worker path | The provider seam still selects a legacy route today. Keep typed behavior intact; the copyable real-model whitelist now includes the existing voice-latency flag. No ledger/reducer ownership switch is completed by test work. |
| P6-01 | P0-07, P0-11; both recorded done; isolated actual store/manager construction before seeding | Characterize fresh-instance typed-task restart behavior | AgentTaskStore/AgentTaskManager constructors are private and the current store targets owner JSON. Add only the narrow isolation seam needed to test those real constructors. Never seed owner data or duplicate restart mapping in a helper. No recovery/retry is enabled by this baseline. |
| P4-07a | P0-11; existing MemoryGuard/NextMemory writer | Persist provenance with lossless legacy decode and privacy assertions | P4-08 is preferred whole-phase order, not a prerequisite. P4-07 then P4-11 remain required before lifecycle mutation. |

These tasks remain **todo** until claimed, implemented/tested and committed.
Their real prerequisites have not been waived. Source anchors were checked:

- Existing latency registration: NextNotesApp's `--selftest-voice-latency` branch;
  capture starts the stall probe and timeline and marks voice/ASR/EOU stages.
- RealtimeAgent.handle still gates the coordinator on its provider override;
  appendVoiceFollowUp remains. P3-01 has actual production-route work to do.
- AgentTaskManager.init loads AgentTaskStore.shared and maps queued/running to
  failed; AgentTaskStore uses AppIdentity/agent-tasks.json. A persistence guard
  does not provide a safe fixture-seeding constructor.

## Requirements retained

The fixed quick bar is still 9/10. The entire STATUS phase-exit table is unchanged,
including Phase 1's two full >=25/30 runs, owner-request requirements and remaining
exit flags, plus latency/full-duplex/durability and product-promise acceptance.
Current quick 5/10 and prior full/owner failures remain recorded as failures.
No result was rerun or reclassified by this documentation change.

A bounded fix can finish when its original regression and relevant functional
and safety checks pass, while its inherited parent aggregate gate stays open.
Run required evaluations, investigate new failures and do not ship a known
introduced regression. Model/default promotion and broad Agent readiness still
need their prescribed evidence. Missing models/grants/test seams are not passes.

P6-06's real P1-21 outcomeUnknown/receipt contract is now an explicit dependency,
where it was previously hidden behind the blanket Phase 1 entry gate. That
contract is already done; the dependency graph now makes it hard rather than
soft. Consequential actions still require authority/effect/receipt checks.
6A/P3-03a/b edits to AgentTaskManager are serial: P6-04a lands before P3-03a
starts, or after P3-03b finishes. 6B still requires its named task-ledger,
reducer/output contracts. Recovery/retry permissions are unchanged.

Characterization baselines (P6-01 and current-behavior coverage in P3-01) may
start green, then demonstrate a failing temporary producer mutation. This pins
today's real behavior without inventing a product failure. Actual route/behavior
fixes still need genuine red-before/green-after evidence.

## Reconciliation and verification

Updated Agent README entry policy/workflow/graph, STATUS dependency cells, the
P2/P3/P4/P6 briefs, dated REVIEW-LOG supersession, BUILD-ORDER, roadmap navigation,
memory-lifecycle prerequisite explanation and AGENTS. Historical measurements
remain intact; a new supersession note explains the old ordering decisions.

Independent read-only review found and resolved unsafe restart-fixture assumptions,
the characterization/red-first contradiction, the missing provenance graph edge,
the stale copyable voice-model whitelist and an implicit receipt dependency.

Checks completed:

- Entire STATUS phase-exit table unchanged byte for byte.
- Three live-eval source files unchanged by SHA-256.
- Only four existing ledger dependency cells changed: P2-01/P3-01/P6-01/P6-06;
  task states, dates, evidence and commit fields unchanged.
- Graph and entry/receipt dependencies agree; provenance has its P0-11 edge.
- Nine new policy Markdown links and heading anchors resolve.
- Whitespace/diff checks pass for the owned documentation.

No application build, model benchmark or runtime change was needed for this
sequencing revision. Concurrent iMessage, dictation and website changes remain
with their existing owners. Readiness to start a task is not completion evidence.

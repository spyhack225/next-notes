# Agent Overhaul status audit — 2026-10-08

Assessment of canonical working sources, commit history, roadmap contracts and retained
qualification reports. No build, benchmark, model inference, installation or owner-store
access was performed. Existing staged/uncommitted work was preserved. This report does
not change the task-state ledger or certify today's entire working tree.

The foundation is substantially implemented; complete product acceptance remains open.
The October 4 ledger understates subsequent implementation and quality results.
Do not infer a completion percentage from its parent and child row counts.

| Phase | Position | Remaining acceptance or implementation |
|---|---|---|
| 0 — Answers | Mostly implemented: model validation/routing, templates, cache, privacy and usage | Endpoint/fallback/late-EOU acceptance; relevant current integration |
| 1 — Tools | Broad implementation; repeated Mini quick results reach the quality bar | Repeated full and mandatory owner cases, current backend/functional reconciliation, Apple evaluation and real-user effects |
| 2 — Latency | More implemented than the ledger: immediate partial preparation, matching frontend prewarm, prepared-answer reuse, native VAD ducking, reply-scoped Pocket sessions and EOU preparation | Single-decision adoption was rejected; Smart Turn and buffer work remain unclosed; warm response, ducking, residency and physical acoustic acceptance |
| 3 — Full duplex | Shared task bridge, effect barrier, output tokens/scheduling, corrections, spoken approval and Island fixes exist | VoiceSession still declares only shadow mode; complete ownership switch, capacity and worker contracts, current regressions and physical interaction |
| 4 — Proactivity | Memory/Knowledge producers and a scheduled text-first Catch-up with saved speech rendering exist | Hosted meeting briefs, owed items/nudges, useful attended first-use journeys, factual meeting quality and complete memory/consent acceptance |
| 5 — Optional cloud realtime | Roadmap-specific provider work remains planned | OpenAI/Gemini realtime frontend and its acceptance server; existing cloud text providers do not complete this phase |
| 6 — Durable jobs | SQLite authority, journal, attempt/receipt admission, held restart, corrections and bounded explicit recovered-read continuation exist | Broader crash/restart recovery, safe retry/reconciliation, restored UI, complete delivery/observability and worker graphs; remote iMessage hosting remains unqualified |

## Quality and speed evidence

- Mini native quick at `d32b123`: **10/10 three times**. Subsequent installed `c2b11e7`
  quick: **9/10 three times**, with A02 still ungrounded. These supersede the ledger's
  historical 3/10 claim for these particular artifacts, not every model or current source.
- Latest retained complete Mini pair identified in this audit, `2afe575`:
  **25/30 and 23/30**; owner **9/10 both**, mandatory subset **8/9** with O08 refusal.
  Thus the required two full passes at least 25/30 and all mandatory owner cases remain
  failed. An earlier artifact's 25/30 and 26/30 does not erase later failures.
- Required-flag retained-log accounting at `69115eb`: **16 PASS / 4 FAIL**.
  Native Mini optional-tool calls, voice grounding, Needle calls and unsigned-in
  Composio were open in that reconciliation. This is historical evidence, not a fresh run.
- Matched voice preparation pair: median onset-to-preparation **1.778 → 0.671s**,
  endpoint-to-token **3.322 → 2.448s**, endpoint-to-audio **3.777 → 2.649s**.
  These remain above owner L1/L2 200ms and roadmap audio 0.9s targets.
- Later split-prewarm Apple/Pocket counted turns report audio median **4.139s**;
  extra warmup commits make the broader run unqualified. No stable speed gain follows.
- Pocket reply pipeline has one engine start and software gap estimates about
  **-10 / +10ms**, with physical acoustic/full-voice acceptance still open.
- Native cold VAD duck measured **593ms** against **200ms**; warm replay succeeds
  at 146ms sample time, which is not physical/live wall-time acceptance.
- Mini C1 on the M3/16GB: **604s**, 96 rounds, median **42.20 tok/s**, p10 **36.14**,
  all overlapping ASR. This qualifies that decode workload only; C2 combined voice
  and model-default acceptance remain open.

## Sources and next priorities

Code checks: `Agent/Tasks/AgentTaskStore.swift` and `Durable/TaskStore.swift` implement
SQL authority; `AgentTaskManager.continueRecoveredRead` and `TaskBridge` expose bounded
continuation; `Duplex/OutputScheduler.swift` owns output capabilities;
`Duplex/VoiceSession.swift` still has `enum Mode { case shadow }`;
`UI/Agent/AgentView.swift` still displays `messages.suffix(40)`;
`Schedules/ScheduledRunner.swift` and `AgentSchedule.swift` contain Catch-up integration.

Relevant compact reports (relative to this report's directory):

- [Repeated native quick](native-quick-d32b123/verification.md)
- [Later quick and video failure](a02-page-inspection/verification.md)
- [Latest full/owner failures](r01-write-after-read/verification.md)
- [Required-flag accounting](acceptance-accounting/verification.md)
- [Voice preparation](voice-preparation/verification.md)
- [Split prewarm and native timings](p2-split-prewarm/verification.md)
- [Pocket pipeline](p2-pocket-reply/verification.md)
- [VAD ducking](p2-vad-duck/verification.md)
- [Rejected single-decision candidate](p2-single-decision-rejected/verification.md)
- [Catch-up implementation](catch-up-core/verification.md)
- [ASR-overlapped decode qualification](c1-mini-decode/verification.md)
- [Open contracts](../../../roadmap/in-progress/AGENT-OVERHAUL/REMAINING-WORK.md)

Next work should follow the owner's quality/speed/product direction: repair remaining
full/owner failures at their producers, qualify one coherent current artifact, finish
latency/full-duplex acceptance, and prove useful proactive journeys. Optional realtime
and worker graphs should not displace those priorities. Reconcile the ledger against
the accepted results instead of repeating its stale 3/10 and latency todo entries.

No application/build artifacts were created or removed by this audit. Disk sampling
reported 6.5 GiB available; no heavy work was launched. Existing binaries, worktrees,
models, caches and evidence were retained.

## Relay board follow-up — 2026-10-08, 16:50 EDT

The initial audit checked active agents/claims and broadcast its findings, but did not
read the full board. A subsequent read used the dashboard's read-only snapshot
(cursor828, last100 messages), including peer progress and project/machine claims.
No claims were present in that snapshot. Peer status is reported work, not verification
of the changes or a fresh product acceptance result.

Claude's current isolated branches cover Catch-up/UI, Google Option C, listening/prefill,
thinking review, bake-off, development tooling and roadmap reconciliation. Its roadmap
agent reports updated October8 blocks and P2-03/05/06/07 in-progress states in its worktree;
this does not establish canonical integration. Catch-up triage reports lifecycle fixes
already present and closing-offer integration still open. Listening and bake-off native
validation were refused by resource gates; thinking review rejects vendor settings and
leaves its streaming repair unverified. Google OAuth is work in progress. The tooling
agent reports63 passing isolated checks, not app performance. Meeting acceptance has
released its heavy-work claims and retains no new installed candidate. These updates
add current work in flight but do not close the full/owner/latency/product gates above.

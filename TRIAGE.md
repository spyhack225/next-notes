# Catch-up triage — c6d850c, 8 October 2026

Written before implementation. This base already includes more than the brief assumed.
Read the paused `../catchup` branch (8c25a50, 2ce054c and its three uncommitted
files) without changing it, plus integration/catch-up-pl11 README, handoff and
04/05/06-headd014192 patches. Those packets describe historical gaps, not this HEAD.
AGENTS.md and PERFORMANCE-STANDARDS.md were read. No source port is needed for 1–4.

1. **PRESENT — same render Task quit join.** CatchUpTemplate.swift:255 creates the
   actual Task, :262 retains that handle, :288 closes admission, captures and cancels
   the retained handles. NextNotesApp.swift:10357 captures them before Pocket's
   beginTermination; :10414 awaits those same handles before Pocket finishTermination.
   Wake begin/finish joins remain at :10360/:10416, along with native/model joins.
   CatchUpSelfTest.swift:1240 exercises entered cancellation-insensitive synthesis,
   delayed join, closed admission and no cancelled artifact attachment. The paused
   uncommitted lifecycle repair and packet06 idea are already integrated in 5c7df10.

2. **PRESENT — artifact fold respects primary admission.**
   AgentTaskManager.swift:2364 peeks records, updates through the primary store,
   checks primaryCommitted, then consumes exactly the copied records.
   AgentArtifactLedger.swift:29 preserves later captures. CatchUpSelfTest.swift:1100
   exercises actual primary refusal, retained links, retry and capture during commit.
   Packet06's producer repair is already here, adapted to typed artifact metadata.

3. **PRESENT — concurrent rendering is guarded.** LongFormRenderer.swift:120 retains
   isRendering; :158 refuses a second render with busy(waited:0), then sets the flag
   before its first suspension and releases it in defer. The detached render is no
   longer presumed to share ScheduledRunner's passChain. CatchUpSelfTest.swift:1164
   uses the actual spawn to hold synthesis while another text result returns.

4. **PRESENT — reverse cooldown at the scheduled producer.** AgentScheduler.swift:489
   checks scheduled pending results/retries (explicit snooze exempt), :561 checks due
   slots, :929 is the shared lookup, :898/:999 check return admission and :1046 return
   retries. CatchUpSelfTest.swift:791 pins 05:30 return followed by 06:00 scheduled
   execution, expiry, nothing-to-report, pending text/retry and snooze controls.
   Comparing 2ce054c confirms its producer idea and original regression are in 5c7df10.

5. **MISSING — scheduled closing offer has no pending production consumer.**
   Estimated complete change: roughly 100–200 lines across scheduler delivery,
   typed and voice pending consumers, notification/tap wiring and regressions;
   more than the owned schedule-only seam. This is a scope estimate, not a measured diff.
   Existing PendingAction.detect (PendingAction.swift:89) binds a conversation's
   original request, question, session and expiry. RealtimeAgent.swift:559/:662 resolves
   and creates typed pending actions; VoiceConversationCoordinator.swift:693/:910
   resolves and creates voice offers, and :1372 registers waiting worker questions.
   LiveScheduleDelivery.deliver (AgentScheduler.swift:1425) posts a notification,
   shows text and optionally speaks sessionlessly. It arms neither pending consumer.
   Notification actions at :1340 support open/read/snooze and existing RoutineDraft
   approval, not an unexecuted free-text catch-up offer. A bare yes cannot be claimed
   to execute this offer. Merely calling detect with the routine prompt would repeat
   the catch-up instead of binding the proposed draft and its evidence. Implementing
   spoken AND tapped acceptance requires explicit offered-action/session ownership,
   cross-consumer handoff and normal approval proof in unowned voice/UI files.
   Under the brief's "only if ... small" condition, leave this documented for owner
   scoping; no new state/store or unsafe guessed action is introduced.

6. **MISSING — explicit live spoken catch-me-up route; design only as requested.**
   Reuse VoiceConversationCoordinator.toolShapeRoute (:1212) to recognize the spoken
   request and dispatch through its existing newWork/task bridge. Resolve an existing
   enabled Catch-up identity through schedule.list and call schedule.run_now through
   the existing tool executor/permission seam; clarify multiple matches and offer
   creation through CatchUpTemplate.setupCall if no routine exists. Setup already
   routes via this seam (:1213) and RealtimeAgent+ToolLoop.swift:1525 from 9e53040.
   Do not create another routine or renderer, infer an arbitrary id, or treat the
   user's phrase as a schedule-write approval. On-demand execution retains the normal
   run_now authority and result delivery; no new queue, timer or model pass is needed.

## Validation plan

Keep source unchanged and run the brief's current build/batch through ../heavy.sh,
including real voice once because Pocket files are present. The historical report
Tests/Reports/agent-overhaul-progress/catch-up-core/verification.md records original
failure8/current pass for items1–3; paused 2ce054c records cooldown original failure5.
Those are historical evidence, not rerun RED evidence for this worktree. No bug-fix
commit is justified by an already-present repair. Record current markers and any
resource/environment blocker in RESULT.md. No install, push, merge or GUI run.

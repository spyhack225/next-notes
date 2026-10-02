# Root implementation now verified

P6-05j original86 missing-feature RED6 → identical fixed87 worker1161/all20 focused flags PASS. [Actual evidence and limits](../human-wait-observation-review/verification.md). Broader stale/recovery/retry gates remain open. The read-only planning audit below is historical preparation; this audit worker performed no implementation/native work.

# P6-05 human-wait exclusion prerequisite — read-only candidate

Prepared 2026-10-02 while root owns the independent P6-05i current Process proof. No implementation, fixture execution or stale verdict is supplied. This is a missing diagnostic input, not a reproduced product misclassification: no parent stale detector currently runs. Do not promote P6-05, recovery/retry or IM-16.

## Confirmed current source contracts

- `PermissionGate.swift:14–24,35–73,103–108`: Gate owns the active `WaitingApproval` and ordered queued entries. Both retain the typed `PermissionRequest.taskID`; a live admitted ask suspends its actual continuation in one of these entries. Queueing is already the real ownership seam, not an Activity-store reconstruction.
- `PermissionGate.swift:263–266`: `hasRestoredRequest` deliberately matches only entries whose `restoredDecision` is nonnil. It cannot identify live nested ACP waits. `pending` identifies only the visible request; `queuedCount` supplies no task ownership. Preserve the restored-only query because Manager cancellation/restored-response routing depends on it.
- `PermissionGate.swift:167–226,311–343`: rejected decision admission retains the exact active card/waiter; accepted decisions clear it before resuming; cancellation removes actual active/queued entries and advances the next. A journal permissionRequested fact is historical after these changes and cannot substitute for current wait ownership.
- `ACPSession.swift:149–209`: normal typed nested permissions validate captured ownership, pass typed taskID to Broker, then bind the same context at the existing Gate await. Post-Gate validation supplies authority separately. Gate does not park the Manager row. The task remains running/acpWorker while that real nested approval waits, including when queued behind another task.
- `AgentTaskManager.swift:668–680,976–1024`: accepted start assigns acpWorker and initial progress timestamps. Permission facts use captured live-map/primary transaction admission but do not change runtimeClass/status or stamp heartbeatAt/lastProgressAt. Only toolStarted/toolCompleted stamp those fields here. Therefore old heartbeat plus acpWorker cannot identify a person wait.

## ACP/model activity trace — separate open contracts

`ACPSession.handleNotification` (`ACPSession.swift:228–257`) checks established session identity, drops thought chunks, appends message deltas to lastReply, and publishes other public titles as activity. `ACPAgentBackend.runSession:383–404` subscribes and forwards permission/activity to ActionOrchestrator/AgentActivityStore/Island using a MainActor Task and Manager.shared running-row check. It neither records a captured TaskJournalEvent nor stamps durable progress. That routing does not prove exact attempt ownership or a heartbeat; repairing attribution/activity admission would be another task.

`RealtimeAgent+ToolLoop.swift:635–710` streams provider chunks, records first-token usage, parses the response envelope, and feeds speech. `VoiceConversationCoordinator.swift:622–674` consumes actual LocalVoiceFrontend deltas into stream progress, envelope routing and speech; `LocalVoiceFrontend.swift:182–196,468–479,658–677,716–742` produces speculation/answer deltas and timing. These paths carry conversation/work/voice correlation, not a proven positive durable worker context. `AgentToolLoop.swift:282–307` calls a bounded completion closure; `LocalAgentBackend.swift:18–60` executes a named tool rather than hosting that model stream. No production `.heartbeat` event producer was found in Agent/Formatting LLM. Do not add per-token SQL writes or infer durable ownership from usage correlation to make the parent heartbeat step appear complete.

## Smallest candidate through the existing seam

Add a synchronous MainActor `PermissionGate.hasWaitingRequest(taskID:) -> Bool` that reads active **and queued** requests regardless of live/restored mode. It must inspect only existing entry.request.taskID, without building reviews, decoding arguments, probing SQL, evaluating validity, altering cards, adding callbacks or persisting anything. A Bool is sufficient for conservative human-wait exclusion; no new snapshot layer or cache is required.

Expose that current task-owned sample through a small Manager diagnostic method guarded by its existing current worker binding. Return nil when the requested live binding is missing/released, not false/dead. Read Gate synchronously after any independent Session observation await if later combined diagnostics need it. The sample means only “Gate currently owns a wait for this task”; it supplies no approval, health, retry or exact successor-attempt authority. Gate's request has typed taskID but no immutable attempt/start fields; do not invent them from requestID or TaskLocal. Any old/restored same-task entry should conservatively exclude an age verdict. Exact attempt attribution would need separately reviewed provenance and remains open.

This candidate needs root ownership of Gate and Manager plus the isolated production-path fixture/registration. Keep `hasRestoredRequest` unchanged. No task status/runtimeClass migration, event save, new store/queue/timer, model pass, foreground await or policy change. The current worker debug seam may log the sample; there is no existing general stale loop to hook. Do not add such a loop as part of this child.

## Required original/control proof before application

Prepare the identical fixture with an unused nil observation scaffold on original, then exercise actual two isolated Managers → ACPBackend → two harmless owned peers → Session → Broker → Gate. Disable only the existing SelfTest autoallow, retain true nested contexts and fail closed on unexpected tools. Fresh typed task IDs are real submissions, never seeded owner records.

Hold A at its real pending card, then submit B until its real request is queued behind A. Actual active A and queued B must each project waiting, unrelated C must not; hasRestoredRequest remains false for these live requests. Fresh readers must show both rows running/acpWorker and exact admitted attempts/receipts. Existing safe progressDateForTesting can make their actual accepted timestamps 40 days old: no history seed or fake helper row. A waiting sample has no age window; absence/unknown still authorizes no stale verdict.

Read repeatedly and assert exact SQL/journal/export/receipt/card/review/grants unchanged. Reject a real decision save and prove the same wait remains; remove the fixture trigger and make one genuine decision. Verify A clearing promotes B, both active/queued cancel paths remove only their exact wait, continuations join once, old/released Manager samples become unavailable, and no tool effect/replay occurs. Preserve ordinary permission/restoration/worker/ACP/MCP/isolation checks. Native original/fixed outcomes remain pending; no count or pass is claimed.

Even a green child would establish only current human-wait input. Complete input-question/restored/remote/voice/scheduled coverage, event-driven/periodic activity, fresh primary/current receipt quality, all active effects, Process/session health, nonmutating four-question stale policy, recovery/retry and the unchanged aggregate gates remain open.

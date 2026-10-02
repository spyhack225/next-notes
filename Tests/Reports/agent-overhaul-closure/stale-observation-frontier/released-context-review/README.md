# Current verified handoff — original59/fixed60

See [actual verification](verification.md). Dated off-source preparation below is retained as historical source evidence; it is not current implementation status. Parent Phase6/IM-16 and aggregate quality gates remain open.

# Released worker context — separate off-source regression

Read-only/off-source review, 2026-10-02. No Sources/index/native/build/model/process changes or executions. Root's ACP original55/fixed56 slot is separate; no55 proposal was altered. No original product failure is claimed until root executes the identical safe fixture on original/fixed.

## First broken contract

The Manager's captured execution-validity producer currently treats current task metadata plus an accepted primary SQL row as live authority. RunningWorker handle/captured binding checks only decide whether to stamp a cached observation; they do not gate the returned Bool. Existing rejected terminal SQL save leaves both memory and primary running. execute's defer then calls releaseWorker before backendExitForTesting, which removes that exact original live map entry. Its old context can still return accepted because workerCondition compares captured/current task fields and primary still matches.

The actual consumer is LocalAgentBackend.submit: positive attempts require the captured TaskJournalContext, then call its isStillValid on MainActor before consuming approval/entering AgentToolExecutor. The executor passes the same validity into Orchestrator's existing pre-fire check. A stale true can therefore admit another real backing through the exact context/receipt/journal path. This is not a claimed automatic retry loop; the counterexample is an actual retained-context replay into the real backend API, using the originally produced task/context and same file arguments.

## Original-compatible actual fixture

TaskWorkerReleasedContextSelfTest.swift.txt uses the existing owned root/input/text from --selftest-task-worker-attempt. It creates two real isolated manager/SQL/receipt-store flows, runs the same actual FilesystemExecutor read via existing fireOverrideForTesting (only counting and forwarding), and captures the real manager-owned task/context/binding at backend entry. No synthetic context, manager cancellation or altered payload intervenes in the stale case.

- Terminal-admitted control: real read completes and handle is released. Its primary row is completed, so both old and fixed validity should refuse replay.
- Rejected-terminal original: real BEFORE UPDATE task WHEN state completed trigger rejects only terminal commit, preserving actual running row, prior tool journal/receipt and no Manager success delivery. Wait for backendExit after real release. Independently prove primary still accepts captured running attempt, while workerBinding is nil. Replay that exact context/task through TaskEventJournal.withValue and LocalAgentBackend.submit on the same read. Expected original bug is stale true plus another actual read/receipt/journal; native verdict pending.

The fixed assertion checks the same read count remains1, plain LocalBackend refusal, no primary/journal/receipt-file changes and no recreated handle observation. The existing authorityBoundaryForTesting existingOpened callback counts actual SQL opens only during absent-handle validity/replay; fixed must open zero. Healthy entry validity must still be true before the first original read. The fixture retains original completed receipt evidence even when task terminal save rejected.

The fire override does not fabricate a tool result: it verifies exact filesystem.read/unchanged path arguments and calls real FilesystemExecutor.run. Only explicitly owned temp paths are decoded/read. No owner/default-store payload is seeded or read, no subprocess/model is launched, and diagnostics contain generic failure labels.

## Smallest producer repair

validity-closure.proposed.swift.txt changes only the existing Manager.journalContext validity closure body. Before workerCondition or any store read, require the existing running[taskID] value, uncancelled handle, and exact taskID/attempt/process owner/start binding matching the captured task. After the existing SQL observation, require the same uncancelled binding before stamping cache AND returning primary acceptance. Both map checks are O(1); no workerBinding getter/task scan is added. SQL is still the existing authority read when a live handle exists; map presence alone never grants execution.

The existing SelfTest denied-persistence shortcut stays after the live binding check, so it cannot resurrect an absent handle. Map acceptance grants neither health nor effect/retry authority. Do not move this guard wholesale into workerCondition in this slice: that function also serves stored approval/input/cancellation record transitions whose handle lifecycle differs. Local-only pending permission restoration remains governed by its existing explicit continuation rules.

The whole current original closure is archived separately. Root's typed ACP integration may change the enclosing hasLocalAttemptRecord conditional to hasWorkerAttemptRecord; replace only the reviewed closure body after56, not the whole Manager source. Current base SHA3453a319..., original closure SHA32c19bd6..., proposed closure SHA32c1fdfa..., fixture SHA7c2b1036.... These hashes are static review pins, not native proof.

## Limits / acceptance

Run the unchanged original fixture first, then apply only the producer guard and reuse identical bytes. Append registration after existing worker cases; preserve the complete629 base plus actual ACP extension as root measures it. Do not predict a final native case count from this audit.

Re-run relevant worker, restoration, authority, review, receipt persistence/ownership and isolation contracts. No new timer/query/save/schema/store/await/model pass is added. Independent original/fixed evidence and related functional checks are prerequisites to bounded closure; aggregate quick9/10 and parent phase gates remain unchanged/open.

This guard does not fence direct retained context.record metadata calls, close the gap after an admitted pre-fire check, reconcile receipts, prove process/session health, recover/retry, host IM-16 or complete ACP permission/compatibility authority. Those producers need separate actual boundaries. Native post-SQL handle invalidation sensitivity is not claimed by this two-flow fixture; the proposed defensive postcheck remains the same-map contract without inventing an easier replacement worker.

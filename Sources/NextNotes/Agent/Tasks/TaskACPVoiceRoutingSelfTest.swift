import Foundation
import SQLite3

/// Actual mounted voice intake -> existing harness router/card -> SAME Manager slot/ACP peer.
/// Missing original ACP routing is a conditional unreachable branch, never a seeded ACP row.
@MainActor
enum TaskACPVoiceRoutingSelfTest {
    private enum Invalid: Error { case isolation, root, task, timeout }
    private static func reached(_ value: @MainActor () -> Bool) async -> Bool {
        let end = ContinuousClock.now.advanced(by: .seconds(8))
        while ContinuousClock.now < end { if value() { return true }; await Task.yield() }
        return value()
    }
    private static func marker(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }
    static func run() async -> (checks: Int, failures: [String]) {
        let c = VoiceConversationCoordinator.shared; let capture = AgentCaptureController.shared
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-voice-work-lifecycle",
              AgentSession.shared.fileURL == nil, !capture.isSessionActive, !c.hasActiveWork,
              PermissionGate.shared.pending == nil, PermissionGate.shared.queuedCount == 0,
              ACPConfirmationGate.shared.pending == nil else { return (0, ["voice ACP: INVALID isolation"]) }
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let root = temp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard root.path == root.resolvingSymlinksInPath().standardizedFileURL.path,
              root.deletingLastPathComponent().path == temp.path, !FileManager.default.fileExists(atPath: root.path) else {
            return (0, ["voice ACP: INVALID root"])
        }
        let owner = SelfTestStoreGuard.take(); let oldBridge = c.taskBridgeOverrideForTesting
        let oldRemember = c.rememberExplicit; let oldProbe = AgentHarnessRouter.shared.availabilityProbe
        let speech = AgentSpeechSynthesizer.shared; let backing = RecordingSpeechBacking()
        var checks = 0; var failures: [String] = []; var created = false; var joined = true
        var operation: Task<Void, Never>?; var manager: AgentTaskManager?
        func check(_ value: Bool, _ label: String) { checks += 1; if !value { failures.append("voice ACP: " + label) } }
        defer {
            ACPConfirmationGate.shared.resetForTesting(); AgentHarnessRouter.shared.resetForTesting()
            AgentHarnessRouter.shared.availabilityProbe = oldProbe
            c.resetForTesting(); _ = c.installTaskBridgeForTesting(oldBridge); c.rememberExplicit = oldRemember
            speech.restoreSystemBacking()
            if created && joined { try? FileManager.default.removeItem(at: root) }
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false); created = true
            speech.useTestingBacking(backing)
            for mode in ["available", "start-refused", "cancel-held", "cancel-save-refused", "closed-held", "missing-cancel", "missing-run-once", "missing-session-closed"] {
                let begin = checks
                let flow = root.appendingPathComponent(mode, isDirectory: true)
                try FileManager.default.createDirectory(at: flow, withIntermediateDirectories: false)
                let sql = TaskStore(root: flow); defer { sql.close() }
                let store = AgentTaskStore(fileURL: flow.appendingPathComponent("agent-tasks.json"), mirror: sql)
                guard store.allowsHarnessPersistence else { throw Invalid.root }
                let receipts = ActionReceiptStore(fileURL: flow.appendingPathComponent("action-receipts.json"))
                let m = AgentTaskManager(store: store, receiptStore: receipts); manager = m
                defer {
                    m.backendEntryForTesting = nil; m.backendExitForTesting = nil
                    m.announcementForTesting = nil; m.voiceACPArgumentsForTesting = nil
                    m.completionDeliveryForTesting = nil
                }
                let bridge = TaskBridge(manager: m)
                guard let outputQueue = OutputScheduler.isolatedForTesting(bridge) else { throw Invalid.isolation }
                var completionCount = 0
                m.completionDeliveryForTesting = { id in completionCount += 1; _ = outputQueue.enqueueCompletion(id) }
                let isHeld = mode == "cancel-held" || mode == "cancel-save-refused" || mode == "closed-held"
                let (script, output) = try TaskACPPrimaryAdmissionSelfTest.writeVoicePeer(root: flow, database: sql.fileURL, hold: isHeld)
                var localCalls = 0; var backendCalls = 0; var ended = false; var activeAtEntry = false
                var rowAtEntry: AgentTask?; var bindingAtEntry: TaskWorkerBinding?; var contextAtEntry: TaskJournalContext?
                var announcements: [String] = []
                m.voiceACPArgumentsForTesting = { _ in ["acpFixture": script.path] }
                m.backendEntryForTesting = {
                    backendCalls += 1
                    guard let context = TaskEventJournal.current else { throw Invalid.task }
                    contextAtEntry = context
                    if let id = UUID(uuidString: context.taskID) { activeAtEntry = VoiceSession.shared.state.activeTasks.contains(TaskID(id)) }
                    rowAtEntry = try sql.load().first { $0.id == context.taskID }
                    bindingAtEntry = m.workerBinding(taskID: context.taskID)
                    operation = m.capturedACPVoiceTaskForTesting(id: context.taskID)
                    joined = operation == nil
                }
                m.backendExitForTesting = { ended = true }
                m.announcementForTesting = { announcements.append($0) }
                c.resetForTesting(); AgentSession.shared.forgetAllConversations()
                guard c.installTaskBridgeForTesting(bridge) else { throw Invalid.isolation }
                c.rememberExplicit = { _ in }; c.prewarmObserverForTesting = {}
                c.workerForTesting = { work in
                    localCalls += 1
                    operation = c.captureVoiceWorkerForTesting(id: work.id)?.task
                    joined = operation == nil
                    return "The explicit local-once fixture finished."
                }
                c.streamForTesting = { _, _ in AsyncThrowingStream { $0.yield("<use_tools/>"); $0.finish() } }
                AgentHarnessRouter.shared.resetForTesting()
                AgentHarnessRouter.shared.availabilityProbe = { _ in !mode.hasPrefix("missing-") }
                await capture.beginSession(captureAudio: false)
                guard let session = capture.sessionID else { throw Invalid.isolation }
                if mode == "start-refused" {
                    try sql.withConnection { try TaskStore.exec($0, "CREATE TRIGGER refuse_voice_acp_running BEFORE UPDATE ON task WHEN NEW.state='running' BEGIN SELECT RAISE(ABORT,'fixture ACP start refusal'); END") }
                }
                let raw = "Use Claude Code to fix the tests."
                RealtimeAgent.shared.userSpeechStarted(); RealtimeAgent.shared.userSpeechEnded()
                let reply = await RealtimeAgent.shared.handle(raw, source: .voice)
                // Admission installs the same Task before backend/worker entry. Retain
                // that handle before any qualification can throw or cancel its slot.
                if operation == nil, let admitted = m.tasks.first,
                   let captured = m.capturedACPVoiceTaskForTesting(id: admitted.id)
                    ?? UUID(uuidString: admitted.id).flatMap({ c.captureVoiceWorkerForTesting(id: $0)?.task }) {
                    operation = captured; joined = false
                }
                check(c.taskBridge === bridge && capture.sessionID == session && AgentSession.shared.fileURL == nil,
                      "C01 actual isolated capture/Coordinator/Bridge did not qualify (\(mode))")
                if !mode.hasPrefix("missing-") {
                    let row = m.tasks.first
                    check(row?.source == "voice" && row?.backend == "acp" && row?.acpCLI == "claude"
                        && row?.userWords == raw && AgentHarnessRouter.shared.lastChoice?.id == .claude,
                        "F01 actual named voice request did not route to canonical ACP (\(mode))")
                    check(localCalls == 0, "F02 named ACP request started a local voice worker (\(mode))")
                    if let row, row.backend == "acp" {
                        if isHeld {
                            guard await reached({ marker(output)["phase"] as? String == "prompt" }),
                                  let held = operation else { throw Invalid.timeout }
                            let before = try sql.load(); let beforeEvents = try sql.journal(taskID: row.id)
                            let beforeExport = try Data(contentsOf: store.storageURL)
                            check(backendCalls == 1 && c.hasActiveWork && bindingAtEntry?.attempt == 1,
                                  "C15 actual ACP voice owner was not held at the real prompt")
                            check(activeAtEntry && VoiceSession.shared.state.activeTasks.contains(TaskID(UUID(uuidString: row.id)!)),
                                  "C22 actual held ACP owner lacked its real accepted voice event")
                            if mode == "closed-held" {
                                await capture.endSession(source: .done)
                                check(!capture.isSessionActive && !held.isCancelled && !ended
                                    && c.hasActiveWork && contextAtEntry?.isStillValid?() == true,
                                    "C19 closing capture cancelled/held actual admitted ACP background work")
                            }
                            if mode == "cancel-save-refused" {
                                try sql.withConnection { try TaskStore.exec($0, "CREATE TRIGGER refuse_voice_acp_cancel BEFORE UPDATE ON task WHEN NEW.state='cancelled' BEGIN SELECT RAISE(ABORT,'fixture ACP cancel refusal'); END") }
                            }
                            let saved: Bool
                            var cancelledAtAdmission: Bool?
                            if mode == "cancel-held" {
                                // Observe the synchronous cancellation boundary, before the awaited voice reply
                                // can resume after this same operation has genuinely returned and released its slot.
                                let priorBoundary = store.migrationBoundaryForTesting
                                defer { store.migrationBoundaryForTesting = priorBoundary }
                                store.migrationBoundaryForTesting = { name in
                                    try priorBoundary?(name)
                                    if name == "beforePrimaryCommit" {
                                        cancelledAtAdmission = held.isCancelled
                                            && m.capturedACPVoiceTaskForTesting(id: row.id) == held
                                            && !c.hasActiveWork && contextAtEntry?.isStillValid?() == false
                                            && capture.sessionID == session && row.origin == rowAtEntry?.origin
                                    }
                                }
                                // Same actual owner and held peer, through the real voice input producer.
                                RealtimeAgent.shared.userSpeechStarted(); RealtimeAgent.shared.userSpeechEnded()
                                let stopped = await RealtimeAgent.shared.handle("Stop that task.", source: .voice)
                                saved = m.lastPersistenceResult?.primaryCommitted == true
                                    && m.task(id: row.id)?.status == .cancelled
                                check(stopped.reply == "Stopping " + TaskStatusRenderer.title(row.objective) + " now.",
                                      "C26 actual held ACP voice stop reply claimed cessation or lost exact task title")
                            } else { saved = c.cancel(UUID(uuidString: row.id)!, userRequested: true) }
                            let immediateControl = mode == "cancel-held" ? cancelledAtAdmission == true
                                : held.isCancelled && m.capturedACPVoiceTaskForTesting(id: row.id) == held
                                    && !c.hasActiveWork && contextAtEntry?.isStillValid?() == false
                            check(immediateControl,
                                  "F04 explicit voice cancellation did not immediately stop the SAME ACP owner/context")
                            if mode == "cancel-save-refused" {
                                let after = try sql.load(); let afterEvents = try sql.journal(taskID: row.id)
                                let afterExport = try Data(contentsOf: store.storageURL)
                                check(!saved && m.lastPersistenceResult == .sqlFailed && after == before
                                    && afterEvents == beforeEvents && afterExport == beforeExport,
                                    "C16 rejected cancellation changed canonical row/events/export or claimed saved control")
                            } else {
                                let after = try sql.load().first { $0.id == row.id }
                                check(saved && after?.status == .cancelled,
                                      "C17 accepted cancellation did not retain its actual canonical cancelled result")
                            }
                            await held.value; joined = true
                            let primary = try sql.load().first { $0.id == row.id }
                            check(ended && m.capturedACPVoiceTaskForTesting(id: row.id) == nil
                                && !announcements.contains("Owned ACP fixture finished.") && outputQueue.pendingCount == 0 && completionCount == 0
                                && primary?.status == (mode == "cancel-save-refused" ? .running : .cancelled),
                                "C18 actual ACP return restored live owner/success or overwrote refused cancellation")
                        } else {
                        guard await reached({ ended || (mode == "start-refused" && m.task(id: row.id)?.status == .failed) }) else { throw Invalid.timeout }
                        if mode == "available" {
                            let primary = try sql.load().first { $0.id == row.id }; let launched = marker(output)
                            let warnedResult = "Owned ACP fixture finished.\nNext Notes could not independently verify the effect. Inspect the target before retrying."
                            print("VOICE_ACP_TERMINAL_OBSERVATION completed=\(primary?.status == .completed) bareResult=\(primary?.result == "Owned ACP fixture finished.") warnedResult=\(primary?.result == warnedResult) bareAnnouncement=\(announcements.contains("Owned ACP fixture finished.")) warnedAnnouncement=\(announcements.contains(warnedResult)) receipts=\(receipts.receipts.count) receiptTask=\(receipts.receipts.first?.taskID == row.id) receiptAttempt=\(receipts.receipts.first?.taskAttempt == 1) receiptUnverified=\(receipts.receipts.first?.status == .couldNotVerify)")
                            check(backendCalls == 1 && activeAtEntry && rowAtEntry?.status == .running
                                && rowAtEntry?.source == "voice" && rowAtEntry?.origin == row.origin
                                && rowAtEntry?.durability?.attempt == 1 && bindingAtEntry?.attempt == 1
                                && contextAtEntry?.attempt == 1 && contextAtEntry?.isStillValid != nil,
                                "C02 actual voice ACP backend entered without admitted positive attempt")
                            check(launched["launchCount"] as? Int == 1 && launched["promptCount"] as? Int == 1
                                && launched["state"] as? String == "running" && launched["attempt"] as? Int == 1
                                && launched["leaseOwner"] as? String == String(ProcessInfo.processInfo.processIdentifier)
                                && launched["runtimeClass"] as? String == "acpWorker",
                                "C03 actual owned peer lacked exact prelaunch primary binding")
                            check(primary?.status == .completed && primary?.result == warnedResult
                                && announcements.contains(warnedResult) && receipts.receipts.count == 1
                                && receipts.receipts.first?.taskID == row.id && receipts.receipts.first?.taskAttempt == 1
                                && receipts.receipts.first?.status == .couldNotVerify
                                && receipts.receipts.first?.result == "Owned ACP fixture finished.",
                                "C04 actual same-row ACP terminal/receipt/result join did not qualify")
                            check(primary?.delivery == .pending && outputQueue.pendingCount == 1 && completionCount == 1
                                && !VoiceSession.shared.state.activeTasks.contains(TaskID(UUID(uuidString: row.id)!)),
                                "C20 actual ACP result did not enter SAME canonical delivery/event consumer")
                        } else {
                            let refusedPrimary = try sql.load().first { $0.id == row.id }
                            check(backendCalls == 0 && !FileManager.default.fileExists(atPath: output.path)
                                && receipts.receipts.isEmpty && refusedPrimary?.status == .queued,
                                "C05 rejected ACP start admitted backend/peer/receipt or changed queued primary")
                        }
                        }
                        check(m.tasks.count == 1 && !c.hasActiveWork && m.workerBinding(taskID: row.id) == nil,
                              "C06 terminal/refused ACP did not release its same canonical active slot")
                    }
                } else {
                    check(!reply.delegated && m.tasks.isEmpty && localCalls == 0 && backendCalls == 0
                        && ACPConfirmationGate.shared.pending?.utterance == raw
                        && AgentHarnessRouter.shared.lastChoice?.needsACPConfirmation == true,
                        "F03 missing named harness bypassed existing confirmation card (\(mode))")
                    if ACPConfirmationGate.shared.pending != nil {
                        guard await reached({ ACPConfirmationGate.shared.voiceWaiterForTesting == true }) else { throw Invalid.timeout }
                        check(m.tasks.isEmpty && !FileManager.default.fileExists(atPath: output.path),
                              "C07 actual waiting confirmation dispatched before user decision")
                        if mode == "missing-cancel" {
                            check(ACPConfirmationGate.shared.cancel(), "C08 real Cancel did not resolve actual waiter")
                            await Task.yield()
                            check(m.tasks.isEmpty && localCalls == 0 && backendCalls == 0, "C09 cancellation dispatched work")
                        } else if mode == "missing-session-closed" {
                            await capture.endSession(source: .done)
                            _ = ACPConfirmationGate.shared.confirmOnce()
                            await Task.yield()
                            check(m.tasks.isEmpty && localCalls == 0 && backendCalls == 0, "C10 stale confirmed session dispatched work")
                        } else {
                            check(ACPConfirmationGate.shared.confirmOnce(), "C11 Run once did not resolve actual waiter")
                            guard await reached({ localCalls == 1 }) else { throw Invalid.timeout }
                            let primary = try sql.load()
                            check(primary.count == 1 && primary.first?.backend == "local" && primary.first?.source == "voice"
                                && primary.first?.userWords == raw && localCalls == 1 && backendCalls == 0
                                && !FileManager.default.fileExists(atPath: output.path),
                                "C12 explicit Run once did not start exactly one local ledger worker")
                        }
                    }
                }
                // Join the first admitted operation before a later queued subcase
                // replaces its retained handle; this adds no worker/model operation.
                if mode == "available", let operation { await operation.value; joined = true }
                if mode == "available", let owned = m.tasks.first, let origin = owned.origin {
                    let beforeAlternate = try sql.load(); let beforeAlternateExport = try Data(contentsOf: store.storageURL)
                    let beforeChoice = AgentHarnessRouter.shared.lastChoice
                    let alternate = TaskBridge(manager: m)
                    let alternateReceipt = alternate.spawnVoiceObjective(id: UUID(),
                        objective: "Use Claude Code to inspect another owned fixture.", userWords: raw, origin: origin)
                    let afterAlternate = try sql.load(); let afterAlternateExport = try Data(contentsOf: store.storageURL)
                    check(alternateReceipt.status != .accepted && afterAlternate == beforeAlternate
                        && afterAlternateExport == beforeAlternateExport && AgentHarnessRouter.shared.lastChoice == beforeChoice,
                        "F05 alternate Bridge borrowed actual current owner for admission/router/write")
                    let beforeQueued = backendCalls; let beforeCompletions = completionCount
                    let queued = c.spawn(objective: "Use Claude Code to inspect queued owned work.",
                        userWords: raw, origin: origin, backend: .acp)
                    check(queued.status == .accepted && queued.id != nil,
                        "F06 actual public ACP queued admission did not qualify")
                    if queued.status == .accepted {
                        guard let queuedID = queued.id,
                              let queuedTask = m.capturedACPVoiceTaskForTesting(id: queuedID.raw),
                              let queuedUUID = UUID(uuidString: queuedID.raw) else { throw Invalid.task }
                        operation = queuedTask; joined = false
                        check(m.task(id: queuedID.raw)?.status == .queued && backendCalls == beforeQueued
                            && VoiceSession.shared.state.activeTasks.contains(queuedID),
                            "C23 genuine same queued Task entered backend before synchronous cancel")
                        let savedQueued = c.cancel(queuedUUID, userRequested: true)
                        check(savedQueued && queuedTask.isCancelled && m.capturedACPVoiceTaskForTesting(id: queuedID.raw) == queuedTask,
                            "C24 synchronous queued cancel did not preserve SAME Task until return")
                        await queuedTask.value; joined = true
                        let returnedQueued = try sql.load().first { $0.id == queuedID.raw }
                        check(m.capturedACPVoiceTaskForTesting(id: queuedID.raw) == nil
                            && !VoiceSession.shared.state.activeTasks.contains(queuedID)
                            && returnedQueued?.status == .cancelled && backendCalls == beforeQueued
                            && completionCount == beforeCompletions && receipts.receipts.count == 1,
                            "C25 actual queued cancelled return stranded owner/event or launched ACP/receipt/delivery")
                    }
                }
                ACPConfirmationGate.shared.cancel()
                for row in m.tasks where [.queued, .running].contains(row.status) { m.cancel(row.id) }
                if let operation { await operation.value }; operation = nil; joined = true
                if mode == "closed-held", let row = m.tasks.first, let id = UUID(uuidString: row.id) {
                    print("VOICE_ACP_CLOSED_OBSERVATION closed=\(VoiceSession.shared.state.phase == .closed) completed=\(row.status == .completed) slotReleased=\(m.capturedACPVoiceTaskForTesting(id: row.id) == nil) shadowActive=\(VoiceSession.shared.state.activeTasks.contains(TaskID(id)))")
                }
                check(m.tasks.allSatisfy { row in
                    guard let id = UUID(uuidString: row.id) else { return false }
                    return !VoiceSession.shared.state.activeTasks.contains(TaskID(id))
                }, "C21 actual no-start/terminal-return retained a voice active task (\(mode))")
                check(!FileManager.default.fileExists(atPath: output.path) || marker(output)["launchCount"] as? Int == 1,
                      "C13 fixture launched an extra protocol peer")
                print("VOICE_ACP_CASE mode=\(mode) checks=\(checks-begin) local=\(localCalls) backend=\(backendCalls) rows=\(m.tasks.count) peer=\(!marker(output).isEmpty)")
                await capture.endSession(source: .done); c.resetForTesting(); manager = nil
            }
            check(SelfTestStoreGuard.diff(owner, SelfTestStoreGuard.take()).isEmpty, "C14 owner state changed")
        } catch {
            failures.append("voice ACP: INVALID \(error)")
            ACPConfirmationGate.shared.cancel()
            // Collect existing owner handles before cancellation can remove slots.
            // These are retained references to actual Tasks, never new cleanup Tasks.
            var draining: [Task<Void, Never>] = []
            if let operation { draining.append(operation) }
            if let manager {
                for row in manager.tasks {
                    let captured = manager.capturedACPVoiceTaskForTesting(id: row.id)
                        ?? UUID(uuidString: row.id).flatMap({ c.captureVoiceWorkerForTesting(id: $0)?.task })
                    if let captured, !draining.contains(captured) { draining.append(captured) }
                }
                for row in manager.tasks { manager.cancel(row.id) }
            }
            for task in draining { await task.value }
            joined = true
            await capture.endSession(source: .done)
        }
        return (checks, failures)
    }
}

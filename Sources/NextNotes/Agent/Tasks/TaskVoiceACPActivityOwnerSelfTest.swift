import Foundation

/// Mounted voice intake -> SAME generic Manager Task -> real ACP notification -> actual step consumer.
/// This proves admitted activity ownership, not model/tool health or complete active-tool coverage.
@MainActor
enum TaskVoiceACPActivityOwnerSelfTest {
    private enum Invalid: Error { case isolation, root, task, timeout, export }
    private static func reached(_ value: @MainActor () -> Bool) async -> Bool {
        let end = ContinuousClock.now.advanced(by: .seconds(8))
        while ContinuousClock.now < end { if value() { return true }; await Task.yield() }
        return value()
    }
    private static func release(_ url: URL) throws {
        try Data(#"{"release":true}"#.utf8).write(to: url, options: .atomic)
    }
    private static func marker(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }
    static func run() async -> (checks: Int, failures: [String]) {
        let c = VoiceConversationCoordinator.shared; let capture = AgentCaptureController.shared
        let activity = AgentActivityStore.shared
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-voice-work-lifecycle",
              AgentSession.shared.fileURL == nil, !capture.isSessionActive, !c.hasActiveWork,
              PermissionGate.shared.pending == nil, PermissionGate.shared.queuedCount == 0,
              ACPConfirmationGate.shared.pending == nil, activity.activeTaskID == nil,
              activity.voiceProgressObserverForTesting == nil,
              ACPAgentBackend.activityHandledForTesting == nil else {
            return (0, ["voice ACP activity: INVALID foreign owner"])
        }
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let root = temp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard root.path == root.resolvingSymlinksInPath().standardizedFileURL.path,
              root.deletingLastPathComponent().path == temp.path,
              !FileManager.default.fileExists(atPath: root.path) else {
            return (0, ["voice ACP activity: INVALID root"])
        }
        let ownerGuard = SelfTestStoreGuard.take()
        let oldBridge = c.taskBridgeOverrideForTesting; let oldRemember = c.rememberExplicit
        let oldAvailability = AgentHarnessRouter.shared.availabilityProbe
        let speech = AgentSpeechSynthesizer.shared; let speechBacking = RecordingSpeechBacking()
        var checks = 0; var failures: [String] = []; var created = false; var joined = true
        func check(_ value: Bool, _ label: String) {
            checks += 1; if !value { failures.append("voice ACP activity: " + label) }
        }
        defer {
            ACPAgentBackend.activityHandledForTesting = nil
            activity.voiceProgressObserverForTesting = nil; activity.resetForSelfTest()
            c.resetForTesting(); _ = c.installTaskBridgeForTesting(oldBridge); c.rememberExplicit = oldRemember
            AgentHarnessRouter.shared.resetForTesting(); AgentHarnessRouter.shared.availabilityProbe = oldAvailability
            speech.restoreSystemBacking()
            if created && joined { try? FileManager.default.removeItem(at: root) }
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false); created = true
            speech.useTestingBacking(speechBacking)
            for mode in ["accepted", "rejected-save", "export-failed", "fresh-primary-held", "capture-closed"] {
                let begin = checks
                let flow = root.appendingPathComponent(mode, isDirectory: true)
                try FileManager.default.createDirectory(at: flow, withIntermediateDirectories: false)
                let sql = TaskStore(root: flow); defer { sql.close() }
                let export = flow.appendingPathComponent("agent-tasks.json")
                let store = AgentTaskStore(fileURL: export, mirror: sql)
                guard store.allowsHarnessPersistence else { throw Invalid.root }
                let receiptFile = flow.appendingPathComponent("action-receipts.json")
                let receipts = ActionReceiptStore(fileURL: receiptFile)
                let m = AgentTaskManager(store: store, receiptStore: receipts)
                let bridge = TaskBridge(manager: m)
                let script = try TaskACPActivityHeartbeatSelfTest.writeVoiceActivityPeer(root: flow)
                let phase1 = flow.appendingPathComponent("release-phase1.json")
                let phase2 = flow.appendingPathComponent("release-phase2.json")
                let finish = flow.appendingPathComponent("release-result.json")
                let start = Date(timeIntervalSince1970: 1_700_000_000)
                var now = start; var context: TaskJournalContext?; var binding: TaskWorkerBinding?
                var task: Task<Void, Never>?; var entered = 0; var ended = 0; var local = 0
                var callbacks: [(String, Bool?)] = []; var consumed: [String] = []
                var holdingSQL: TaskStore?; var holdingManager: AgentTaskManager?
                defer {
                    store.migrationBoundaryForTesting = nil; holdingSQL?.close()
                    m.backendEntryForTesting = nil; m.backendExitForTesting = nil
                    m.voiceACPArgumentsForTesting = nil; m.progressDateForTesting = nil
                    ACPAgentBackend.activityHandledForTesting = nil
                    activity.voiceProgressObserverForTesting = nil
                }
                m.progressDateForTesting = { now }
                m.voiceACPArgumentsForTesting = { _ in ["acpFixture": script.path] }
                m.backendEntryForTesting = {
                    entered += 1
                    guard let captured = TaskEventJournal.current,
                          let row = m.task(id: captured.taskID) else { throw Invalid.task }
                    context = captured; binding = m.workerBinding(taskID: row.id)
                    if let capturedTask = m.capturedACPVoiceTaskForTesting(id: row.id) {
                        task = capturedTask; joined = false
                    }
                    try JSONSerialization.data(withJSONObject: ["objective": row.objective,
                        "marker": "The owned voice activity fixture finished.", "taskID": row.id,
                        "taskAttempt": captured.attempt, "taskLeaseOwner": captured.leaseOwner ?? "",
                        "phases": 1, "burstCount": 1], options: .sortedKeys)
                        .write(to: flow.appendingPathComponent("config.json"), options: .atomic)
                }
                m.backendExitForTesting = { ended += 1 }
                ACPAgentBackend.activityHandledForTesting = { id, admitted, _ in callbacks.append((id, admitted)) }
                activity.voiceProgressObserverForTesting = { consumed.append($0) }
                c.resetForTesting(); AgentSession.shared.forgetAllConversations(); activity.resetForSelfTest()
                guard c.installTaskBridgeForTesting(bridge) else { throw Invalid.isolation }
                c.rememberExplicit = { _ in }; c.prewarmObserverForTesting = {}
                c.workerForTesting = { _ in local += 1; return "Unexpected local fallback." }
                c.streamForTesting = { _, _ in AsyncThrowingStream { $0.yield("<use_tools/>"); $0.finish() } }
                AgentHarnessRouter.shared.resetForTesting(); AgentHarnessRouter.shared.availabilityProbe = { _ in true }
                do {
                    await capture.beginSession(captureAudio: false)
                    guard let session = capture.sessionID else { throw Invalid.isolation }
                    let raw = "Use Claude Code to describe the owned fixture progress."
                    RealtimeAgent.shared.userSpeechStarted(); RealtimeAgent.shared.userSpeechEnded()
                    _ = await RealtimeAgent.shared.handle(raw, source: .voice)
                    // Retain the actual admitted operation BEFORE every fallible held guard.
                    if task == nil, let admitted = m.tasks.first,
                       let retained = m.capturedACPVoiceTaskForTesting(id: admitted.id)
                        ?? UUID(uuidString: admitted.id).flatMap({ c.captureVoiceWorkerForTesting(id: $0)?.task }) {
                        task = retained; joined = false
                    }
                    guard await reached({ FileManager.default.fileExists(atPath: flow.appendingPathComponent("prompt-observed.json").path) }),
                          let task, let context, let binding,
                          let original = m.task(id: context.taskID) else { throw Invalid.timeout }
                    let id = original.id
                    check(c.taskBridge === bridge && capture.sessionID == session && original.hasVoiceOrigin
                        && original.userWords == raw && original.source == "voice" && original.backend == "acp"
                        && local == 0 && AgentSession.shared.fileURL == nil,
                        "C01 mounted voice/primary/raw provenance (\(mode))")
                    check(entered == 1 && ended == 0 && context.attempt == 1
                        && context.taskID == id && context.leaseOwner == String(ProcessInfo.processInfo.processIdentifier)
                        && context.receiptStore === receipts && context.isStillValid?() == true
                        && m.capturedACPVoiceTaskForTesting(id: id) == task && !task.isCancelled
                        && m.workerBinding(taskID: id) == binding,
                        "C02 exact admitted retained ACP Task/context (\(mode))")
                    check(activity.steps(taskID: id).isEmpty && consumed.isEmpty && callbacks.isEmpty
                        && AgentTaskManager.sharedIfLoaded !== m,
                        "C03 distinct owner/empty actual presentation (\(mode))")
                    let receiptBytes = try Data(contentsOf: receiptFile)
                    check(receipts.receipts.count == 1 && receipts.receipts.first?.status == .fired
                        && receipts.receipts.first?.taskID == id && original.durability?.receiptIDs.count == 1,
                        "C04 actual prepared/fired receipt before notification (\(mode))")
                    let rejected = mode == "rejected-save" || mode == "fresh-primary-held"
                    if mode == "fresh-primary-held" {
                        let fresh = TaskStore(root: flow); holdingSQL = fresh
                        holdingManager = AgentTaskManager(store: AgentTaskStore(fileURL: export, mirror: fresh),
                            receiptStore: ActionReceiptStore(fileURL: receiptFile))
                        guard holdingManager?.task(id: id)?.status == .failed,
                              context.isStillValid?() == false else { throw Invalid.task }
                    }
                    if mode == "capture-closed" { await capture.endSession(source: .done) }
                    if mode == "rejected-save" {
                        try sql.withConnection { try TaskStore.exec($0, "CREATE TRIGGER refuse_voice_activity BEFORE INSERT ON task_event WHEN NEW.kind='heartbeat' BEGIN SELECT RAISE(ABORT,'owned voice activity refusal'); END") }
                    }
                    if mode == "export-failed" {
                        store.migrationBoundaryForTesting = { name in if name == "primaryCommitted" { throw Invalid.export } }
                    }
                    let before = try sql.load(); let events = try sql.journal(taskID: id)
                    let witness = try Data(contentsOf: export); let cached = m.task(id: id)
                    now = start.addingTimeInterval(60)
                    try release(phase1)
                    guard await reached({ callbacks.count == 1 }) else { throw Invalid.timeout }
                    let row = try sql.load().first { $0.id == id }; let journal = try sql.journal(taskID: id)
                    check(callbacks.count == 1 && callbacks.first?.0 == id && callbacks.first?.1 == !rejected
                        && entered == 1 && ended == 0 && m.capturedACPVoiceTaskForTesting(id: id) == task,
                        "C05 actual correct-session callback/held Task (\(mode))")
                    check(try Data(contentsOf: receiptFile) == receiptBytes,
                        "C06 activity must not alter actual fired receipt (\(mode))")
                    if rejected {
                        check(try sql.load() == before && journal == events && Data(contentsOf: export) == witness
                            && m.task(id: id) == cached && consumed.isEmpty && activity.steps(taskID: id).isEmpty,
                            "C07 rejected/stale callback rollback and no presentation (\(mode))")
                    } else {
                        check(row?.durability?.heartbeatAt == now && row?.durability?.lastProgressAt == now
                            && journal.count == events.count + 1 && journal.last?.draft.kind == .heartbeat
                            && journal.last?.draft.detail == "acp.activity" && journal.last?.draft.at == now,
                            "C07 actual same primary activity transaction (\(mode))")
                    }
                    check((mode != "rejected-save" || m.lastPersistenceResult == .sqlFailed)
                        && (mode != "export-failed" || m.lastPersistenceResult == .exportFailed)
                        && (mode != "capture-closed" || (!capture.isSessionActive && !task.isCancelled))
                        && (mode != "fresh-primary-held" || holdingManager?.backendStartsForTesting == 0),
                        "C08 exact refusal/export/capture/held boundaries (\(mode))")
                    let afterWitness = try Data(contentsOf: export)
                    check(mode != "export-failed" || afterWitness == witness,
                        "C09 refused export retains witness after accepted SQL (\(mode))")
                    let steps = activity.steps(taskID: id)
                    check(rejected ? consumed.isEmpty && steps.isEmpty
                        : consumed == [id] && steps.count == 1
                            && steps.first?.title == "Owned fixture phase one 0"
                            && steps.first?.detail == "tool_call_update" && steps.first?.avatar == .tool,
                        "F01 admitted voice ACP activity reaches SAME real step consumer (\(mode))")
                    SelfTest.diagnostic("VOICE_ACP_ACTIVITY_OWNER_TRACE mode=\(mode) callbacks=\(callbacks.count) admitted=\(callbacks.first?.1 == true) consumers=\(consumed.count) steps=\(steps.count) pending=\(ended == 0) closed=\(!capture.isSessionActive)")
                    store.migrationBoundaryForTesting = nil
                    if mode == "rejected-save" { try sql.withConnection { try TaskStore.exec($0, "DROP TRIGGER refuse_voice_activity") } }
                    try release(finish)
                    await task.value; joined = true
                    check(ended == 1 && m.capturedACPVoiceTaskForTesting(id: id) == nil
                        && m.workerBinding(taskID: id) == nil && !FileManager.default.fileExists(atPath: flow.appendingPathComponent("peer-error.json").path),
                        "C10 actual operation return/join/protocol (\(mode))")
                    if capture.isSessionActive { await capture.endSession(source: .done) }
                    c.resetForTesting(); activity.resetForSelfTest()
                    SelfTest.diagnostic("VOICE_ACP_ACTIVITY_OWNER_MODE mode=\(mode) checks=\(checks-begin) joined=\(joined)")
                } catch {
                    // Preserve exact queued/live Task before cancellation removes/replaces a slot.
                    let retained = task ?? m.tasks.compactMap {
                        m.capturedACPVoiceTaskForTesting(id: $0.id)
                            ?? UUID(uuidString: $0.id).flatMap({ c.captureVoiceWorkerForTesting(id: $0)?.task })
                    }.first
                    if let retained { task = retained; joined = false }
                    store.migrationBoundaryForTesting = nil
                    for row in m.tasks { m.cancel(row.id) }
                    try? release(phase1); try? release(phase2); try? release(finish)
                    if let retained { await retained.value; joined = true }
                    if capture.isSessionActive { await capture.endSession(source: .done) }
                    throw error
                }
            }
            check(SelfTestStoreGuard.diff(ownerGuard, SelfTestStoreGuard.take()).isEmpty && PermissionGate.shared.pending == nil
                && PermissionGate.shared.queuedCount == 0 && ACPConfirmationGate.shared.pending == nil,
                "E01 owner isolation/permission unchanged")
        } catch {
            failures.append("voice ACP activity: INVALID \(String(describing: error))")
        }
        return (checks, failures)
    }
}

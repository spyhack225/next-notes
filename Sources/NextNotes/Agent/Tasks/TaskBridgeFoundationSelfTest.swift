import Foundation
import SQLite3

/// Actual Coordinator intake -> same bridge -> Manager -> isolated authoritative SQL.
/// Existing worker seam stands in for model work only; no synthetic durable outcome.
@MainActor
enum TaskBridgeFoundationSelfTest {
    private enum InputError: Error { case unsafe, timeout }
    private static func reached(_ predicate: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if predicate() { return true }
            await Task.yield()
        }
        return predicate()
    }
    private static func canonical(_ rows: [AgentTask]) throws -> [AgentTask] {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([AgentTask].self, from: encoder.encode(rows))
    }
    static func run() async -> (checks: Int, failures: [String]) {
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-voice-work-lifecycle",
              AgentSession.shared.fileURL == nil, PermissionGate.shared.pending == nil else {
            return (0, ["task bridge: isolated lifecycle diagnostic required"])
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextNotesTaskBridge-" + UUID().uuidString, isDirectory: true)
        let safe = root.resolvingSymlinksInPath().standardizedFileURL
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard safe.deletingLastPathComponent().path == temp.path,
              !FileManager.default.fileExists(atPath: root.path) else {
            return (0, ["task bridge: unsafe temporary root"])
        }
        let owner = SelfTestStoreGuard.take()
        var checks = 0; var failures: [String] = []; var projectionChecks = 0
        var activeConversation: VoiceConversationCoordinator?
        var activeTask: Task<Void, Never>?
        var activeTaskID: UUID?
        var drainRelease: (() -> Void)?
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if !value { failures.append("task bridge: " + label) }
        }
        func checkProjection(_ value: Bool, _ label: String) {
            projectionChecks += 1
            check(value, label)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            for mode in ["accepted", "start-rejected", "finish-rejected", "cancel-rejected", "export-failed"] {
                let capture = AgentCaptureController.shared
                if mode == "finish-rejected" || mode == "cancel-rejected" {
                    await capture.beginSession(captureAudio: false)
                    guard capture.sessionID != nil else { throw InputError.unsafe }
                }
                let startChecks = checks
                let directory = root.appendingPathComponent(mode, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                let sql = TaskStore(root: directory)
                defer { sql.close() }
                let file = directory.appendingPathComponent("agent-tasks.json")
                let store = AgentTaskStore(fileURL: file, mirror: sql)
                guard store.allowsHarnessPersistence, store.save([]).primaryCommitted else { throw InputError.unsafe }
                let manager = AgentTaskManager(store: store)
                let bridge = TaskBridge(manager: manager)
                // Active capture/shadow always observes the SAME production owner.
                // Non-session baseline cases retain their isolated object routing.
                let mountedSession = mode == "finish-rejected" || mode == "cancel-rejected"
                let conversation = mountedSession ? VoiceConversationCoordinator.shared : VoiceConversationCoordinator()
                let priorBridge = conversation.taskBridgeOverrideForTesting
                if mountedSession { conversation.resetForTesting() }
                defer { _ = conversation.installTaskBridgeForTesting(priorBridge) }
                activeConversation = conversation
                func input(_ words: String) async -> AgentTurn {
                    if mountedSession {
                        let agent = RealtimeAgent.shared
                        agent.userSpeechStarted()
                        agent.userSpeechEnded()
                        return await agent.handle(words, source: .voice)
                    }
                    return await conversation.handle(words)
                }
                guard conversation.installTaskBridgeForTesting(bridge) else { throw InputError.unsafe }
                var entered = 0; var ended = 0; var warmups = 0; var announcements: [String] = []
                var release: CheckedContinuation<String, Never>?
                drainRelease = { release?.resume(returning: "Owned invalid cleanup."); release = nil }
                var currentOwner = 0; var cancelled = false; var effectAllowed = true; var generationCurrent = true
                var capturedWork: VoiceConversationWork?
                var capturedWorker: RealtimeAgent?
                func currentCapture() -> VoiceWorkerTestCapture? {
                    guard let id = capturedWork?.id else { return nil }
                    return conversation.captureVoiceWorkerForTesting(id: id)
                }
                let frontend = TaskBridgeFrontendProbe()
                conversation.rememberExplicit = { _ in }
                conversation.prewarmObserverForTesting = { warmups += 1 }
                conversation.streamForTesting = { _, messages in await frontend.stream(messages) }
                conversation.workerForTesting = { work in
                    entered += 1; capturedWork = work
                    capturedWorker = currentCapture()?.worker
                    if let worker = capturedWorker { currentOwner = worker.currentGeneration }
                    let result = await withCheckedContinuation { release = $0 }
                    cancelled = Task.isCancelled
                    effectAllowed = await conversation.mayCommitEffect()
                    generationCurrent = capturedWorker?.isCurrent(currentOwner) == true
                    ended += 1
                    return result
                }
                manager.announcementForTesting = { announcements.append($0) }
                if mode == "start-rejected" {
                    try sql.withConnection { try TaskStore.exec($0, "CREATE TRIGGER refuse_voice_start BEFORE INSERT ON task BEGIN SELECT RAISE(ABORT,'owned voice intake rejection'); END") }
                }
                if mode == "export-failed" {
                    store.migrationBoundaryForTesting = { if $0 == "primaryCommitted" { throw InputError.unsafe } }
                }
                let startRows = try sql.load(); let startBytes = try Data(contentsOf: file)
                let response = await input("Open Safari.")
                activeTask = currentCapture()?.task; activeTaskID = capturedWork?.id
                await Task.yield()
                let intakeFrontendCalls = await frontend.calls
                print("TASK_BRIDGE_INTAKE mode=\(mode) replyOnIt=\(response.reply == "I'm on it.") replyNotStarted=\(response.reply == "I couldn't save that task, so I haven't started it.") replyHaiku=\(response.reply == "A haiku is a short poem.") delegated=\(response.delegated) jobs=\(bridge.cachedTasks.filter { $0.source == "voice" }.count) entered=\(entered) ended=\(ended) warmups=\(warmups) frontendCalls=\(intakeFrontendCalls)")
                if mode == "start-rejected" {
                    check(entered == 0 && bridge.cachedTasks.filter { $0.source == "voice" }.isEmpty && !conversation.hasActiveWork,
                        "F01 refused primary intake started worker (\(mode))")
                    let refusedStartRows = try sql.load()
                    check(manager.tasks == startRows && refusedStartRows == startRows,
                        "F02 refused primary intake left a ghost ledger row")
                    check(response.reply == "I couldn't save that task, so I haven't started it.",
                        "F03 refused intake promised work to the user")
                    let refusedStartExport = try Data(contentsOf: file)
                    check(announcements.isEmpty && refusedStartExport == startBytes,
                        "C01 refused intake altered export or announced result")
                    // On original only, stop and join the actual incorrectly-started SAME Task.
                    if let job = currentCapture() {
                        guard await reached({ release != nil }), let task = job.task else { throw InputError.timeout }
                        conversation.cancel(job.id)
                        release?.resume(returning: "Owned rejected-start reply."); release = nil
                        await task.value
                    }
                    conversation.resetForTesting()
                    check(entered == ended && announcements.isEmpty, "C02 rejected intake cleanup did not join its actual worker")
                } else {
                    guard await reached({ release != nil }), let job = currentCapture(),
                          let workerTask = job.task, let work = capturedWork else { throw InputError.timeout }
                    activeTask = workerTask; activeTaskID = job.id
                    check(entered == 1 && ended == 0 && work.id == job.id && warmups == 1,
                        "C03 actual admitted worker identity/prewarm changed (\(mode))")
                    let running = try sql.load()
                    check(running.count == 1 && running[0].id == job.id.uuidString
                        && running[0].source == "voice" && running[0].status == .running,
                        "C04 worker did not receive one admitted canonical row (\(mode))")
                    check(bridge.record(TaskID(job.id))?.id == job.id.uuidString && bridge.record(TaskID(job.id))?.status == .running,
                        "F04 bridge/job did not project the canonical admitted row (\(mode))")
                    let callsBeforeStatus = await frontend.calls
                    let memoryBeforeStatus = manager.tasks
                    let exportBeforeStatus = try Data(contentsOf: file)
                    let eventsBeforeStatus = try sql.journal(taskID: job.id.uuidString)
                    let statusReply = await input("What is the status of that task?")
                    let callsAfterStatus = await frontend.calls
                    let statusTitle = TaskStatusRenderer.title(work.original)
                    let namedStatusPattern = "^Still on " + NSRegularExpression.escapedPattern(for: statusTitle)
                        + ", (just started|about [0-9]+ seconds in|about [0-9]+ minutes in|start time unavailable)\\.$"
                    let legacyStatusCopy = statusReply.reply == "I'm working on that."
                    let namedStatusCopy = statusReply.reply.range(of: namedStatusPattern, options: .regularExpression) != nil
                    let currentStatusCopy = (legacyStatusCopy || namedStatusCopy) && callsAfterStatus == callsBeforeStatus
                    // These original private-Coordinator fixtures intentionally have no
                    // current voice origin; an indexed status may not borrow a session.
                    let unboundScope = running.count == 1 && running[0].origin == nil && !mountedSession
                    let unboundStatusCopy = unboundScope && statusReply.reply == "A haiku is a short poem."
                        && callsAfterStatus == callsBeforeStatus + 1
                    let rowsAfterStatus = try sql.load()
                    let eventsAfterStatus = try sql.journal(taskID: job.id.uuidString)
                    let exportAfterStatus = try Data(contentsOf: file)
                    let statusMetadataUnchanged = rowsAfterStatus == running && manager.tasks == memoryBeforeStatus
                        && eventsAfterStatus == eventsBeforeStatus && exportAfterStatus == exportBeforeStatus
                    print("VOICE_STATUS_COPY scope=bridgeRunning mode=\(mode) legacy=\(legacyStatusCopy) named=\(namedStatusCopy) sameCalls=\(callsAfterStatus == callsBeforeStatus) originNil=\(running.first?.origin == nil) mounted=\(mountedSession) unbound=\(unboundStatusCopy) metadataUnchanged=\(statusMetadataUnchanged)")
                    check((currentStatusCopy || unboundStatusCopy) && statusMetadataUnchanged
                        && entered == 1 && ended == 0,
                        "F08 current status ask used model or missed canonical progress (\(mode))")
                    if mode == "finish-rejected" || mode == "cancel-rejected" {
                        try sql.withConnection { try TaskStore.exec($0,
                            "CREATE TRIGGER refuse_voice_terminal BEFORE UPDATE ON task WHEN NEW.state IN ('completed','cancelled') BEGIN SELECT RAISE(ABORT,'owned voice terminal rejection'); END") }
                    }
                    let beforeBytes = try Data(contentsOf: file); let beforeEvents = try sql.journal(taskID: job.id.uuidString)
                    if mode == "cancel-rejected" {
                        let cancelReply = await input("Cancel the task.")
                        check(workerTask.isCancelled && capturedWorker?.isCurrent(currentOwner) == false,
                            "C05 failed cancellation persistence left worker/effect generation live")
                        check(bridge.record(TaskID(job.id))?.status == .running && workerTask.isCancelled && !conversation.hasActiveWork,
                            "F05 failed cancel save invented durable cancelled state")
                        let legacyCancelCopy = cancelReply.reply == "I stopped that task, but couldn't save its status." || cancelReply.reply == "I'm stopping that task, but couldn't save its status."
                        let namedCancelCopy = cancelReply.reply == "Stopping \(statusTitle) now. I couldn't save its status."
                        print("VOICE_STATUS_COPY scope=bridgeRefusedCancel legacy=\(legacyCancelCopy) named=\(namedCancelCopy) sameTaskCancelled=\(workerTask.isCancelled)")
                        check(legacyCancelCopy || namedCancelCopy,
                            "F06 failed cancel persistence was hidden from user")
                    }
                    if mode == "cancel-rejected" {
                        _ = await input("What is a haiku?")
                        let package = await frontend.lastPackage
                        checkProjection(package.contains("[stopping]") || package.contains("[Stopped; saved status uncertain]") || package.contains("[Stopping; saved status uncertain]"),
                            "C15 actual failed-cancel frontend falsely described working task")
                        let rowsAtControl = try sql.load()
                        checkProjection(rowsAtControl == running && workerTask.isCancelled && entered == 1 && ended == 0,
                            "C16 failed-cancel projection changed canonical status or failed to observe same pending task")
                    }
                    release?.resume(returning: "Owned final reply."); release = nil
                    await workerTask.value; activeTask = nil
                    check(entered == 1 && ended == 1, "C06 exact worker did not end once (\(mode))")
                    let afterRows = try sql.load(); let afterEvents = try sql.journal(taskID: job.id.uuidString)
                    if mode == "finish-rejected" || mode == "cancel-rejected" {
                        let canonicalMemory = try canonical(manager.tasks)
                        check(afterRows == running && canonicalMemory == running && afterEvents == beforeEvents,
                            "C07 rejected terminal admission changed canonical history (\(mode))")
                        let expectedAnnouncements = mode == "finish-rejected"
                            ? ["The work finished, but I couldn't save its result."] : []
                        check(announcements == expectedAnnouncements && bridge.record(TaskID(job.id))?.result?.isEmpty != false
                            && bridge.record(TaskID(job.id))?.status != .completed,
                            "F07 rejected terminal save delivered a successful result (\(mode))")
                        check((try Data(contentsOf: file)) == beforeBytes,
                            "C08 rejected terminal admission changed retained export (\(mode))")
                    } else {
                        check(afterRows[0].status == .completed && afterRows[0].result == "Owned final reply."
                            && bridge.record(TaskID(job.id))?.status == .completed && bridge.record(TaskID(job.id))?.result == afterRows[0].result
                            && announcements == ["Owned final reply."],
                            "C09 committed terminal result was not consumed exactly once (\(mode))")
                        check(mode != "export-failed" || manager.lastPersistenceResult == .exportFailed,
                            "C10 accepted SQL/export failure incorrectly revoked success")
                    }
                    if mode == "cancel-rejected" {
                        check(cancelled && !effectAllowed && !generationCurrent,
                            "C11 same cancelled worker admitted a later consequential effect")
                    } else {
                        check(!cancelled && effectAllowed && generationCurrent,
                            "C12 healthy worker was unexpectedly cancelled (\(mode))")
                    }
                    if mode == "finish-rejected" {
                        _ = await input("What is a haiku?")
                        let package = await frontend.lastPackage
                        checkProjection(package.contains("[unfinished]") || package.contains("[Finished; saved status uncertain]"),
                            "C17 actual returned-worker frontend falsely described working task")
                        let rowsAtControl = try sql.load()
                        checkProjection(rowsAtControl == running && conversation.captureVoiceWorkerForTesting(id: job.id)?.task == nil && entered == 1 && ended == 1,
                            "C18 returned-worker projection changed canonical status or restarted work")
                    }
                    let retainedRows = try sql.load(); let retainedJournal = try sql.journal(taskID: job.id.uuidString)
                    let retainedExport = try Data(contentsOf: file)
                    for _ in 0..<8 { _ = bridge.record(TaskID(job.id)); _ = bridge.taskRecord(TaskID(job.id)); _ = bridge.record(TaskID(job.id))?.result }
                    let projectedRows = try sql.load(); let projectedJournal = try sql.journal(taskID: job.id.uuidString)
                    let projectedExport = try Data(contentsOf: file)
                    check(projectedRows == retainedRows && projectedJournal == retainedJournal
                        && projectedExport == retainedExport && entered == 1,
                        "C13 repeated canonical status projection mutated history or restarted worker (\(mode))")
                    conversation.resetForTesting()
                }
                if mode == "finish-rejected" || mode == "cancel-rejected" {
                    await capture.endSession(source: .done)
                }
                activeConversation = nil; activeTask = nil; activeTaskID = nil; drainRelease = nil
                print("TASK_BRIDGE_TRACE mode=\(mode) checks=\(checks-startChecks) entered=\(entered) ended=\(ended) announcements=\(announcements.count)")
            }
            check(SelfTestStoreGuard.diff(owner, SelfTestStoreGuard.take()).isEmpty,
                "C14 changed owner stores/defaults/grants")
        } catch {
            // Same actual existing Task only, no cleanup waiter or invented result.
            if let conversation = activeConversation {
                let task = activeTask
                if let id = activeTaskID { conversation.cancel(id) }
                drainRelease?()
                if let task { await task.value }
                conversation.resetForTesting()
            }
            failures.append("task bridge: INVALID actual input/control: \(error)")
        }
        print("TASK_BRIDGE_CONTROL_PROJECTION_CHECKS=\(projectionChecks)")
        print("TASK_BRIDGE_RESULT checks=\(checks) problems=\(failures.count)")
        return (checks, failures)
    }
}

private actor TaskBridgeFrontendProbe {
    private(set) var calls = 0
    private(set) var lastPackage = ""
    func stream(_ messages: [LLMChatMessage]) -> AsyncThrowingStream<String, Error> {
        calls += 1
        lastPackage = messages.last?.content ?? ""
        // Only the actual authoritative current-input package selects work. A status
        // request remains answer prose, so original cannot accidentally spawn twice.
        let currentWork = messages.last?.role == .user
            && messages.last?.content.hasSuffix("Latest user speech:\nOpen Safari.") == true
        let response = currentWork ? "<use_tools/>" : "<answer/>A haiku is a short poem."
        return AsyncThrowingStream { $0.yield(response); $0.finish() }
    }
}

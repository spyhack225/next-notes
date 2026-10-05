import Foundation
import SQLite3

/// Same real RTA/capture -> streamed decision -> Bridge -> isolated SQL ->
/// retained Manager Task in both versions. External model/worker output only is
/// scripted. These controls supply no account, native model or physical proof.
@MainActor
enum FrontendControlSchemaSelfTest {
    private enum Invalid: Error { case scope, worker, cleanup }
    @MainActor private final class Probe {
        var output = "<decision>{\"intent\":\"spawn\",\"objective\":\"Arrange the owned itinerary.\"}</decision>"
        var frontendCalls = 0
        var messages: [LLMChatMessage] = []
        var entered: [UUID] = []
        var held: [UUID: CheckedContinuation<String, Never>] = [:]
        var cleanup = false
        func stream(_ messages: [LLMChatMessage]) -> AsyncThrowingStream<String, Error> {
            frontendCalls += 1; self.messages = messages
            let chunk = output
            return AsyncThrowingStream { continuation in
                let middle = chunk.index(chunk.startIndex, offsetBy: chunk.count / 2)
                continuation.yield(String(chunk[..<middle])); continuation.yield(String(chunk[middle...]))
                continuation.finish()
            }
        }
        func worker(_ work: VoiceConversationWork) async -> String {
            entered.append(work.id)
            if cleanup { return "" }
            return await withCheckedContinuation { held[work.id] = $0 }
        }
        func releaseAll() {
            cleanup = true
            let values = Array(held.values); held.removeAll()
            for continuation in values { continuation.resume(returning: "The owned itinerary result.") }
        }
    }
    private static func reached(_ predicate: @MainActor () -> Bool) async -> Bool {
        let until = ContinuousClock.now.advanced(by: .seconds(8))
        while ContinuousClock.now < until { if predicate() { return true }; await Task.yield() }
        return predicate()
    }
    static func run() async -> (checks: Int, failures: [String]) {
        let conversation = VoiceConversationCoordinator.shared, capture = AgentCaptureController.shared
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-voice-turn-routing",
              AgentSession.shared.fileURL == nil, !capture.isSessionActive, !conversation.hasActiveWork,
              PermissionGate.shared.pending == nil, PermissionGate.shared.queuedCount == 0 else {
            return (0, ["frontend schemas: INVALID scope"])
        }
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let root = temp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard root.path == root.resolvingSymlinksInPath().standardizedFileURL.path,
              root.deletingLastPathComponent().path == temp.path,
              !FileManager.default.fileExists(atPath: root.path) else { return (0, ["frontend schemas: INVALID root"]) }
        let oldBridge = conversation.taskBridgeOverrideForTesting, oldRemember = conversation.rememberExplicit
        let synth = AgentSpeechSynthesizer.shared, recording = RecordingSpeechBacking()
        let owner = SelfTestStoreGuard.take()
        var manager: AgentTaskManager?, probe: Probe?
        var retained: [Task<Void, Never>] = []
        var created = false, safeCleanup = true, sessionOwned = false
        var checks = 0, failures: [String] = []
        func check(_ value: Bool, _ label: String) { checks += 1; if !value { failures.append("frontend schemas: " + label) } }
        func retain() {
            guard let manager else { return }
            for row in manager.tasks {
                if let id = UUID(uuidString: row.id), let task = conversation.captureVoiceWorkerForTesting(id: id)?.task,
                   !retained.contains(task) { retained.append(task) }
            }
        }
        func input(_ words: String) async -> AgentTurn {
            RealtimeAgent.shared.userSpeechStarted(); RealtimeAgent.shared.userSpeechEnded()
            return await RealtimeAgent.shared.handle(words, source: .voice)
        }
        func drain() {
            for _ in 0..<32 where synth.voiceLifecycleSnapshot.hasClause || synth.pendingClauseCount > 0 {
                let token = synth.currentPlaybackToken
                synth.notifyTestingFirstAudio(token: token)
                recording.finishNaturallyForTesting(); synth.notifyTestingAudioFinished(token: token)
            }
        }
        defer {
            conversation.resetForTesting(); _ = conversation.installTaskBridgeForTesting(oldBridge)
            conversation.rememberExplicit = oldRemember; synth.restoreSystemBacking()
            if created && safeCleanup { try? FileManager.default.removeItem(at: root) }
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false); created = true
            synth.useTestingBacking(recording)
            let modes = ["spawn", "spawn-refused", "status-one", "status-all", "status-invalid", "cancel-one", "cancel-newest", "cancel-invalid", "cancel-refused", "approval-unoffered", "extra-argument", "unknown-control"]
            for mode in modes {
                let start = checks
                let directory = root.appendingPathComponent(mode, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                let sql = TaskStore(root: directory); defer { sql.close() }
                let file = directory.appendingPathComponent("agent-tasks.json")
                let store = AgentTaskStore(fileURL: file, mirror: sql)
                guard store.allowsHarnessPersistence, store.save([]).primaryCommitted else { throw Invalid.scope }
                let current = AgentTaskManager(store: store); manager = current
                let bridge = TaskBridge(manager: current), state = Probe(); probe = state
                retained = []; conversation.resetForTesting(); AgentSession.shared.forgetAllConversations()
                guard conversation.installTaskBridgeForTesting(bridge) else { throw Invalid.scope }
                conversation.rememberExplicit = { _ in }; conversation.prewarmObserverForTesting = {}
                conversation.streamForTesting = { _, messages in await state.stream(messages) }
                conversation.workerForTesting = { work in await state.worker(work) }
                await capture.beginSession(captureAudio: false); sessionOwned = true
                guard let session = capture.sessionID else { throw Invalid.scope }
                let seeds = mode.hasPrefix("status-") || mode.hasPrefix("cancel-") ? 2 : 0
                var admissionIDs: [UUID] = []
                for number in 1...max(seeds, 1) where seeds > 0 {
                    let objective = "Arrange the owned itinerary \(number)."
                    state.output = try FrontendDecisionPayload(intent: "spawn", objective: objective).controlChunk()
                    safeCleanup = false
                    let seed = await input(objective); retain()
                    guard seed.reply == ReceiptAck.fallback, await reached({ state.held.count == number }),
                          let id = current.tasks.first.flatMap({ UUID(uuidString: $0.id) }) else { throw Invalid.worker }
                    admissionIDs.append(id); drain()
                }
                let before = try sql.load(); let beforeBytes = try Data(contentsOf: file)
                let indexedBefore = bridge.indexedSessionTasks(session)
                let calls = state.frontendCalls, entered = state.entered.count
                if mode == "spawn-refused" {
                    try sql.withConnection { try TaskStore.exec($0, "CREATE TRIGGER refuse_schema_spawn BEFORE INSERT ON task BEGIN SELECT RAISE(ABORT,'owned refusal'); END") }
                }
                if mode == "cancel-refused" {
                    try sql.withConnection { try TaskStore.exec($0, "CREATE TRIGGER refuse_schema_cancel BEFORE UPDATE ON task WHEN NEW.state='cancelled' BEGIN SELECT RAISE(ABORT,'owned refusal'); END") }
                }
                let value: FrontendDecisionPayload
                switch mode {
                case "spawn", "spawn-refused": value = .init(intent: "spawn_task", objective: "Arrange the owned itinerary.", acknowledgement: "Arranging the owned itinerary.")
                case "status-one": value = .init(intent: "task_status", task: 2)
                case "status-all": value = .init(intent: "task_status")
                case "status-invalid": value = .init(intent: "task_status", task: 99)
                case "cancel-one", "cancel-refused": value = .init(intent: "cancel_task", task: 1)
                case "cancel-newest": value = .init(intent: "cancel_task")
                case "cancel-invalid": value = .init(intent: "cancel_task", task: 99)
                case "approval-unoffered": value = .init(intent: "respond_approval", decision: "approve")
                case "extra-argument": value = .init(intent: "task_status", objective: "Run a write.")
                default: value = .init(intent: "send_email")
                }
                state.output = try value.controlChunk()
                safeCleanup = false
                let raw = mode.hasPrefix("spawn") ? "Arrange the owned itinerary."
                    : mode.hasPrefix("cancel") ? "Please end the selected work item."
                    : mode.hasPrefix("status") ? "Tell me about the second work item."
                    : "Explain the available choice to me."
                let turn = await input(raw); retain()
                if mode == "spawn", !current.tasks.isEmpty { guard await reached({ state.held.count == 1 }) else { throw Invalid.worker } }
                let after = try sql.load(); let afterBytes = try Data(contentsOf: file)
                check(state.frontendCalls == calls + 1, "C01 one actual frontend invocation (\(mode))")
                check(seeds == 0 || (before.count == 2 && admissionIDs.count == 2 && entered == 2), "C02 actual held task seed qualification (\(mode))")
                let context = state.messages.last(where: { $0.role == .user })?.content ?? ""
                let schemaNames = ["spawn_task", "task_status", "cancel_task"]
                check(schemaNames.allSatisfy(context.contains) && !context.contains("respond_approval"), "F01 actual route caller did not receive exact available schemas (\(mode))")
                check(state.entered.count == entered + (mode == "spawn" ? 1 : 0), "F02 control dispatched missing or extra actual worker (\(mode))")
                switch mode {
                case "spawn":
                    check(current.tasks.count == 1 && current.tasks.first?.objective == raw && current.tasks.first?.userWords == raw && turn.reply == "Arranging the owned itinerary.", "F03 actual schema spawn receipt/objective/raw acknowledgement")
                case "spawn-refused":
                    check(current.tasks.isEmpty && after == before && turn.reply == "I couldn't save that task, so I haven't started it.", "F03 rejected primary schema spawn dispatched or claimed success")
                case "status-one", "status-all":
                    check(turn.reply == bridge.statusReply(mode == "status-one" ? bridge.indexedSessionTasks(session).dropFirst().first?.id : nil, sessionID: session), "F03 real schema status did not consume exact current cached row")
                case "cancel-one", "cancel-newest", "cancel-refused":
                    let selected = mode == "cancel-newest" ? admissionIDs.last! : UUID(uuidString: indexedBefore.first!.id.raw)!
                    let capture = conversation.captureVoiceWorkerForTesting(id: selected)
                    check(capture?.task?.isCancelled == true && turn.reply.hasPrefix("I'm stopping that task."), "F03 cancellation did not retain same requested Task or reported cessation")
                case "status-invalid", "cancel-invalid":
                    check(after == before && afterBytes == beforeBytes && !turn.reply.isEmpty, "C03 out-of-range control mutated history")
                default:
                    check(after == before && afterBytes == beforeBytes && state.entered.count == entered, "C03 unsupported or extra argument reached an effect")
                }
                if mode == "cancel-refused" {
                    check(after == before && afterBytes == beforeBytes && current.lastPersistenceResult == .sqlFailed && turn.reply.contains("couldn't save"), "F04 refused cancel must revoke same Task but retain primary/history and uncertainty")
                } else {
                    check(mode.hasPrefix("cancel") && !mode.hasSuffix("invalid") || mode == "spawn" || (after == before && afterBytes == beforeBytes), "C04 read/control refusal preserved history (\(mode))")
                }
                check(PermissionGate.shared.pending == nil && PermissionGate.shared.queuedCount == 0, "C05 no fabricated approval or permission owner (\(mode))")
                state.releaseAll(); for task in retained { await task.value }
                check(current.tasks.allSatisfy { row in guard let id = UUID(uuidString: row.id) else { return false }; return conversation.captureVoiceWorkerForTesting(id: id)?.task == nil }, "C06 same worker Tasks all returned (\(mode))")
                safeCleanup = true; retained = []; drain()
                print("FRONTEND_SCHEMA_CASE mode=\(mode) checks=\(checks-start) streams=\(state.frontendCalls-calls) entered=\(state.entered.count-entered) held=\(state.held.count) owned=true physical=false")
                await capture.endSession(source: .done); sessionOwned = false
                conversation.resetForTesting(); manager = nil; probe = nil
            }
            let full = AgentCapabilityManifest.frontendControlSchemas(approvalOffered: true)
            check(full.map(\.name.rawValue) == FrontendToolContract.Name.allCases.map(\.rawValue)
                  && full.allSatisfy { !$0.parameters.additionalProperties }, "F05 canonical four closed schemas absent")
            check(SelfTestStoreGuard.diff(owner, SelfTestStoreGuard.take()).isEmpty, "C07 owner files/default invariant")
        } catch {
            failures.append("frontend schemas: INVALID \(error)")
            retain()
            if let manager { for row in manager.tasks { if let id = UUID(uuidString: row.id) { _ = conversation.cancel(id) } } }
            probe?.releaseAll(); for task in retained { await task.value }
            safeCleanup = manager?.tasks.allSatisfy { row in guard let id = UUID(uuidString: row.id) else { return false }; return conversation.captureVoiceWorkerForTesting(id: id)?.task == nil } ?? true
            if !safeCleanup { failures.append("frontend schemas: INVALID worker drain; root retained") }
            if sessionOwned { await capture.endSession(source: .done) }
        }
        return (checks, failures)
    }
}

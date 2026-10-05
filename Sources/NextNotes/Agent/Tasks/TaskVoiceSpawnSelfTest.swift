import Foundation
import SQLite3

/// Actual voice intake and public spawn -> SAME canonical Bridge/Manager admission.
/// The external scripted provider and read-only temporary backing are the only fakes.
@MainActor
enum TaskVoiceSpawnSelfTest {
    private enum Invalid: Error { case unsafe, ownership, worker, shape }
    private static func reached(_ predicate: @MainActor () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while ContinuousClock.now < deadline {
            if await predicate() { return true }
            await Task.yield()
        }
        return await predicate()
    }
    static func run() async -> (checks: Int, failures: [String]) {
        let conversation = VoiceConversationCoordinator.shared
        let capture = AgentCaptureController.shared
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-voice-work-lifecycle",
              AgentSession.shared.fileURL == nil, !capture.isSessionActive,
              PermissionGate.shared.pending == nil, PermissionGate.shared.queuedCount == 0,
              conversation.taskBridge.cachedTasks.allSatisfy({ row in UUID(uuidString: row.id).flatMap { conversation.captureVoiceWorkerForTesting(id: $0) } == nil }) else { return (0, ["voice spawn: INVALID isolated lifecycle required"]) }
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let root = temp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard root.standardizedFileURL.path == root.resolvingSymlinksInPath().standardizedFileURL.path,
              root.deletingLastPathComponent().path == temp.path,
              !FileManager.default.fileExists(atPath: root.path) else { return (0, ["voice spawn: INVALID unsafe root"]) }
        let priorBridge = conversation.taskBridgeOverrideForTesting
        let oldRemember = conversation.rememberExplicit
        let oldFake = AgentToolExecutor.fakeForTesting
        let oldFire = AgentToolExecutor.fireOverrideForTesting
        let oldPolicy = AgentToolExecutor.policyOverrideForTesting
        let oldInputs = AgentCapabilityManifestBuilder.inputsOverrideForTesting
        let oldWhole = PlannerBackends.wholeTurnOverrideForTesting
        let oldNeedle = ToolLoopLiveEval.needleFirstForTesting
        let owner = SelfTestStoreGuard.take()
        var ownedTasks: [Task<Void, Never>] = []
        var probe: VoiceSpawnProbe?
        var rootCreated = false
        var checks = 0; var failures: [String] = []
        func check(_ value: Bool, _ label: String) {
            checks += 1; if !value { failures.append("voice spawn: " + label) }
        }
        func input(_ text: String) async -> AgentTurn {
            RealtimeAgent.shared.userSpeechStarted(); RealtimeAgent.shared.userSpeechEnded()
            return await RealtimeAgent.shared.handle(text, source: .voice)
        }
        defer {
            conversation.resetForTesting()
            _ = conversation.installTaskBridgeForTesting(priorBridge)
            conversation.rememberExplicit = oldRemember
            AgentToolExecutor.fakeForTesting = oldFake
            AgentToolExecutor.fireOverrideForTesting = oldFire
            AgentToolExecutor.policyOverrideForTesting = oldPolicy
            AgentCapabilityManifestBuilder.inputsOverrideForTesting = oldInputs
            PlannerBackends.wholeTurnOverrideForTesting = oldWhole
            ToolLoopLiveEval.needleFirstForTesting = oldNeedle
            if rootCreated { try? FileManager.default.removeItem(at: root) }
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false); rootCreated = true
            AgentToolExecutor.fakeForTesting = nil
            AgentCapabilityManifestBuilder.inputsOverrideForTesting = RealtimeAgentToolLoopSelfTest.allEnabledFixture()
            PlannerBackends.wholeTurnOverrideForTesting = nil
            ToolLoopLiveEval.needleFirstForTesting = false
            for mode in ["duplicate-held", "duplicate-terminal", "different-turn", "different-objective", "approval-pending", "start-refused", "foreign-session"] {
                let startChecks = checks
                let directory = root.appendingPathComponent(mode, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                let text = "Owned spawn bytes " + UUID().uuidString
                let target = directory.appendingPathComponent("owned.txt")
                try Data(text.utf8).write(to: target)
                let sql = TaskStore(root: directory); defer { sql.close() }
                let file = directory.appendingPathComponent("agent-tasks.json")
                let store = AgentTaskStore(fileURL: file, mirror: sql)
                guard store.allowsHarnessPersistence, store.save([]).primaryCommitted else { throw Invalid.unsafe }
                let manager = AgentTaskManager(store: store)
                let bridge = TaskBridge(manager: manager)
                conversation.resetForTesting(); AgentSession.shared.forgetAllConversations()
                guard conversation.installTaskBridgeForTesting(bridge) else { throw Invalid.unsafe }
                await capture.beginSession(captureAudio: false)
                guard let session = capture.sessionID else { throw Invalid.ownership }
                let request = mode == "approval-pending"
                    ? "Inspect the current window and press escape for the owned spawn case."
                    : "Inspect the owned spawn document for " + mode + "."
                let state = VoiceSpawnProbe(request: request, target: target.path, contents: text,
                                            permission: mode == "approval-pending")
                probe = state
                var warmups = 0; var reads = 0; var keypresses = 0
                conversation.rememberExplicit = { _ in }
                conversation.prewarmObserverForTesting = { warmups += 1 }
                conversation.workerForTesting = nil
                conversation.workerProviderForTesting = VoiceSpawnProvider(probe: state)
                conversation.streamForTesting = { _, messages in await state.frontend(messages) }
                AgentToolExecutor.policyOverrideForTesting = mode == "approval-pending" ? .denyMutations : .selfTest
                AgentToolExecutor.fireOverrideForTesting = { tool, arguments in
                    if tool.id == "computer.press_key" { keypresses += 1; throw Invalid.unsafe }
                    guard tool.id == "filesystem.read", arguments["path"] == target.path,
                          target.standardizedFileURL.path == target.resolvingSymlinksInPath().standardizedFileURL.path else { throw Invalid.unsafe }
                    reads += 1
                    return try FilesystemExecutor.run(tool, arguments: arguments)
                }
                let accepted = await input(request)
                ownedTasks = conversation.taskBridge.cachedTasks.compactMap { row in UUID(uuidString: row.id).flatMap { conversation.captureVoiceWorkerForTesting(id: $0) }?.task }
                guard await reached({ await state.heldCount == 1 }), let first = conversation.taskBridge.cachedTasks.first.flatMap { UUID(uuidString: $0.id) }.flatMap { conversation.captureVoiceWorkerForTesting(id: $0) },
                      let firstTask = first.task, let row = manager.task(id: first.id.uuidString),
                      case .voice(let rowSession, let turn)? = row.origin else { throw Invalid.worker }
                check(accepted.reply == "I'm on it." && rowSession == session && row.status == .running
                    && conversation.taskBridge.cachedTasks.count == 1 && ownedTasks.count == 1 && warmups == 1,
                    "C01 actual receipt-first intake/current primary/worker did not qualify (\(mode))")
                guard let reader = AgentCapabilityManifestRuntime.publishedReader else { throw Invalid.shape }
                let manifest = AgentCapabilityManifestBuilder.build(.live(reader: reader), request: first.work.original,
                    previousRequest: AgentSession.shared.recentUserTexts(limit: 2).dropLast().last)
                let call = try state.call()
                let parsed = AgentToolCallParser.parse(call, knownNames: RealtimeAgent.callNames(manifest))
                let expectedTool = mode == "approval-pending" ? "computer.press_key" : "filesystem.read"
                guard manifest.allowedIDs.contains(expectedTool), LlamaGrammarPlanner.grammar(for: manifest).matches(call),
                      parsed.calls.count == 1, parsed.calls.first?.name == expectedTool else { throw Invalid.shape }
                check(reads == 0 && keypresses == 0 && !firstTask.isCancelled,
                    "C02 held real planner entered no backing and retained exact task (\(mode))")
                if mode == "duplicate-terminal" {
                    await state.releaseAll(); await firstTask.value
                    guard manager.task(id: first.id.uuidString)?.status == .completed, reads == 1 else { throw Invalid.worker }
                } else if mode == "approval-pending" {
                    await state.releaseAll()
                    guard await reached({ PermissionGate.shared.pending?.taskID == first.id.uuidString }),
                          let pending = PermissionGate.shared.pending else { throw Invalid.ownership }
                    check(pending.toolID == "computer.press_key" && pending.arguments["key"] == "escape"
                        && PermissionGate.shared.pendingReview?.isReadyToRun == true && keypresses == 0,
                        "C03 actual current-session gate/request did not qualify")
                }
                let beforeRows = try sql.load()
                let beforeBytes = try Data(contentsOf: file)
                let beforeEvents = try sql.journal(taskID: first.id.uuidString)
                let beforeWarmups = warmups
                let beforeJobs = conversation.taskBridge.cachedTasks.count
                let beforeReads = reads
                let origin = TaskOrigin.voice(sessionID: session, turn: turn)
                if mode == "start-refused" {
                    try sql.withConnection { db in
                        try TaskStore.exec(db, "CREATE TRIGGER refuse_voice_spawn BEFORE INSERT ON task WHEN NEW.objective='Read another owned spawn document.' BEGIN SELECT RAISE(ABORT,'fixture spawn refusal'); END")
                    }
                }
                var receipt: TaskReceipt?
                let began = ContinuousClock.now
                if mode == "different-turn" {
                    let second = await input(request)
                    ownedTasks = conversation.taskBridge.cachedTasks.compactMap { row in UUID(uuidString: row.id).flatMap { conversation.captureVoiceWorkerForTesting(id: $0) }?.task }
                    check(second.reply == "I'm on it." && conversation.taskBridge.cachedTasks.count == 2 && manager.tasks.count == 2,
                        "C04 real next-turn same objective was incorrectly treated as duplicate")
                    guard let next = conversation.taskBridge.cachedTasks.first(where: { $0.id != first.id.uuidString }).flatMap { UUID(uuidString: $0.id) }.flatMap { conversation.captureVoiceWorkerForTesting(id: $0) },
                          case .voice(let nextSession, let nextTurn)? = manager.task(id: next.id.uuidString)?.origin else { throw Invalid.ownership }
                    check(nextSession == session && nextTurn != turn && next.id != first.id,
                        "C05 next task did not retain its actual new current turn")
                } else {
                    let objective: String
                    let passedOrigin: TaskOrigin
                    if mode.hasPrefix("duplicate") {
                        objective = "  " + request.uppercased() + "  "
                        passedOrigin = origin
                    } else {
                        objective = "Read another owned spawn document."
                        passedOrigin = mode == "foreign-session" ? .voice(sessionID: UUID(), turn: turn) : origin
                    }
                    receipt = conversation.spawn(objective: objective, userWords: objective, origin: passedOrigin)
                    ownedTasks = conversation.taskBridge.cachedTasks.compactMap { row in UUID(uuidString: row.id).flatMap { conversation.captureVoiceWorkerForTesting(id: $0) }?.task }
                    if mode.hasPrefix("duplicate") {
                        check(receipt?.status == .duplicate && receipt?.id == TaskID(first.id),
                            "F01 normalized same-turn spawn did not return the existing receipt (\(mode))")
                        check(try sql.load() == beforeRows && Data(contentsOf: file) == beforeBytes
                            && sql.journal(taskID: first.id.uuidString) == beforeEvents,
                            "F02 duplicate spawn changed the canonical primary/export/journal (\(mode))")
                        check(conversation.taskBridge.cachedTasks.count == beforeJobs && (mode == "duplicate-terminal" ? manager.task(id: first.id.uuidString)?.status == .completed : conversation.captureVoiceWorkerForTesting(id: first.id)?.worker === first.worker)
                            && warmups == beforeWarmups,
                            "F03 duplicate spawn created/prewarmed a second actual worker (\(mode))")
                        check(receipt?.spokenAcknowledgment == "I've already taken that request.",
                            "F04 duplicate acknowledgment invented fresh work or terminal progress (\(mode))")
                    } else if mode == "approval-pending" {
                        check(receipt?.status == .refusedApprovalPending && receipt?.id == nil,
                            "F05 current-session actual pending Gate did not refuse a new spawn")
                        check(try sql.load() == beforeRows && Data(contentsOf: file) == beforeBytes
                            && sql.journal(taskID: first.id.uuidString) == beforeEvents,
                            "F06 refused approval-pending spawn changed retained canonical history")
                        check(conversation.taskBridge.cachedTasks.count == beforeJobs && warmups == beforeWarmups,
                            "F07 refused approval-pending spawn created/prewarmed another worker")
                        check(receipt?.spokenAcknowledgment == "Please answer the approval that's waiting first.",
                            "F08 approval-pending acknowledgment claimed a new start")
                    } else if mode == "different-objective" {
                        check(receipt?.status == .accepted && receipt?.id != nil && receipt?.id != TaskID(first.id)
                            && manager.tasks.count == 2 && conversation.taskBridge.cachedTasks.count == 2,
                            "C06 a genuinely different objective on the same turn was refused")
                    } else {
                        if case .refusedUnavailable? = receipt?.status {} else {
                            failures.append("voice spawn: C07 invalid session/refused primary returned a start receipt (\(mode))")
                        }
                        checks += 1
                        check(receipt?.id == nil && receipt?.spokenAcknowledgment != "I'm on it."
                            && conversation.taskBridge.cachedTasks.count == beforeJobs && warmups == beforeWarmups,
                            "C08 refused admission started/prewarmed another worker (\(mode))")
                        check(try sql.load() == beforeRows && Data(contentsOf: file) == beforeBytes
                            && sql.journal(taskID: first.id.uuidString) == beforeEvents,
                            "C09 refused admission changed retained canonical history (\(mode))")
                    }
                }
                let elapsed = began.duration(to: .now)
                // Target <=5ms is measured, never invented from a receipt Boolean.
                print("VOICE_SPAWN_RECEIPT mode=\(mode) elapsed=\(elapsed) jobs=\(conversation.taskBridge.cachedTasks.count) rows=\(manager.tasks.count) readsBefore=\(beforeReads) pending=\(PermissionGate.shared.pending != nil)")
                if mode == "approval-pending" {
                    // Let every actually created successor reach its real provider boundary
                    // while the first native permission waiter stays pending. No seeded Gate.
                    let successorCount = max(0, conversation.taskBridge.cachedTasks.count - 1)
                    guard await reached({ await state.heldCount == successorCount }) else { throw Invalid.worker }
                    let actualPlannerStarts = await state.readStarts
                    // No granted keypress: cancel actual pending workers and drain SAME handles.
                    for row in conversation.taskBridge.cachedTasks { if let id = UUID(uuidString: row.id) { _ = conversation.cancel(id) } }
                    await state.releaseAll()
                    for task in ownedTasks { await task.value }
                    check(keypresses == 0 && PermissionGate.shared.pending == nil
                        && actualPlannerStarts == conversation.taskBridge.cachedTasks.count,
                        "C10 actual Gate cleanup entered keypress backing or left a waiter")
                } else {
                    let expectedHeld = ownedTasks.filter { !$0.isCancelled }.count
                    guard await reached({ await state.heldCount == expectedHeld }) else { throw Invalid.worker }
                    await state.releaseAll()
                    for task in ownedTasks { await task.value }
                    let actualReadStarts = await state.readStarts
                    if mode.hasPrefix("duplicate") {
                        check(reads == 1 && actualReadStarts == 1,
                            "F09 duplicate spawn entered another real planner/read backing (\(mode))")
                    } else if mode == "different-turn" || mode == "different-objective" {
                        check(reads == 2 && actualReadStarts == 2,
                            "C11 distinct admitted objectives did not perform their two actual reads (\(mode))")
                    } else {
                        check(reads == 1 && actualReadStarts == 1,
                            "C12 invalid/refused spawn entered a second real planner/read backing (\(mode))")
                    }
                    check(manager.tasks.allSatisfy { $0.status == .completed },
                        "C13 actual admitted read workers did not complete (\(mode))")
                }
                print("VOICE_SPAWN_CASE mode=\(mode) checks=\(checks - startChecks) reads=\(reads) keys=\(keypresses) readStarts=\(await state.readStarts)")
                ownedTasks = []
                await capture.endSession(source: .done)
                conversation.resetForTesting(); probe = nil
            }
            check(SelfTestStoreGuard.diff(owner, SelfTestStoreGuard.take()).isEmpty,
                "C14 fixture changed owner state")
        } catch {
            failures.append("voice spawn: INVALID \(error)")
            for row in conversation.taskBridge.cachedTasks { if let id = UUID(uuidString: row.id) { _ = conversation.cancel(id) } }
            await probe?.releaseAll()
            for task in ownedTasks { await task.value }
            await capture.endSession(source: .done)
        }
        return (checks, failures)
    }
}

private actor VoiceSpawnProbe {
    let request: String; let target: String; let contents: String; let permission: Bool
    private var held: [CheckedContinuation<Void, Never>] = []
    private(set) var readStarts = 0
    var heldCount: Int { held.count }
    init(request: String, target: String, contents: String, permission: Bool) {
        self.request = request; self.target = target; self.contents = contents; self.permission = permission
    }
    func frontend(_ messages: [LLMChatMessage]) -> AsyncThrowingStream<String, Error> {
        let body = messages.last?.content.hasSuffix("Latest user speech:\n" + request) == true
            ? "<use_tools/>" : "<answer/>A haiku is a short poem."
        return AsyncThrowingStream { $0.yield(body); $0.finish() }
    }
    func releaseAll() { let current = held; held = []; for item in current { item.resume() } }
    nonisolated func call() throws -> String {
        if permission {
            return #"<tool_call>{"name":"computer.press_key","arguments":{"key":"escape","modifiers":null},"rationale":"Apply the owned requested key after approval."}</tool_call>"#
        }
        let args = try JSONSerialization.data(withJSONObject: ["path": target], options: [.sortedKeys])
        return "<tool_call>{\"name\":\"filesystem.read\",\"arguments\":" + String(decoding: args, as: UTF8.self)
            + ",\"rationale\":\"Read the owned fixture file.\"}</tool_call>"
    }
    func complete(user: String) async throws -> String {
        if user.contains(contents) { return "The owned spawn document is ready." }
        readStarts += 1
        await withCheckedContinuation { held.append($0) }
        return try call()
    }
}
private struct VoiceSpawnProvider: LLMProvider {
    let id = LLMProviderID.appLLM
    let probe: VoiceSpawnProbe
    var contextTokens: Int { 8_192 }
    var unavailableReason: String? { get async { nil } }
    func countTokens(_ text: String) async throws -> Int { text.count / 4 }
    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        let text = try await probe.complete(user: user)
        return LLMCompletion(text: text, generatedTokens: text.count, duration: 0)
    }
}

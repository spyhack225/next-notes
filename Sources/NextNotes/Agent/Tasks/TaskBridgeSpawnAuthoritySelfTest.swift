import Foundation
import SQLite3

/// Actual voice intake and public spawn -> SAME canonical Bridge/Manager admission.
/// The external scripted provider and read-only temporary backing are the only fakes.
@MainActor
enum TaskBridgeSpawnAuthoritySelfTest {
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
              conversation.taskBridge.cachedTasks.allSatisfy({ row in UUID(uuidString: row.id).flatMap { conversation.captureVoiceWorkerForTesting(id: $0) } == nil }) else { return (0, ["bridge spawn: INVALID isolated lifecycle required"]) }
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let root = temp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard root.standardizedFileURL.path == root.resolvingSymlinksInPath().standardizedFileURL.path,
              root.deletingLastPathComponent().path == temp.path,
              !FileManager.default.fileExists(atPath: root.path) else { return (0, ["bridge spawn: INVALID unsafe root"]) }
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
        var probe: BridgeSpawnAuthorityProbe?
        var rootCreated = false
        var checks = 0; var failures: [String] = []
        func check(_ value: Bool, _ label: String) {
            checks += 1; if !value { failures.append("bridge spawn: " + label) }
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
            for mode in ["nil-origin", "typed-origin", "scheduled-origin", "meeting-origin", "selftest-origin", "foreign-session", "zero-turn", "empty-objective", "current-duplicate", "closed-session", "reopened-session"] {
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
                let request = "Inspect the owned spawn document for " + mode + "."
                let state = BridgeSpawnAuthorityProbe(request: request, target: target.path, contents: text,
                                            permission: false)
                probe = state
                var warmups = 0; var reads = 0; var keypresses = 0
                conversation.rememberExplicit = { _ in }
                conversation.prewarmObserverForTesting = { warmups += 1 }
                conversation.workerForTesting = nil
                conversation.workerProviderForTesting = BridgeSpawnAuthorityProvider(probe: state)
                conversation.streamForTesting = { _, messages in await state.frontend(messages) }
                AgentToolExecutor.policyOverrideForTesting = .selfTest
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
                let expectedTool = "filesystem.read"
                guard manifest.allowedIDs.contains(expectedTool), LlamaGrammarPlanner.grammar(for: manifest).matches(call),
                      parsed.calls.count == 1, parsed.calls.first?.name == expectedTool else { throw Invalid.shape }
                check(reads == 0 && keypresses == 0 && !firstTask.isCancelled,
                    "C02 held real planner entered no backing and retained exact task (\(mode))")
                let originalOrigin = TaskOrigin.voice(sessionID: session, turn: turn)
                if mode == "closed-session" || mode == "reopened-session" {
                    await state.releaseAll(); await firstTask.value
                    guard reads == 1, manager.task(id: first.id.uuidString)?.status == .completed else { throw Invalid.worker }
                    await capture.endSession(source: .done)
                    if mode == "reopened-session" { await capture.beginSession(captureAudio: false) }
                }
                let qualified = mode == "closed-session" ? !capture.isSessionActive
                    : mode == "reopened-session" ? (capture.isSessionActive && capture.sessionID != session)
                    : (capture.isSessionActive && capture.sessionID == session)
                guard qualified else { throw Invalid.ownership }
                check(qualified, "C03 actual current/closed/reopened session did not qualify (\(mode))")
                let beforeRows = try sql.load(); let beforeCached = manager.tasks
                let beforeBytes = try Data(contentsOf: file)
                let beforeEvents = try sql.journal(taskID: first.id.uuidString)
                let beforeJobs = conversation.taskBridge.cachedTasks.count; let beforeWarmups = warmups; let beforeReads = reads
                let suppliedOrigin: TaskOrigin?
                switch mode {
                case "nil-origin": suppliedOrigin = nil
                case "typed-origin": suppliedOrigin = .typed
                case "scheduled-origin": suppliedOrigin = .scheduled
                case "meeting-origin": suppliedOrigin = .meeting(UUID())
                case "selftest-origin": suppliedOrigin = .selfTest
                case "foreign-session": suppliedOrigin = .voice(sessionID: UUID(), turn: turn)
                case "zero-turn": suppliedOrigin = .voice(sessionID: session, turn: TurnID(raw: 0))
                default: suppliedOrigin = originalOrigin
                }
                let wantsDuplicate = ["current-duplicate", "closed-session", "reopened-session"].contains(mode)
                let objective = mode == "empty-objective" ? " \n "
                    : wantsDuplicate ? "  " + request.uppercased() + "  " : "Read another owned spawn document."
                let begin = ContinuousClock.now
                let receipt = bridge.spawnVoiceObjective(id: UUID(), objective: objective, userWords: objective, origin: suppliedOrigin)
                let elapsed = begin.duration(to: .now)
                if mode == "current-duplicate" {
                    check(receipt.status == .duplicate && receipt.id == TaskID(first.id),
                          "C04 direct current duplicate lost the existing real receipt")
                    let afterRows = try sql.load()
                    check(afterRows == beforeRows && manager.tasks == beforeCached,
                          "C05 direct current duplicate changed primary/cached rows")
                    let unchangedBytes = try Data(contentsOf: file) == beforeBytes
                    let unchangedEvents = try sql.journal(taskID: first.id.uuidString) == beforeEvents
                    check(unchangedBytes && unchangedEvents, "C06 direct current duplicate changed export/journal")
                } else {
                    let refused: Bool = if case .refusedUnavailable = receipt.status { true } else { false }
                    check(refused && receipt.id == nil && receipt.spokenAcknowledgment != "I'm on it.",
                          "F01 raw invalid origin/current turn returned admission (\(mode))")
                    let afterRows = try sql.load()
                    check(afterRows == beforeRows && manager.tasks == beforeCached,
                          "F02 raw invalid origin/current turn changed primary/cached rows (\(mode))")
                    let unchangedBytes = try Data(contentsOf: file) == beforeBytes
                    let unchangedEvents = try sql.journal(taskID: first.id.uuidString) == beforeEvents
                    check(unchangedBytes && unchangedEvents, "F03 raw invalid origin/current turn changed export/journal (\(mode))")
                }
                check(conversation.taskBridge.cachedTasks.count == beforeJobs && warmups == beforeWarmups && reads == beforeReads,
                      "C07 raw admission invented a worker/prewarm/backing owner (\(mode))")
                await state.releaseAll(); await firstTask.value
                let actualReadStarts = await state.readStarts
                check(reads == 1 && keypresses == 0 && actualReadStarts == 1
                    && manager.task(id: first.id.uuidString)?.status == .completed,
                    "C08 actual Coordinator consumer did not retain its one real read/result (\(mode))")
                print("BRIDGE_SPAWN_AUTHORITY_CASE mode=\(mode) checks=\(checks - startChecks) rows=\(manager.tasks.count) jobs=\(conversation.taskBridge.cachedTasks.count) reads=\(reads) receipt=\(receipt.status) elapsed=\(elapsed)")
                ownedTasks = []
                await capture.endSession(source: .done)
                conversation.resetForTesting(); probe = nil
            }
            check(SelfTestStoreGuard.diff(owner, SelfTestStoreGuard.take()).isEmpty,
                "C09 fixture changed owner state")
        } catch {
            failures.append("bridge spawn: INVALID \(error)")
            for row in conversation.taskBridge.cachedTasks { if let id = UUID(uuidString: row.id) { _ = conversation.cancel(id) } }
            await probe?.releaseAll()
            for task in ownedTasks { await task.value }
            await capture.endSession(source: .done)
        }
        return (checks, failures)
    }
}

private actor BridgeSpawnAuthorityProbe {
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
private struct BridgeSpawnAuthorityProvider: LLMProvider {
    let id = LLMProviderID.appLLM
    let probe: BridgeSpawnAuthorityProbe
    var contextTokens: Int { 8_192 }
    var unavailableReason: String? { get async { nil } }
    func countTokens(_ text: String) async throws -> Int { text.count / 4 }
    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        let text = try await probe.complete(user: user)
        return LLMCompletion(text: text, generatedTokens: text.count, duration: 0)
    }
}

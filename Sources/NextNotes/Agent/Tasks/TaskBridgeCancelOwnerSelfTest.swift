import Foundation
import SQLite3

/// Actual voice intake and public spawn -> SAME canonical Bridge/Manager admission.
/// The external scripted provider and read-only temporary backing are the only fakes.
@MainActor
enum TaskBridgeCancelOwnerSelfTest {
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
              conversation.taskBridge.cachedTasks.allSatisfy({ row in UUID(uuidString: row.id).flatMap { conversation.captureVoiceWorkerForTesting(id: $0) } == nil }) else { return (0, ["bridge cancel: INVALID isolated lifecycle required"]) }
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let root = temp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard root.standardizedFileURL.path == root.resolvingSymlinksInPath().standardizedFileURL.path,
              root.deletingLastPathComponent().path == temp.path,
              !FileManager.default.fileExists(atPath: root.path) else { return (0, ["bridge cancel: INVALID unsafe root"]) }
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
        var probe: BridgeCancelOwnerProbe?
        var rootCreated = false
        var checks = 0; var failures: [String] = []
        func check(_ value: Bool, _ label: String) {
            checks += 1; if !value { failures.append("bridge cancel: " + label) }
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
            for mode in ["accepted", "save-refused", "nil-owner", "stale-bridge", "no-match"] {
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
                let state = BridgeCancelOwnerProbe(request: request, target: target.path, contents: text,
                                            permission: false)
                probe = state
                var warmups = 0; var reads = 0; var keypresses = 0
                conversation.rememberExplicit = { _ in }
                conversation.prewarmObserverForTesting = { warmups += 1 }
                conversation.workerForTesting = nil
                conversation.workerProviderForTesting = BridgeCancelOwnerProvider(probe: state)
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
                var selected = first
                var cancellingBridge = bridge
                if mode == "nil-owner" {
                    // SAME Manager/row, but this fresh Bridge has never owned a Job.
                    cancellingBridge = TaskBridge(manager: manager)
                } else if mode == "stale-bridge" {
                    // Actual second intake binds its new Bridge to SAME existing owner.
                    // The original Bridge is not allowed to cancel that new Job.
                    let successorBridge = TaskBridge(manager: manager)
                    guard conversation.installTaskBridgeForTesting(successorBridge) else { throw Invalid.ownership }
                    let next = await input(request)
                    ownedTasks = conversation.taskBridge.cachedTasks.compactMap { row in UUID(uuidString: row.id).flatMap { conversation.captureVoiceWorkerForTesting(id: $0) }?.task }
                    guard next.reply == "I'm on it.", let latest = conversation.taskBridge.cachedTasks.first(where: { $0.id != first.id.uuidString }).flatMap { UUID(uuidString: $0.id) }.flatMap { conversation.captureVoiceWorkerForTesting(id: $0) }, let latestTask = latest.task,
                          latest.id != first.id, await reached({ await state.heldCount == 2 }) else { throw Invalid.worker }
                    selected = latest
                    check(!latestTask.isCancelled && latest.bridge === successorBridge,
                          "C03 actual successor has SAME owner and different Bridge")
                }
                guard let selectedTask = selected.task, let before = manager.task(id: selected.id.uuidString) else { throw Invalid.worker }
                let expectedReads = mode == "stale-bridge" ? 2 : 1
                if mode == "save-refused" {
                    try sql.withConnection { try TaskStore.exec($0,
                        "CREATE TRIGGER refuse_voice_cancel BEFORE UPDATE ON task WHEN NEW.state='cancelled' BEGIN SELECT RAISE(ABORT,'owned cancel refusal'); END") }
                }
                let beforeRows = try sql.load(); let beforeCache = manager.tasks
                let beforeBytes = try Data(contentsOf: file); let beforeJournal = try sql.journal(taskID: selected.id.uuidString)
                let targetID = mode == "no-match" ? UUID() : selected.id
                let elapsedStart = ContinuousClock.now
                let cancelled = cancellingBridge.cancelVoiceObjective(id: targetID)
                let elapsed = elapsedStart.duration(to: .now)
                let afterRows = try sql.load(); let afterBytes = try Data(contentsOf: file)
                let afterJournal = try sql.journal(taskID: selected.id.uuidString)
                if mode == "accepted" || mode == "save-refused" {
                    check(selectedTask.isCancelled && !conversation.hasActiveWork,
                          "F01 public cancellation did not stop SAME Task immediately (\(mode))")
                    if mode == "accepted" {
                        check(cancelled && manager.task(id: selected.id.uuidString)?.status == .cancelled
                            && afterRows.first(where: { $0.id == selected.id.uuidString })?.status == .cancelled,
                            "C04 accepted cancellation did not retain primary receipt")
                    } else {
                        check(!cancelled && manager.lastPersistenceResult == .sqlFailed,
                              "C05 refused cancellation manufactured durable success")
                        check(afterRows == beforeRows && manager.tasks == beforeCache
                            && afterBytes == beforeBytes && afterJournal == beforeJournal,
                            "C06 refused cancellation did not preserve primary/export/journal")
                    }
                } else {
                    let label = mode == "no-match" ? "C07" : "F02"
                    check(!cancelled && !selectedTask.isCancelled && !firstTask.isCancelled,
                          label + " stale/nil/no-match Bridge stopped another Job (\(mode))")
                    let unchangedLabel = mode == "no-match" ? "C08" : "F03"
                    check(afterRows == beforeRows && manager.tasks == beforeCache
                        && afterBytes == beforeBytes && afterJournal == beforeJournal,
                        unchangedLabel + " stale/nil/no-match Bridge changed retained history (\(mode))")
                }
                check(reads == 0 && keypresses == 0 && conversation.taskBridge.cachedTasks.count == ownedTasks.count,
                      "C09 direct cancellation created backing or another Task owner (\(mode))")
                await state.releaseAll()
                for task in ownedTasks { await task.value }
                let actualReadStarts = await state.readStarts
                if mode == "accepted" || mode == "save-refused" {
                    check(reads == 0 && actualReadStarts == 1 && PermissionGate.shared.pending == nil,
                          "F04 cancelled SAME production plan reached backing after release (\(mode))")
                    check(mode != "save-refused" || (manager.task(id: selected.id.uuidString) == before
                        && manager.lastPersistenceResult == .sqlFailed),
                        "F05 refused cancellation lost uncertain retained outcome on return")
                } else {
                    check(reads == expectedReads && actualReadStarts == expectedReads,
                          "C11 unrelated actual held workers were stopped or replayed (\(mode))")
                }
                print("BRIDGE_CANCEL_OWNER_CASE mode=\(mode) checks=\(checks-startChecks) primary=\(manager.task(id:selected.id.uuidString)?.status.rawValue ?? "missing") taskCancelled=\(selectedTask.isCancelled) admitted=\(cancelled) reads=\(reads) elapsed=\(elapsed)")
                if mode == "save-refused" { try sql.withConnection { try TaskStore.exec($0, "DROP TRIGGER refuse_voice_cancel") } }
                // Cleanup only actually mounted jobs, after all external callbacks returned.
                for row in conversation.taskBridge.cachedTasks { if let id = UUID(uuidString: row.id) { _ = conversation.cancel(id) } }
                for task in ownedTasks { await task.value }
                ownedTasks = []
                await capture.endSession(source: .done)
                conversation.resetForTesting(); probe = nil
            }
            // Actual hosted question, not a seeded row. A second wrapper over
            // the SAME Manager must not borrow the live owner's resumable work.
            let directory = root.appendingPathComponent("hosted-waiting-other-bridge", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let sql = TaskStore(root: directory); defer { sql.close() }
            let file = directory.appendingPathComponent("agent-tasks.json")
            let store = AgentTaskStore(fileURL: file, mirror: sql)
            guard store.allowsHarnessPersistence, store.save([]).primaryCommitted else { throw Invalid.unsafe }
            let manager = AgentTaskManager(store: store)
            let bridge = TaskBridge(manager: manager)
            conversation.resetForTesting(); AgentSession.shared.forgetAllConversations()
            guard conversation.installTaskBridgeForTesting(bridge) else { throw Invalid.unsafe }
            await capture.beginSession(captureAudio: false)
            let request = "Inspect the owned waiting document."
            let question = "Which document should I read?"
            let state = BridgeCancelOwnerProbe(request: request, target: "", contents: "", permission: false)
            probe = state
            conversation.workerProviderForTesting = nil
            conversation.workerForTesting = { _ in await state.question(question) }
            conversation.streamForTesting = { _, messages in await state.frontend(messages) }
            let admitted = await input(request)
            ownedTasks = conversation.taskBridge.cachedTasks.compactMap { row in UUID(uuidString: row.id).flatMap { conversation.captureVoiceWorkerForTesting(id: $0) }?.task }
            guard let job = conversation.taskBridge.cachedTasks.first.flatMap { UUID(uuidString: $0.id) }.flatMap { conversation.captureVoiceWorkerForTesting(id: $0) }, let task = job.task,
                  await reached({ await state.heldCount == 1 }) else { throw Invalid.worker }
            await state.releaseAll(); await task.value
            guard let pending = bridge.voiceInputRequest(TaskID(job.id)) else { throw Invalid.worker }
            check(admitted.reply == "I'm on it." && manager.task(id: job.id.uuidString)?.status == .waitingForInput
                && pending.question == question && conversation.taskBridge.cachedTasks.first.flatMap { UUID(uuidString: $0.id) }.flatMap { conversation.captureVoiceWorkerForTesting(id: $0) }?.task == nil,
                "C13 actual hosted question and resumable owner did not qualify")
            let rows = try sql.load(); let cache = manager.tasks
            let bytes = try Data(contentsOf: file); let journal = try sql.journal(taskID: job.id.uuidString)
            let other = TaskBridge(manager: manager)
            let borrowed = other.cancelVoiceObjective(id: job.id)
            let afterRows = try sql.load(); let afterBytes = try Data(contentsOf: file)
            let afterJournal = try sql.journal(taskID: job.id.uuidString)
            check(!borrowed && afterRows == rows && manager.tasks == cache && afterBytes == bytes && afterJournal == journal,
                "C14 different Bridge borrowed a genuinely hosted waiting question")
            check(conversation.captureVoiceWorkerForTesting(id: job.id)?.work === job.work && conversation.captureVoiceWorkerForTesting(id: job.id)?.worker === job.worker
                && bridge.voiceInputRequest(TaskID(job.id)) == pending && !task.isCancelled,
                "C15 refused wrapper changed SAME resumable work/worker/request")
            let stopped = bridge.cancelVoiceObjective(id: job.id)
            check(stopped && manager.task(id: job.id.uuidString)?.status == .cancelled
                && bridge.voiceInputRequest(TaskID(job.id)) == nil,
                "C16 exact hosted owner could not cancel its question")
            ownedTasks = []; probe = nil
            await capture.endSession(source: .done); conversation.resetForTesting()
            check(SelfTestStoreGuard.diff(owner, SelfTestStoreGuard.take()).isEmpty,
                  "C12 fixture changed owner state")
        } catch {
            failures.append("bridge cancel: INVALID \(error)")
            for row in conversation.taskBridge.cachedTasks { if let id = UUID(uuidString: row.id) { _ = conversation.cancel(id) } }
            await probe?.releaseAll()
            for task in ownedTasks { await task.value }
            await capture.endSession(source: .done)
        }
        return (checks, failures)
    }
}

private actor BridgeCancelOwnerProbe {
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
    func question(_ value: String) async -> String {
        await withCheckedContinuation { held.append($0) }
        return value
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
private struct BridgeCancelOwnerProvider: LLMProvider {
    let id = LLMProviderID.appLLM
    let probe: BridgeCancelOwnerProbe
    var contextTokens: Int { 8_192 }
    var unavailableReason: String? { get async { nil } }
    func countTokens(_ text: String) async throws -> Int { text.count / 4 }
    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        let text = try await probe.complete(user: user)
        return LLMCompletion(text: text, generatedTokens: text.count, duration: 0)
    }
}

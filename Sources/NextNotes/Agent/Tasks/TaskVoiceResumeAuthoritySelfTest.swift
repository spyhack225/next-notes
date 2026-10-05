import Foundation

/// Real voice question -> canonical public resume admission, with no seeded row/request.
@MainActor
enum TaskVoiceResumeAuthoritySelfTest {
    private enum Invalid: Error { case unsafe, owner, worker, shape }
    private static func reached(_ predicate: @MainActor () async -> Bool) async -> Bool {
        let until = ContinuousClock.now.advanced(by: .seconds(8))
        while ContinuousClock.now < until { if await predicate() { return true }; await Task.yield() }
        return await predicate()
    }
    static func run() async -> (checks: Int, failures: [String]) {
        let conversation = VoiceConversationCoordinator.shared
        let capture = AgentCaptureController.shared
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-voice-work-lifecycle",
              AgentSession.shared.fileURL == nil, conversation.taskBridge.cachedTasks.allSatisfy({ row in
                  guard let id = UUID(uuidString: row.id) else { return true }
                  return conversation.captureVoiceWorkerForTesting(id: id) == nil
              }),
              !capture.isSessionActive, PermissionGate.shared.pending == nil,
              PermissionGate.shared.queuedCount == 0 else { return (0, ["voice resume: INVALID existing owner"]) }
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let root = temp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard root.standardizedFileURL.path == root.resolvingSymlinksInPath().standardizedFileURL.path,
              root.deletingLastPathComponent().path == temp.path,
              !FileManager.default.fileExists(atPath: root.path) else { return (0, ["voice resume: INVALID root"]) }
        let priorBridge = conversation.taskBridgeOverrideForTesting
        let oldRemember = conversation.rememberExplicit
        let oldFake = AgentToolExecutor.fakeForTesting; let oldFire = AgentToolExecutor.fireOverrideForTesting
        let oldPolicy = AgentToolExecutor.policyOverrideForTesting
        let oldInputs = AgentCapabilityManifestBuilder.inputsOverrideForTesting
        let oldWhole = PlannerBackends.wholeTurnOverrideForTesting
        let oldNeedle = ToolLoopLiveEval.needleFirstForTesting
        let owner = SelfTestStoreGuard.take()
        var checks = 0; var failures: [String] = []; var created = false
        var ownedTask: Task<Void, Never>?; var held: VoiceResumeProbe?
        func check(_ value: Bool, _ label: String) { checks += 1; if !value { failures.append("voice resume: " + label) } }
        func input(_ text: String) async -> AgentTurn {
            RealtimeAgent.shared.userSpeechStarted(); RealtimeAgent.shared.userSpeechEnded()
            return await RealtimeAgent.shared.handle(text, source: .voice)
        }
        defer {
            conversation.resetForTesting(); _ = conversation.installTaskBridgeForTesting(priorBridge)
            conversation.rememberExplicit = oldRemember
            AgentToolExecutor.fakeForTesting = oldFake; AgentToolExecutor.fireOverrideForTesting = oldFire
            AgentToolExecutor.policyOverrideForTesting = oldPolicy
            AgentCapabilityManifestBuilder.inputsOverrideForTesting = oldInputs
            PlannerBackends.wholeTurnOverrideForTesting = oldWhole
            ToolLoopLiveEval.needleFirstForTesting = oldNeedle
            if created { try? FileManager.default.removeItem(at: root) }
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false); created = true
            AgentToolExecutor.fakeForTesting = nil; AgentToolExecutor.policyOverrideForTesting = .selfTest
            AgentCapabilityManifestBuilder.inputsOverrideForTesting = RealtimeAgentToolLoopSelfTest.allEnabledFixture()
            PlannerBackends.wholeTurnOverrideForTesting = nil; ToolLoopLiveEval.needleFirstForTesting = false
            for mode in ["current", "omitted", "wrong-session", "closed-session", "new-session", "save-refused"] {
                let countBefore = checks
                let directory = root.appendingPathComponent(mode, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                let target = directory.appendingPathComponent("owned.txt")
                let contents = "Owned resume bytes " + UUID().uuidString
                try Data(contents.utf8).write(to: target)
                let sql = TaskStore(root: directory); defer { sql.close() }
                let file = directory.appendingPathComponent("agent-tasks.json")
                let store = AgentTaskStore(fileURL: file, mirror: sql)
                guard store.allowsHarnessPersistence, store.save([]).primaryCommitted else { throw Invalid.unsafe }
                let manager = AgentTaskManager(store: store); let bridge = TaskBridge(manager: manager)
                conversation.resetForTesting(); AgentSession.shared.forgetAllConversations()
                guard conversation.installTaskBridgeForTesting(bridge) else { throw Invalid.unsafe }
                await capture.beginSession(captureAudio: false)
                guard let session = capture.sessionID else { throw Invalid.owner }
                let request = "Inspect the owned resume document for " + mode + "."
                let answer = "Use the file at " + target.path
                let state = VoiceResumeProbe(request: request, answer: answer, target: target.path, contents: contents)
                held = state
                conversation.rememberExplicit = { _ in }; conversation.prewarmObserverForTesting = {}
                conversation.workerForTesting = nil; conversation.workerProviderForTesting = VoiceResumeProvider(probe: state)
                conversation.streamForTesting = { _, messages in await state.frontend(messages) }
                var reads = 0
                AgentToolExecutor.fireOverrideForTesting = { tool, arguments in
                    guard tool.id == "filesystem.read", arguments == ["path": target.path],
                          target.standardizedFileURL.path == target.resolvingSymlinksInPath().standardizedFileURL.path else { throw Invalid.unsafe }
                    reads += 1; return try FilesystemExecutor.run(tool, arguments: arguments)
                }
                let started = await input(request)
                ownedTask = bridge.cachedTasks.first(where: { $0.source == "voice" }).flatMap { row in
                    UUID(uuidString: row.id).flatMap { conversation.captureVoiceWorkerForTesting(id: $0)?.task }
                }
                guard await reached({ await state.parked }), let rawID = bridge.cachedTasks.first(where: { $0.source == "voice" })?.id,
                      let workerID = UUID(uuidString: rawID),
                      let job = conversation.captureVoiceWorkerForTesting(id: workerID),
                      let task = ownedTask, let reader = AgentCapabilityManifestRuntime.publishedReader else { throw Invalid.worker }
                let manifest = AgentCapabilityManifestBuilder.build(.live(reader: reader), request: job.work.original,
                    previousRequest: AgentSession.shared.recentUserTexts(limit: 2).dropLast().last)
                let call = try state.call()
                let parsed = AgentToolCallParser.parse(call, knownNames: RealtimeAgent.callNames(manifest))
                guard LlamaGrammarPlanner.grammar(for: manifest).matches(call), parsed.calls.count == 1,
                      parsed.calls[0].name == "filesystem.read", parsed.calls[0].arguments == ["path": target.path] else { throw Invalid.shape }
                await state.release(); await task.value; ownedTask = nil
                guard let question = bridge.voiceInputRequest(TaskID(job.id)),
                      let row = manager.task(id: job.id.uuidString),
                      case .voice(let ownedSession, _)? = row.origin else { throw Invalid.worker }
                check(started.reply == "I'm on it." && ownedSession == session && row.status == .waitingForInput
                    && question.taskID == row.id && question.question == VoiceResumeProbe.question,
                    "C01 actual same-session typed question not qualified (\(mode))")
                check(reads == 0 && conversation.taskBridge.cachedTasks.filter { $0.source == "voice" }.count == 1 && conversation.captureVoiceWorkerForTesting(id: job.id)?.task == nil
                    && job.work.followUps.isEmpty,
                    "C02 actual question did not release SAME worker without backing (\(mode))")
                if mode == "closed-session" || mode == "new-session" {
                    await capture.endSession(source: .done)
                    if mode == "new-session" { await capture.beginSession(captureAudio: false) }
                    guard manager.task(id: row.id)?.status == .waitingForInput else { throw Invalid.owner }
                }
                let rows = try sql.load(); let export = try Data(contentsOf: file)
                let journal = try sql.journal(taskID: row.id)
                if mode == "current" {
                    await state.parkNext()
                    let replied = await input(answer)
                    let resumedOwner = conversation.captureVoiceWorkerForTesting(id: job.id)
                    ownedTask = resumedOwner?.task
                    guard await reached({ await state.parked }), let resumedTask = ownedTask else { throw Invalid.worker }
                    let resumed = try sql.load().first { $0.id == row.id }
                    check(replied.reply == "Got it. I'll continue that task." && conversation.taskBridge.cachedTasks.filter { $0.source == "voice" }.count == 1
                        && resumedOwner?.worker === job.worker && resumedOwner?.work === job.work && resumedOwner?.work.followUps == [answer],
                        "C03 current production caller lost SAME worker/answer")
                    guard let originalSQLStart = rows.first(where: { $0.id == row.id })?.startedAt else { throw Invalid.owner }
                    let startDelta: Double? = if let left = resumed?.startedAt, let right = row.startedAt { left.timeIntervalSince(right) } else { nil }
                    print("VOICE_RESUME_CURRENT_INPUT statusRunning=\(resumed?.status == .running) pendingAbsent=\(resumed?.pendingInteraction == nil) exactAnswer=\(resumed?.userWords == answer) exactOrigin=\(resumed?.origin == row.origin) cacheStartEqual=\(resumed?.startedAt == row.startedAt) sqlStartPreserved=\(resumed?.startedAt == originalSQLStart) cacheOriginalSQLEqual=\(originalSQLStart == row.startedAt) backingZero=\(reads == 0) startDeltaSeconds=\(startDelta.map { String($0) } ?? "missing")")
                    check(resumed?.status == .running && resumed?.pendingInteraction == nil && resumed?.userWords == answer
                        && resumed?.origin == row.origin && resumed?.startedAt == originalSQLStart && reads == 0,
                        "C04 current answer did not commit exact ownership before backing")
                    await state.release(); await resumedTask.value; ownedTask = nil
                    let final = try sql.load().first { $0.id == row.id }
                    let calls = await state.calls
                    check(final?.status == .completed && final?.result == "The owned resume document is ready."
                        && reads == 1 && calls == 3 && conversation.captureVoiceWorkerForTesting(id: job.id)?.task == nil,
                        "C05 actual resumed planner/read/result did not complete")
                    check(!manager.resumeVoiceObjective(id: job.id, requestID: question.id, answer: answer, sessionID: session),
                        "C06 consumed question accepted another answer")
                } else if mode == "save-refused" {
                    try sql.withConnection { try TaskStore.exec($0, "CREATE TRIGGER refuse_owned_resume BEFORE UPDATE ON task WHEN OLD.state='waitingForInput' AND NEW.state='running' BEGIN SELECT RAISE(ABORT,'owned resume refusal'); END") }
                    let refused = await input(answer)
                    check(refused.reply == "I couldn't save your answer. The task is still waiting." && manager.lastPersistenceResult == .sqlFailed,
                        "C07 actual current answer refusal was misreported")
                    let afterRows = try sql.load(); let afterBytes = try Data(contentsOf: file); let afterJournal = try sql.journal(taskID: row.id)
                    check(afterRows == rows && afterBytes == export && afterJournal == journal && bridge.voiceInputRequest(TaskID(job.id)) == question,
                        "C08 refused current answer changed exact primary question/export/journal")
                    check(reads == 0 && conversation.captureVoiceWorkerForTesting(id: job.id)?.task == nil && job.work.followUps.isEmpty
                        && conversation.effectHoldEpoch != nil,
                        "C09 refused current answer started worker/backing or released hold")
                } else {
                    let passed: UUID? = mode == "omitted" ? nil : mode == "wrong-session" ? UUID()
                        : mode == "new-session" ? capture.sessionID : session
                    let admitted = mode == "wrong-session"
                        ? bridge.resumeVoiceObjective(id: job.id, requestID: question.id, answer: answer, sessionID: passed)
                        : manager.resumeVoiceObjective(id: job.id, requestID: question.id, answer: answer, sessionID: passed)
                    check(!admitted, "F01 public API admitted absent/closed/foreign session authority (\(mode))")
                    let afterRows = try sql.load(); let afterBytes = try Data(contentsOf: file); let afterJournal = try sql.journal(taskID: row.id)
                    check(afterRows == rows && afterBytes == export && afterJournal == journal,
                        "F02 wrong-session API changed canonical primary/export/journal (\(mode))")
                    check(bridge.voiceInputRequest(TaskID(job.id)) == question && manager.task(id: row.id)?.userWords == request,
                        "F03 wrong-session API consumed exact pending question (\(mode))")
                    let actualCalls = await state.calls
                    check(reads == 0 && conversation.taskBridge.cachedTasks.filter { $0.source == "voice" }.count == 1 && conversation.captureVoiceWorkerForTesting(id: job.id)?.task == nil
                        && job.work.followUps.isEmpty && actualCalls == 1,
                        "C10 public primary API alone started another worker or backing (\(mode))")
                }
                check(try Data(contentsOf: target) == Data(contents.utf8), "C11 actual read input changed (\(mode))")
                print("VOICE_RESUME_CASE mode=\(mode) checks=\(checks-countBefore) reads=\(reads) calls=\(await state.calls) activeSession=\(capture.isSessionActive) state=\(manager.task(id: row.id)?.status.rawValue ?? "missing")")
                await capture.endSession(source: .done); conversation.resetForTesting(); held = nil
            }
            check(SelfTestStoreGuard.diff(owner, SelfTestStoreGuard.take()).isEmpty, "C12 changed owner state")
        } catch {
            failures.append("voice resume: INVALID \(error)")
            for row in conversation.taskBridge.cachedTasks where row.source == "voice" {
                if let id = UUID(uuidString: row.id) { _ = conversation.cancel(id) }
            }
            await held?.release(); if let ownedTask { await ownedTask.value }
            await capture.endSession(source: .done)
        }
        return (checks, failures)
    }
}
private actor VoiceResumeProbe {
    static let question = "Which file should I read?"
    let request: String; let answer: String; let target: String; let contents: String
    private var continuation: CheckedContinuation<Void, Never>?
    private var shouldPark = true
    private(set) var calls = 0
    var parked: Bool { continuation != nil }
    init(request: String, answer: String, target: String, contents: String) {
        self.request = request; self.answer = answer; self.target = target; self.contents = contents
    }
    func release() { let current = continuation; continuation = nil; current?.resume() }
    func parkNext() { shouldPark = true }
    func frontend(_ messages: [LLMChatMessage]) -> AsyncThrowingStream<String, Error> {
        let package = messages.last?.content ?? ""
        let response = package.hasSuffix("Latest user speech:\n" + request) ? "<use_tools/>"
            : package.hasSuffix("Latest user speech:\n" + answer) ? "<revise id=\"1\"/>" : "<answer/>A haiku is a short poem."
        return AsyncThrowingStream { $0.yield(response); $0.finish() }
    }
    nonisolated func call() throws -> String {
        let args = try JSONSerialization.data(withJSONObject: ["path": target], options: [.sortedKeys])
        return "<tool_call>{\"name\":\"filesystem.read\",\"arguments\":" + String(decoding: args, as: UTF8.self)
            + ",\"rationale\":\"Read the owned resume fixture.\"}</tool_call>"
    }
    func complete(user: String) async throws -> String {
        calls += 1
        if shouldPark { shouldPark = false; await withCheckedContinuation { continuation = $0 } }
        if user.contains(contents) { return "The owned resume document is ready." }
        if user.contains(answer) { return try call() }
        return Self.question
    }
}
private struct VoiceResumeProvider: LLMProvider {
    let id = LLMProviderID.appLLM; let probe: VoiceResumeProbe
    var contextTokens: Int { 8_192 }
    var unavailableReason: String? { get async { nil } }
    func countTokens(_ text: String) async throws -> Int { text.count / 4 }
    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        let text = try await probe.complete(user: user)
        return LLMCompletion(text: text, generatedTokens: text.count, duration: 0)
    }
}

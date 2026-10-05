import Foundation
import SQLite3

/// Public Coordinator spawn -> SAME Manager Task -> scripted real planner -> real temp-file
/// executor -> actual Activity update -> canonical Manager/SQL -> existing status consumer.
/// Captured-scope negatives are explicitly narrower callback-boundary controls.
@MainActor
enum TaskVoiceProgressSelfTest {
    private enum Invalid: Error { case unsafe, owner, worker, shape, callback }
    private static func reached(_ predicate: @MainActor () async -> Bool) async -> Bool {
        let until = ContinuousClock.now.advanced(by: .seconds(8))
        while ContinuousClock.now < until { if await predicate() { return true }; await Task.yield() }
        return await predicate()
    }
    static func run() async -> (checks: Int, failures: [String]) {
        let c = VoiceConversationCoordinator.shared; let capture = AgentCaptureController.shared
        let activity = AgentActivityStore.shared
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-voice-work-lifecycle",
              AgentSession.shared.fileURL == nil, !c.hasActiveWork, !capture.isSessionActive,
              PermissionGate.shared.pending == nil, PermissionGate.shared.queuedCount == 0 else {
            return (0, ["voice progress: INVALID isolation"])
        }
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let root = temp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard root.path == root.resolvingSymlinksInPath().standardizedFileURL.path,
              root.deletingLastPathComponent().path == temp.path,
              !FileManager.default.fileExists(atPath: root.path) else { return (0, ["voice progress: INVALID root"]) }
        let priorBridge = c.taskBridgeOverrideForTesting
        let oldFake = AgentToolExecutor.fakeForTesting; let oldFire = AgentToolExecutor.fireOverrideForTesting
        let oldPolicy = AgentToolExecutor.policyOverrideForTesting
        let oldInputs = AgentCapabilityManifestBuilder.inputsOverrideForTesting
        let oldWhole = PlannerBackends.wholeTurnOverrideForTesting; let oldNeedle = ToolLoopLiveEval.needleFirstForTesting
        let oldObserver = activity.voiceProgressObserverForTesting
        let oldRemember = c.rememberExplicit
        let owner = SelfTestStoreGuard.take()
        let speech = AgentSpeechSynthesizer.shared; let recorder = RecordingSpeechBacking()
        var checks = 0; var failures: [String] = []; var created = false; var contextInstalled = false
        var ownedTask: Task<Void, Never>?; var ownedID: UUID?; var held: VoiceProgressProbe?; var contextManager: AgentTaskManager?
        var drained = true
        func check(_ value: Bool, _ label: String) { checks += 1; if !value { failures.append("voice progress: " + label) } }
        defer {
            if contextInstalled { _ = ToolCallContextBuilder.setMeetingContextForTesting(nil, root: root) }
            activity.voiceProgressObserverForTesting = oldObserver
            c.resetForTesting(); _ = c.installTaskBridgeForTesting(priorBridge); c.rememberExplicit = oldRemember
            AgentToolExecutor.fakeForTesting = oldFake; AgentToolExecutor.fireOverrideForTesting = oldFire
            AgentToolExecutor.policyOverrideForTesting = oldPolicy
            AgentCapabilityManifestBuilder.inputsOverrideForTesting = oldInputs
            PlannerBackends.wholeTurnOverrideForTesting = oldWhole; ToolLoopLiveEval.needleFirstForTesting = oldNeedle
            speech.restoreSystemBacking(); activity.resetForSelfTest()
            if created && drained { try? FileManager.default.removeItem(at: root) }
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false); created = true
            guard ToolCallContextBuilder.setMeetingContextForTesting({ meeting, task in
                guard meeting == nil, let task, contextManager?.task(id: task) != nil else { return nil }
                return ToolCallContext() // Authored empty external meeting context, never owner history.
            }, root: root) else { throw Invalid.unsafe }; contextInstalled = true
            AgentToolExecutor.fakeForTesting = nil; AgentToolExecutor.fireOverrideForTesting = nil
            // Authored read-only corpus policy: filesystem reads have their own
            // autoSearchFiles decision; autoRead alone does not admit that namespace.
            AgentToolExecutor.policyOverrideForTesting = PermissionPolicy(
                autoObserve: true, autoRead: true, autoSearchFiles: true,
                autoComputerControl: false, grants: [])
            AgentCapabilityManifestBuilder.inputsOverrideForTesting = RealtimeAgentToolLoopSelfTest.allEnabledFixture()
            PlannerBackends.wholeTurnOverrideForTesting = nil; ToolLoopLiveEval.needleFirstForTesting = false
            speech.useTestingBacking(recorder)
            for mode in ["current", "SQL-refused", "export-failed", "old-revision", "cancel-save-refused", "session-closed"] {
                let countBefore = checks
                let dir = root.appendingPathComponent(mode, isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
                let first = dir.appendingPathComponent("first.txt"); let second = dir.appendingPathComponent("second.txt")
                let firstText = "Owned first progress marker " + UUID().uuidString
                let secondText = "Owned second progress marker " + UUID().uuidString
                try Data(firstText.utf8).write(to: first); try Data(secondText.utf8).write(to: second)
                let sql = TaskStore(root: dir); defer { sql.close() }
                let file = dir.appendingPathComponent("agent-tasks.json")
                let store = AgentTaskStore(fileURL: file, mirror: sql)
                guard store.allowsHarnessPersistence, store.save([]).primaryCommitted else { throw Invalid.unsafe }
                let manager = AgentTaskManager(store: store); let bridge = TaskBridge(manager: manager)
                contextManager = manager
                c.resetForTesting(); activity.resetForSelfTest(); AgentSession.shared.forgetAllConversations()
                guard c.installTaskBridgeForTesting(bridge) else { throw Invalid.unsafe }
                await capture.beginSession(captureAudio: false)
                guard let session = capture.sessionID else { throw Invalid.owner }
                let state = VoiceProgressProbe(first: first.path, second: second.path,
                    firstText: firstText, secondText: secondText, twoReads: mode == "current" || mode == "export-failed")
                held = state
                c.prewarmObserverForTesting = {}; c.rememberExplicit = { _ in }; c.workerForTesting = nil
                c.workerProviderForTesting = VoiceProgressProvider(probe: state)
                c.streamForTesting = { _, _ in AsyncThrowingStream { $0.yield("<answer/>An unrelated answer."); $0.finish() } }
                var observed: [(Int, String, String, AgentTaskPersistenceResult?)] = []; var admittedID: String?
                var scope: AgentWorkPresentationScope.VoiceProgress?
                var binding: AgentWorkPresentationScope.Binding?
                var callbackCount = 0, matchingCallbackCount = 0
                var callbackScopePresent = false, callbackScopeMatches = false
                activity.voiceProgressObserverForTesting = { id in
                    callbackCount += 1
                    callbackScopePresent = AgentWorkPresentationScope.voiceProgress != nil
                    callbackScopeMatches = AgentWorkPresentationScope.voiceProgress?.taskID == id
                    guard id == admittedID else { return }
                    matchingCallbackCount += 1
                    let steps = activity.steps(taskID: id)
                    if let last = steps.last {
                        observed.append((steps.count, last.title, manager.task(id: id)?.progress ?? "", manager.lastPersistenceResult))
                    }
                    scope = AgentWorkPresentationScope.voiceProgress
                    if binding == nil { binding = activity.presentationBinding(taskID: id) }
                }
                let turn = VoiceSession.shared.beginTurnIfNeeded()
                let receipt = c.spawn(objective: "Inspect both owned progress documents.", userWords: "Read the owned fixtures.",
                    origin: .voice(sessionID: session, turn: turn))
                admittedID = receipt.id?.raw
                ownedID = receipt.id.flatMap { UUID(uuidString: $0.raw) }
                ownedTask = ownedID.flatMap { c.captureVoiceWorkerForTesting(id: $0)?.task }
                drained = ownedTask == nil
                guard await reached({ await state.phase == 1 }), let capturedID = receipt.id.flatMap({ UUID(uuidString: $0.raw) }),
                      let job = c.captureVoiceWorkerForTesting(id: capturedID), let task = job.task,
                      receipt.id == TaskID(job.id), let reader = AgentCapabilityManifestRuntime.publishedReader else { throw Invalid.worker }
                ownedTask = task; ownedID = job.id; drained = false
                let manifest = AgentCapabilityManifestBuilder.build(.live(reader: reader), request: job.work.original, previousRequest: nil)
                let call = try state.call(first.path)
                let parsed = AgentToolCallParser.parse(call, knownNames: RealtimeAgent.callNames(manifest))
                guard LlamaGrammarPlanner.grammar(for: manifest).matches(call), parsed.calls.count == 1,
                      parsed.calls[0].name == "filesystem.read", parsed.calls[0].arguments == ["path": first.path] else { throw Invalid.shape }
                check(receipt.status == .accepted && manager.task(id: job.id.uuidString)?.status == .running
                    && job.bridge === bridge && manager.task(id: job.id.uuidString)?.origin == .voice(sessionID: session, turn: turn) && job.worker.isVoiceWorker,
                    "C01 actual public intake/current job did not qualify (\(mode))")
                if mode == "SQL-refused" {
                    try sql.withConnection { try TaskStore.exec($0, "CREATE TRIGGER refuse_voice_progress BEFORE UPDATE ON task WHEN NEW.progress LIKE 'Step %' BEGIN SELECT RAISE(ABORT,'fixture progress refusal'); END") }
                }
                if mode == "export-failed" { store.migrationBoundaryForTesting = { if $0 == "primaryCommitted" { throw Invalid.unsafe } } }
                await state.release()
                let phaseReached = await reached({ await state.phase == 2 })
                let callbackPhase = await state.phase
                let callbackRead = await state.snapshot()
                print("VOICE_PROGRESS_CALLBACK_QUALIFICATION mode=\(mode) phaseReached=\(phaseReached) phase=\(callbackPhase) sawFirst=\(callbackRead.first) modelCalls=\(callbackRead.calls) callbackCount=\(callbackCount) matchingCallbacks=\(matchingCallbackCount) observed=\(observed.count) scopePresent=\(scope != nil) bindingPresent=\(binding != nil) callbackScopePresent=\(callbackScopePresent) callbackScopeMatches=\(callbackScopeMatches)")
                guard phaseReached, let scope, let binding, observed.count == 1 else { throw Invalid.callback }
                let id = job.id.uuidString; let title = observed[0].1; let expected = "Step 1: " + (title.hasSuffix("…") ? String(title.dropLast()) : title)
                let primary = try sql.load().first { $0.id == id }
                check(await state.sawFirst && observed[0].0 == 1 && AgentActivityProjector.isPublic(title)
                    && !title.contains(first.path) && AgentToolExecutor.fakeForTesting == nil && AgentToolExecutor.fireOverrideForTesting == nil,
                    "C02 real unrestricted-by-fake temp read/public step did not qualify (\(mode))")
                if mode == "current" || mode == "export-failed" {
                    check(primary?.progress == expected && bridge.taskRecord(TaskID(id))?.progress == expected,
                        "F01 real step did not commit canonical progress (\(mode))")
                    let callsBefore = await state.calls
                    RealtimeAgent.shared.userSpeechStarted(); RealtimeAgent.shared.userSpeechEnded()
                    let reply = await RealtimeAgent.shared.handle("How's it going?", source: .voice)
                    let callsAfter = await state.calls
                    // Declared copy contracts before BOTH status versions: retained step-only
                    // reply or exact named running/step/duration sentence. No contains fallback.
                    let ownedTitle = TaskStatusRenderer.title(job.work.original)
                    let ownedStep = String(expected.dropFirst("Step 1: ".count))
                    let statusPattern = "^Still on " + NSRegularExpression.escapedPattern(for: ownedTitle)
                        + " — " + NSRegularExpression.escapedPattern(for: ownedStep)
                        + ", (?:just started|about [0-9]+ seconds in|about [0-9]+ minutes in|start time unavailable)\\.$"
                    let namedStatus = reply.reply.range(of: statusPattern, options: .regularExpression) != nil
                    let admittedCopy = reply.reply == expected || namedStatus
                    check(admittedCopy && bridge.workStatusLines(sessionID: session).contains(expected)
                        && callsAfter == callsBefore, "F02 actual status consumer lost progress or added inference (\(mode))")
                    if mode == "export-failed" {
                        check(observed[0].3 == .exportFailed && primary?.progress == expected,
                            "F03 export failure revoked SQL progress admission")
                        store.migrationBoundaryForTesting = nil
                    }
                } else if mode == "SQL-refused" {
                    check(primary?.progress == "Working locally" && manager.task(id: id)?.progress == "Working locally"
                        && observed[0].3 == .sqlFailed, "F04 rejected progress save did not roll back cached/primary progress")
                }
                // Actual captured producer context; never mint a fake Job or revision.
                let beforeRows = try sql.load(); let beforeBytes = try Data(contentsOf: file); let beforeEvents = try sql.journal(taskID: id)
                let otherBridge = TaskBridge(manager: manager)
                let rejects = AgentWorkPresentationScope.$voiceProgress.withValue(scope) {
                    AgentWorkPresentationScope.$binding.withValue(binding) {
                        [bridge.noteProgress(taskID: UUID().uuidString, step: 1, title: title),
                         bridge.noteProgress(taskID: id, step: 0, title: title),
                         bridge.noteProgress(taskID: id, step: 99, title: title),
                         bridge.noteProgress(taskID: id, step: 1, title: "secret chain of thought"),
                         otherBridge.noteProgress(taskID: id, step: 1, title: title),
                         bridge.noteProgress(taskID: id, step: 1, title: title)]
                    }
                }
                check(rejects.allSatisfy { !$0 }, "C03 wrong identity/order/private title/duplicate wrote progress (\(mode))")
                check(try sql.load() == beforeRows && Data(contentsOf: file) == beforeBytes && sql.journal(taskID: id) == beforeEvents,
                    "C04 refused/duplicate observations changed primary/export/journal (\(mode))")
                if mode == "old-revision" || mode == "cancel-save-refused" || mode == "session-closed" {
                    if mode == "old-revision" {
                        job.work.append("Use the revised instruction.")
                        guard bridge.recordVoiceRevision(TaskID(id), revision: job.work.revision) else { throw Invalid.owner }
                    } else if mode == "cancel-save-refused" {
                        try sql.withConnection { try TaskStore.exec($0, "CREATE TRIGGER refuse_voice_cancel BEFORE UPDATE ON task WHEN NEW.state='cancelled' BEGIN SELECT RAISE(ABORT,'fixture cancel refusal'); END") }
                        check(!c.cancel(job.id) && task.isCancelled && manager.task(id: id)?.status == .running,
                            "C05 rejected durable cancel did not invalidate SAME actual task")
                    } else { await capture.endSession(source: .done) }
                    let old = try sql.load(); let oldBytes = try Data(contentsOf: file)
                    let oldSteps = activity.steps(taskID: id)
                    AgentWorkPresentationScope.$voiceProgress.withValue(scope) {
                        AgentWorkPresentationScope.$binding.withValue(binding) {
                            activity.update(taskID: id, kind: .reading, title: "Reading the previous instruction…")
                        }
                    }
                    check(try sql.load() == old && Data(contentsOf: file) == oldBytes,
                        "C06 stale/cancelled/closed actual captured callback overwrote current row (\(mode))")
                    check(activity.steps(taskID: id) == oldSteps,
                        "F06 stale/cancelled/closed actual captured callback changed the live step feed (\(mode))")
                }
                await state.release()
                if mode == "current" || mode == "export-failed" {
                    guard await reached({ await state.phase == 3 }), observed.count == 2 else { throw Invalid.callback }
                    let secondTitle = observed[1].1
                    let secondProgress = "Step 2: " + (secondTitle.hasSuffix("…") ? String(secondTitle.dropLast()) : secondTitle)
                    let sawSecond = await state.sawSecond; let secondRows = try sql.load()
                    check(sawSecond && observed[1].0 == 2 && secondRows.first?.progress == secondProgress
                        && bridge.workStatusLines(sessionID: session).contains(secondProgress),
                        "F05 real second backing lost ordered canonical/status progress (\(mode))")
                    await state.release()
                }
                await state.releaseAll()
                await task.value; ownedTask = nil; drained = true
                let ended = await state.snapshot()
                let intact = try Data(contentsOf: first) == Data(firstText.utf8) && Data(contentsOf: second) == Data(secondText.utf8)
                check(!ended.parked && (c.captureVoiceWorkerForTesting(id: job.id)?.task == nil || task.isCancelled) && intact, "C07 SAME worker/read handles or temp bytes did not settle (\(mode))")
                print("VOICE_PROGRESS_CASE mode=\(mode) checks=\(checks-countBefore) actualSteps=\(observed.count) modelCalls=\(ended.calls) sawFirst=\(ended.first) sawSecond=\(ended.second) pending=\(ended.parked)")
                await capture.endSession(source: .done); c.resetForTesting(); activity.voiceProgressObserverForTesting = nil; held = nil
            }
            check(SelfTestStoreGuard.diff(owner, SelfTestStoreGuard.take()).isEmpty, "C08 owner state changed")
        } catch {
            failures.append("voice progress: INVALID \(error)")
            if let ownedID { _ = c.cancel(ownedID) }
            await held?.releaseAll()
            if let ownedTask { await ownedTask.value }; drained = true
            await capture.endSession(source: .done)
        }
        return (checks, failures)
    }
}

private actor VoiceProgressProbe {
    let first: String; let second: String; let firstText: String; let secondText: String; let twoReads: Bool
    private(set) var phase = 0; private(set) var calls = 0
    private(set) var sawFirst = false; private(set) var sawSecond = false
    private var held: CheckedContinuation<Void, Never>?
    private var keepParking = true
    init(first: String, second: String, firstText: String, secondText: String, twoReads: Bool) {
        self.first = first; self.second = second; self.firstText = firstText; self.secondText = secondText; self.twoReads = twoReads
    }
    func release() { let value = held; held = nil; value?.resume() }
    func releaseAll() { keepParking = false; release() }
    struct Snapshot: Sendable { let calls: Int; let parked: Bool; let first: Bool; let second: Bool }
    func snapshot() -> Snapshot { .init(calls: calls, parked: held != nil, first: sawFirst, second: sawSecond) }
    nonisolated func call(_ path: String) throws -> String {
        let args = try JSONSerialization.data(withJSONObject: ["path": path], options: [.sortedKeys])
        return "<tool_call>{\"name\":\"filesystem.read\",\"arguments\":" + String(decoding: args, as: UTF8.self)
            + ",\"rationale\":\"Read the owned progress fixture.\"}</tool_call>"
    }
    func complete(user: String) async throws -> String {
        calls += 1; phase += 1
        if user.contains(firstText) { sawFirst = true }; if user.contains(secondText) { sawSecond = true }
        if keepParking { await withCheckedContinuation { held = $0 } }
        if !sawFirst { return try call(first) }
        if twoReads && !sawSecond { return try call(second) }
        return "The owned progress documents are ready."
    }
}
private struct VoiceProgressProvider: LLMProvider {
    let id = LLMProviderID.appLLM; let probe: VoiceProgressProbe
    var contextTokens: Int { 8_192 }
    var unavailableReason: String? { get async { nil } }
    func countTokens(_ text: String) async throws -> Int { text.count / 4 }
    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        let text = try await probe.complete(user: user)
        return LLMCompletion(text: text, generatedTokens: text.count, duration: 0)
    }
}

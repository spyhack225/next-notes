import Foundation
import SQLite3

/// SAME actual current voice intake. The external frontend supplies an authored
/// conversational fallback; the existing worker seam holds before any account/tool.
@MainActor
enum TaskToolShapeCallsiteSelfTest {
    private enum Invalid: Error { case scope, capability, worker }
    @MainActor private final class FrontendProbe {
        var calls = 0
        func stream() -> AsyncThrowingStream<String, Error> {
            calls += 1
            return AsyncThrowingStream { $0.yield("<answer/>That reached the frontend."); $0.finish() }
        }
    }
    private static func reached(_ predicate: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while ContinuousClock.now < deadline {
            if predicate() { return true }
            await Task.yield()
        }
        return predicate()
    }
    static func run(recorder: RecordingSpeechBacking) async -> (checks: Int, failures: [String]) {
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-voice-work-lifecycle",
              AgentSession.shared.fileURL == nil, !AgentCaptureController.shared.isSessionActive,
              !VoiceConversationCoordinator.shared.hasActiveWork,
              PermissionGate.shared.pending == nil, PermissionGate.shared.queuedCount == 0 else {
            return (0, ["tool shape callsite: INVALID prior owner"])
        }
        let c = VoiceConversationCoordinator.shared, capture = AgentCaptureController.shared
        let speech = AgentSpeechSynthesizer.shared
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let root = temp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard root.path == root.resolvingSymlinksInPath().standardizedFileURL.path,
              root.deletingLastPathComponent().path == temp.path,
              !FileManager.default.fileExists(atPath: root.path) else { return (0, ["tool shape callsite: INVALID root"]) }
        let priorBridge = c.taskBridgeOverrideForTesting, priorRemember = c.rememberExplicit
        let priorFake = AgentToolExecutor.fakeForTesting, priorFire = AgentToolExecutor.fireOverrideForTesting
        let priorPolicy = AgentToolExecutor.policyOverrideForTesting
        let priorInputs = AgentCapabilityManifestBuilder.inputsOverrideForTesting
        let owner = SelfTestStoreGuard.take()
        var owned: Task<Void, Never>?, release: CheckedContinuation<String, Never>?
        var manager: AgentTaskManager?, created = false, safeCleanup = false
        var checks = 0, failures: [String] = []
        func check(_ value: Bool, _ label: String) { checks += 1; if !value { failures.append("tool shape callsite: " + label) } }
        func drain() {
            var remaining = 32
            while (speech.voiceLifecycleSnapshot.hasClause || speech.pendingClauseCount > 0) && remaining > 0 {
                let token = speech.currentPlaybackToken
                speech.notifyTestingFirstAudio(token: token)
                recorder.finishNaturallyForTesting(); speech.notifyTestingAudioFinished(token: token)
                remaining -= 1
            }
        }
        defer {
            c.resetForTesting(); _ = c.installTaskBridgeForTesting(priorBridge); c.rememberExplicit = priorRemember
            AgentToolExecutor.fakeForTesting = priorFake; AgentToolExecutor.fireOverrideForTesting = priorFire
            AgentToolExecutor.policyOverrideForTesting = priorPolicy
            AgentCapabilityManifestBuilder.inputsOverrideForTesting = priorInputs
            speech.restoreSystemBacking()
            if created && safeCleanup { try? FileManager.default.removeItem(at: root) }
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false); created = true
            speech.useTestingBacking(recorder)
            AgentToolExecutor.fakeForTesting = nil
            AgentToolExecutor.policyOverrideForTesting = .denyMutations
            AgentCapabilityManifestBuilder.inputsOverrideForTesting = RealtimeAgentToolLoopSelfTest.allEnabledFixture()
            for (index, pair) in [("Reply to the email.", "send_email"), ("Read my email.", "search_email"), ("Check my inbox.", "search_email")].enumerated() {
                safeCleanup = false
                let start = checks
                let sql = TaskStore(root: root.appendingPathComponent(String(index), isDirectory: true)); defer { sql.close() }
                try FileManager.default.createDirectory(at: sql.fileURL.deletingLastPathComponent(), withIntermediateDirectories: false)
                let store = AgentTaskStore(fileURL: sql.fileURL.deletingLastPathComponent().appendingPathComponent("agent-tasks.json"), mirror: sql)
                guard store.allowsHarnessPersistence, store.save([]).primaryCommitted else { throw Invalid.scope }
                let current = AgentTaskManager(store: store); manager = current
                let bridge = TaskBridge(manager: current)
                c.resetForTesting(); AgentSession.shared.forgetAllConversations()
                guard c.installTaskBridgeForTesting(bridge) else { throw Invalid.scope }
                c.rememberExplicit = { _ in }; c.prewarmObserverForTesting = {}
                let frontend = FrontendProbe()
                var entered = 0, ended = 0, fires = 0
                c.streamForTesting = { _, _ in await frontend.stream() }
                c.workerForTesting = { _ in
                    entered += 1
                    let result = await withCheckedContinuation { release = $0 }
                    ended += 1
                    return result
                }
                AgentToolExecutor.fireOverrideForTesting = { _, _ in fires += 1; throw Invalid.worker }
                await capture.beginSession(captureAudio: false)
                guard let session = capture.sessionID else { throw Invalid.scope }
                let manifest = AgentCapabilityManifest.current(reader: .voiceFrontend)
                guard manifest.allowedIDs.contains(pair.1) else { throw Invalid.capability }
                let direct = AgentDirectIntent.parse(pair.0, wholeSentence: false)
                let question = AgentDirectIntent.questionRoute(in: pair.0, readyIntents: Set(manifest.allowed.map(\.intent)))
                let shape = AgentDirectIntent.toolShapeMatch(in: AgentDirectIntent.normalize(pair.0), allowedIDs: manifest.allowedIDs)
                RealtimeAgent.shared.userSpeechStarted(); RealtimeAgent.shared.userSpeechEnded()
                let turn = await RealtimeAgent.shared.handle(pair.0, source: .voice)
                let frontendCalls = frontend.calls
                let row = current.tasks.first
                let captured = row.flatMap { item in UUID(uuidString: item.id).flatMap { c.captureVoiceWorkerForTesting(id: $0) } }
                owned = captured?.task
                if !current.tasks.isEmpty {
                    guard owned != nil, await reached({ release != nil }) else { throw Invalid.worker }
                }
                check(direct == nil && question == nil && manifest.allowedIDs.contains(pair.1), "C01 actual ready capability and preceding route predicates (case\(index))")
                check(frontendCalls == 0 && turn.reply == "I'm on it.", "F01 actual punctuation command bypassed frontend (case\(index))")
                let positiveOrigin: Bool
                if case .voice(let ownedSession, let ownedTurn)? = row?.origin { positiveOrigin = ownedSession == session && ownedTurn.raw > 0 }
                else { positiveOrigin = false }
                check(current.tasks.count == 1 && entered == 1 && ended == 0 && positiveOrigin
                    && captured?.id.uuidString == row?.id && captured?.task == owned,
                    "F02 actual one admitted current Task reached existing held worker (case\(index))")
                let rows = try sql.load()
                check(rows.map(\.id) == current.tasks.map(\.id)
                    && rows.allSatisfy { $0.source == "voice" && $0.status == .running },
                    "C02 actual SQL/current ownership metadata (case\(index))")
                check(fires == 0 && PermissionGate.shared.pending == nil && PermissionGate.shared.queuedCount == 0,
                    "C03 no permission/effect/account backing before qualifier (case\(index))")
                print("TOOL_SHAPE_CALLSITE case=\(index) direct=\(direct != nil) question=\(question != nil) shapeExpected=\(shape == pair.1) frontendCalls=\(frontendCalls) rows=\(current.tasks.count) entered=\(entered) ended=\(ended) sameTask=\(captured?.task != nil && captured?.task == owned) acceptedReply=\(turn.reply == "I'm on it.") fallbackReply=\(turn.reply == "That reached the frontend.") effects=\(fires)")
                release?.resume(returning: "Owned route worker returned."); release = nil
                if let owned { await owned.value }; owned = nil
                drain()
                check(entered == ended && current.tasks.allSatisfy { item in
                    guard let id = UUID(uuidString: item.id) else { return false }
                    return current.voiceOwnedOperationForTesting(id: id) == nil
                }, "C04 actual same worker returned before cleanup (case\(index))")
                await capture.endSession(source: .done); c.resetForTesting(); manager = nil; drain()
                safeCleanup = true
                print("TOOL_SHAPE_CALLSITE_CASE case=\(index) checks=\(checks-start) joined=\(entered == ended)")
            }
            check(SelfTestStoreGuard.diff(owner, SelfTestStoreGuard.take()).isEmpty, "C05 owner/default invariant")
        } catch {
            failures.append("tool shape callsite: INVALID \(error)")
            if let manager { for row in manager.tasks { if let id = UUID(uuidString: row.id) { _ = c.cancel(id) } } }
            release?.resume(returning: "Owned invalid route cleanup."); release = nil
            if let owned { await owned.value; safeCleanup = true } else { safeCleanup = manager?.tasks.isEmpty != false }
            owned = nil; drain()
            if capture.isSessionActive { await capture.endSession(source: .done) }
        }
        return (checks, failures)
    }
}

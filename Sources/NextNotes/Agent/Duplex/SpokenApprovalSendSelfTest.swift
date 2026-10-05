import Foundation
import SQLite3

/// Actual current voice intake -> planned key executor -> Gate -> SAME scheduler/audio.
/// External model stream and final application-key backing are scripted. No approval,
/// task, review or positive playback receipt is seeded. Physical audio/key proof is open.
@MainActor
enum SpokenApprovalSendSelfTest {
    private enum Invalid: Error { case unsafe, owner, worker, grammar, context }
    private static func reached(_ predicate: @MainActor () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while ContinuousClock.now < deadline {
            if await predicate() { return true }
            await Task.yield()
        }
        return await predicate()
    }
    static func run(recorder: RecordingSpeechBacking) async -> (checks: Int, failures: [String]) {
        let c = VoiceConversationCoordinator.shared, capture = AgentCaptureController.shared
        let gate = PermissionGate.shared, synth = AgentSpeechSynthesizer.shared
        let playback = VoicePlaybackDelivery.shared
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-voice-delivery",
              AgentSession.shared.fileURL == nil, !capture.isSessionActive,
              c.taskBridge.liveVoiceTasks(owner: c).isEmpty, gate.pending == nil, gate.queuedCount == 0 else {
            return (0, ["spoken send: INVALID prior owner"])
        }
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let root = temp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard root.path == root.resolvingSymlinksInPath().standardizedFileURL.path,
              root.deletingLastPathComponent().path == temp.path,
              !FileManager.default.fileExists(atPath: root.path) else { return (0, ["spoken send: INVALID root"]) }
        let priorBridge = c.taskBridgeOverrideForTesting, priorRemember = c.rememberExplicit
        let priorFake = AgentToolExecutor.fakeForTesting, priorFire = AgentToolExecutor.fireOverrideForTesting
        let priorPolicy = AgentToolExecutor.policyOverrideForTesting
        let priorInputs = AgentCapabilityManifestBuilder.inputsOverrideForTesting
        let priorWhole = PlannerBackends.wholeTurnOverrideForTesting, priorNeedle = ToolLoopLiveEval.needleFirstForTesting
        let owner = SelfTestStoreGuard.take(), grants = PermissionGrantStore.shared.grants
        func currentCapture() -> VoiceWorkerTestCapture? {
            guard let raw = c.taskBridge.cachedTasks.first(where: { $0.source == "voice" })?.id,
                  let id = UUID(uuidString: raw) else { return nil }
            return c.captureVoiceWorkerForTesting(id: id)
        }
        var currentManager: AgentTaskManager?, owned: Task<Void, Never>?, probe: ApprovalSendProbe?
        var created = false, installedContext = false, contextRejected = false, contextReads = 0
        var checks = 0; var failures: [String] = []
        func check(_ value: Bool, _ label: String) { checks += 1; if !value { failures.append("spoken send: " + label) } }
        func input(_ text: String) async -> AgentTurn {
            RealtimeAgent.shared.userSpeechStarted(); RealtimeAgent.shared.userSpeechEnded()
            return await RealtimeAgent.shared.handle(text, source: .voice)
        }
        defer {
            c.resetForTesting(); _ = c.installTaskBridgeForTesting(priorBridge)
            c.rememberExplicit = priorRemember
            AgentToolExecutor.fakeForTesting = priorFake; AgentToolExecutor.fireOverrideForTesting = priorFire
            AgentToolExecutor.policyOverrideForTesting = priorPolicy
            AgentCapabilityManifestBuilder.inputsOverrideForTesting = priorInputs
            PlannerBackends.wholeTurnOverrideForTesting = priorWhole; ToolLoopLiveEval.needleFirstForTesting = priorNeedle
            _ = playback.installOutputForTesting(nil)
            if installedContext { _ = ToolCallContextBuilder.setMeetingContextForTesting(nil, root: root) }
            if created { try? FileManager.default.removeItem(at: root) }
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false); created = true
            guard ToolCallContextBuilder.setMeetingContextForTesting({ meeting, task in
                contextReads += 1
                guard root.path == root.resolvingSymlinksInPath().standardizedFileURL.path,
                      FileManager.default.fileExists(atPath: root.path), meeting == nil,
                      let task, currentManager?.task(id: task)?.source == "voice" else {
                    contextRejected = true; return nil // Never fall back to owner context.
                }
                return ToolCallContext()
            }, root: root) else { throw Invalid.context }
            installedContext = true
            AgentToolExecutor.fakeForTesting = nil; AgentToolExecutor.policyOverrideForTesting = .denyMutations
            AgentCapabilityManifestBuilder.inputsOverrideForTesting = RealtimeAgentToolLoopSelfTest.allEnabledFixture()
            PlannerBackends.wholeTurnOverrideForTesting = nil; ToolLoopLiveEval.needleFirstForTesting = false
            for mode in ["full", "partial", "long", "unsafe", "edited", "card", "no"] {
                let start = checks
                let directory = root.appendingPathComponent(mode, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                let sql = TaskStore(root: directory); defer { sql.close() }
                let file = directory.appendingPathComponent("agent-tasks.json")
                let store = AgentTaskStore(fileURL: file, mirror: sql)
                guard store.allowsHarnessPersistence, store.save([]).primaryCommitted else { throw Invalid.unsafe }
                let manager = AgentTaskManager(store: store), bridge = TaskBridge(manager: manager)
                currentManager = manager
                guard let output = OutputScheduler.isolatedForTesting(bridge),
                      c.installTaskBridgeForTesting(bridge), playback.installOutputForTesting(output) else { throw Invalid.unsafe }
                let message = mode == "long" ? String(repeating: "The owned report is ready for review. ", count: 18)
                    : mode == "unsafe" ? "The complete owned report is at https://owned.invalid/report."
                    : "Hi Marie, here is the deck we talked about. Thanks!"
                let requested = "Send an email to marie.dupont@acme.com with subject The deck and this exact message: " + message
                let state = ApprovalSendProbe(request: requested, message: message); probe = state
                c.rememberExplicit = { _ in }; c.prewarmObserverForTesting = {}
                c.workerForTesting = nil
                c.workerProviderForTesting = ApprovalSendProvider(probe: state)
                c.streamForTesting = { _, messages in await state.frontend(messages) }
                var fired: [[String: String]] = []
                AgentToolExecutor.fireOverrideForTesting = { tool, arguments in
                    guard tool.id == "send_email", arguments["to"] == "marie.dupont@acme.com",
                          arguments["subject"] == "The deck", arguments["body"] == message else { throw Invalid.unsafe }
                    fired.append(arguments)
                    return AgentToolResult(summary: "The owned message was sent by the controlled transport.")
                }
                await capture.beginSession(captureAudio: false)
                let intake = await input(requested); owned = currentCapture()?.task
                guard let job = currentCapture(), let task = owned,
                      await reached({ await state.heldCount > 0 }), let session = capture.sessionID else { throw Invalid.worker }
                check(intake.reply == "I'm on it." && c.taskBridge.cachedTasks.filter { $0.source == "voice" }.count == 1 && fired.isEmpty
                    && manager.task(id: job.id.uuidString)?.source == "voice",
                    "SC01 actual current managed send worker (\(mode))")
                drain(synth, recorder); recorder.reset()
                guard let reader = AgentCapabilityManifestRuntime.publishedReader else { throw Invalid.grammar }
                let manifest = AgentCapabilityManifestBuilder.build(.live(reader: reader), request: requested)
                let call = try state.call()
                guard manifest.allowedIDs.contains("send_email"), LlamaGrammarPlanner.grammar(for: manifest).matches(call),
                      AgentToolCallParser.parse(call, knownNames: RealtimeAgent.callNames(manifest)).calls.first?.name == "send_email" else { throw Invalid.grammar }
                await state.release()
                guard await reached({ gate.pending?.taskID == job.id.uuidString }), let request = gate.pending,
                      let review = ToolCallReviewStore.shared.review(id: request.id), !contextRejected else { throw Invalid.context }
                check(request.toolID == "send_email" && request.risk == .send && request.arguments["body"] == message
                    && review.executionArguments(mergedOver: request.arguments)["body"] == message.trimmingCharacters(in: .whitespacesAndNewlines) && fired.isEmpty,
                    "SC02 same declared send review/executable full payload (\(mode))")
                guard review.isReadyToRun else { throw Invalid.context }
                let row = try sql.load().first
                let exactRequest: Bool = if case .permission(let saved, _, _) = row?.pendingInteraction { saved.id == request.id } else { false }
                check(row?.status == .waitingForPermission && exactRequest,
                    "SF01 same send proposal primary admission (\(mode))")
                output.setNowForTesting(Date().addingTimeInterval(2))
                let flushed = output.flush(userHasFloor: false)
                check(flushed && output.activeOutputID != nil && bridge.pendingApproval(sessionID: session)?.request.id == request.id,
                    "SF02 same send prompt/current OutputID (\(mode))")
                if mode == "partial" {
                    synth.notifyTestingFirstAudio(token: synth.currentPlaybackToken)
                } else { drain(synth, recorder) }
                let spoken = bridge.pendingApproval(sessionID: session)
                if mode == "full" || mode == "no" || mode == "card" || mode == "edited" {
                    check(spoken?.heardStart == true && spoken?.heardFully == true && spoken?.prompt.messageBody == message
                        && spoken?.prompt.executionArguments == review.executionArguments(mergedOver: request.arguments),
                        "SF03 full same-message ordered playback receipt (\(mode))")
                } else {
                    check(mode == "partial" ? spoken?.heardFully == false : spoken?.prompt.voiceMayApprove == false,
                        "SF04 partial/long/unsafe send not speak-approved (\(mode))")
                }
                var reply = ""
                if mode == "card" {
                    guard !contextRejected, gate.respond(id: request.id, approved: true) else { throw Invalid.owner }
                    let completed = await reached({ fired.count == 1 }); if completed { await task.value }
                    check(completed && fired.first?["body"] == message && gate.pending == nil,
                        "SC03 same actual card decision uses controlled complete message transport")
                } else {
                    if mode == "edited" { ToolCallReviewStore.shared.update(id: request.id, field: "body", to: message + " Changed.") }
                    reply = await input(mode == "no" ? "No." : "Yes.").reply
                    if mode == "full" {
                        let completed = await reached({ fired.count == 1 }); if completed { await task.value }
                        check(completed && fired.first?["body"] == message && gate.pending == nil && reply == "Sending it.",
                            "SF05 heard whole exact message releases one actual controlled send")
                    } else if mode == "no" {
                        check(gate.pending == nil && fired.isEmpty && reply == "Okay, I won't send it.",
                            "SF06 heard no refuses SAME send request")
                    } else {
                        check(gate.pending?.id == request.id && fired.isEmpty && PermissionGrantStore.shared.grants == grants,
                            "SC04 partial/long/unsafe/edited yes never fires or grants (\(mode))")
                        check(reply == (mode == "edited" ? "It changed on screen, so please approve it there."
                            : mode == "partial" ? "I'll read the whole message first."
                            : "Please check the whole message and send it on screen."),
                            "SF07 honest send refusal uses current preview boundary (\(mode))")
                    }
                }
                if currentCapture()?.task != nil { _ = c.cancel(job.id) }
                await state.release(); await task.value; owned = nil
                drain(synth, recorder)
                if capture.isSessionActive { await capture.endSession(source: .done) }
                c.resetForTesting(); _ = c.installTaskBridgeForTesting(nil)
                output.setNowForTesting(nil); _ = playback.installOutputForTesting(nil)
                ToolCallReviewStore.shared.remove(id: request.id)
                check(gate.pending == nil && gate.queuedCount == 0 && c.barrierWaiterCountForTesting == 0
                    && PermissionGrantStore.shared.grants == grants,
                    "SC05 same send waiter/grant cleanup (\(mode))")
                print("SPOKEN_SEND_CASE mode=\(mode) checks=\(checks-start) fireCount=\(fired.count) sameBody=\(fired.first?["body"] == message) physical=false account=false")
                currentManager = nil; probe = nil
            }
            check(contextReads > 0 && !contextRejected, "SC06 actual request/task scoped context stayed isolated")
            check(SelfTestStoreGuard.diff(owner, SelfTestStoreGuard.take()).isEmpty, "SC07 owner store/default invariant")
        } catch {
            failures.append("spoken send: INVALID \(error)")
            for row in c.taskBridge.cachedTasks where row.source == "voice" { if let id = UUID(uuidString: row.id) { _ = c.cancel(id) } }
            await probe?.release(); if let owned { await owned.value }
            if capture.isSessionActive { await capture.endSession(source: .done) }
        }
        return (checks, failures)
    }
    private static func drain(_ synth: AgentSpeechSynthesizer, _ recorder: RecordingSpeechBacking) {
        var bound = 32
        while (synth.voiceLifecycleSnapshot.hasClause || synth.pendingClauseCount > 0) && bound > 0 {
            synth.notifyTestingFirstAudio(token: synth.currentPlaybackToken)
            recorder.finishNaturallyForTesting(); synth.notifyTestingAudioFinished(token: synth.currentPlaybackToken)
            bound -= 1
        }
    }
}
private actor ApprovalSendProbe {
    let request: String; let message: String
    private var hold: CheckedContinuation<Void, Never>?
    private var first = true
    var heldCount: Int { hold == nil ? 0 : 1 }
    init(request: String, message: String) { self.request = request; self.message = message }
    func release() { let old = hold; hold = nil; old?.resume() }
    func frontend(_ messages: [LLMChatMessage]) -> AsyncThrowingStream<String, Error> {
        let value = messages.last?.content.hasSuffix("Latest user speech:\n" + request) == true ? "<use_tools/>" : "<answer>I heard that.</answer>"
        return AsyncThrowingStream { $0.yield(value); $0.finish() }
    }
    nonisolated func call() throws -> String {
        // SAME native catalogue order: to, subject, body. No unadvertised cc/bcc.
        let encodedBody = String(decoding: try JSONEncoder().encode(message), as: UTF8.self)
        return "<tool_call>{\"name\":\"send_email\",\"arguments\":{\"to\":\"marie.dupont@acme.com\",\"subject\":\"The deck\",\"body\":"
            + encodedBody + "},\"rationale\":\"Send the exact owned requested message after approval.\"}</tool_call>"
    }
    func complete(_ user: String) async throws -> String {
        if user.contains("The owned message was sent by the controlled transport.") { return "The owned message result is ready." }
        if first { first = false; await withCheckedContinuation { hold = $0 } }
        return try call()
    }
}
private struct ApprovalSendProvider: LLMProvider {
    let id = LLMProviderID.appLLM; let probe: ApprovalSendProbe
    var contextTokens: Int { 8_192 }
    var unavailableReason: String? { get async { nil } }
    func countTokens(_ text: String) async throws -> Int { text.count / 4 }
    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        let text = try await probe.complete(user)
        return LLMCompletion(text: text, generatedTokens: text.count, duration: 0)
    }
}

import Foundation

/// Runs the production frontend, capture policy and planned workers with scripted models.
/// No microphone, model weights, external tools, or user-history writes.
enum VoiceWorkLifecycleSelfTest {
    @MainActor
    static func run() async -> Bool {
        let shadow = VoiceSession.shared
        shadow.resetDiagnosticsForTesting()
        let agent = RealtimeAgent.shared
        let capture = AgentCaptureController.shared
        let conversation = VoiceConversationCoordinator.shared
        let speech = AgentSpeechSynthesizer.shared
        let recorder = RecordingSpeechBacking()
        var failures: [String] = []
        func check(_ value: Bool, _ message: String) { if !value { failures.append(message) } }
        func speak(_ text: String) async -> AgentTurn {
            agent.userSpeechStarted()
            agent.userSpeechEnded()
            return await agent.handle(text, source: .voice)
        }
        speech.useTestingBacking(recorder)
        let oldExecutor = AgentToolExecutor.fakeForTesting
        AgentToolExecutor.fakeForTesting = { _, _ in AgentToolResult(summary: "Nothing is frontmost.") }
        defer {
            conversation.resetForTesting()
            agent.localModelProviderForTesting = nil
            agent.budgetForTesting = nil
            AgentToolExecutor.fakeForTesting = oldExecutor
            speech.restoreSystemBacking()
            Task { @MainActor in await capture.endSession(source: .done) }
        }
        await capture.endSession(source: .done)
        AgentSession.shared.forgetAllConversations()
        await capture.beginSession(captureAudio: false)
        conversation.resetForTesting()
        let state = VoiceWorkLifecycleProbe()
        conversation.workerProviderForTesting = VoiceWorkLifecycleProvider(state: state)
        conversation.streamForTesting = { _, messages in
            let response = messages.last?.content.hasSuffix("What is a haiku?") == true
                ? "<answer/>A haiku is a short poem." : "<use_tools/>"
            return AsyncThrowingStream { $0.yield(response); $0.finish() }
        }
        await state.parkNext(answer: "The objective remains active.")
        _ = await speak("Check the active app and its running sessions.")
        for _ in 0..<200 {
            if await state.isParked { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        check(await state.isParked, "planned worker never reached its parked provider")
        let original = conversation.jobs.first
        // A deliberately incompatible *typed* override must not reroute voice. It does
        // not supply the voice reply; this assertion catches the old routing producer.
        agent.localModelProviderForTesting = VoiceWorkLifecycleProvider(state: VoiceWorkLifecycleProbe())
        let side = await speak("What is a haiku?")
        agent.localModelProviderForTesting = nil
        check(side.reply == "A haiku is a short poem.", "typed provider override rerouted voice away from coordinator")
        check(original != nil && conversation.jobs.first?.status == "running"
              && original?.work.revision == 0, "side question cancelled or revised the real worker")

        recorder.reset()
        capture.simulateSpeech("Cancel that")
        capture.simulateSilence()
        check(await capture.considerEndpoint(), "explicit cancel did not endpoint")
        await capture.waitForActiveTurnForTesting()
        check(agent.lastReply == "I stopped that task.", "explicit cancel did not confirm the stopped task")
        check(conversation.jobs.first?.id == original?.id && conversation.jobs.first?.status == "cancelled",
              "explicit cancel retained/replaced the active job")
        check(original.map { job in AgentTaskManager.shared.tasks.contains {
            $0.id == job.id.uuidString && $0.status == .cancelled
        }} == true, "real task ledger did not record cancellation")
        await state.release()
        try? await Task.sleep(for: .milliseconds(30))
        _ = VoiceAnnouncementQueue.shared.flush(userHasFloor: false)
        check(!recorder.spoken.contains("The objective remains active."), "cancelled producer spoke a stale answer")
        await capture.endSession(source: .done)

        // C1: the actual planner is parked on round one. A stalled frontend owns
        // the input epoch while that round produces a read. Its deadline must reopen
        // planning/reads, while the separate write-effect hold remains in force.
        await capture.beginSession(captureAudio: false)
        conversation.resetForTesting()
        let stalled = VoiceFailureWorkerProbe()
        conversation.workerProviderForTesting = VoiceFailureWorkerProvider(state: stalled)
        conversation.streamForTesting = { _, _ in
            AsyncThrowingStream { $0.yield("<use_tools/>"); $0.finish() }
        }
        _ = await speak("Inspect the frontmost app.")
        for _ in 0..<200 {
            if await stalled.parked { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        check(await stalled.parked, "C1 worker never parked on real planner round one")
        conversation.responseDeadlineForTesting = .milliseconds(200)
        conversation.streamForTesting = { _, _ in AsyncThrowingStream { _ in } }
        agent.userSpeechStarted()
        agent.userSpeechEnded()
        let failedTurn = Task { @MainActor in await agent.handle("Stall please.", source: .voice) }
        for _ in 0..<100 {
            if conversation.inputPending { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        check(conversation.inputPending, "C1 frontend never owned the input barrier")
        await stalled.release()
        _ = await failedTurn.value
        let failedAt = ContinuousClock.now
        check(conversation.lastFailure?.code == .deadline, "C1 frontend did not fail at its real deadline")
        check(!conversation.inputPending && conversation.effectHoldEpoch != nil,
              "C1 failure did not release reads and retain the effect hold")
        for _ in 0..<100 {
            if await stalled.roundTwoAt != nil { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        let resumed = await stalled.roundTwoAt
        check(resumed.map { failedAt.duration(to: $0) <= .milliseconds(200) } == true,
              "C1 real planner round two did not resume within 200 ms")
        for _ in 0..<200 {
            if conversation.jobs.first?.status == "finished" { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        check(conversation.jobs.first?.result == "The read finished.", "C1 actual worker did not finish its read")
        check(conversation.effectHoldEpoch != nil, "C1 worker completion released unclassified effects")
        print("VOICE_WORK_LIFECYCLE_C1: round2_ms=\(resumed.map { String(ModelPassRecorder.milliseconds(failedAt.duration(to: $0))) } ?? "absent") status=\(conversation.jobs.first?.status ?? "absent")")
        await capture.endSession(source: .done)
        conversation.resetForTesting()

        failures.append(contentsOf: await runRevisionCases(check: { _ in }))

        await Task.yield()
        shadow.printDiagnostics()
        check(shadow.divergenceCount == 0, "shadow producer divergence")
        check(["effectsHeld", "turnPending", "output"].allSatisfy { shadow.comparisonCounts[$0, default: 0] > 0 },
              "shadow sampler lacked covered fields")
        check(shadow.outputPresenceComparisonCount > 0, "shadow output presence coverage absent")
        for failure in failures { print("VOICE_WORK_LIFECYCLE_WRONG: \(failure)") }
        print(failures.isEmpty ? "VOICE_WORK_LIFECYCLE_OK" : "VOICE_WORK_LIFECYCLE_FAILED")
        return failures.isEmpty
    }

    /// P1-06, H1 #17: a correction restarts the round clock.
    ///
    /// A spoken objective is revised by the person mid-flight. The revision starts the round
    /// deadline over, and once every ten seconds it also tops the ceiling back up to half of
    /// what the budget allows — so a corrected objective does not begin against the clock the
    /// *previous* wording spent. Measured on 2026-09-14: three follow-up revisions each ended
    /// "The model took too long to answer." two to three seconds after the follow-up arrived.
    ///
    /// The correction is delivered while the model is parked mid-round, so the case does not
    /// depend on winning a race with a stopwatch. A second correction inside the interval must
    /// not refill again, and the round after it must then run out of ceiling.
    @MainActor
    static func runRevisionCases(check: (String) -> Void) async -> [String] {
        var failures: [String] = []
        func fail(_ name: String) { failures.append(name); check(name) }

        let answer = "Two unread messages."
        let timeoutSentence = AgentReplyRenderer.render(.timedOut(lastVerified: nil), voice: true)
        let budget = ToolLoopBudget(
            perRound: .seconds(2), perReadCall: .seconds(1),
            ceiling: .seconds(3), coldLoadAllowance: .zero)
        let call = "<tool_call>{\"name\":\"computer.active_app\",\"arguments\":{},"
            + "\"rationale\":\"look\"}</tool_call>"

        /// One worker run: two slow tool rounds and then the answer, with the corrections
        /// delivered into the parked rounds named in `parkOn`.
        @MainActor
        func run(parkOn: Set<Int>) async -> (String, VoiceBudgetProbe)? {
            let work = VoiceConversationWork("check the frontmost app and its running sessions")
            let agent = RealtimeAgent(voiceWorker: work)
            let probe = VoiceBudgetProbe(parkOn: parkOn)
            agent.localModelProviderForTesting = VoiceBudgetScriptProvider(
                probe: probe, script: [call, call, answer, "A stale answer."])
            agent.budgetForTesting = budget
            let previousExecutor = AgentToolExecutor.fakeForTesting
            AgentToolExecutor.fakeForTesting = { _, _ in
                AgentToolResult(summary: "Nothing is frontmost.")
            }
            defer { AgentToolExecutor.fakeForTesting = previousExecutor }
            let task = Task { @MainActor in await agent.runVoiceObjective() }
            for index in parkOn.sorted() {
                // Long enough to cover the rounds before it: each of those spends its own
                // scripted delay first, and this is a wall clock, not a model.
                var reached = false
                for _ in 0..<2_000 {
                    if await probe.isParked(on: index) { reached = true; break }
                    try? await Task.sleep(for: .milliseconds(3))
                }
                guard reached else {
                    let reply = await task.value
                    fail("the worker never parked on round \(index) — it made "
                        + "\(await probe.roundsMade()) round(s) and answered \"\(reply)\"")
                    return nil
                }
                work.append("and only the unread ones")
                await probe.release(on: index)
            }
            let reply = await task.value
            return (reply, probe)
        }

        do {
            guard let (reply, _) = await run(parkOn: [2]) else { return failures }
            if reply != answer { fail("a corrected objective answered \"\(reply)\"") }
            if reply.contains(timeoutSentence) {
                fail("a corrected objective was charged to the clock the first wording spent: "
                    + "\"\(reply)\"")
            }
        }
        do {
            guard let (reply, _) = await run(parkOn: [2, 3]) else { return failures }
            if reply.contains(answer) {
                fail("a second correction inside the interval refilled the ceiling again: "
                    + "\"\(reply)\"")
            }
            if !reply.contains(timeoutSentence) {
                fail("a second correction inside the interval still left a reply: \"\(reply)\"")
            }
        }
        return failures
    }
}

/// P1-06's probe: one scripted round at a time, with the rounds the case names parked so a
/// correction can be delivered while the model is provably mid-round. Rounds are numbered
/// from one, as a person would count them.
private actor VoiceBudgetProbe {
    private let parkOn: Set<Int>
    private var call = 0
    private var parked: Set<Int> = []
    private var released: Set<Int> = []

    init(parkOn: Set<Int>) { self.parkOn = parkOn }

    func isParked(on round: Int) -> Bool { parked.contains(round) }

    /// How many model calls this probe was actually asked for. Named in a failure, because
    /// "never parked" is a symptom and this is the fact.
    func roundsMade() -> Int { call }

    func release(on round: Int) { released.insert(round) }

    /// One round's text, after the delay this case wants that round to take. A parked round
    /// is given a shorter one, so the round's own deadline still has room for the case to
    /// deliver the correction while the model is parked.
    func response(script: [String], delay: Duration) async throws -> String {
        call += 1
        let round = call
        let wait = parkOn.contains(round) ? delay * 4 / 5 : delay
        if wait > .zero { try await Task.sleep(for: wait) }
        if parkOn.contains(round) {
            parked.insert(round)
            while !released.contains(round) {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        return round <= script.count ? script[round - 1] : "There is nothing more to add."
    }
}

private struct VoiceBudgetScriptProvider: LLMProvider {
    let id = LLMProviderID.appLLM
    let probe: VoiceBudgetProbe
    let script: [String]
    /// Long enough that two of them nearly spend a three-second ceiling, and the refill that
    /// follows has to be what pays for the round after them.
    let delay: Duration = .seconds(1)
    var contextTokens: Int { 8_192 }
    var unavailableReason: String? { get async { nil } }
    func countTokens(_ text: String) async throws -> Int { text.count / 4 }
    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        let text = try await probe.response(script: script, delay: delay)
        return LLMCompletion(text: text, generatedTokens: text.count, duration: 0)
    }
}

private actor VoiceWorkLifecycleProbe {
    private(set) var calls = 0
    private(set) var isParked = false
    private var shouldPark = false
    private var released = false
    private var parkedAnswer = ""

    func parkNext(answer: String) {
        shouldPark = true
        released = false
        isParked = false
        parkedAnswer = answer
    }
    func release() { released = true }
    func response() async throws -> String {
        calls += 1
        if shouldPark {
            isParked = true
            while !released {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(5))
            }
            shouldPark = false
            return parkedAnswer
        }
        return "The objective remains active."
    }
}

private struct VoiceWorkLifecycleProvider: LLMProvider {
    let id = LLMProviderID.appLLM
    let state: VoiceWorkLifecycleProbe
    var contextTokens: Int { 8_192 }
    var unavailableReason: String? { get async { nil } }
    func countTokens(_ text: String) async throws -> Int { text.count / 4 }
    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        let answer = try await state.response()
        return LLMCompletion(text: answer, generatedTokens: answer.count, duration: 0)
    }
}

private actor VoiceFailureWorkerProbe {
    private(set) var parked = false
    private(set) var roundTwoAt: ContinuousClock.Instant?
    private var released = false
    private var rounds = 0
    func release() { released = true }
    func response() async throws -> String {
        rounds += 1
        if rounds == 1 {
            parked = true
            while !released {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(2))
            }
            return #"<tool_call>{"name":"computer.active_app","arguments":{},"rationale":"Inspect the app"}</tool_call>"#
        }
        roundTwoAt = .now
        return "The read finished."
    }
}

private struct VoiceFailureWorkerProvider: LLMProvider {
    let id = LLMProviderID.appLLM
    let state: VoiceFailureWorkerProbe
    var contextTokens: Int { 8_192 }
    var unavailableReason: String? { get async { nil } }
    func countTokens(_ text: String) async throws -> Int { text.count / 4 }
    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        let text = try await state.response()
        return LLMCompletion(text: text, generatedTokens: text.count, duration: 0)
    }
}

import Foundation

/// Runs real voice handle/capture policy with a controllable local provider.
/// No microphone, model weights, external tools, or user-history writes.
enum VoiceWorkLifecycleSelfTest {
    @MainActor
    static func run() async -> Bool {
        let agent = RealtimeAgent.shared
        let capture = AgentCaptureController.shared
        let speech = AgentSpeechSynthesizer.shared
        let recorder = RecordingSpeechBacking()
        let state = VoiceWorkLifecycleProbe()
        var failures: [String] = []
        speech.useTestingBacking(recorder)
        agent.localModelProviderForTesting = VoiceWorkLifecycleProvider(state: state)
        // P1-06: the budget is three numbers now. These two cases want exactly what the
        // single `toolLoopLimitForTesting` used to say — one number, and one deadline for
        // everything — so `perRound` and `ceiling` both carry it.
        agent.budgetForTesting = .init(
            perRound: .milliseconds(120), perReadCall: .milliseconds(120),
            ceiling: .milliseconds(120), coldLoadAllowance: .zero)
        defer {
            agent.localModelProviderForTesting = nil
            agent.budgetForTesting = nil
            speech.restoreSystemBacking()
            Task { @MainActor in await capture.endSession(source: .done) }
        }

        AgentSession.shared.forgetAllConversations()
        await capture.endSession(source: .done)
        await capture.beginSession(captureAudio: false)
        await state.parkNext(answer: "The objective remains active.")
        let heldTurn = Task { @MainActor in
            await agent.handle("Check the active app and its running sessions.", source: .voice)
        }
        for _ in 0..<100 {
            if await state.isParked { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        if !(await state.isParked) { failures.append("provider never started before held floor") }
        agent.userSpeechStarted()
        await state.release()
        try? await Task.sleep(for: .milliseconds(250))
        if !agent.isThinking { failures.append("completed model reply replaced unfinished speech") }
        agent.userSpeechEnded()
        let heldResult = await heldTurn.value
        if heldResult.reply != "The objective remains active." {
            failures.append("held floor spent inference budget or lost response: \(heldResult.reply)")
        }
        await capture.endSession(source: .done)

        AgentSession.shared.forgetAllConversations()
        agent.budgetForTesting = .init(
            perRound: .seconds(1), perReadCall: .seconds(1),
            ceiling: .seconds(1), coldLoadAllowance: .zero)
        await state.parkNext(answer: "A stale answer after cancel.")
        await capture.beginSession(captureAudio: false)
        let cancelledTurn = Task { @MainActor in
            await agent.handle("Check the active app and its running sessions.", source: .voice)
        }
        for _ in 0..<100 {
            if await state.isParked { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        if !(await state.isParked) { failures.append("provider never reached parked model boundary") }
        let originalWork = agent.voiceWork?.id
        capture.simulateSpeech("Cancel that")
        capture.simulateSilence()
        if !(await capture.considerEndpoint()) { failures.append("explicit cancel did not endpoint") }
        if originalWork == nil || agent.voiceWork != nil || agent.isThinking {
            failures.append("explicit cancel retained active work")
        }
        await state.release()
        _ = await cancelledTurn.value
        try? await Task.sleep(for: .milliseconds(30))
        if recorder.spoken.contains("A stale answer after cancel.") {
            failures.append("cancelled producer spoke a stale answer")
        }
        await capture.endSession(source: .done)

        failures.append(contentsOf: await runRevisionCases(check: { failures.append($0) }))

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
            AgentToolExecutor.fakeForTesting = { tool, _ in
                AgentToolResult(summary: "Nothing is frontmost.")
            }
            defer { AgentToolExecutor.fakeForTesting = nil }
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
            if reply.contains("too long") {
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
            if !reply.contains("too long") {
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

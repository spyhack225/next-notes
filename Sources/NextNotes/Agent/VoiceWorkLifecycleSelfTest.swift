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
        agent.toolLoopLimitForTesting = .milliseconds(120)
        defer {
            agent.localModelProviderForTesting = nil
            agent.toolLoopLimitForTesting = nil
            speech.restoreSystemBacking()
            Task { @MainActor in await capture.endSession(source: .done) }
        }

        AgentSession.shared.clear()
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

        AgentSession.shared.clear()
        agent.toolLoopLimitForTesting = .seconds(1)
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

        for failure in failures { print("VOICE_WORK_LIFECYCLE_WRONG: \(failure)") }
        print(failures.isEmpty ? "VOICE_WORK_LIFECYCLE_OK" : "VOICE_WORK_LIFECYCLE_FAILED")
        return failures.isEmpty
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
    let id = LLMProviderID.gemma4E4B
    let state: VoiceWorkLifecycleProbe
    var contextTokens: Int { 8_192 }
    var unavailableReason: String? { get async { nil } }
    func countTokens(_ text: String) async throws -> Int { text.count / 4 }
    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        let answer = try await state.response()
        return LLMCompletion(text: answer, generatedTokens: answer.count, duration: 0)
    }
}

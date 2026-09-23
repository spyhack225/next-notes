import Foundation

/// Production-route probe for the opt-in local answer path. The fake provider is only
/// injected for this test; all assertions go through `RealtimeAgent.handle` and the real
/// streaming speech bridge.
enum RealtimeAgentLocalModelSelfTest {
    @MainActor
    @discardableResult
    static func run() async -> Bool {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        let agent = RealtimeAgent.shared
        let synthesizer = AgentSpeechSynthesizer.shared
        let recorder = RecordingSpeechBacking()
        synthesizer.useTestingBacking(recorder)
        agent.localModelProviderForTesting = nil
        await AgentCaptureController.shared.endSession(source: .done)

        defer {
            agent.localModelProviderForTesting = nil
            agent.localModelLimitForTesting = nil
            synthesizer.restoreSystemBacking()
            Task { @MainActor in await AgentCaptureController.shared.endSession(source: .done) }
        }

        let state = LocalAnswerTestState()
        check("Agent history did not survive a disk round trip", AgentSession.persistenceSelfTest())
        AgentSession.shared.recordUser("What was the project codename?", source: .voice)
        AgentSession.shared.recordAssistant("The project codename is Silver Fern.")
        let duplicateStart = Date()
        check("voice duplicate was not detected",
              AgentSession.shared.isRecentDuplicateVoiceTurn(
                  "what was the project codename", now: duplicateStart
              ))
        check("rolling voice duplicate window expired while repeats continued",
              AgentSession.shared.isRecentDuplicateVoiceTurn(
                  "What was the project codename?", now: duplicateStart.addingTimeInterval(11)
              ) && AgentSession.shared.isRecentDuplicateVoiceTurn(
                  "What was the project codename?", now: duplicateStart.addingTimeInterval(20)
              ))
        check("different voice request was suppressed",
              !AgentSession.shared.isRecentDuplicateVoiceTurn("Open the calendar"))
        AgentSession.shared.recordUser("Typed check", source: .text)
        AgentSession.shared.recordAssistant("I received the typed check.")
        check("a matching typed request suppressed a new voice turn",
              !AgentSession.shared.isRecentDuplicateVoiceTurn("Typed check"))
        agent.localModelProviderForTesting = LocalAnswerTestProvider(
            chunks: ["The first answer.", " The second answer."],
            delay: .milliseconds(400),
            state: state
        )
        await AgentCaptureController.shared.beginSession(captureAudio: false)
        let turn = Task { @MainActor in
            await agent.handle("ask the local model explain the test", source: .voice)
        }
        try? await Task.sleep(for: .milliseconds(100))
        check("first clause was not enqueued while generation was in flight", recorder.spoken == ["The first answer."])
        check("fake generation completed before first clause", !(await state.completed))
        check(
            "model prompt omitted the prior Agent turn",
            (await state.lastPrompt).contains("The project codename is Silver Fern.")
        )

        agent.interrupt()
        _ = await turn.value
        try? await Task.sleep(for: .milliseconds(500))
        check("interruption allowed a later model clause to reach the speaker", !recorder.spoken.contains("The second answer."))
        await AgentCaptureController.shared.endSession(source: .done)

        for unsafe in ["https://example.com/private", "```swift\nlet answer = 1\n```"] {
            recorder.reset()
            let unsafeState = LocalAnswerTestState()
            agent.localModelProviderForTesting = LocalAnswerTestProvider(
                chunks: [unsafe], delay: .milliseconds(1), state: unsafeState
            )
            await AgentCaptureController.shared.beginSession(captureAudio: false)
            let unsafeTurn = await agent.handle(
                "ask the local model repeat this exactly",
                source: .voice
            )
            let kind = unsafe.hasPrefix("http") ? "URL" : "code"
            check("unsafe \(kind) reached the speaker", recorder.spoken.isEmpty)
            check("unsafe answer was not still visible", !unsafeTurn.reply.isEmpty)
            await AgentCaptureController.shared.endSession(source: .done)
        }

        recorder.reset()
        agent.localModelLimitForTesting = .milliseconds(80)
        agent.localModelProviderForTesting = LocalAnswerTestProvider(
            chunks: ["A reply that arrived too late."], delay: .zero,
            state: LocalAnswerTestState(), initialDelay: .milliseconds(400)
        )
        await AgentCaptureController.shared.beginSession(captureAudio: false)
        let timedOut = await agent.handle("ask the local model wait", source: .voice)
        check("model timeout did not return a visible reply", timedOut.reply.contains("took too long"))
        try? await Task.sleep(for: .milliseconds(450))
        check("a timed-out model spoke after its turn ended", !recorder.spoken.contains("A reply that arrived too late."))
        await AgentCaptureController.shared.endSession(source: .done)
        agent.localModelLimitForTesting = nil

        let recognized = AgentTurnIntent.resolve(
            "ask the local model what is two plus two?",
            choice: AgentHarnessChoice(id: .local, source: .settings, available: true, fallbackToLocal: false, note: "")
        )
        check("explicit local-model prefix did not select model route", recognized == .localModel(prompt: "what is two plus two?"))
        check(
            "punctuated local-model prefix did not select model route",
            AgentTurnIntent.localModelPrompt(for: "ask the local model, explain this") == "explain this"
        )
        check(
            "Apple cumulative snapshots repeated earlier text",
            FoundationModelLLMProvider.delta(previous: "Hello", current: "Hello there.") == " there."
        )
        check(
            "Apple replacement snapshot was accepted as a delta",
            FoundationModelLLMProvider.delta(previous: "Hello", current: "Goodbye") == nil
        )

        for failure in failures { print("  LOCAL_MODEL_STREAM_WRONG: \(failure)") }
        print(failures.isEmpty ? "LOCAL_MODEL_STREAM_OK" : "LOCAL_MODEL_STREAM_FAILED")
        return failures.isEmpty
    }
}

private actor LocalAnswerTestState {
    var completed = false
    var lastPrompt = ""

    func markCompleted() { completed = true }
    func recordPrompt(_ prompt: String) { lastPrompt = prompt }
}

private struct LocalAnswerTestProvider: LLMProvider {
    let id = LLMProviderID.appLLM
    let chunks: [String]
    let delay: Duration
    let state: LocalAnswerTestState
    var initialDelay: Duration = .zero

    var contextTokens: Int { 4_096 }
    var unavailableReason: String? { get async { nil } }
    func countTokens(_ text: String) async throws -> Int { text.count / 4 + 1 }
    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        LLMCompletion(text: chunks.joined(), generatedTokens: chunks.joined().count, duration: 0)
    }
    func stream(system: String, user: String, maxTokens: Int) async -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    await state.recordPrompt(user)
                    if initialDelay > .zero { try await Task.sleep(for: initialDelay) }
                    for (index, chunk) in chunks.enumerated() {
                        try Task.checkCancellation()
                        continuation.yield(chunk)
                        if index < chunks.count - 1 { try await Task.sleep(for: delay) }
                    }
                    await state.markCompleted()
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

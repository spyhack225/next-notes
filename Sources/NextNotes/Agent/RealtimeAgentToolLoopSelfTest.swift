import Foundation

/// Exercises the normal `RealtimeAgent.handle` route used by voice input. The fake
/// provider only controls planning; `computer.active_app` still goes through the real
/// registry, permission policy, and executor.
enum RealtimeAgentToolLoopSelfTest {
    @MainActor
    @discardableResult
    static func run() async -> Bool {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        let agent = RealtimeAgent.shared
        let providerState = ToolLoopTestState()
        agent.localModelProviderForTesting = ToolLoopTestProvider(state: providerState)
        defer {
            agent.localModelProviderForTesting = nil
            agent.localModelLimitForTesting = nil
            agent.toolLoopLimitForTesting = nil
        }

        let turn = await agent.handle(
            "tell me which app is frontmost",
            source: .text
        )
        let rounds = await providerState.rounds
        let sawResult = await providerState.sawToolResult
        let schemaCharacters = await providerState.lastSystemCharacters

        check(
            "ordinary request did not select the model tool route",
            AgentTurnIntent.resolve(
                "tell me which app is frontmost",
                choice: AgentHarnessChoice(
                    id: .local,
                    source: .settings,
                    available: true,
                    fallbackToLocal: false,
                    note: ""
                )
            ) == .toolLoop(prompt: "tell me which app is frontmost")
        )
        check("tool planner did not make a second model round", rounds >= 2)
        check("tool planner did not receive a real tool result", sawResult)
        check("tool catalogue crowded out the 4K model context (\(schemaCharacters) chars)",
              schemaCharacters < 8_000)
        check("tool loop returned no final answer", !turn.reply.isEmpty)
        check("tool loop leaked a tool tag to the user", !turn.reply.contains("<tool_call>"))

        // Mutations are available to the planner, but a malformed request must
        // fail at the executor before prompting or changing the user's UI.
        agent.localModelProviderForTesting = ToolLoopTestProvider(
            state: ToolLoopTestState(), firstCall: "computer.type"
        )
        let forbidden = await agent.handle("type a secret", source: .text)
        check("malformed model mutation bypassed argument validation", forbidden.reply.contains("did not run"))

        // A stalled model is bounded and cannot produce a late visible answer.
        agent.toolLoopLimitForTesting = .milliseconds(80)
        agent.localModelProviderForTesting = ToolLoopTestProvider(
            state: ToolLoopTestState(), delay: .milliseconds(400)
        )
        let timedOut = await agent.handle("inspect this", source: .text)
        check("tool planner timeout was not visible", timedOut.reply.contains("too long"))

        // An ordinary answer, with no tool tag, must begin speaking from the
        // first complete streamed clause. Barge-in must suppress later chunks.
        agent.toolLoopLimitForTesting = nil
        let recorder = RecordingSpeechBacking()
        AgentSpeechSynthesizer.shared.useTestingBacking(recorder)
        let answerState = ToolLoopTestState()
        agent.localModelProviderForTesting = ToolLoopTestProvider(
            state: answerState, firstCall: "", delay: .milliseconds(400)
        )
        await AgentCaptureController.shared.beginSession(captureAudio: false)
        let spokenTurn = Task { @MainActor in
            await agent.handle("Explain this briefly", source: .voice)
        }
        try? await Task.sleep(for: .milliseconds(100))
        check("plain model answer waited for all tokens before speaking",
              recorder.spoken == ["First answer."])
        check("model answer finished before its first clause was audible",
              !(await answerState.completed))
        agent.interrupt()
        _ = await spokenTurn.value
        check("interrupted answer spoke a later clause",
              !recorder.spoken.contains("Second answer."))
        await AgentCaptureController.shared.endSession(source: .done)
        AgentSpeechSynthesizer.shared.restoreSystemBacking()

        for failure in failures { print("  TOOLLOOP_PRODUCTION_WRONG: \(failure)") }
        print(failures.isEmpty ? "TOOLLOOP_PRODUCTION_OK" : "TOOLLOOP_PRODUCTION_FAILED")
        return failures.isEmpty
    }
}

private actor ToolLoopTestState {
    var rounds = 0
    var sawToolResult = false
    var completed = false
    var lastSystemCharacters = 0

    func next(user: String, system: String) -> Int {
        rounds += 1
        lastSystemCharacters = system.count
        if user.contains("computer.active_app returned") { sawToolResult = true }
        return rounds
    }

    func markCompleted() { completed = true }
}

private struct ToolLoopTestProvider: LLMProvider {
    let id = LLMProviderID.qwen35_4b
    let state: ToolLoopTestState
    let firstCall: String
    let delay: Duration
    var contextTokens: Int { 4_096 }
    var unavailableReason: String? { get async { nil } }

    init(state: ToolLoopTestState, firstCall: String = "computer.active_app", delay: Duration = .zero) {
        self.state = state
        self.firstCall = firstCall
        self.delay = delay
    }

    func countTokens(_ text: String) async throws -> Int { text.count / 4 + 1 }

    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        let round = await state.next(user: user, system: system)
        if delay > .zero { try await Task.sleep(for: delay) }
        let text: String
        if round == 1 {
            text = "<tool_call>{\"name\":\"" + firstCall + "\",\"arguments\":{},\"rationale\":\"test\"}</tool_call>"
        } else {
            text = "The frontmost application is the one reported by the system."
        }
        return LLMCompletion(text: text, generatedTokens: text.count, duration: 0)
    }

    func stream(system: String, user: String, maxTokens: Int) async -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if firstCall.isEmpty {
                        _ = await state.next(user: user, system: system)
                        continuation.yield("First answer.")
                        try await Task.sleep(for: delay)
                        continuation.yield(" Second answer.")
                    } else {
                        let response = try await complete(system: system, user: user, maxTokens: maxTokens)
                        continuation.yield(response.text)
                    }
                    await state.markCompleted()
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

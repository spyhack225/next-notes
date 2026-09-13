import Foundation

/// Exercises the same opt-in `RealtimeAgent.handle` route used by voice input. The fake
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
            "use tools to tell me which app is frontmost",
            source: .text
        )
        let rounds = await providerState.rounds
        let sawResult = await providerState.sawToolResult

        check(
            "explicit tool prefix did not select the model tool route",
            AgentTurnIntent.resolve(
                "use tools to tell me which app is frontmost",
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
        check("tool loop returned no final answer", !turn.reply.isEmpty)
        check("tool loop leaked a tool tag to the user", !turn.reply.contains("<tool_call>"))

        // A mutation emitted by the planner is refused before it reaches the executor.
        agent.localModelProviderForTesting = ToolLoopTestProvider(
            state: ToolLoopTestState(), firstCall: "computer.type"
        )
        let forbidden = await agent.handle("use tools to type a secret", source: .text)
        check("model tool route allowed a forbidden mutation", forbidden.reply.contains("unavailable tool"))

        // A stalled model is bounded and cannot produce a late visible answer.
        agent.toolLoopLimitForTesting = .milliseconds(80)
        agent.localModelProviderForTesting = ToolLoopTestProvider(
            state: ToolLoopTestState(), delay: .milliseconds(400)
        )
        let timedOut = await agent.handle("use tools to inspect this", source: .text)
        check("tool planner timeout was not visible", timedOut.reply.contains("too long"))

        for failure in failures { print("  TOOLLOOP_PRODUCTION_WRONG: \(failure)") }
        print(failures.isEmpty ? "TOOLLOOP_PRODUCTION_OK" : "TOOLLOOP_PRODUCTION_FAILED")
        return failures.isEmpty
    }
}

private actor ToolLoopTestState {
    var rounds = 0
    var sawToolResult = false

    func next(user: String) -> Int {
        rounds += 1
        if user.contains("computer.active_app returned") { sawToolResult = true }
        return rounds
    }
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
        let round = await state.next(user: user)
        if delay > .zero { try await Task.sleep(for: delay) }
        let text: String
        if round == 1 {
            text = "<tool_call>{\"name\":\"" + firstCall + "\",\"arguments\":{},\"rationale\":\"test\"}</tool_call>"
        } else {
            text = "The frontmost application is the one reported by the system."
        }
        return LLMCompletion(text: text, generatedTokens: text.count, duration: 0)
    }
}

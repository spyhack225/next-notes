import Foundation

/// Multi-round tool use for a voice turn. MeetingAgent already had this shape; the
/// realtime path was one completion and the first call. Both providers take one system
/// and one user message, so prior results are appended to the user side rather than
/// sent as a tool-role turn.
enum AgentToolLoop {
    static let defaultMaxRounds = 4
    static let minRounds = 4
    static let maxRoundsBound = 8
    static let defaultMaxCalls = 8
    static let defaultMaxWallTime: Duration = .seconds(20)

    static func clampedMaxRounds(_ requested: Int) -> Int {
        min(maxRoundsBound, max(minRounds, requested))
    }

    struct Outcome: Sendable, Equatable {
        var reply: String
        var rounds: Int
        var calls: Int
    }

    /// Builds the next user message. Empty results is the original utterance; later
    /// rounds are that utterance plus what the tools already returned.
    static func userMessage(original: String, results: [String]) -> String {
        guard !results.isEmpty else { return original }
        return """
            \(original)

            What you have already done:
            \(results.joined(separator: "\n"))

            Continue. If you have enough to answer, reply in plain language with no tool calls.
            """
    }

    @MainActor
    static func run(
        user original: String,
        maxRounds: Int = defaultMaxRounds,
        maxCalls: Int = defaultMaxCalls,
        maxWallTime: Duration = defaultMaxWallTime,
        complete: (String) async throws -> String,
        execute: (AgentToolCall) async -> String
    ) async throws -> Outcome {
        var results: [String] = []
        var callCount = 0
        let rounds = clampedMaxRounds(maxRounds)
        let clock = ContinuousClock()
        let deadline = clock.now + maxWallTime

        for round in 0..<rounds {
            try Task.checkCancellation()
            if clock.now >= deadline {
                break
            }
            let completion = try await complete(userMessage(original: original, results: results))
            let calls = AgentToolCallParser.calls(in: completion)
            if calls.isEmpty {
                let reply = completion.trimmingCharacters(in: .whitespacesAndNewlines)
                if !reply.isEmpty {
                    return Outcome(reply: reply, rounds: round + 1, calls: callCount)
                }
                if !results.isEmpty {
                    return Outcome(
                        reply: results.joined(separator: "\n"),
                        rounds: round + 1,
                        calls: callCount
                    )
                }
                return Outcome(reply: "", rounds: round + 1, calls: callCount)
            }

            for call in calls {
                if callCount >= maxCalls || clock.now >= deadline { break }
                let output = await execute(call)
                results.append(AgentPrompts.toolResult(name: call.name, output: output))
                callCount += 1
            }
            if clock.now >= deadline { break }
        }

        return Outcome(
            reply: results.joined(separator: "\n"),
            rounds: rounds,
            calls: callCount
        )
    }
}

extension AgentToolLoop {
    /// Inspect → click must make both calls. Not wired to `--selftest-realtime`
    /// and never calls `RunLog.record`.
    @MainActor
    static func runSelfTest() async {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        do {
            var executed: [String] = []
            let loop = try await AgentToolLoop.run(
                user: "Click Run",
                maxRounds: defaultMaxRounds,
                complete: { user in
                    if user.contains("computer.click returned") {
                        return "Done."
                    }
                    if user.contains("computer.inspect_ui returned") {
                        return #"<tool_call>{"name":"computer.click","arguments":{"id":"12"},"rationale":"click"}</tool_call>"#
                    }
                    return #"<tool_call>{"name":"computer.inspect_ui","arguments":{},"rationale":"look"}</tool_call>"#
                },
                execute: { call in
                    executed.append(call.name)
                    switch call.name {
                    case "computer.inspect_ui": return "[12] Run\n[18] Search"
                    case "computer.click": return "Clicked"
                    default: return "unknown"
                    }
                }
            )
            check("inspect→click loop did not finish in plain language", loop.reply == "Done.")
            check("inspect→click loop used the wrong number of rounds", loop.rounds == 3)
            check("inspect→click loop dropped a tool call", loop.calls == 2)
            check(
                "a two-call inspect/click fixture stopped after one call",
                executed == ["computer.inspect_ui", "computer.click"]
            )
        } catch {
            failures.append("tool loop failed: \(error.localizedDescription)")
        }

        do {
            var roundsSeen = 0
            let capped = try await AgentToolLoop.run(
                user: "loop",
                maxRounds: 20,
                maxCalls: 100,
                complete: { _ in
                    roundsSeen += 1
                    return #"<tool_call>{"name":"computer.inspect_ui","arguments":{},"rationale":"look"}</tool_call>"#
                },
                execute: { _ in "ok" }
            )
            check("maxRounds was not bounded to 8", capped.rounds == maxRoundsBound)
            check("a 20-round ask ran more than eight completions", roundsSeen == maxRoundsBound)
        } catch {
            failures.append("round cap failed: \(error.localizedDescription)")
        }

        for failure in failures {
            print("TOOLLOOP_WRONG: \(failure)")
        }
        print(failures.isEmpty ? "TOOLLOOP_OK" : "TOOLLOOP_FAILED")
    }
}

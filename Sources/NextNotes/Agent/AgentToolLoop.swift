import Foundation

/// Multi-round tool use for a voice turn. MeetingAgent already had this shape; the
/// realtime path was one completion and the first call. Both providers take one system
/// and one user message, so prior results are appended to the user side rather than
/// sent as a tool-role turn.
enum AgentToolLoop {
    static let defaultMaxRounds = 4

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
        complete: (String) async throws -> String,
        execute: (AgentToolCall) async -> String
    ) async throws -> Outcome {
        var results: [String] = []
        var callCount = 0
        let rounds = max(1, maxRounds)

        for round in 0..<rounds {
            try Task.checkCancellation()
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
                let output = await execute(call)
                results.append(AgentPrompts.toolResult(name: call.name, output: output))
                callCount += 1
            }
        }

        return Outcome(
            reply: results.joined(separator: "\n"),
            rounds: rounds,
            calls: callCount
        )
    }
}

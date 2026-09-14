import Foundation

/// Multi-round tool use for a voice turn. MeetingAgent already had this shape; the
/// realtime path was one completion and the first call. Both providers take one system
/// and one user message, so prior results are appended to the user side rather than
/// sent as a tool-role turn.
enum AgentToolLoop {
    private final class CallbackBox<Value>: @unchecked Sendable {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

    private enum CompletionFailure: Error, Sendable {
        case message(String)
    }

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

    /// A relative day in the current request is grounded by the device clock,
    /// not by a small model's remembered training date. This validates an
    /// already-selected calendar tool; it does not decide whether to call one.
    static func groundedArguments(
        for tool: String, proposed: [String: String], request: String,
        now: Date = Date(), calendar: Calendar = .current
    ) -> [String: String] {
        guard tool == "get_agenda",
              request.range(of: #"\btoday\b"#, options: [.regularExpression, .caseInsensitive]) != nil,
              request.range(of: #"\b\d{4}-\d{2}-\d{2}\b"#, options: .regularExpression) == nil
        else { return proposed }
        var grounded = proposed
        let components = calendar.dateComponents([.year, .month, .day], from: now)
        guard let year = components.year, let month = components.month, let day = components.day else {
            return proposed
        }
        grounded["date"] = String(format: "%04d-%02d-%02d", year, month, day)
        return grounded
    }

    @MainActor
    static func run(
        user original: String,
        maxRounds: Int = defaultMaxRounds,
        maxCalls: Int = defaultMaxCalls,
        maxWallTime: Duration = defaultMaxWallTime,
        complete: @escaping (String) async throws -> String,
        execute: @escaping (AgentToolCall) async -> String
    ) async throws -> Outcome {
        var results: [String] = []
        var callCount = 0
        let rounds = clampedMaxRounds(maxRounds)
        let clock = ContinuousClock()
        let deadline = clock.now + maxWallTime
        var completedRounds = 0
        let completeBox = CallbackBox(complete)
        let executeBox = CallbackBox(execute)

        for round in 0..<rounds {
            try Task.checkCancellation()
            let remaining = clock.now.duration(to: deadline)
            if remaining <= .zero {
                break
            }
            let priorResults = results
            let completionResult: Result<String, CompletionFailure>? = await withBoundedWait(remaining) {
                do {
                    return .success(try await completeBox.value(
                        userMessage(original: original, results: priorResults)
                    ))
                } catch {
                    return .failure(.message(error.localizedDescription))
                }
            }
            guard let completionResult else { break }
            if case .failure(.message(let message)) = completionResult {
                throw AgentError.backendUnavailable("Tool loop completion failed: \(message)")
            }
            guard case .success(let completion) = completionResult else { break }
            let calls = AgentToolCallParser.calls(in: completion)
            if calls.isEmpty {
                completedRounds = round + 1
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

            var roundTimedOut = false
            for call in calls {
                let callRemaining = clock.now.duration(to: deadline)
                if callCount >= maxCalls || callRemaining <= .zero {
                    roundTimedOut = callRemaining <= .zero
                    break
                }
                guard let output = await withBoundedWait(callRemaining, {
                    await executeBox.value(call)
                }) else {
                    roundTimedOut = true
                    break
                }
                results.append(AgentPrompts.toolResult(name: call.name, output: output))
                callCount += 1
            }
            // A model response is only a completed round once its proposed tool calls
            // have returned. Do not report a full round when the deadline abandoned an
            // execute child that may still be unwinding.
            if !roundTimedOut { completedRounds = round + 1 }
            if clock.now >= deadline { break }
        }

        return Outcome(
            reply: results.joined(separator: "\n"),
            rounds: completedRounds,
            calls: callCount
        )
    }
}

extension AgentToolLoop {
    /// Inspect → click must make both calls. Not wired to `--selftest-realtime`
    /// and never calls `RunLog.record`.
    @MainActor
    @discardableResult
    static func runSelfTest() async -> Bool {
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

        do {
            let bounded = try await AgentToolLoop.run(
                user: "deadline",
                maxWallTime: .milliseconds(20),
                complete: { _ in
                    try await Task.sleep(for: .milliseconds(200))
                    return "too late"
                },
                execute: { _ in "unreachable" }
            )
            check("completion deadline was not enforced", bounded.rounds == 0 && bounded.calls == 0)
        } catch {
            failures.append("deadline fixture failed: \(error.localizedDescription)")
        }

        do {
            let bounded = try await AgentToolLoop.run(
                user: "tool deadline",
                maxWallTime: .milliseconds(20),
                complete: { _ in
                    #"<tool_call>{"name":"computer.inspect_ui","arguments":{},"rationale":"look"}</tool_call>"#
                },
                execute: { _ in
                    try? await Task.sleep(for: .milliseconds(200))
                    return "too late"
                }
            )
            check(
                "tool execution deadline was not reflected in completed rounds",
                bounded.rounds == 0 && bounded.calls == 0
            )
        } catch {
            failures.append("tool deadline fixture failed: \(error.localizedDescription)")
        }

        for failure in failures {
            print("TOOLLOOP_WRONG: \(failure)")
        }
        print(failures.isEmpty ? "TOOLLOOP_OK" : "TOOLLOOP_FAILED")
        return failures.isEmpty
    }
}

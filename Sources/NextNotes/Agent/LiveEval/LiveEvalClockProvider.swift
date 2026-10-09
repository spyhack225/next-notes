import Foundation

/// C01/C04's unchanged requests, fixtures, parser, runner, executor and grader;
/// only the model completions are substituted. CLI admission is in ToolLoopLiveEval.
actor LiveEvalClockProvider: LLMProvider {
    nonisolated let id = LLMProviderID.localServer
    nonisolated let displayModelName = "Scripted clock diagnostic"
    nonisolated let contextTokens = 16_384
    var unavailableReason: String? { get async { nil } }
    private var round = 0

    func countTokens(_ text: String) async throws -> Int { max(1, text.count / 4) }

    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        if maxTokens == 4 { return LLMCompletion(text: "OK", generatedTokens: 1, duration: 0) }
        guard let now = SelfTest.fixtureClock else { throw AgentError.backendUnavailable("Fixture clock missing") }
        let date = await LiveEvalGrader.dayString(now: now)
        guard system.contains(date) else {
            throw AgentError.backendUnavailable("Planner prompt lost fixture clock")
        }
        let tomorrow = await LiveEvalGrader.dayString(offset: 1, now: now)
        let script = [
            // Retained Qwen first completion. Parsing and execution both stay real.
            "I don't have access to your calendar right now. Let me check for you.\n\n"
                + "<tool_call>{\"name\":\"get_agenda\", \"arguments\": {\"date\": \"\(date)\"}, "
                + "\"rationale\":\"Check the user's calendar for today's schedule as requested.\"}</tool_call>",
            "Today you have a standup, a budget review with Ana and a call with Marcus about pricing.",
            // Retained Mini C04 first completion, including its different wire form.
            "I'll check your Gmail for recent emails and your calendar for tomorrow's events.\n"
                + "<function name=\"search_email\"></function>\n"
                + "<function name=\"get_agenda\"><param name=\"date\">\(tomorrow)</param></function>",
            "Marcus sent the pricing sheet, Ana requested the deck and Stripe sent an invoice. "
                + "Tomorrow you have a dentist appointment, a design sync and dinner with Cyril."
        ]
        guard round < script.count else { throw AgentError.backendUnavailable("Clock diagnostic exceeded scripted rounds") }
        let text = script[round]
        round += 1
        return LLMCompletion(text: text, generatedTokens: max(1, text.count / 4), duration: 0)
    }

    /// The default callers (account floor and Needle) must agree with the explicit
    /// ToolStepRunner binding. Also retain explicit-clock and explicit-date precedence.
    @MainActor
    static func checkDefaults() -> [String] {
        guard let now = SelfTest.fixtureClock else { return ["fixture unavailable"] }
        var failures: [String] = []
        for id in ["C01", "C04"] {
            let request = LiveEvalCases.caseWithID(id: id)!.turns[0]
            let expected = LiveEvalGrader.dayString(offset: id == "C01" ? 0 : 1, now: now)
            let proposed = ["date": expected]
            let grounded = AgentToolLoop.groundedArguments(for: "get_agenda", proposed: proposed, request: request)
            let floor = AgentAccountRead.defaultRead(for: .calendar, request: request)?.arguments
            SelfTest.diagnostic("TOOLLOOP_LIVE_CLOCK_TRACE \(id) proposed=\(expected) "
                + "default=\(grounded["date"] ?? "nil") floor=\(floor?["date"] ?? "nil")")
            if grounded != proposed { failures.append("\(id) default grounding replaced fixture day") }
            if floor != proposed { failures.append("\(id) default account floor replaced fixture day") }
            let explicit = now.addingTimeInterval(-10 * 86_400)
            let expectedExplicit = LiveEvalGrader.dayString(offset: id == "C01" ? 0 : 1, now: explicit)
            if AgentToolLoop.groundedArguments(for: "get_agenda", proposed: proposed,
                    request: request, now: explicit)["date"] != expectedExplicit {
                failures.append("\(id) explicit clock lost precedence")
            }
        }
        let historical = ["date": "2023-10-27"]
        if AgentToolLoop.groundedArguments(for: "get_agenda", proposed: historical,
                request: "What was booked on 2023-10-27?") != historical {
            failures.append("explicit historical day changed")
        }
        if AgentToolLoop.groundedArguments(for: "get_agenda", proposed: historical,
                request: "today and tomorrow") != historical {
            failures.append("ambiguous day changed")
        }
        SelfTest.diagnostic(failures.isEmpty ? "TOOLLOOP_LIVE_CLOCK_DEFAULTS_OK" : "TOOLLOOP_LIVE_CLOCK_DEFAULTS_FAILED")
        return failures
    }
}

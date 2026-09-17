import Foundation

/// Exercises the normal `RealtimeAgent.handle` route used by voice input. The fake
/// provider only controls planning; `computer.active_app` still goes through the real
/// registry, permission policy, and executor.
enum RealtimeAgentToolLoopSelfTest {
    /// Ask the installed Qwen model for routing decisions without executing
    /// tools or recording these fixtures in the user's conversation.
    @MainActor
    static func runToolAwareness() async -> Bool {
        let provider = LlamaLLMProvider()
        if let reason = await provider.unavailableReason {
            print("TOOL_AWARENESS_FAILED: \(reason)")
            return false
        }
        let system = RealtimeAgent.voiceRoutingSystem(voice: true)
        let probes: [(name: String, messages: [LLMChatMessage], expected: String)] = [
            ("CALENDAR", [.init(role: .user, content: "What is on my calendar for today?")],
             "<use_tools/>"),
            ("PRIOR_DENIAL", [
                .init(role: .user, content: "What is on my calendar today?"),
                .init(role: .assistant, content: "I don't have access to your calendar."),
                .init(role: .user, content: "Please check my calendar for today.")
            ], "<use_tools/>"),
            ("MEETING_ACTIONS", [
                .init(role: .user, content: "What action items came from my last meeting?")
            ], "<use_tools/>"),
            ("CAPABILITIES", [.init(role: .user, content: "Can you check your tools?")],
             "<answer/>"),
            ("MY_TODO", [.init(role: .user, content: "What is on my to-do list for today?")],
             "<use_tools/>"),
            ("YOUR_TODO", [.init(role: .user, content: "What is on your to-do list for today?")],
             "<answer/>"),
        ]
        var failures: [String] = []
        for probe in probes {
            let response: String? = await withBoundedWait(.seconds(90)) {
                do {
                    var answer = ""
                    let stream = await provider.streamConversation(
                        system: system, messages: probe.messages, maxTokens: 112
                    )
                    for try await chunk in stream {
                        answer += chunk
                        if VoiceResponseEnvelope.parse(answer) == .tools { return "<use_tools/>" }
                    }
                    if case .answer(let text) = VoiceResponseEnvelope.parse(answer), !text.isEmpty {
                        return "<answer/>"
                    }
                    return answer.trimmingCharacters(in: .whitespacesAndNewlines)
                } catch {
                    return "ERROR: \(error.localizedDescription)"
                }
            }
            let answer = response ?? ""
            print("TOOL_AWARENESS_\(probe.name): \(String(answer.prefix(240)))")
            if answer != probe.expected {
                failures.append("\(probe.name): expected \(probe.expected), got \(answer)")
            }
        }
        for failure in failures { print("TOOL_AWARENESS_WRONG: \(failure)") }
        print(failures.isEmpty ? "TOOL_AWARENESS_OK" : "TOOL_AWARENESS_FAILED")
        return failures.isEmpty
    }

    /// Real Qwen probe for the 09:48 recording. This only asks a question of
    /// the local model; it does not add a row to the user's Agent conversation.
    @MainActor
    static func runVoiceGrounding() async -> Bool {
        let provider = LlamaLLMProvider()
        if let reason = await provider.unavailableReason {
            print("VOICE_GROUNDING_FAILED: \(reason)")
            return false
        }
        let response: String? = await withBoundedWait(.seconds(90)) {
            do {
                var answer = ""
                let stream = await provider.streamConversation(
                    system: RealtimeAgent.modelTurnSystem(voice: true),
                    messages: [.init(role: .user, content: "Can you hear me?")],
                    maxTokens: 96
                )
                for try await chunk in stream { answer += chunk }
                return answer.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                return "ERROR: \(error.localizedDescription)"
            }
        }
        let answer = response ?? ""
        let lowered = answer.lowercased()
        let correct = !answer.isEmpty && !lowered.hasPrefix("error:")
            && !lowered.contains("can't hear") && !lowered.contains("cannot hear")
            && !lowered.contains("don't have ears") && !lowered.contains("do not have ears")
            && !lowered.contains("typed") && !lowered.contains("type")
            && !answer.contains("<use_tools")
        print("VOICE_GROUNDING_RESPONSE: \(String(answer.prefix(240)))")
        let followUp: String? = await withBoundedWait(.seconds(90)) {
            do {
                var answer = ""
                let stream = await provider.streamConversation(
                    system: RealtimeAgent.modelTurnSystem(voice: true),
                    messages: [
                        .init(role: .user, content: "Can you hear me?"),
                        .init(role: .assistant, content: "Yes, I received your spoken words."),
                        .init(role: .user, content: "Your voice keeps breaking mid-answer."),
                        .init(role: .user, content: "Why is he choppy?")
                    ],
                    maxTokens: 96
                )
                for try await chunk in stream { answer += chunk }
                return answer.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                return "ERROR: \(error.localizedDescription)"
            }
        }
        let followUpAnswer = followUp ?? ""
        let followUpLower = followUpAnswer.lowercased()
        let understandsReferent = !followUpAnswer.isEmpty && !followUpLower.hasPrefix("error:")
            && !followUpLower.contains("who he") && !followUpLower.contains("who 'he'")
            && !followUpLower.contains("who \"he\"")
            && !followUpLower.contains("clarify who")
            && !followUpLower.contains("don't know who")
            && !followUpLower.contains("his voice")
            && !followUpLower.contains("not his")
            && (followUpLower.contains("my voice") || followUpLower.contains("my speech")
                || followUpLower.contains("my spoken") || followUpLower.contains("my output"))
            && !followUpLower.contains("audio connection")
            && !followUpLower.contains("network connection")
            && !followUpLower.contains("network issue")
            && !followUpLower.contains("connection issue")
            && !followUpLower.contains("connection stability")
            && !followUpLower.contains("audio settings")
            && !followUpLower.contains("your device")
            && !followUpLower.contains("microphone issue")
            && !followUpLower.contains("restarting your device")
        print("VOICE_FOLLOWUP_RESPONSE: \(String(followUpAnswer.prefix(240)))")
        // September 14 recording: the previous answer about tools was repeated
        // when the user changed the subject to the earlier model timeout.
        let timeoutFollowUp: String? = await withBoundedWait(.seconds(90)) {
            do {
                var answer = ""
                let stream = await provider.streamConversation(
                    system: RealtimeAgent.modelTurnSystem(voice: true),
                    messages: [
                        .init(role: .user, content: "Can you hear me?"),
                        .init(role: .assistant, content: "The model took too long to answer."),
                        .init(role: .user, content: "Why did you use a tool? It was a simple question."),
                        .init(role: .assistant, content: "I didn't use any tools; I answered directly."),
                        .init(role: .user, content: "Why did it say the model took too long to answer?")
                    ],
                    maxTokens: 96
                )
                for try await chunk in stream { answer += chunk }
                return answer.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                return "ERROR: \(error.localizedDescription)"
            }
        }
        let timeoutAnswer = timeoutFollowUp ?? ""
        let timeoutLower = timeoutAnswer.lowercased()
        let addressesTimeout = !timeoutAnswer.isEmpty
            && !timeoutLower.hasPrefix("error:")
            && !timeoutAnswer.contains("<use_tools")
            && (timeoutLower.contains("model") || timeoutLower.contains("timeout")
                || timeoutLower.contains("timed out")
                || (timeoutLower.contains("response generation")
                    && timeoutLower.contains("longer")))
            && !timeoutLower.contains("i didn't use any tools")
            && !timeoutLower.contains("no delay")
        print("VOICE_TIMEOUT_FOLLOWUP_RESPONSE: \(String(timeoutAnswer.prefix(240)))")
        print(correct && understandsReferent && addressesTimeout
            ? "VOICE_GROUNDING_OK" : "VOICE_GROUNDING_FAILED")
        return correct && understandsReferent && addressesTimeout
    }

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
        check("tool request did not enter the separate planner", rounds >= 3)
        check("tool planner did not receive a real tool result", sawResult)
        check("tool catalogue crowded out the 4K model context (\(schemaCharacters) chars)",
              schemaCharacters < 8_000)
        check("tool loop returned no final answer", !turn.reply.isEmpty)
        check("tool loop leaked a tool tag to the user", !turn.reply.contains("<tool_call>"))

        // A conversational answer streams in its routing pass. No second
        // model prefill, and no full tool schema on the speech path.
        let directState = ToolLoopTestState()
        agent.localModelProviderForTesting = ToolLoopTestProvider(
            state: directState, firstCall: ""
        )
        let direct = await agent.handle("Can you hear me?", source: .text)
        check("conversation did not answer directly", direct.reply == "First answer. Second answer.")
        let directRounds = await directState.rounds
        let firstPromptCharacters = await directState.firstSystemCharacters
        check("conversation entered tool planning (\(directRounds) rounds)", directRounds == 1)
        let firstPrompt = RealtimeAgent.voiceRoutingSystem(voice: false)
        check("first pass omitted the model tool decision", firstPrompt.contains("<use_tools/>"))
        check("conversation prompt still carries the full tool roster (\(firstPromptCharacters) chars)",
              firstPromptCharacters < 1_500)


        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let knownDay = utc.date(from: DateComponents(year: 2026, month: 9, day: 14))!
        let today = AgentToolLoop.groundedArguments(
            for: "get_agenda", proposed: ["date": "2023-10-27"],
            request: "What's on my calendar for today?", now: knownDay, calendar: utc
        )
        check("the model's stale calendar date was not grounded", today["date"] == "2026-09-14")
        let historical = AgentToolLoop.groundedArguments(
            for: "get_agenda", proposed: ["date": "2023-10-27"],
            request: "What was booked on 2023-10-27?", now: knownDay, calendar: utc
        )
        check("an explicit historical calendar date was overwritten", historical["date"] == "2023-10-27")

        // A successful read is a usable answer even when a second model pass
        // runs past the turn's deadline. This was the missing calendar reply.
        let fallbackState = ToolLoopTestState()
        agent.toolLoopLimitForTesting = .seconds(2)
        agent.localModelProviderForTesting = ToolLoopTestProvider(
            state: fallbackState, secondRoundDelay: .seconds(4)
        )
        let fallback = await agent.handle("which app is frontmost?", source: .text)
        check("a completed read was thrown away on model timeout",
              fallback.reply.contains("Remaining steps are unfinished.")
                  && fallback.reply.components(separatedBy: "\n").first?.isEmpty == false)
        check("the second model pass was never exercised", (await fallbackState.rounds) >= 2)

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
        agent.localModelProviderForTesting = ToolLoopTestProvider(
            state: ToolLoopTestState(), firstCall: ""
        )
        await AgentCaptureController.shared.beginSession(captureAudio: false)
        _ = await agent.handle("Explain this briefly", source: .text)
        check("typed turn spoke while a voice session was open", recorder.spoken.isEmpty)
        await AgentCaptureController.shared.endSession(source: .done)
        let voiceState = ToolLoopTestState()
        agent.localModelProviderForTesting = ToolLoopTestProvider(
            state: voiceState,
            finalAnswer: "- /private/one\n- /private/two\n- /private/three\n- /private/four"
        )
        await AgentCaptureController.shared.beginSession(captureAudio: false)
        let voiceTurn = await agent.handle("tell me which app is frontmost", source: .voice)
        try? await Task.sleep(for: .milliseconds(100))
        check("unspeakable tool listing was read aloud", recorder.spoken.allSatisfy {
            !$0.contains("/private/")
        })
        check("verified tool result produced no voice fallback", !recorder.spoken.isEmpty)
        check("voice turn lost the full text result", voiceTurn.reply.contains("/private/"))
        check("voice summary added an extra model round", (await voiceState.rounds) == 3)
        await AgentCaptureController.shared.endSession(source: .done)
        recorder.reset()
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
    var firstSystemCharacters = 0

    func next(user: String, system: String) -> Int {
        rounds += 1
        if rounds == 1 { firstSystemCharacters = system.count }
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
    let secondRoundDelay: Duration
    let finalAnswer: String
    var contextTokens: Int { 4_096 }
    var unavailableReason: String? { get async { nil } }

    init(state: ToolLoopTestState, firstCall: String = "computer.active_app",
         delay: Duration = .zero, secondRoundDelay: Duration = .zero,
         finalAnswer: String = "The frontmost application is the one reported by the system.") {
        self.state = state
        self.firstCall = firstCall
        self.delay = delay
        self.secondRoundDelay = secondRoundDelay
        self.finalAnswer = finalAnswer
    }

    func countTokens(_ text: String) async throws -> Int { text.count / 4 + 1 }

    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        _ = await state.next(user: user, system: system)
        let choosing = system.contains("<use_tools/>")
        let afterTool = user.contains("computer.active_app returned")
        let wait = afterTool ? secondRoundDelay : (choosing ? delay : .zero)
        if wait > .zero { try await Task.sleep(for: wait) }
        let text: String
        if choosing {
            text = "<use_tools/>"
        } else if !afterTool {
            text = "<tool_call>{\"name\":\"" + firstCall + "\",\"arguments\":{},\"rationale\":\"test\"}</tool_call>"
        } else {
            text = finalAnswer
        }
        return LLMCompletion(text: text, generatedTokens: text.count, duration: 0)
    }

    func stream(system: String, user: String, maxTokens: Int) async -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if firstCall.isEmpty {
                        _ = await state.next(user: user, system: system)
                        continuation.yield("<answer/>First answer.")
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

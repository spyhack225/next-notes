import Foundation

enum VoiceConversationSelfTest {
    @MainActor
    static func run() async -> Bool {
        var failures: [String] = []
        func check(_ message: String, _ condition: Bool) {
            if !condition { failures.append(message) }
        }
        let agent = RealtimeAgent.shared
        let capture = AgentCaptureController.shared
        let recorder = RecordingSpeechBacking()
        AgentSpeechSynthesizer.shared.useTestingBacking(recorder)
        defer {
            agent.localModelProviderForTesting = nil
            AgentSpeechSynthesizer.shared.restoreSystemBacking()
        }
        for (input, expected) in [
            ("<ans", VoiceResponseEnvelope.pending),
            ("<answer/>\nHello.", .answer("\nHello.")),
            ("<answer>", .answer("")),
            ("<answer>Hello.</answer>", .answer("Hello.")),
            ("<use_tools/>", .tools),
            ("<answer/> I was thinking about our conversation.", .answer(" I was thinking about our conversation.")),
            ("<unexpected/>", .invalid),
            ("A natural answer.", .answer("A natural answer."))
        ] {
            check("incorrect stream envelope for \(input)", VoiceResponseEnvelope.parse(input) == expected)
        }
        for name in ["Claude Code", "Codex", "Qwen Code", "OpenCode"] {
            check("a name correction selected a backend: \(name)",
                  AgentHarnessRouter.explicitHarness(in: "No, I meant \(name).") == nil)
            check("an inspection selected a backend: \(name)",
                  AgentHarnessRouter.explicitHarness(in: "Check \(name) for running sessions.") == nil)
            check("explicit delegation was lost: \(name)",
                  AgentHarnessRouter.explicitHarness(in: "Use \(name) to fix the tests.") != nil)
        }

        // Both scenarios use capture -> RealtimeAgent -> real planner/executor.
        // The provider delays at a known boundary, not the microphone or tools.
        for afterRead in [false, true] {
            AgentSession.shared.clear() // SelfTest disables disk writes.
            await capture.beginSession(captureAudio: false)
            recorder.reset()
            let state = VoiceConversationProbeState(afterRead: afterRead)
            agent.localModelProviderForTesting = VoiceConversationProbeProvider(state: state)
            capture.simulateSpeech("Check the active app and its running sessions.")
            capture.simulateSilence()
            _ = await capture.considerEndpoint()
            for _ in 0..<200 {
                if await state.parked { break }
                try? await Task.sleep(for: .milliseconds(10))
            }
            check("producer never reached the suspended boundary", await state.parked)
            let workID = agent.voiceWork?.id
            agent.userSpeechStarted()
            check("starting speech cancelled work", agent.isThinking && agent.voiceWork?.id == workID)
            check("starting speech failed to stop playback", AgentSpeechSynthesizer.shared.didStop)

            // Let the old model finish while the user still holds the floor.
            await state.release()
            try? await Task.sleep(for: .milliseconds(80))
            check("a completed response spoke over unfinished input", recorder.spoken.isEmpty)
            check("unfinished input completed the work", agent.isThinking)

            capture.simulateSpeech("No, Claude Code. C L A U D E. Check Claude instead.")
            capture.simulateSilence()
            let ended = await capture.considerEndpoint()
            check("follow-up was not committed", ended)
            check("follow-up replaced the work item", workID != nil && agent.voiceWork?.id == workID)
            await capture.waitForActiveTurnForTesting()
            check("original objective or correction was lost", await state.sawAmendedObjective)
            check("stale plan executed or correction was lost", agent.lastReply == "I retained the request and applied your correction.")
            if afterRead {
                check("completed read was lost after correction", await state.sawRetainedResult)
                check("completed read was requested again", await state.readRequests == 1)
            }
            await capture.endSession(source: .done)
        }

        await capture.beginSession(captureAudio: false)
        recorder.reset()
        VoiceAnnouncementQueue.shared.enqueue("The background check finished.")
        check("background result interrupted the user",
              !VoiceAnnouncementQueue.shared.flush(userHasFloor: true) && recorder.spoken.isEmpty)
        check("background result was not delivered in a quiet interval",
              VoiceAnnouncementQueue.shared.flush(userHasFloor: false)
                  && recorder.spoken == ["The background check finished."])
        VoiceAnnouncementQueue.shared.enqueue("This belongs to the old session.")
        await capture.endSession(source: .done)
        await capture.beginSession(captureAudio: false)
        check("an old announcement leaked into a new session",
              !VoiceAnnouncementQueue.shared.flush(userHasFloor: false))
        await capture.endSession(source: .done)

        // The last validity check runs inside the real executor, after approval
        // and target resolution, immediately before the effect.
        var validityChecked = false
        do {
            _ = try await AgentToolExecutor.run("computer.active_app", arguments: [:],
                policy: .fromSettings(), autoApproveReads: true, isStillValid: {
                    validityChecked = true
                    return false
                })
            failures.append("executor fired an invalidated operation")
        } catch is CancellationError {
            check("executor rejected before reaching the validity check", validityChecked)
        } catch {
            failures.append("executor did not exercise the validity gate: \(error.localizedDescription)")
        }

        for failure in failures { print("VOICE_CONVERSATION_WRONG: \(failure)") }
        print(failures.isEmpty ? "VOICE_CONVERSATION_OK" : "VOICE_CONVERSATION_FAILED")
        return failures.isEmpty
    }

    /// Real installed model, synthetic text only: no microphone, network, tools,
    /// conversation persistence, or synthesized speech. Measures first answer text.
    @MainActor
    static func runLocalBenchmark() async -> Bool {
        let provider = LlamaLLMProvider()
        if let reason = await provider.unavailableReason {
            print("VOICE_LOCAL_FAILED: \(reason)")
            return false
        }
        let warmBegan = ContinuousClock.now
        do { try await NotesModelRuntime.shared.prepareForConversation() }
        catch {
            print("VOICE_LOCAL_FAILED: prewarm \(error.localizedDescription)")
            return false
        }
        print("VOICE_LOCAL_PREWARM: \(warmBegan.duration(to: .now))")
        let probes: [(String, Bool)] = [
            ("How's it going?", false),
            ("What were you thinking about?", false),
            ("What is on my calendar today?", true),
            ("Open Google Chrome and check Claude for running sessions.", true),
            ("Okay, thank you.", false)
        ]
        var failures: [String] = []
        for (request, needsTools) in probes {
            let began = ContinuousClock.now
            var first: Duration?
            var text = ""
            do {
                let stream = await provider.streamInteractiveConversation(
                    system: RealtimeAgent.voiceRoutingSystem(voice: true),
                    messages: [.init(role: .user, content: request)], maxTokens: 112)
                for try await chunk in stream {
                    text += chunk
                    let parsed = VoiceResponseEnvelope.parse(text)
                    if case .tools = parsed { first = began.duration(to: .now); break }
                    if case .answer(let answer) = parsed, !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       first == nil { first = began.duration(to: .now) }
                }
                let parsed = VoiceResponseEnvelope.parse(text)
                switch parsed {
                case .tools where needsTools: break
                case .answer(let answer) where !needsTools && !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty: break
                default: failures.append("incorrect response for \(request): \(text)")
                }
            } catch { failures.append(error.localizedDescription) }
            print("VOICE_LOCAL_SAMPLE: \(request) · first=\(first?.description ?? "none") · total=\(began.duration(to: .now)) · \(text)")
        }
        for failure in failures { print("VOICE_LOCAL_WRONG: \(failure)") }
        print(failures.isEmpty ? "VOICE_LOCAL_OK" : "VOICE_LOCAL_FAILED")
        return failures.isEmpty
    }
}

private actor VoiceConversationProbeState {
    let afterRead: Bool
    private(set) var parked = false
    private var released = false
    private(set) var sawAmendedObjective = false
    private(set) var sawRetainedResult = false
    private(set) var readRequests = 0

    init(afterRead: Bool) { self.afterRead = afterRead }
    func release() { released = true }
    func response(system: String, user: String) async throws -> String {
        if system.contains("<use_tools/>") { return "<use_tools/>" }
        let amended = user.contains("Check Claude instead.")
        let hasRead = user.contains("computer.active_app returned")
        if amended {
            sawAmendedObjective = user.contains("Check the active app and its running sessions.")
            sawRetainedResult = hasRead
            return "I retained the request and applied your correction."
        }
        if afterRead && !hasRead {
            readRequests += 1
            return #"<tool_call>{"name":"computer.active_app","arguments":{},"rationale":"Inspect the app"}</tool_call>"#
        }
        parked = true
        while !released {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(10))
        }
        // Invalid arguments would fail visibly if the obsolete plan were run.
        return #"<tool_call>{"name":"computer.type","arguments":{},"rationale":"Obsolete plan"}</tool_call>"#
    }
}

private struct VoiceConversationProbeProvider: LLMProvider {
    let id = LLMProviderID.qwen35_4b
    let state: VoiceConversationProbeState
    var contextTokens: Int { 8_192 }
    var unavailableReason: String? { get async { nil } }
    func countTokens(_ text: String) async throws -> Int { text.count / 4 }
    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        let text = try await state.response(system: system, user: user)
        return LLMCompletion(text: text, generatedTokens: text.count, duration: 0)
    }
}

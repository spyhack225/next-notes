import Foundation

/// Acceptance coverage for the capability conversation that failed in the September
/// 14 session. This deliberately runs through VoiceConversationCoordinator rather than
/// testing the envelope parser in isolation: a capability answer needs the same history,
/// work context and capability roster that a real turn receives.
enum VoiceCapabilityConversationSelfTest {
    private static let capabilityQuestions = [
        "What can you do",
        "can you list me all of your tasks, all of your capabilities and functionalities?",
        "What about your tools?",
        "What are the list of tools that you have?"
    ]

    private static let replayQuestions = [
        "What can you do", "Uh",
        "can you list me all of your tasks, all of your capabilities and functionalities?",
        "What about your tools?", "What are the list of tools that you have?"
    ]

    private static let denialPhrases = [
        "i don't have capabilities",
        "i do not have capabilities",
        "i have no capabilities",
        "i don't have any tools",
        "i do not have any tools",
        "i cannot list",
        "i can't list",
        "i cannot provide a list",
        "i don't have tasks or capabilities",
        "i can't help with that",
        "i cannot help with that",
        "i couldn't interpret that",
        "i could not interpret that",
        "could you say it another way",
        "could you rephrase",
        "could you clarify",
        "say it another way"
    ]

    private static let targetedDenialPhrases = [
        "i can't check", "i cannot check", "i can't inspect", "i cannot inspect",
        "i can't search", "i cannot search", "i can't browse", "i cannot browse",
        "i can't use", "i cannot use", "i can't run", "i cannot run",
        "i don't support", "i do not support"
    ]

    private static func minimumCategories(for question: String) -> Int {
        if question == capabilityQuestions[1] { return 7 }
        if question == capabilityQuestions[0] { return 2 }
        return 1
    }

    /// Deterministic coordinator regression. The fake frontend models both a healthy
    /// grounded response and the response-contract failures that used to collapse into
    /// the same clarification sentence. It never invokes a real tool or RunLog.
    @MainActor
    static func run() async -> Bool {
        guard SelfTest.isRunning else {
            print("VOICE_CAPABILITY_FAILED: requires SelfTest.isRunning to protect conversation history")
            return false
        }

        let harnessFailureBefore = SelfTest.failed
        let coordinator = VoiceConversationCoordinator.shared
        coordinator.resetForTesting()
        AgentSession.shared.clear()
        let plannerIDs = Set(RealtimeAgent.plannableTools().map(\.id))
        let requiredIDs = [
            "get_agenda", "search_email", "computer.inspect_ui", "filesystem.search",
            "browser.snapshot", "shell.run"
        ].filter { plannerIDs.contains($0) }
        let probe = VoiceCapabilityProbe(requiredIDs: requiredIDs, mode: .healthy)
        var workerCalls = 0
        coordinator.streamForTesting = { system, messages in
            await probe.stream(system: system, messages: messages)
        }
        coordinator.workerForTesting = { _ in
            workerCalls += 1
            return "test worker unexpectedly ran"
        }

        var failures: [String] = []
        failures.append(contentsOf: responseOutcomeFailures())
        failures.append(contentsOf: promptPlanFailures())
        failures.append(contentsOf: snapshotFailures())
        let inventory = VoiceCapabilitySnapshot.current()
        print("VOICE_CAPABILITY_INVENTORY: \(inventory.promptText.count) characters; \(inventory.toolIDs.count) tools")
        for category in ["Meeting context:", "Google Workspace:", "Frontmost Mac UI:", "Browser pages:", "Local files:", "Shell:"] {
            if !inventory.promptText.contains(category) {
                failures.append("inventory omitted category \(category)")
            }
        }
        let unavailable = VoiceCapabilitySnapshot.make(tools: RealtimeAgent.plannableTools(),
            availability: .init(accessibilityGranted: false, workspace: .signedOut))
        if !unavailable.promptText.contains("Accessibility: not granted")
            || !unavailable.promptText.contains("Google Workspace: not connected")
            || !unavailable.promptText.contains("require approval") {
            failures.append("inventory lost availability or approval evidence under its normal budget")
        }
        var outputs: [(String, String)] = []
        var capabilityCallIndex = 0
        for (index, question) in replayQuestions.enumerated() {
            let turn = await coordinator.handle(question)
            let reply = turn.reply
            outputs.append(("capability-" + String(index + 1), reply))
            if let failure = coordinator.lastFailure {
                failures.append("healthy turn recorded failure: " + failure.auditDetail)
                SelfTest.diagnostic("VOICE_CAPABILITY_HEALTHY_FAILURE: " + bounded(failure.auditDetail))
            }
            if question == "Uh" {
                let short = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                if !short.isEmpty {
                    failures.append("filler turn was not silent: " + bounded(reply))
                }
                continue
            }
            let snapshotText = await probe.snapshotText(for: capabilityCallIndex)
            capabilityCallIndex += 1
            let groundedIDs = inventory.toolIDs
            if !snapshotText.contains("Capability inventory") { failures.append("missing capability context") }
            if question == capabilityQuestions[1],
               (!snapshotText.contains(capabilityQuestions[0]) || !snapshotText.contains("Uh")) {
                failures.append("capability list follow-up lost the original question or hesitation")
            }
            let expectedCategories = minimumCategories(for: question)
            let answerCheck = capabilityAnswerCheck(
                reply,
                groundedIDs: groundedIDs,
                minimumCategories: expectedCategories
            )
            if !answerCheck.ok {
                failures.append(question + ": " + answerCheck.reason)
            }
        }
        try? await Task.sleep(for: .milliseconds(25))
        if await probe.streamCallCount != capabilityQuestions.count {
            failures.append("filler turn triggered frontend inference")
        }
        if workerCalls != 0 {
            failures.append("capability questions executed " + String(workerCalls) + " tool worker(s)")
        }
        if await probe.historyTurnsObserved < capabilityQuestions.count - 1 {
            failures.append("coordinator did not preserve prior capability turns in history")
        }
        if coordinator.hasActiveWork || !coordinator.jobs.isEmpty {
            failures.append("describing capabilities created a background objective")
        }
        if AgentSession.shared.messages.contains(where: {
            $0.role == "system" || $0.text.contains("Supported capabilities from the execution registry:")
        }) {
            failures.append("capability inventory leaked into user conversation history")
        }

        // Keep response-contract failures distinct from an ambiguous user request. The
        // healthy capability assertions above must never accidentally accept these cases.
        for fixture in [VoiceCapabilityProbe.Mode.modelError, .malformed, .ambiguous] {
            coordinator.resetForTesting()
            let errorProbe = VoiceCapabilityProbe(requiredIDs: requiredIDs, mode: fixture)
            coordinator.streamForTesting = { system, messages in
                await errorProbe.stream(system: system, messages: messages)
            }
            coordinator.workerForTesting = { _ in
                workerCalls += 1
                return "test worker unexpectedly ran"
            }
            let label = fixture.label
            let turn = await coordinator.handle(fixture.request)
            let reply = turn.reply.trimmingCharacters(in: .whitespacesAndNewlines)
            outputs.append((label, reply))
            guard !reply.isEmpty else {
                failures.append(label + ": coordinator returned an empty diagnostic reply")
                continue
            }
            if fixture == .ambiguous {
                if capabilityAnswerCheck(reply, groundedIDs: [], minimumCategories: 1).ok {
                    failures.append("ambiguous request was presented as a grounded capability answer")
                }
            } else if capabilityAnswerCheck(reply, groundedIDs: requiredIDs, minimumCategories: 1).ok {
                failures.append(label + ": failure was accepted as a capability answer")
            }
            if coordinator.hasActiveWork || !coordinator.jobs.isEmpty {
                failures.append(label + ": response-contract failure created background work")
            }
            if fixture != .ambiguous && !coordinator.inputPending {
                failures.append(label + ": internal failure released the input barrier")
            }
            let expectedFailure: VoiceFrontendFailureCode? = switch fixture {
            case .modelError: .modelError
            case .malformed: .malformedEnvelope
            default: nil
            }
            if coordinator.lastFailure?.code != expectedFailure {
                failures.append(label + ": wrong failure category")
                let detail = coordinator.lastFailure?.auditDetail ?? "none"
                SelfTest.diagnostic("VOICE_CAPABILITY_FAILURE_CATEGORY: " + label + " " + bounded(detail))
            } else if let failure = coordinator.lastFailure {
                SelfTest.diagnostic("VOICE_CAPABILITY_FAILURE: " + label + " " + bounded(failure.auditDetail))
                if fixture == .modelError {
                    let code = failure.errorCode ?? ""
                    if code.isEmpty || code.count > 64 {
                        failures.append(label + ": model error detail was missing or unbounded")
                        SelfTest.diagnostic("VOICE_CAPABILITY_FAILURE_DETAIL: " + label + " missing-or-unbounded")
                    }
                }
            }
        }
        // A later valid capability answer must release an error-held input barrier, while
        // continuing to avoid the worker path entirely.
        coordinator.streamForTesting = { system, messages in
            let recoveryProbe = VoiceCapabilityProbe(requiredIDs: requiredIDs, mode: .healthy)
            return await recoveryProbe.stream(system: system, messages: messages)
        }
        let recovery = await coordinator.handle(capabilityQuestions[0])
        if coordinator.inputPending {
            failures.append("valid capability answer did not release the input barrier")
        }
        let recoveryGrounding = requiredIDs
        if !capabilityAnswerCheck(recovery.reply, groundedIDs: recoveryGrounding, minimumCategories: 1).ok {
            failures.append("valid capability recovery was not grounded")
        }
        if let failure = coordinator.lastFailure {
            failures.append("valid capability recovery recorded failure: " + failure.auditDetail)
            SelfTest.diagnostic("VOICE_CAPABILITY_RECOVERY_FAILURE: " + bounded(failure.auditDetail))
        }
        if workerCalls != 0 {
            failures.append("response-contract fixtures executed " + String(workerCalls) + " tool worker(s)")
        }

        // A typed capability control is answered from the authoritative snapshot and
        // must never enter the worker path merely because the user asked for a list.
        coordinator.resetForTesting()
        let capabilitiesProbe = VoiceCapabilityProbe(requiredIDs: requiredIDs, mode: .capabilities)
        coordinator.streamForTesting = { system, messages in
            await capabilitiesProbe.stream(system: system, messages: messages)
        }
        coordinator.workerForTesting = { _ in
            workerCalls += 1
            return "test worker unexpectedly ran"
        }
        let capabilitiesTurn = await coordinator.handle(capabilityQuestions[0])
        outputs.append(("typed-capabilities", capabilitiesTurn.reply))
        if capabilitiesTurn.reply != VoiceCapabilitySnapshot.current().spokenSummary {
            failures.append("typed capability control did not return the authoritative inventory summary")
        }
        if coordinator.lastFailure != nil || coordinator.inputPending {
            failures.append("typed capability control left a failure or input barrier")
        }
        if workerCalls != 0 || coordinator.hasActiveWork || !coordinator.jobs.isEmpty {
            failures.append("typed capability control dispatched tool work")
        }

        failures += await failureLifecycleFailures()
        if SelfTest.failed && !harnessFailureBefore {
            failures.append("self-test harness failure was raised during deterministic replay")
            SelfTest.diagnostic("VOICE_CAPABILITY_HARNESS_FAILURE: deterministic replay")
        }
        for (label, output) in outputs {
            print("VOICE_CAPABILITY_CASE: " + label + " output=" + bounded(output))
        }
        for failure in failures {
            print("VOICE_CAPABILITY_WRONG: \(bounded(failure))")
        }
        let okay = failures.isEmpty && !SelfTest.failed
        print(okay ? "VOICE_CAPABILITY_OK" : "VOICE_CAPABILITY_FAILED")
        coordinator.resetForTesting()
        return okay
    }

    @MainActor
    private static func failureLifecycleFailures() async -> [String] {
        let coordinator = VoiceConversationCoordinator.shared
        let capture = AgentCaptureController.shared
        let agent = RealtimeAgent.shared
        let speech = AgentSpeechSynthesizer.shared
        coordinator.resetForTesting()
        await capture.beginSession(captureAudio: false)
        speech.useTestingBacking(RecordingSpeechBacking())
        var queued: [String] = []
        speech.onPlaybackEvent = { event in
            if case .enqueued(let text) = event { queued.append(text) }
        }
        var failures: [String] = []
        let held = AsyncThrowingStream<String, Error>.makeStream()
        let heldInferenceCount = VoiceHeldInferenceCount()
        coordinator.streamForTesting = { _, _ in
            await heldInferenceCount.increment()
            return held.stream
        }
        coordinator.responseDeadlineForTesting = .seconds(2)
        let activeResponse = Task { await coordinator.handle("Explain this synthetic result.") }
        for _ in 0..<100 {
            if await heldInferenceCount.value > 0 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        held.continuation.yield("<answer/>Here is the result. ")
        try? await Task.sleep(for: .milliseconds(30))
        let speechEpoch = agent.speechGeneration
        let hesitation = await coordinator.handle("Uh")
        let inferenceCount = await heldInferenceCount.value
        if !hesitation.reply.isEmpty || inferenceCount != 1 || !agent.isThinking
            || agent.speechGeneration != speechEpoch {
            failures.append("hesitation interrupted or replaced an active frontend response")
        }
        held.continuation.yield("The result remains available.")
        held.continuation.finish()
        let heldReply = await activeResponse.value
        if heldReply.reply != "Here is the result. The result remains available." {
            failures.append("an active response was lost after hesitation")
        }
        if !coordinator.inputPending {
            failures.append("old response released the newer hesitation input barrier")
        }
        coordinator.resetForTesting()
        coordinator.responseDeadlineForTesting = .milliseconds(50)
        coordinator.streamForTesting = { _, _ in
            AsyncThrowingStream { continuation in
                continuation.yield("<answer/>")
                // Deliberately outlive the deadline: cancellation of a caller
                // cannot be assumed to stop a native producer.
                Task.detached {
                    try? await Task.sleep(for: .milliseconds(180))
                    continuation.yield("Late stale answer must never be spoken.")
                    continuation.finish()
                }
            }
        }
        _ = await coordinator.handle("Answer this synthetic deadline request.")
        if coordinator.lastFailure?.code != .deadline {
            failures.append("deadline fixture did not actually hit its deadline")
        }
        if !coordinator.inputPending {
            failures.append("deadline failure released the input barrier")
        }
        try? await Task.sleep(for: .milliseconds(250))
        if queued.contains(where: { $0.contains("Late stale answer") }) {
            failures.append("expired response restarted speech after its failure reply")
        }
        coordinator.responseDeadlineForTesting = nil
        let generation = agent.beginVoiceFrontend()
        agent.userSpeechStarted()
        agent.discardVoiceInput()
        if agent.isThinking || coordinator.inputPending {
            failures.append("discarding interrupted input left the frontend busy")
        }
        // Merely discarding acoustic activity must not clear a still-valid
        // response that was never interrupted by recognized user speech.
        _ = generation
        _ = agent.beginVoiceFrontend()
        coordinator.inputActivityStarted()
        agent.discardVoiceInput()
        if !agent.isThinking {
            failures.append("discarding an acoustic-only candidate cleared a valid response")
        }
        agent.waitForVoiceContinuation()
        coordinator.resetForTesting()
        await capture.endSession(source: .done)
        speech.restoreSystemBacking()
        return failures
    }

    /// Live model acceptance. Inputs are synthetic text, while generation, coordinator
    /// history and capability grounding are real. SelfTest.isRunning is required because
    /// the coordinator records turns in AgentSession; under the self-test harness those
    /// appends stay in memory and never reach the user's conversation file.
    @MainActor
    static func runLive() async -> Bool {
        guard SelfTest.isRunning else {
            print("VOICE_CAPABILITY_LIVE_FAILED: requires SelfTest.isRunning to protect conversation history")
            return false
        }

        let harnessFailureBefore = SelfTest.failed
        let coordinator = VoiceConversationCoordinator.shared
        coordinator.resetForTesting()
        AgentSession.shared.clear()
        let pollutedHistory = CommandLine.arguments.contains("--voice-polluted-history")
        if pollutedHistory {
            // In-memory constants reproduce the saved history before the 18:48
            // failure. Never load or rewrite the user's actual conversation.
            let priorTurns = [
                ("What can you do", "I can help with questions or tasks—do you have anything in mind?"),
                ("Uh", ""),
                ("can you list me all of your tasks, all of your capabilities and functionalities?", "I don’t have tasks or capabilities to list—do you have a specific question or need help with something else?"),
                ("What about your tools?", "I couldn't interpret that. Could you say it another way?"),
                ("No, uh... Could you say it", "I couldn’t quite understand your question—could you clarify what you meant?"),
                ("I couldn't quite under", "I couldn't interpret that. Could you say it another way?"),
                ("What are the list of tools that you have?", "I couldn't interpret that. Could you say it another way?"),
                ("Access to. I", "I couldn't interpret that. Could you say it another way?"),
                ("How's it going? Easy, easy.", "I'm here to help—how can I assist you?")
            ]
            for (user, assistant) in priorTurns {
                AgentSession.shared.recordUser(user, source: .voice)
                if !assistant.isEmpty {
                    let id = AgentSession.shared.recordAssistant(assistant, source: .voice)
                    AgentSession.shared.updateSpeech(messageID: id,
                        delivery: VoiceSpeechDelivery(completedText: "", status: "interrupted"))
                }
            }
            print("VOICE_CAPABILITY_LIVE_HISTORY: polluted interrupted conversation")
        }
        let backing = RecordingSpeechBacking()
        AgentSpeechSynthesizer.shared.useTestingBacking(backing)
        defer {
            coordinator.resetForTesting()
            AgentSpeechSynthesizer.shared.restoreSystemBacking()
        }

        do {
            try await LocalVoiceFrontend.shared.prepare()
        } catch {
            print("VOICE_CAPABILITY_LIVE_FAILED: model unavailable \(bounded(error.localizedDescription))")
            return false
        }

        var failures: [String] = []
        var outputs: [(String, String)] = []
        var durations: [TimeInterval] = []
        let startedMessageCount = AgentSession.shared.messages.count
        let liveRegistryIDs = Set(RealtimeAgent.plannableTools().map(\.id))
        var attemptedWorkerCalls = 0
        coordinator.workerForTesting = { _ in
            attemptedWorkerCalls += 1
            return "self-test worker; no external effect"
        }
        for (index, question) in replayQuestions.enumerated() {
            let messageCountBefore = AgentSession.shared.messages.count
            let began = Date()
            let turn = await coordinator.handle(question)
            durations.append(Date().timeIntervalSince(began))
            let reply = turn.reply
            outputs.append(("live-" + String(index + 1), reply))
            if let failure = coordinator.lastFailure {
                failures.append("healthy live turn recorded failure: " + failure.auditDetail)
                SelfTest.diagnostic("VOICE_CAPABILITY_LIVE_FAILURE: " + bounded(failure.auditDetail))
            }
            if question == "Uh" {
                let short = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                if !short.isEmpty {
                    failures.append("live filler turn was not silent: " + bounded(reply))
                }
                let added = AgentSession.shared.messages.count - messageCountBefore
                if added != 1 || AgentSession.shared.messages.last?.role != "user" {
                    failures.append("live filler turn created an assistant response or extra history")
                }
                continue
            }
            if pollutedHistory, reply != VoiceCapabilitySnapshot.current().spokenSummary {
                failures.append("polluted history did not select the authoritative capability route: " + question)
            }
            let minimumCategories = question == capabilityQuestions[1] ? 7 : 1
            let result = capabilityAnswerCheck(
                reply,
                groundedIDs: Array(liveRegistryIDs),
                minimumCategories: minimumCategories
            )
            if !result.ok {
                failures.append(question + ": " + result.reason)
            }
        }

        if pollutedHistory {
            let ordinary = await coordinator.handle("What is a haiku?")
            let answer = ordinary.reply.lowercased()
            if !answer.contains("poem") || !(answer.contains("three") || answer.contains("3"))
                || ordinary.reply == VoiceCapabilitySnapshot.current().spokenSummary {
                failures.append("ordinary question after polluted history lost its answer: " + ordinary.reply)
            }
            outputs.append(("ordinary-after-pollution", ordinary.reply))
        }
        try? await Task.sleep(for: .milliseconds(25))
        if attemptedWorkerCalls != 0 {
            failures.append("live capability probe attempted " + String(attemptedWorkerCalls) + " tool worker dispatch(es)")
        }

        if !backing.spoken.isEmpty {
            failures.append("live capability probe reached the speech backing")
        }
        if coordinator.hasActiveWork || !coordinator.jobs.isEmpty {
            failures.append("live capability probe created a background objective")
        }
        let recorded = AgentSession.shared.messages.count - startedMessageCount
        if recorded < capabilityQuestions.count * 2 + 1 {
            failures.append("live coordinator did not retain user and assistant turns in memory")
        }
        if AgentSession.shared.messages.contains(where: {
            $0.role == "system" || $0.text.contains("Supported capabilities from the execution registry:")
        }) {
            failures.append("live capability inventory leaked into user conversation history")
        }

        if SelfTest.failed && !harnessFailureBefore {
            failures.append("self-test harness failure was raised during live replay")
            SelfTest.diagnostic("VOICE_CAPABILITY_LIVE_HARNESS_FAILURE: live replay")
        }
        for (label, output) in outputs {
            let index = outputs.firstIndex { $0.0 == label && $0.1 == output } ?? 0
            let elapsed = index < durations.count ? String(format: "%.3fs", durations[index]) : "unknown"
            print("VOICE_CAPABILITY_LIVE_CASE: " + label + " elapsed=" + elapsed + " text_only=true output=" + bounded(output))
        }
        for failure in failures {
            print("VOICE_CAPABILITY_LIVE_WRONG: \(bounded(failure))")
        }
        let okay = failures.isEmpty && !SelfTest.failed
        print(okay ? "VOICE_CAPABILITY_LIVE_OK" : "VOICE_CAPABILITY_LIVE_FAILED")
        return okay
    }

    private static func capabilityAnswerCheck(
        _ reply: String,
        groundedIDs: [String],
        minimumCategories: Int
    ) -> (ok: Bool, reason: String) {
        let lower = reply.lowercased().replacingOccurrences(of: "’", with: "'")
        guard !lower.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (false, "empty answer")
        }
        if denialPhrases.contains(where: lower.contains) {
            return (false, "blanket denial or clarification fallback: \(bounded(reply))")
        }
        let clauses = lower.components(separatedBy: CharacterSet(charactersIn: ".;!\n"))
        if clauses.contains(where: { clause in
            targetedDenialPhrases.contains(where: clause.contains)
                && !["without", "until", "permission", "connection", "connected", "approval", "setup"]
                    .contains(where: clause.contains)
        }) {
            return (false, "denied a supported feature while listing capability categories")
        }
        if ["voice delivery", "no complete spoken clause", "completed spoken clauses", "confirmed heard"]
            .contains(where: lower.contains) {
            return (false, "delivery diagnostics leaked into the answer")
        }
        let ending = lower.trimmingCharacters(in: .whitespacesAndNewlines).last
        if ending != "." && ending != "!" && ending != "?" {
            return (false, "answer does not end with a complete sentence: " + bounded(reply))
        }
        let positive = ["i can", "i'm able", "you can ask", "i help", "can check", "can inspect",
                        "can search", "can use", "can answer"]
        guard positive.contains(where: lower.contains) else {
            return (false, "no positive ability statement: \(bounded(reply))")
        }
        let categories = supportedCategories(in: groundedIDs.isEmpty ? nil : Set(groundedIDs))
        let answerCategories = categories.filter { category in
            category.terms.contains(where: lower.contains)
        }
        if answerCategories.count < minimumCategories {
            return (false, "only " + String(answerCategories.count) + " concrete capability categories; expected " + String(minimumCategories) + ": " + bounded(reply))
        }
        return (true, "")
    }

    private static func supportedCategories(in ids: Set<String>?) -> [(name: String, terms: [String])] {
        let all: [(name: String, terms: [String])] = [
            ("calendar", ["calendar", "agenda", "event"]),
            ("computer", ["frontmost", "window", "inspect", "click", "type"]),
            ("files", ["file", "files", "drive", "document"]),
            ("mail", ["mail", "email", "gmail"]),
            ("browser", ["browser", "web page", "webpage", "tab"]),
            ("shell", ["shell", "command", "terminal"]),
            ("meeting", ["meeting", "transcript", "action item"])
        ]
        guard let ids else { return all }
        return all.filter { category in
            ids.contains { id in
                switch category.name {
                case "calendar": return id == "get_agenda" || id.contains("event")
                case "computer": return id.hasPrefix("computer.")
                case "files": return id.hasPrefix("filesystem.") || id.contains("drive") || id.contains("doc")
                case "mail": return id.contains("mail")
                case "browser": return id.hasPrefix("browser.")
                case "shell": return id == "shell.run"
                case "meeting": return id.hasPrefix("meeting.")
                default: return false
                }
            }
        }
    }

    private static func promptPlanFailures() -> [String] {
        let messages: [LLMChatMessage] = [
            .init(role: .system, content: "Application facts"),
            .init(role: .user, content: "What can you do"),
            .init(role: .assistant, content: "I can read your calendar."),
            .init(role: .user, content: "Uh"),
            .init(role: .user, content: "What about your tools?")
        ]
        guard let plan = LocalVoicePrompt.plan(system: "Policy", messages: messages) else {
            return ["native history did not construct a prompt"]
        }
        var failures: [String] = []
        if plan.instructions != "Policy\n\nApplication facts"
            || plan.latestUser != "What about your tools?"
            || plan.entryRoles != [.user, .assistant, .user]
            || plan.history.map(\.content) != Array(messages[1...3]).map(\.content) {
            failures.append("native prompt lost role order, application facts, or latest-turn boundary")
        }
        if LocalVoicePrompt.plan(system: "Policy", messages: [.init(role: .system, content: "Facts")]) != nil {
            failures.append("native prompt accepted absent user input")
        }
        return failures
    }

    @MainActor private static func snapshotFailures() -> [String] {
        var failures: [String] = []
        let empty = VoiceCapabilitySnapshot.make(tools: [])
        if empty.spokenSummary != "No application tools are currently enabled." {
            failures.append("empty registry claimed supported tools")
        }
        let onlyRead = RealtimeAgent.plannableTools().filter { $0.id == "filesystem.read" }
        if onlyRead.count != 1 { failures.append("read-only snapshot fixture is missing its registry tool") }
        let readSummary = VoiceCapabilitySnapshot.make(tools: onlyRead).spokenSummary
        if !readSummary.contains("read local files") || readSummary.contains("write local files")
            || readSummary.contains("email") || readSummary.contains("calendar") {
            failures.append("read-only registry claimed an unsupported capability")
        }
        return failures
    }

    /// Pure response-contract coverage. These fixtures keep a malformed model output,
    /// a timeout, cancellation and an input uncertainty in separate failure classes even
    /// when their user-facing recovery sentence is short.
    private static func responseOutcomeFailures() -> [String] {
        let fixtures: [(String, String, VoiceFrontendStreamTermination, VoiceFrontendResponseOutcome)] = [
            ("capabilities", "<capabilities/>", .completed, .capabilities),
            ("capabilities-trailing", "<capabilities/>oops", .completed,
             .failure(.malformedEnvelope(shape: "malformedTag", length: 19))),
            (
                "empty",
                "",
                .completed,
                .failure(.emptyCompletion(shape: "empty", length: 0))
            ),
            (
                "prefix-incomplete",
                "<ans",
                .completed,
                .failure(.incompleteCompletion(shape: "answerPrefix", length: 4))
            ),
            (
                "malformed",
                "<unexpected>",
                .completed,
                .failure(.malformedEnvelope(shape: "malformedTag", length: 12))
            ),
            (
                "deadline",
                "<answer/>I can",
                .deadline,
                .failure(.deadline(shape: "answer", length: 14))
            ),
            (
                "cancellation",
                "<answer/>partial",
                .cancelled,
                .failure(.cancelled(shape: "answer", length: 16))
            ),
            (
                "model-error",
                "<answer/>partial",
                .modelError("simulated_model_error"),
                .failure(.modelError(shape: "answer", length: 16, errorCode: "simulated_model_error"))
            ),
            (
                "valid-answer",
                "<answer/>I can help.",
                .completed,
                .answer("I can help.")
            ),
            (
                "valid-control",
                "<use_tools/>",
                .completed,
                .newWork
            )
        ]
        var failures: [String] = []
        for (label, snapshot, termination, expected) in fixtures {
            let actual = VoiceFrontendResponseOutcome.resolve(snapshot: snapshot, termination: termination)
            if actual != expected {
                failures.append("response outcome " + label + " resolved as " + String(describing: actual))
            }
        }
        return failures
    }

    private static func bounded(_ text: String) -> String {
        let oneLine = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return String(oneLine.prefix(420))
    }

    /// P0-3 / P0-4 / P0-6 (+D8) / P0-7 coordinator routing. Deterministic: every model
    /// response is scripted, no tool runs, no RunLog. Wire with `--selftest-voice-turn-routing`
    /// in `NextNotesApp.runRequestedSelfTest`.
    @MainActor
    static func runTurnRouting() async -> Bool {
        guard SelfTest.isRunning else {
            print("VOICE_TURN_ROUTING_FAILED: requires SelfTest.isRunning to protect conversation history")
            return false
        }
        let harnessFailureBefore = SelfTest.failed
        var failures: [String] = []
        var outputs: [(String, String)] = []
        let coordinator = VoiceConversationCoordinator.shared

        // MARK: P0-3 — eight real garbled utterances; none reaches frontend inference.
        coordinator.resetForTesting()
        AgentSession.shared.clear()
        let garbleProbe = TurnRoutingProbe()
        coordinator.streamForTesting = { _, _ in await garbleProbe.stream() }
        coordinator.workerForTesting = { work in await garbleProbe.ranWorker(work.original) }
        let auditBeforeGarble = AgentAuditLog.shared.entries.count
        let garbled = [
            "boys", "Am", "Take it.", "Okay.", "hey win", "Hey we",
            "can you also nothing get to my folder to my document folder in open next project",
            "note the four days called next note",
        ]
        for (index, utterance) in garbled.enumerated() {
            let turn = await coordinator.handle(utterance)
            outputs.append(("garble-\(index + 1)", "\(utterance) → \(turn.reply)"))
            if turn.reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                failures.append("garble turn was silent: \(utterance)")
            }
        }
        if await garbleProbe.streamCalls != 0 {
            failures.append("garbled utterances reached frontend inference "
                + "\(await garbleProbe.streamCalls)x")
        }
        let clarifiers = AgentAuditLog.shared.entries.prefix(
            max(0, AgentAuditLog.shared.entries.count - auditBeforeGarble)
        ).filter { $0.detail.contains("garble_clarifier") }
        // Six short fragments plus the orphan naming turn clarify; the folder sentence
        // parses and submits. A confident index hit may submit instead of clarifying,
        // but it still never reaches the frontend — hence the lower bound.
        if clarifiers.count < 6 {
            failures.append("only \(clarifiers.count) garble_clarifier audit entries for eight garbled turns")
        }
        if coordinator.jobs.isEmpty {
            failures.append("the parsable folder sentence was never submitted")
        }

        // MARK: P0-4 — the 20:45:00Z browser command through the live coordinator path.
        coordinator.resetForTesting()
        AgentSession.shared.clear()
        let browserProbe = TurnRoutingProbe()
        coordinator.streamForTesting = { _, _ in await browserProbe.stream() }
        coordinator.workerForTesting = { work in await browserProbe.ranWorker(work.original) }
        let auditBeforeBrowser = AgentAuditLog.shared.entries.count
        let browserUtterance = "You open Google Chrome and go to youtube.com."
        let browserTurn = await coordinator.handle(browserUtterance)
        outputs.append(("browser-command", browserTurn.reply))
        try? await Task.sleep(for: .milliseconds(150))
        if await browserProbe.streamCalls != 0 {
            failures.append("browser command reached frontend inference")
        }
        if await browserProbe.workerPrompts != [browserUtterance] {
            failures.append("browser command did not submit its own text: "
                + bounded((await browserProbe.workerPrompts).joined(separator: " | ")))
        }
        let browserEntries = Array(AgentAuditLog.shared.entries.prefix(
            max(0, AgentAuditLog.shared.entries.count - auditBeforeBrowser)))
        if !browserEntries.contains(where: { $0.detail.contains("browser.navigate") }) {
            failures.append("audit shows no browser.navigate path for the browser command")
        }
        if browserEntries.contains(where: {
            ($0.title + " " + $0.detail + " " + ($0.toolID ?? "")).contains("append_doc")
        }) {
            failures.append("audit mentions append_doc for a browser command")
        }

        // MARK: P0-6 + D8 — the 5-turn email/calendar loop.
        //
        // T1 routes before any model call. T2 rephrases as a question the gate
        // deliberately misses, so the scripted denial exercises the pending slot;
        // T3 resolves it, T4 repeats the denial into the backstop, T5 confirms the
        // re-stored pending still resolves.
        coordinator.resetForTesting()
        AgentSession.shared.clear()
        let loopProbe = TurnRoutingProbe()
        coordinator.streamForTesting = { _, _ in await loopProbe.stream() }
        coordinator.workerForTesting = { work in await loopProbe.ranWorker(work.original) }
        let request = "Summarise my emails, list tomorrow's events."
        let rephrase = "What did my emails say today?"
        let t1 = await coordinator.handle(request)
        outputs.append(("d8-1-request", t1.reply))
        if t1.reply != "I'm on it." {
            failures.append("tool-shaped request did not route before the model: " + bounded(t1.reply))
        }
        await loopProbe.enqueueAnswer("<answer/>I don't have access to your email.")
        let t2 = await coordinator.handle(rephrase)
        outputs.append(("d8-2-denial", t2.reply))
        if coordinator.pendingIntent?.requestText != rephrase {
            failures.append("denied capability mention was not kept as pending")
        }
        let t3 = await coordinator.handle("use them")
        outputs.append(("d8-3-ack", t3.reply))
        if t3.reply != "I'm on it." {
            failures.append("bare acknowledgment did not resolve to pending: " + bounded(t3.reply))
        }
        if coordinator.pendingIntent != nil {
            failures.append("resolved pending intent was not cleared")
        }
        await loopProbe.enqueueAnswer("<answer/>I don't have access to your email.")
        let t4 = await coordinator.handle(rephrase)
        outputs.append(("d8-4-backstop", t4.reply))
        if t4.reply != "I'm on it." {
            failures.append("second identical denial was spoken again: " + bounded(t4.reply))
        }
        let t5 = await coordinator.handle("yes")
        outputs.append(("d8-5-ack", t5.reply))
        if t5.reply != "I'm on it." {
            failures.append("acknowledgment after the backstop did not resolve: " + bounded(t5.reply))
        }
        try? await Task.sleep(for: .milliseconds(150))
        if await loopProbe.streamCalls != 2 {
            failures.append("D8 loop used frontend inference \(await loopProbe.streamCalls)x, expected 2")
        }
        if await loopProbe.workerPrompts != [request, rephrase, rephrase, rephrase] {
            failures.append("D8 loop did not submit the original texts: "
                + bounded((await loopProbe.workerPrompts).joined(separator: " | ")))
        }
        let denialsSpoken = outputs.filter { $0.0.hasPrefix("d8-") && $0.1.contains("don't have access") }
        if denialsSpoken.count > 1 {
            failures.append("the denial sentence was spoken \(denialsSpoken.count)x in one loop")
        }

        // MARK: P0-7 — the single renderer and live-only claims.
        let rawCases = [
            "Codex stopped: ERROR: You've hit your usage limit, I'll do it myself",
            "The model is not downloaded.",
            "OpenRouter HTTP 429: Rate limited",
            "https://openrouter.ai/api/v1 failed",
        ]
        for raw in rawCases {
            let rendered = RealtimeAgent.voiceSafeReply(raw)
            outputs.append(("renderer", "\(raw) → \(rendered)"))
            let lower = rendered.lowercased()
            if lower.contains("error:") || lower.contains("http") || lower.contains("is not downloaded") {
                failures.append("renderer leaked raw text: \(bounded(rendered))")
            }
        }
        func checkCode(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }
        checkCode("openrouter missing key was not notConfigured",
                  OpenRouterError.missingKey.asVoiceCode == .notConfigured)
        checkCode("openrouter missing model was not modelMissing",
                  OpenRouterError.missingModel.asVoiceCode == .modelMissing)
        checkCode("openrouter 429 was not rateLimited",
                  OpenRouterError.http(429, "Rate limited").asVoiceCode == .rateLimited)
        checkCode("openrouter quota was not quotaExceeded",
                  OpenRouterError.http(402, "quota exceeded").asVoiceCode == .quotaExceeded)
        checkCode("llama modelMissing was not modelMissing",
                  LlamaError.modelMissing.asVoiceCode == .modelMissing)
        checkCode("local-server noModel was not modelMissing",
                  LocalServerError.noModel("Ollama").asVoiceCode == .modelMissing)
        checkCode("an untyped error was not unknown",
                  NSError(domain: "example", code: 1).asVoiceCode == .unknown)
        let unready = VoiceCapabilitySnapshot.make(
            tools: RealtimeAgent.plannableTools(), availability: .init(modelResident: false))
        if unready.spokenSummary != "My voice model isn't ready yet. Open Settings ▸ Models to get it." {
            failures.append("a missing voice model still claimed capabilities: "
                + bounded(unready.spokenSummary))
        }
        let noCLI = VoiceCapabilitySnapshot.make(
            tools: RealtimeAgent.plannableTools(), availability: .init(cliOnPATH: false))
        if noCLI.spokenSummary.contains("search email")
            && !noCLI.spokenSummary.contains("helper isn't installed") {
            failures.append("a missing helper CLI still claimed workspace tools silently")
        }
        // A coordinator failure reply passes through the same renderer.
        coordinator.resetForTesting()
        AgentSession.shared.clear()
        let failureProbe = TurnRoutingProbe()
        coordinator.streamForTesting = { _, _ in await failureProbe.stream() }
        coordinator.workerForTesting = { work in await failureProbe.ranWorker(work.original) }
        await failureProbe.enqueueThrow()
        let failed = await coordinator.handle("Tell me a haiku about rain.")
        outputs.append(("failure-reply", failed.reply))
        let failedLower = failed.reply.lowercased()
        if failedLower.contains("error:") || failedLower.contains("http")
            || failedLower.contains("is not downloaded") {
            failures.append("coordinator failure reply leaked raw text: " + bounded(failed.reply))
        }
        if coordinator.lastFailure?.code != .modelError {
            failures.append("thrown frontend stream was not recorded as a model error")
        }

        if SelfTest.failed && !harnessFailureBefore {
            failures.append("self-test harness failure was raised during deterministic replay")
            SelfTest.diagnostic("VOICE_TURN_ROUTING_HARNESS_FAILURE: deterministic replay")
        }
        for (label, output) in outputs {
            print("VOICE_TURN_ROUTING_CASE: " + label + " output=" + bounded(output))
        }
        for failure in failures {
            print("VOICE_TURN_ROUTING_WRONG: \(bounded(failure))")
        }
        let okay = failures.isEmpty && !SelfTest.failed
        print(okay ? "VOICE_TURN_ROUTING_OK" : "VOICE_TURN_ROUTING_FAILED")
        coordinator.resetForTesting()
        return okay
    }
}

private actor VoiceHeldInferenceCount {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor VoiceCapabilityProbe {
    enum Mode: Equatable, Sendable {
        case healthy, capabilities, modelError, malformed, ambiguous

        var label: String {
            switch self {
            case .healthy: "healthy"
            case .capabilities: "capabilities"
            case .modelError: "model-error"
            case .malformed: "malformed"
            case .ambiguous: "ambiguous"
            }
        }

        var request: String {
            switch self {
            case .healthy: "What can you do"
            case .capabilities: "What can you do"
            case .modelError: "What about your tools?"
            case .malformed: "What are the list of tools that you have?"
            case .ambiguous: "Could you handle that?"
            }
        }
    }

    let requiredIDs: [String]
    let mode: Mode
    private var seenMessages: [[LLMChatMessage]] = []
    private var seenSystems: [String] = []
    private(set) var streamCallCount = 0
    private(set) var historyTurnsObserved = 0

    init(requiredIDs: [String], mode: Mode) {
        self.requiredIDs = requiredIDs
        self.mode = mode
    }

    func stream(system: String, messages: [LLMChatMessage]) -> AsyncThrowingStream<String, Error> {
        streamCallCount += 1
        seenMessages.append(messages)
        seenSystems.append(system)
        let history = seenMessages.count > 1 && messages.count > 1
        if history { historyTurnsObserved += 1 }
        let snapshotText = system + "\n" + messages.map(\.content).joined(separator: "\n")
        let groundedCount = requiredIDs.reduce(into: 0) { count, id in
            if snapshotText.contains(id) { count += 1 }
        }
        let hasGrounding = groundedCount >= 3
        let request = latestSpeech(in: messages)
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        switch mode {
        case .capabilities:
            continuation.yield("<capabilities/>")
            continuation.finish()
        case .modelError:
            continuation.finish(throwing: ProbeError.generation)
        case .malformed:
            continuation.yield("<unexpected>")
            continuation.finish()
        case .ambiguous:
            continuation.yield("<answer/>Could you clarify that request?")
            continuation.finish()
            case .healthy:
            let isCapability = request.lowercased().contains("what can you do")
                || request.lowercased().contains("capabilit")
                || request.lowercased().contains("what about your tools")
                || request.lowercased().contains("list of tools")
            if isCapability && hasGrounding {
                continuation.yield("<answer/>I can read meeting transcripts, check your calendar and email, inspect the frontmost window, search local files, work with browser pages, and run shell commands. Actions that change things wait for your approval.")
            } else if isCapability {
                continuation.yield("<use_tools/>")
            } else {
                continuation.yield("<answer/>Okay.")
            }
            continuation.finish()
        }
        return stream
    }

    func snapshotText(for index: Int) -> String {
        guard seenMessages.indices.contains(index) else { return "" }
        return seenSystems[index] + "\n" + seenMessages[index].map(\.content).joined(separator: "\n")
    }

    private func latestSpeech(in messages: [LLMChatMessage]) -> String {
        guard let content = messages.last?.content,
              let marker = content.range(of: "Latest user speech:", options: .backwards)
        else { return messages.last?.content ?? "" }
        return String(content[marker.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum ProbeError: Error {
        case generation
    }
}

/// Scripted frontend + worker capture for `--selftest-voice-turn-routing`. Counts
/// frontend stream calls (the garble and tool-shape gates must keep that at zero)
/// and records every worker prompt (acks and backstops must resubmit the original).
private actor TurnRoutingProbe {
    private(set) var streamCalls = 0
    private(set) var workerPrompts: [String] = []
    private var queued: [String] = []
    private var throwNext = false

    func enqueueAnswer(_ body: String) { queued.append(body) }
    func enqueueThrow() { throwNext = true }

    func stream() -> AsyncThrowingStream<String, Error> {
        streamCalls += 1
        if throwNext {
            throwNext = false
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: ProbeError.generation)
            }
        }
        let body = queued.isEmpty ? "<answer/>Okay." : queued.removeFirst()
        return AsyncThrowingStream { continuation in
            continuation.yield(body)
            continuation.finish()
        }
    }

    func ranWorker(_ original: String) -> String {
        workerPrompts.append(original)
        return "test worker; no external effect"
    }

    private enum ProbeError: Error {
        case generation
    }
}

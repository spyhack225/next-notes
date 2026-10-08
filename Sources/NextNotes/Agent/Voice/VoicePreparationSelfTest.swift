import Foundation
import NextNotesDictionary

/// PL-12: scripted stable partials through the actual coordinator and speculative
/// frontend slot. Only the external generator is replaced; no microphone/model required.
/// Run with --selftest-voice-latency --voice-latency-partials.
@MainActor
enum VoicePreparationSelfTest {
    static func run() async -> [String] {
        if CommandLine.arguments.contains("--voice-latency-partial-route") {
            return await VoicePartialRouteSelfTest.run()
        }
        let coordinator = VoiceConversationCoordinator.shared
        let capture = AgentCaptureController.shared
        let frontend = FrontendResponder.shared
        await capture.endSession(source: .done)
        coordinator.resetForTesting()
        await frontend.clearStagedTurn()
        await capture.beginSession(captureAudio: false)
        let source = Source()
        await frontend.setGenerationForTesting { _, messages, _ in
            source.stream(messages: messages)
        }
        var problems: [String] = []
        var speech = 0
        coordinator.answerSpeechObserverForTesting = { _ in speech += 1 }
        let historyCount = AgentSession.shared.messages.count
        if CommandLine.arguments.contains("--voice-no-speculation") {
            let speechBacking = RecordingSpeechBacking()
            AgentSpeechSynthesizer.shared.useTestingBacking(speechBacking)
            let words = "Hello there friend again"
            coordinator.prepareResponseIfUseful(words)
            if await source.waitForCount(1, within: .milliseconds(150)) {
                problems.append("no-speculation partial started model inference before commit")
            }
            if speech != 0 || !speechBacking.spoken.isEmpty
                || AgentSession.shared.messages.count != historyCount {
                problems.append("no-speculation partial spoke or stored a conversation before commit")
            }
            source.finishFutureRequests()
            source.finishLast()
            let turn = await coordinator.handle(words)
            let expected = "Prepared \(words)."
            if source.count != 1 || turn.delegated || turn.reply != expected
                || speechBacking.spoken.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines) != expected {
                problems.append("no-speculation committed turn did not produce exactly one fresh answer and speech")
            }
            await capture.endSession(source: .done)
            coordinator.resetForTesting()
            await frontend.clearStagedTurn()
            await frontend.setGenerationForTesting(nil)
            AgentSpeechSynthesizer.shared.restoreSystemBacking()
            return problems
        }
        problems += await AgentCaptureController.earlyLexicalPreparationSelfTestFailures(source: source)
        // Every revision gets its own observable producer. Four words separately
        // detects the old fixed delay, even if the short-partial gate is removed alone.
        for words in ["Hello", "Hello there", "Hello there friend", "Hello there friend again"] {
            let before = source.count
            let began = ContinuousClock.now
            coordinator.prepareResponseIfUseful(words)
            if !(await source.waitForCount(before + 1, within: .milliseconds(150))) {
                problems.append("preparation did not start within 150ms for '\(words)'")
            } else {
                let elapsed = began.duration(to: .now).components
                let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                SelfTest.diagnostic("VOICE_PREPARATION_START words=\(words.split(separator: " ").count) seconds=\(seconds)")
            }
        }
        // Let the original fourth revision expose its producer too: the unchanged
        // red test can still check reuse/cancellation rather than ending at the gate.
        _ = await source.waitForCount(1, within: .milliseconds(400))
        let count = source.count
        coordinator.prepareResponseIfUseful(" Hello there friend again! ")
        try? await Task.sleep(for: .milliseconds(50))
        if source.count != count { problems.append("an equivalent partial restarted preparation") }
        if speech != 0 || AgentSession.shared.messages.count != historyCount {
            problems.append("preparation delivered speech or stored a conversation before commit")
        }
        coordinator.prepareResponseIfUseful("")
        if count > 0, !(await source.waitForCancellation(count - 1)) {
            problems.append("an empty revision did not cancel the stale producer")
        }
        if source.count != count { problems.append("an empty revision started inference") }

        let final = "Hello there friend once more"
        coordinator.prepareResponseIfUseful(final)
        if await source.waitForCount(count + 1, within: .milliseconds(500)),
           let request = source.last {
            // The actual staging caller carries all the same application context,
            // excluding only the words still being spoken.
            let staging = coordinator.stagingRequest()
            let marker = "Latest user speech:\n"
            let expectedPrefix: String?
            if let content = request.messages.last?.content,
               let range = content.range(of: marker, options: .backwards) {
                expectedPrefix = String(content[..<range.upperBound])
            } else { expectedPrefix = nil }
            if staging.system != VoiceConversationCoordinator.systemPrompt
                || staging.messages.count != request.messages.count
                || zip(staging.messages.dropLast(), request.messages.dropLast()).contains(where: { pair in
                    pair.0.role != pair.1.role || pair.0.content != pair.1.content
                })
                || staging.messages.last?.content != expectedPrefix {
                problems.append("staging caller lost the actual history/capability/work prefix")
            }
            source.finishLast()
            do {
                let stream = await ModelPassRecorder.$correlation.withValue(request.correlation) {
                    await frontend.stream(system: VoiceConversationCoordinator.systemPrompt,
                        messages: request.messages, maxTokens: 256)
                }
                var answer = ""
                for try await delta in stream { answer += delta }
                if answer != "<answer/> Prepared \(final)." || source.count != count + 1 {
                    problems.append("matching commit did not reuse the exact revised preparation")
                }
            } catch { problems.append("matching commit failed: \(error.localizedDescription)") }
        } else { problems.append("final scripted revision did not reach the actual frontend") }
        problems += await frozenPlaybackContextCases()
        problems += await dictionaryPreparationCases()
        // Existing slot negatives pin context/word/symbol/identity changes and late
        // revisions through the SAME frontend implementation, independently of timing.
        if !(await LocalVoiceFrontendSpeculationSelfTest.run()) {
            problems.append("existing exact-request/correlation/revision safety checks failed")
        }
        await capture.endSession(source: .done)
        coordinator.resetForTesting()
        await frontend.clearStagedTurn()
        await frontend.setGenerationForTesting(nil)
        return problems
    }

    /// Actual prior-clause receipt may arrive between an early useful partial and
    /// its committed barge-in. Only the playback-context string freezes; current
    /// history, controls, dictionary and work state keep their existing admission.
    private static func frozenPlaybackContextCases() async -> [String] {
        let coordinator = VoiceConversationCoordinator.shared
        let capture = AgentCaptureController.shared
        let frontend = FrontendResponder.shared
        let audio = RealtimeAudioSession.shared
        let synth = AgentSpeechSynthesizer.shared
        let backing = RecordingSpeechBacking()
        synth.useTestingBacking(backing)
        var problems: [String] = []
        for mode in ["commit", "empty", "discard", "close"] {
            await capture.endSession(source: .done)
            coordinator.resetForTesting()
            await frontend.clearStagedTurn()
            AgentSession.shared.forgetAllConversations()
            await capture.beginSession(captureAudio: false)
            let source = Source()
            await frontend.setGenerationForTesting { _, messages, _ in source.stream(messages: messages) }
            let prior = "First fact. Second fact."
            audio.speak(OutputScheduler.tokenForTesting(), prior)
            let priorID = AgentSession.shared.recordAssistant(prior, source: .voice)
            guard let output = audio.retainedOutputID else {
                problems.append("playback context: actual prior output identity missing")
                break
            }
            VoicePlaybackDelivery.shared.bind(messageID: priorID, output: output,
                turn: RealtimeAgent.shared.currentGeneration)
            let initialContext = AgentSession.shared.latestVoiceDeliveryContext
            let words = "Please explain a haiku briefly"
            let beforeHistory = AgentSession.shared.messages.count
            let beforeSpeech = backing.spoken
            coordinator.prepareResponseIfUseful(words)
            guard await source.waitForCount(1, within: .milliseconds(500)), let first = source.last else {
                problems.append("\(mode): actual playback-context preparation missing")
                break
            }
            if !first.messages.contains(where: { $0.role == .system && $0.content.hasSuffix(initialContext) })
                || initialContext.isEmpty || !audio.isSpeaking
                || backing.spoken != beforeSpeech || AgentSession.shared.messages.count != beforeHistory {
                problems.append("\(mode): initial preparation changed speech/history or lost pending playback facts")
            }
            // Native callbacks are held by the existing recording backing. This
            // real receipt updates the bound AgentSession message via delivery.
            let token = synth.currentPlaybackToken
            synth.notifyTestingFirstAudio(token: token)
            synth.notifyTestingAudioFinished(token: token)
            let currentContext = AgentSession.shared.latestVoiceDeliveryContext
            if currentContext == initialContext || !currentContext.contains("First fact.")
                || AgentSession.shared.messages.first(where: { $0.id == priorID })?.speechDelivery?.completedText != "First fact." {
                problems.append("\(mode): actual completed-clause receipt did not change the bound playback context")
            }
            if mode != "commit" {
                if mode == "empty" { coordinator.prepareResponseIfUseful("") }
                if mode == "discard" { coordinator.discardInput() }
                if mode == "close" { coordinator.closeSession() }
                if !(await source.waitForCancellation(0)) {
                    problems.append("\(mode): withdrawn preparation producer did not cancel")
                }
                coordinator.prepareResponseIfUseful(words)
                if !(await source.waitForCount(2, within: .milliseconds(500))) {
                    problems.append("\(mode): next input did not start a fresh producer")
                }
                if source.last?.messages.first?.content.hasSuffix(currentContext) != true {
                    problems.append("\(mode): next input inherited the withdrawn playback snapshot")
                }
            }
            // Same committed interruption edge used by Capture.emitTurn. The
            // second clause is unconfirmed; no fixture pretends it was heard.
            RealtimeAgent.shared.userSpeechStarted()
            RealtimeAgent.shared.userSpeechEnded()
            source.finishFutureRequests()
            source.finishLast()
            let turn = await coordinator.handle(words)
            let expectedCalls = mode == "commit" ? 1 : 2
            let expected = "Prepared \(words)."
            if source.count != expectedCalls || turn.delegated || turn.reply != expected {
                problems.append("\(mode): actual committed barge-in did not adopt its exact playback-context preparation once")
            }
            if backing.spoken.last != expected {
                problems.append("\(mode): adopted answer did not reach actual speech consumer")
            }
            // Commit releases the snapshot immediately; a following request
            // uses the newly recorded answer's real pending-delivery context.
            if coordinator.stagingRequest().messages.first?.content.hasSuffix(
                AgentSession.shared.latestVoiceDeliveryContext) != true {
                problems.append("\(mode): committed playback snapshot leaked into the next request")
            }
        }
        await capture.endSession(source: .done)
        coordinator.resetForTesting()
        await frontend.clearStagedTurn()
        await frontend.setGenerationForTesting(nil)
        synth.restoreSystemBacking()
        return problems
    }

    /// Same raw ASR partial and commit, through the actual coordinator/provider/speech path.
    private static func dictionaryPreparationCases() async -> [String] {
        let coordinator = VoiceConversationCoordinator.shared
        let capture = AgentCaptureController.shared
        let frontend = FrontendResponder.shared
        let speech = RecordingSpeechBacking()
        AgentSpeechSynthesizer.shared.useTestingBacking(speech)
        defer {
            _ = VoiceConversationCoordinator.installCorrectorForTesting(nil)
            coordinator.answerSpeechObserverForTesting = nil
            AgentSpeechSynthesizer.shared.restoreSystemBacking()
        }
        var problems: [String] = []
        let raw = "Tell me about cloud code"
        for mode in ["corrected", "unchanged", "revised", "cancelled", "dictionary_changed"] {
            await capture.endSession(source: .done)
            coordinator.resetForTesting()
            await frontend.clearStagedTurn()
            AgentSession.shared.forgetAllConversations()
            await capture.beginSession(captureAudio: false)
            let original = DictionaryCorrector(entries: DictionaryStore.parse(
                mode == "unchanged" ? "# off: cloud code -> Claude Code" : "cloud code -> Claude Code"))
            guard VoiceConversationCoordinator.installCorrectorForTesting(original) else {
                problems.append("dictionary fixture isolation refused")
                break
            }
            let source = Source(finishImmediately: mode != "cancelled")
            await frontend.setGenerationForTesting { _, messages, _ in source.stream(messages: messages) }
            var observed: [String] = []
            coordinator.answerSpeechObserverForTesting = { observed.append($0) }
            speech.reset()
            let history = AgentSession.shared.messages.count
            func correctionRows() -> Int {
                AgentAuditLog.shared.entries.filter { $0.detail.hasPrefix("dictionary corrected:") }.count
            }
            let audit = correctionRows()
            coordinator.prepareResponseIfUseful(raw)
            let prepared = await source.waitForCount(1, within: .milliseconds(500))
            let preparedWords = source.last?.messages.last?.content.components(separatedBy: "Latest user speech:\n").last
            if !prepared || preparedWords != original.apply(to: raw).text {
                problems.append("\(mode): preparation provider did not receive the corrected authored partial")
            }
            if correctionRows() != audit || AgentSession.shared.messages.count != history || !speech.spoken.isEmpty {
                problems.append("\(mode): preparation audited, stored or spoke before commit")
            }
            var final = raw
            var commitCorrector = original
            if mode == "revised" { final += " again" }
            if mode == "dictionary_changed" {
                commitCorrector = DictionaryCorrector(entries: DictionaryStore.parse("cloud code -> Cloud Workshop"))
                if !VoiceConversationCoordinator.installCorrectorForTesting(commitCorrector) {
                    problems.append("updated dictionary fixture isolation refused")
                }
            }
            if mode == "cancelled" {
                coordinator.prepareResponseIfUseful("")
                if !(await source.waitForCancellation(0)) {
                    problems.append("cancelled dictionary preparation retained its producer")
                }
                source.finishFutureRequests()
            }
            let corrected = commitCorrector.apply(to: final)
            let expected = "Prepared \(corrected.text)."
            let turn = await coordinator.handle(final)
            let expectedCalls = ["corrected", "unchanged"].contains(mode) ? 1 : 2
            if source.count != expectedCalls {
                problems.append("\(mode): commit generation count \(source.count), expected \(expectedCalls)")
            }
            if turn.delegated || turn.reply != expected
                || observed.last?.trimmingCharacters(in: .whitespacesAndNewlines) != expected
                || speech.spoken.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines) != expected {
                problems.append("\(mode): actual committed answer/speech did not retain the current corrected request")
            }
            let expectedCorrections = corrected.applied.isEmpty ? 0 : 1
            if correctionRows() - audit != expectedCorrections {
                problems.append("\(mode): dictionary correction audit was not commit-only")
            }
        }
        await capture.endSession(source: .done)
        coordinator.resetForTesting()
        await frontend.clearStagedTurn()
        await frontend.setGenerationForTesting(nil)
        return problems
    }

    final class Source: @unchecked Sendable {
        struct Request {
            let continuation: AsyncThrowingStream<String, Error>.Continuation
            let correlation: UsageCorrelation?
            let messages: [LLMChatMessage]
        }
        private let lock = NSLock()
        private var requests: [Request] = []
        private var cancelled: Set<Int> = []
        private var finishImmediately: Bool
        init(finishImmediately: Bool = false) { self.finishImmediately = finishImmediately }
        func finishFutureRequests() { lock.withLock { finishImmediately = true } }
        var count: Int { lock.withLock { requests.count } }
        var last: Request? { lock.withLock { requests.last } }

        func stream(messages: [LLMChatMessage]) -> AsyncThrowingStream<String, Error> {
            let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
            let words = messages.last?.content.components(separatedBy: "Latest user speech:\n").last ?? "missing"
            let index = lock.withLock {
                let index = requests.count
                // A visible request must already have its authored first chunk.
                // Otherwise waitForCount/finishLast can finish before this yield.
                // Install termination only after unlocking, avoiding reentrancy.
                continuation.yield("<answer/> Prepared \(words).")
                if finishImmediately { continuation.finish() }
                requests.append(Request(continuation: continuation, correlation: ModelPassRecorder.correlation, messages: messages))
                return index
            }
            continuation.onTermination = { [weak self] reason in
                if case .cancelled = reason { _ = self?.lock.withLock { self?.cancelled.insert(index) } }
            }
            return stream
        }
        func finishLast() { last?.continuation.finish() }
        func waitForCount(_ desired: Int, within duration: Duration) async -> Bool {
            let until = ContinuousClock.now.advanced(by: duration)
            while count < desired, ContinuousClock.now < until {
                try? await Task.sleep(for: .milliseconds(2))
            }
            return count >= desired
        }
        func waitForCancellation(_ index: Int) async -> Bool {
            let until = ContinuousClock.now.advanced(by: .milliseconds(500))
            while ContinuousClock.now < until {
                if lock.withLock({ cancelled.contains(index) }) { return true }
                try? await Task.sleep(for: .milliseconds(2))
            }
            return false
        }
    }
}

/// Diagnostic partials through Coordinator -> the actual split collector/validator ->
/// committed stream -> speech. Only the Apple route and answer generators are scripted.
@MainActor
enum VoicePartialRouteSelfTest {
    static func run() async -> [String] {
        var wrong: [String] = []
        let coordinator = VoiceConversationCoordinator.shared
        let frontend = FrontendResponder.shared
        let capture = AgentCaptureController.shared
        let speech = RecordingSpeechBacking()
        AgentSpeechSynthesizer.shared.useTestingBacking(speech)
        let words = "Explain a haiku briefly"
        for mode in ["matched", "canonical", "final-revised", "partial-revised", "empty", "context", "pending"] {
            await capture.endSession(source: .done)
            coordinator.resetForTesting()
            await frontend.clearStagedTurn()
            AgentSession.shared.forgetAllConversations()
            await capture.beginSession(captureAudio: false)
            speech.reset()
            let source = Source(held: mode == "pending")
            await frontend.setGenerationForTesting { _, messages, _ in source.answer(messages) }
            guard await frontend.setPartialRouteForTesting({ messages in try await source.route(messages) }) else {
                wrong.append("scripted split boundary was refused")
                break
            }
            let history = AgentSession.shared.messages.count
            let tasks = AgentTaskManager.shared.tasks.count
            coordinator.prepareResponseIfUseful(words)
            if !(await source.wait(routes: 1)) { wrong.append("\(mode): stable partial did not enter real split collector") }
            // A bounded test settle lets the original producer expose its premature
            // answer. This is test synchronization, never a production debounce.
            try? await Task.sleep(for: .milliseconds(30))
            if source.answers != 0 { wrong.append("\(mode): answer generation started before commit") }
            if !speech.spoken.isEmpty || AgentSession.shared.messages.count != history
                || AgentTaskManager.shared.tasks.count != tasks {
                wrong.append("\(mode): partial produced speech/history/tool work")
            }
            var final = words
            var expectedRoutes = 1
            if mode == "canonical" { final = " Explain a haiku briefly! " }
            if mode == "final-revised" { final += " in French"; expectedRoutes = 2 }
            if mode == "partial-revised" {
                final += " in French"
                coordinator.prepareResponseIfUseful(final)
                expectedRoutes = 2
                if !(await source.wait(routes: 2)) { wrong.append("revised partial was blocked by the canceled producer") }
                try? await Task.sleep(for: .milliseconds(30))
                if source.answers != 0 { wrong.append("revised partial started answer before commit") }
            }
            if mode == "empty" { coordinator.prepareResponseIfUseful(""); expectedRoutes = 2 }
            if mode == "context" {
                AgentSession.shared.recordAssistant("A previous unrelated fact.", source: .voice)
                expectedRoutes = 2
            }
            let commit = Task { await coordinator.handle(final) }
            if mode == "pending" {
                try? await Task.sleep(for: .milliseconds(30))
                if source.routes != 1 || source.answers != 0 { wrong.append("pending commit rerouted or answered before route completion") }
                source.release()
            }
            let turn = await commit.value
            let expectedWords = mode == "canonical" ? words : final.trimmingCharacters(in: .whitespacesAndNewlines)
            let expected = "Prepared \(expectedWords)."
            if source.routes != expectedRoutes || source.answers != 1 {
                wrong.append("\(mode): expected \(expectedRoutes) routes/one committed answer, got \(source.routes)/\(source.answers)")
            }
            if turn.delegated || turn.reply != expected
                || speech.spoken.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines) != expected {
                wrong.append("\(mode): committed answer did not reach real reply/speech consumer")
            }
            SelfTest.diagnostic("VOICE_PARTIAL_ROUTE_CASE \(mode) routes=\(source.routes) answers=\(source.answers)")
        }
        await capture.endSession(source: .done)
        coordinator.resetForTesting()
        await frontend.clearStagedTurn()
        await frontend.setPartialRouteForTesting(nil)
        await frontend.setGenerationForTesting(nil)
        AgentSpeechSynthesizer.shared.restoreSystemBacking()
        wrong += await frontendCases()
        return wrong
    }

    private static func frontendCases() async -> [String] {
        var wrong: [String] = []
        let system = VoiceConversationCoordinator.systemPrompt
        let words = "Explain a haiku briefly"
        let prefix = "Work status:\nNo tasks.\n\nLatest user speech:\n"
        for mode in ["identity", "courtesy", "sealed", "control", "invalid"] {
            let frontend = FrontendResponder()
            let source = Source(intent: mode == "control" ? .notAddressedToMe : mode == "invalid" ? .startExternalTask : .answerQuestion)
            await frontend.setGenerationForTesting { _, messages, _ in source.answer(messages) }
            _ = await frontend.setPartialRouteForTesting { messages in try await source.route(messages) }
            let ids = UsageCorrelation(turnID: UUID(), conversationID: UUID())
            let messages: [LLMChatMessage] = [.init(role: .user, content: prefix + words)]
            await ModelPassRecorder.$correlation.withValue(ids) {
                await frontend.speculate(system: system, messages: messages, maxTokens: 256, revision: 1)
            }
            _ = await source.wait(routes: 1)
            try? await Task.sleep(for: .milliseconds(30))
            if source.answers != 0 { wrong.append("\(mode): uncommitted frontend sampled answer") }
            await frontend.cancelSpeculation(through: 0) // stale cancellation preserves the slot
            let final = mode == "courtesy" ? [.init(role: LLMChatMessage.Role.user, content: prefix + words + " please")] : messages
            let commitIDs = mode == "identity" ? UsageCorrelation(turnID: UUID(), conversationID: ids.conversationID) : ids
            let stream = await ModelPassRecorder.$correlation.withValue(commitIDs) {
                await frontend.stream(system: system, messages: final, maxTokens: 256, commitRevision: 2)
            }
            do {
                var reply = ""
                for try await piece in stream { reply += piece }
                if mode == "invalid" { wrong.append("invalid route escaped the real validator") }
                else if mode == "control" {
                    if source.answers != 0 || !reply.contains("not_addressed") { wrong.append("complete control started an answer or lost its payload") }
                } else if source.answers != 1 { wrong.append("\(mode): commit sampled more than once") }
            } catch {
                if mode != "invalid" { wrong.append("\(mode): committed stream failed: \(error.localizedDescription)") }
            }
            let expectedRoutes = ["identity", "courtesy"].contains(mode) ? 2 : 1
            if source.routes != expectedRoutes { wrong.append("\(mode): exact request/identity admission used \(source.routes) routes, expected \(expectedRoutes)") }
            if mode == "sealed" {
                await frontend.speculate(system: system, messages: messages, maxTokens: 256, revision: 1)
                try? await Task.sleep(for: .milliseconds(20))
                if source.routes != 1 { wrong.append("sealed revision restarted routing") }
            }
            await frontend.clearStagedTurn()
        }
        return wrong
    }

    final class Source: @unchecked Sendable {
        private let lock = NSLock()
        private var routeCount = 0
        private var answerCount = 0
        private var held: Bool
        private let intent: LocalVoiceRoute.Intent
        init(held: Bool = false, intent: LocalVoiceRoute.Intent = .answerQuestion) { self.held = held; self.intent = intent }
        var routes: Int { lock.withLock { routeCount } }
        var answers: Int { lock.withLock { answerCount } }
        func release() { lock.withLock { held = false } }
        func route(_ messages: [LLMChatMessage]) async throws -> LocalVoiceRoute {
            lock.withLock { routeCount += 1 }
            while lock.withLock({ held }) { try await Task.sleep(for: .milliseconds(2)) }
            try Task.checkCancellation()
            return LocalVoiceRoute(intent: intent, taskNumber: nil, objective: "", acknowledgement: "", approvalDecision: "", approvalChange: "")
        }
        func answer(_ messages: [LLMChatMessage]) -> AsyncThrowingStream<String, Error> {
            lock.withLock { answerCount += 1 }
            let words = messages.last?.content.components(separatedBy: "Latest user speech:\n").last ?? "missing"
            return AsyncThrowingStream { c in c.yield("Prepared \(words)."); c.finish() }
        }
        func wait(routes count: Int) async -> Bool {
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
            while routes < count && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(2)) }
            return routes >= count
        }
    }
}

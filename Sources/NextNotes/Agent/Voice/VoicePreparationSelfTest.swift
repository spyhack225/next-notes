import Foundation
import NextNotesDictionary

/// PL-12: scripted stable partials through the actual coordinator and speculative
/// frontend slot. Only the external generator is replaced; no microphone/model required.
/// Run with --selftest-voice-latency --voice-latency-partials.
@MainActor
enum VoicePreparationSelfTest {
    static func run() async -> [String] {
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

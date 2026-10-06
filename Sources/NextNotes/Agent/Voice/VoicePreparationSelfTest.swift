import Foundation

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

    final class Source: @unchecked Sendable {
        struct Request {
            let continuation: AsyncThrowingStream<String, Error>.Continuation
            let correlation: UsageCorrelation?
            let messages: [LLMChatMessage]
        }
        private let lock = NSLock()
        private var requests: [Request] = []
        private var cancelled: Set<Int> = []
        var count: Int { lock.withLock { requests.count } }
        var last: Request? { lock.withLock { requests.last } }

        func stream(messages: [LLMChatMessage]) -> AsyncThrowingStream<String, Error> {
            let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
            let index = lock.withLock {
                let index = requests.count
                requests.append(Request(continuation: continuation, correlation: ModelPassRecorder.correlation, messages: messages))
                return index
            }
            continuation.onTermination = { [weak self] reason in
                if case .cancelled = reason { _ = self?.lock.withLock { self?.cancelled.insert(index) } }
            }
            let words = messages.last?.content.components(separatedBy: "Latest user speech:\n").last ?? "missing"
            continuation.yield("<answer/> Prepared \(words).")
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

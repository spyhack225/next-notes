import Foundation

/// Script only external route/native/Apple generation. Admission, validator,
/// exact partial reuse, committed reply and single speech consumer remain real.
@MainActor
enum VoiceResidentAnswerSelfTest {
    static func run() async -> [String] {
        let frontend = FrontendResponder.shared
        let coordinator = VoiceConversationCoordinator.shared
        let capture = AgentCaptureController.shared
        let backing = RecordingSpeechBacking()
        AgentSpeechSynthesizer.shared.useTestingBacking(backing)
        var wrong = VoiceDiagnosticSpeech.contractProblems()
        AgentSpeechSynthesizer.shared.useTestingBacking(backing)
        let spec = ModelSpec(displayName: "Missing resident fixture", fileName: "missing-voice-resident-\(UUID()).gguf",
            url: URL(fileURLWithPath: "/absent"), expectedBytes: 1, expectedSHA256: nil)
        let runtime = NotesModelRuntime(spec: spec, gpuLayers: 0)
        // Real cold runtime entry: a resident request must reject before attempting
        // a load. The deliberately absent file keeps the RED safe and bounded.
        for cap in [8, Int.max] {
            let response = await runtime.streamInteractiveConversation(system: "Answer briefly.",
                messages: [.init(role: .user, content: "Hello")], maxTokens: cap, residentOnly: true)
            do {
                for try await _ in response {}
                wrong.append("cold runtime did not refuse resident-only entry")
            } catch LlamaError.notLoaded {} catch {
                wrong.append("cold runtime reached load instead of resident refusal: \(type(of: error))")
            }
        }
        if await runtime.isLoaded { wrong.append("cold refusal loaded weights") }
        let provider = LlamaLLMProvider(modelName: spec.displayName, runtime: runtime)
        if !(await frontend.installVoiceLatencyAnswerProvider(provider)) {
            wrong.append("isolated answering provider was refused")
        }
        for mode in ["cold", "evicted", "resident", "revised", "control", "invalid", "fault", "cancel", "late-notLoaded"] {
            await capture.endSession(source: .done)
            coordinator.resetForTesting()
            await frontend.clearStagedTurn()
            AgentSession.shared.forgetAllConversations()
            await capture.beginSession(captureAudio: false)
            backing.reset()
            let source = Source(mode: mode)
            await frontend.setGenerationForTesting { _, _, _ in source.apple() }
            _ = await frontend.setPartialRouteForTesting { _ in source.route() }
            _ = await frontend.setResidentAnswerForTesting { try await source.native() }
            let words = "Explain a haiku briefly"
            coordinator.prepareResponseIfUseful(words)
            let deadline = ContinuousClock.now.advanced(by: .seconds(1))
            while source.routes == 0, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(2)) }
            try? await Task.sleep(for: .milliseconds(20))
            if source.nativeCalls != 0 || source.appleCalls != 0 || !backing.spoken.isEmpty {
                wrong.append("\(mode): partial answered or spoke before complete commit")
            }
            let final = mode == "revised" ? words + " in French" : words
            let turn = await coordinator.handle(final)
            let refusal = ["control", "invalid"].contains(mode)
            let failed = ["fault", "cancel", "late-notLoaded"].contains(mode)
            let fallback = ["cold", "evicted"].contains(mode)
            let expectedNative = refusal ? 0 : 1
            let expectedApple = fallback ? 1 : 0
            if source.nativeCalls != expectedNative || source.appleCalls != expectedApple {
                wrong.append("\(mode): native/Apple calls \(source.nativeCalls)/\(source.appleCalls), expected \(expectedNative)/\(expectedApple)")
            }
            if !refusal && !failed {
                let expected = fallback ? "Apple fixture answer." : "Resident fixture answer."
                if turn.reply != expected || backing.spoken.joined(separator: " ") != expected || turn.delegated {
                    wrong.append("\(mode): selected answer did not reach committed reply and speech exactly once")
                }
                let actual = frontend.admittedVoiceLatencyAnswerProvider()
                if actual.map({ ModelPassRecorder.usageProvider(for: $0.id).rawValue }) != (fallback ? "appleFM" : "llama") {
                    wrong.append("\(mode): actual committed answer identity was not retained for the real tracker")
                }
            }
            if (refusal || failed) && backing.spoken.contains("Apple fixture answer.") {
                wrong.append("\(mode): invalid route/native failure silently changed answer model")
            }
            SelfTest.diagnostic("VOICE_RESIDENT_ANSWER_CASE \(mode) routes=\(source.routes) native=\(source.nativeCalls) apple=\(source.appleCalls)")
        }
        await capture.endSession(source: .done)
        coordinator.resetForTesting()
        await frontend.clearStagedTurn()
        _ = await frontend.setResidentAnswerForTesting(nil)
        _ = await frontend.setPartialRouteForTesting(nil)
        await frontend.setGenerationForTesting(nil)
        AgentSpeechSynthesizer.shared.restoreSystemBacking()
        return wrong
    }

    final class Source: @unchecked Sendable {
        let mode: String
        private let lock = NSLock()
        private var counts = [0, 0, 0]
        init(mode: String) { self.mode = mode }
        var routes: Int { lock.withLock { counts[0] } }
        var nativeCalls: Int { lock.withLock { counts[1] } }
        var appleCalls: Int { lock.withLock { counts[2] } }
        func route() -> LocalVoiceRoute {
            lock.withLock { counts[0] += 1 }
            return LocalVoiceRoute(intent: mode == "control" ? .notAddressedToMe : mode == "invalid" ? .startExternalTask : .answerQuestion,
                taskNumber: nil, objective: "", acknowledgement: "", approvalDecision: "", approvalChange: "")
        }
        func native() async throws -> AsyncThrowingStream<String, Error> {
            lock.withLock { counts[1] += 1 }
            if mode == "cold" { throw LlamaError.notLoaded }
            if mode == "evicted" { await Task.yield(); throw LlamaError.notLoaded }
            if mode == "fault" { throw LlamaError.decodeFailed }
            if mode == "cancel" { throw CancellationError() }
            return AsyncThrowingStream {
                $0.yield("Resident fixture answer.")
                if mode == "late-notLoaded" { $0.finish(throwing: LlamaError.notLoaded) }
                else { $0.finish() }
            }
        }
        func apple() -> AsyncThrowingStream<String, Error> {
            lock.withLock { counts[2] += 1 }
            return AsyncThrowingStream { $0.yield("Apple fixture answer."); $0.finish() }
        }
    }
}

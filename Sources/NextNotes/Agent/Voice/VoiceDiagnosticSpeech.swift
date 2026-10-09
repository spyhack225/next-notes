import Foundation

/// SelfTest-only Pocket transport on the existing synthesizer. Native failures
/// stay silent and fail evidence instead of choosing the Apple voice.
@MainActor
enum VoiceDiagnosticSpeech {
    static func install(_ backing: (any AgentSpeechBacking)?, fallbackSpy: any AgentSpeechBacking) {
        AgentSpeechSynthesizer.shared.useTestingBacking(backing ?? Silence(), fallback: Silence())
    }

    static func contractProblems() -> [String] {
        var wrong: [String] = []
        for ready in [false, true] {
            let failing = ready ? FailingReply() : nil
            let apple = RecordingSpeechBacking()
            install(failing, fallbackSpy: apple)
            let synth = AgentSpeechSynthesizer.shared
            synth.speak("Speech fixture.")
            let token = synth.currentPlaybackToken
            failing?.onFailure?("", 1, token)
            if !apple.spoken.isEmpty { wrong.append("diagnostic \(ready ? "failed" : "unready") Pocket reached Apple fallback backing") }
            synth.restoreSystemBacking()
            SelfTest.diagnostic("VOICE_DIAGNOSTIC_APPLE_CALLS=\(apple.spoken.count) ready=\(ready)")
        }
        return wrong
    }

    static func preparePocket() async -> Proof? {
        guard SelfTest.isRunning,
              ["--selftest-voice-latency", "--selftest-voice-pipeline"].contains(SelfTest.requested ?? "") else { return nil }
        await PocketAgentVoice.shared.prepare()
        guard PocketAgentVoice.shared.isReady else { return nil }
        let proof = Proof()
        let synth = AgentSpeechSynthesizer.shared
        synth.useTestingBacking(PocketSpeechBacking(), fallback: proof.silence)
        return proof
    }

    @MainActor final class Proof {
        private let appleCallsAtStart = AgentSpeechSynthesizer.appleSynthesisCallsForTesting
        fileprivate let silence = Silence()
        private var finished = false
        func finish() -> [String] {
            guard !finished else { return [] }
            finished = true
            let synth = AgentSpeechSynthesizer.shared
            synth.restoreSystemBacking()
            let appleCalls = AgentSpeechSynthesizer.appleSynthesisCallsForTesting - appleCallsAtStart
            SelfTest.diagnostic("VOICE_DIAGNOSTIC_APPLE_CALLS=\(appleCalls) silent_failure_clauses=\(silence.dropped)")
            var wrong: [String] = []
            if appleCalls != 0 { wrong.append("diagnostic reached Apple playback") }
            if silence.dropped != 0 { wrong.append("Pocket failed; \(silence.dropped) clauses stayed silent") }
            return wrong
        }
    }

    fileprivate final class Silence: AgentSpeechBacking {
        var isSpeaking: Bool { false }
        private(set) var dropped = 0
        func speak(_ text: String, volume: Float, token: UInt64) { dropped += 1 }
        func pauseForListening() {}
        func resumeAfterListening() {}
        func stop() {}
    }

    private final class FailingReply: AgentReplySpeechBacking {
        var isSpeaking = false
        var onUtteranceStarted: ((UInt64) -> Void)?
        var onUtteranceFinished: ((UInt64) -> Void)?
        var onFailure: ((String, Float, UInt64) -> Void)?
        func beginReply(volume: Float) {}
        func enqueue(_ text: String, token: UInt64) { isSpeaking = true }
        func finishReply() {}
        func speak(_ text: String, volume: Float, token: UInt64) { isSpeaking = true }
        func pauseForListening() {}
        func resumeAfterListening() {}
        func stop() { isSpeaking = false }
    }
}

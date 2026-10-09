import Foundation

/// Harness-only playback. A Pocket failure must fail the audio proof and stay
/// silent rather than synthesize the diagnostic with an unrequested voice.
@MainActor
enum VoiceDiagnosticSpeech {
    // RED scaffold exercises the real synthesizer's failure consumer with a
    // recorder standing in for its Apple fallback; it renders no Apple audio.
    static func install(_ backing: (any AgentSpeechBacking)?, fallbackSpy: any AgentSpeechBacking) {
        AgentSpeechSynthesizer.shared.useTestingBacking(backing ?? fallbackSpy, fallback: fallbackSpy)
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

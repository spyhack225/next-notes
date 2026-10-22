import Foundation

/// SelfTest-only permitted Pocket transport. The no-Apple owner settles native
/// failures as written text; the actual installed silent route is observed.
@MainActor
enum VoiceDiagnosticSpeech {
    static func install(_ backing: (any AgentSpeechBacking)?, fallbackSpy: any AgentSpeechBacking) {
        AgentSpeechSynthesizer.shared.useTestingBacking(backing ?? fallbackSpy)
    }

    static func contractProblems(prohibitedStandIn: Bool = false) -> [String] {
        var wrong: [String] = []
        let synth = AgentSpeechSynthesizer.shared
        for ready in [false, true] {
            let failing = ready ? FailingReply() : nil
            let silence = Silence()
            // This inert PCM sink rejects text; it never performs synthesis.
            let prohibited = PreparedPCMSpeechBacking()
            let before = synth.forbiddenSpeechEntriesForTesting
            let requests = synth.speechSynthesisCallsForTesting
            install(failing, fallbackSpy: prohibitedStandIn ? prohibited : silence)
            synth.speak("Speech fixture.")
            failing?.onFailure?("", 1, synth.currentPlaybackToken)
            let drops = silence.dropped
            let entries = synth.forbiddenSpeechEntriesForTesting - before + prohibited.forbiddenTextCallsForTesting
            if entries != 0 { wrong.append("diagnostic reached prohibited installed text entry") }
            if !prohibitedStandIn && drops != (ready ? 0 : 1) { wrong.append("diagnostic installed silent route was not observed") }
            if synth.speechSynthesisCallsForTesting != requests { wrong.append("scripted diagnostic entered native synthesis") }
            if synth.isSpeaking { wrong.append("failed diagnostic retained speaking state") }
            synth.restoreSystemBacking()
            SelfTest.diagnostic("VOICE_DIAGNOSTIC forbidden_entries=\(entries) silent_drops=\(drops) ready=\(ready) stand_in=\(prohibitedStandIn)")
        }
        return wrong
    }

    static func preparePocket() async -> Proof? {
        guard SelfTest.isRunning,
              ["--selftest-voice-latency", "--selftest-voice-pipeline"].contains(SelfTest.requested ?? "") else { return nil }
        await PocketAgentVoice.shared.prepare()
        guard PocketAgentVoice.shared.isReady else { return nil }
        let proof = Proof()
        AgentSpeechSynthesizer.shared.useTestingBacking(PocketSpeechBacking())
        return proof
    }

    @MainActor final class Proof {
        private let forbiddenAtStart = AgentSpeechSynthesizer.shared.forbiddenSpeechEntriesForTesting
        private let requestsAtStart = AgentSpeechSynthesizer.shared.speechSynthesisCallsForTesting
        private var finished = false
        func finish() -> [String] {
            guard !finished else { return [] }
            finished = true
            let synth = AgentSpeechSynthesizer.shared
            let failed = synth.outputAvailability == .failed
            synth.restoreSystemBacking()
            let entries = synth.forbiddenSpeechEntriesForTesting - forbiddenAtStart
            let requests = synth.speechSynthesisCallsForTesting - requestsAtStart
            SelfTest.diagnostic("VOICE_DIAGNOSTIC forbidden_entries=\(entries) allowed_requests=\(requests) failed=\(failed)")
            var wrong: [String] = []
            if entries != 0 { wrong.append("diagnostic reached prohibited text entry") }
            if failed { wrong.append("Pocket failed; answer stayed written") }
            if requests == 0 { wrong.append("Pocket diagnostic recorded no permitted requests") }
            return wrong
        }
    }

    private final class Silence: AgentSpeechBacking {
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

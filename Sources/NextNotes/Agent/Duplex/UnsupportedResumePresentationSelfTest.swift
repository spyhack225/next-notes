import Foundation

/// Actual capture → audio → VoiceSession → Island, with a receipt-incapable
/// scripted player. Native Pocket/Kokoro capability is checked before substitution.
@MainActor enum UnsupportedResumePresentationSelfTest {
    static func run() async -> [String] {
        let synth = AgentSpeechSynthesizer.shared
        let capture = AgentCaptureController.shared
        let audio = RealtimeAudioSession.shared
        let shadow = VoiceSession.shared
        let island = IslandState.shared
        let priorTurn = capture.turnHandlerForTesting
        var failures: [String] = []
        var turns = 0
        capture.turnHandlerForTesting = { _ in turns += 1 }
        defer {
            synth.stop(); synth.restoreSystemBacking(); synth.clearVoiceReadinessForTesting()
            capture.turnHandlerForTesting = priorTurn
        }
        for engine in ["pocket", "kokoro"] {
            synth.restoreSystemBacking()
            synth.engineOverrideForTesting = engine
            synth.setVoiceReadinessForTesting(engine: engine, ready: true)
            synth.prepareForStream()
            if synth.supportsQualifiedResumeReceipt { failures.append("R1: native \(engine) capability unexpectedly supported") }
            let player = RecordingSpeechBacking()
            synth.useTestingBacking(player)
            await capture.beginSession(captureAudio: false)
            capture.simulateCumulativeSpeech("Um")
            let handle = OutputScheduler.tokenForTesting()
            if !audio.beginSpokenReply(handle) { failures.append("R1: output admission absent") }
            audio.appendSpokenReply(handle, "The rendered answer stays with the same output while we listen.")
            audio.finalizeSpokenReply(handle)
            let token = synth.currentPlaybackToken
            synth.notifyTestingFirstAudio(token: token)
            if shadow.state.output?.status != .playing { failures.append("R1: actual rendered control absent") }
            capture.simulateCumulativeSpeech("Please stop speaking")
            if !synth.isPausedForListening { failures.append("R1: actual provisional pause absent") }
            capture.simulateCumulativeSpeech("mm hmm"); capture.simulateSilence()
            let discarded = await capture.considerEndpoint()
            if !discarded || player.resumeCount != 1 || player.paused || !player.isSpeaking {
                failures.append("R1: actual backchannel did not physically resume retained output")
            }
            if shadow.state.output?.status != .awaitingResume || !synth.voiceLifecycleSnapshot.resumePending {
                failures.append("R1: unsupported route fabricated resume proof")
            }
            if IslandOwnership.sessionOwnsIsland || island.voiceProjection != nil {
                failures.append("R1: \(engine) unsupported shadow escaped into actual Island consumer")
            }
            let writes = IslandOwnership.rejected.values.reduce(0, +)
            island.showAgentListening(transcript: "Still listening", level: 0)
            if IslandOwnership.rejected.values.reduce(0, +) != writes {
                failures.append("R1: unsupported shadow suppressed legacy presentation")
            }
            audio.noteUserSpeech()
            await capture.endSession(source: .done)
            if island.voiceProjection != nil { failures.append("R1: unsupported closed projection leaked") }
        }
        if turns != 0 { failures.append("R1: discarded backchannel started work") }
        return failures
    }
}

// Simulated receipt-capable route. Positive resume cases do not establish
// Pocket/Kokoro support; their current capability is explicitly false.
import Foundation

/// Proposed original/fixed simulated PCM regression. Uses explicit deterministic played events; no simulated playback claim.
/// This intentionally fails the current missing post-resume contract; it does not
/// equate a later buffer callback's arrival with samples played after the pause.
@MainActor
enum VoicePlaybackResumeReceiptSelfTest {
    private static func reached(_ predicate: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }

    static func run() async -> String {
        guard SelfTest.isRunning else { return "VOICE_PLAYBACK_RESUME_RECEIPT_FAILED: harness required" }
        let capture = AgentCaptureController.shared
        let audio = RealtimeAudioSession.shared
        let speech = AgentSpeechSynthesizer.shared
        let shadow = VoiceSession.shared
        guard !capture.isSessionActive, !speech.isSpeaking,
              !CommandLine.arguments.contains("--voice-pocket-source") else {
            return "VOICE_PLAYBACK_RESUME_RECEIPT_FAILED: isolated simulated PCM playback required"
        }
        let before = SelfTestStoreGuard.take()
        let oldEngine = speech.engineOverrideForTesting
        let oldVolume = speech.utteranceVolume
        let oldTurnHandler = capture.turnHandlerForTesting
        let oldPlayback = speech.onPlaybackEvent
        let oldSettled = speech.onVoiceLifecycleSettled
        let oldResumeObserver = audio.voiceResumeObserverForTesting
        var checks = 0
        var failures: [String] = []
        var unexpectedTurns = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if !value { failures.append(label) }
        }
        defer {
            speech.restoreSystemBacking()
            speech.engineOverrideForTesting = oldEngine
            speech.utteranceVolume = oldVolume
            capture.turnHandlerForTesting = oldTurnHandler
            speech.onPlaybackEvent = oldPlayback
            speech.onVoiceLifecycleSettled = oldSettled
            audio.voiceResumeObserverForTesting = oldResumeObserver
        }
        let pcm = PCMReceiptSpeechBacking()
        speech.useTestingBacking(pcm)
        capture.turnHandlerForTesting = { _ in unexpectedTurns += 1 }
        let clause = "This single simulated PCM playback clause remains deliberately long enough to "
            + "pause its simulated playback, classify a harmless backchannel through the "
            + "actual capture endpoint, and resume the exact same output without starting "
            + "another model, tool, voice preference, or audio capture session."

        for holdOldReceipt in [false, true] {
            shadow.resetDiagnosticsForTesting()
            await capture.beginSession(captureAudio: false)
            guard let captureID = capture.sessionID else {
                failures.append("INPUT: capture session absent")
                await capture.endSession(source: .done)
                continue
            }
            capture.simulateCumulativeSpeech("Um")
            let prior = speech.onPlaybackEvent
            var simulatedOnsets = 0
            var deliveredOnsets = 0
            var retained: AgentSpeechSynthesizer.PlaybackEvent?
            var callbackToken: UInt64?
            var observedResumes = 0
            var resumeShadowStatus = "unobserved"
            var resumeLegacyStatus = "unobserved"
            var afterOldIsland = "unobserved"
            speech.onPlaybackEvent = { event in
                if case .startAcknowledged = event {
                    simulatedOnsets += 1
                    callbackToken = speech.currentPlaybackToken
                    if holdOldReceipt && retained == nil {
                        retained = event // exact actual event; never reconstruct its text
                        return
                    }
                    deliveredOnsets += 1
                }
                prior?(event)
            }
            audio.beginSpokenReply(OutputScheduler.tokenForTesting())
            speech.utteranceVolume = 0
            audio.appendSpokenReply(OutputScheduler.currentTokenForTesting(), clause)
            audio.finalizeSpokenReply(OutputScheduler.currentTokenForTesting())
            let output = shadow.state.output?.id
            let token = speech.currentPlaybackToken
            let generation = speech.outputGeneration
            check(output != nil && shadow.state.output?.status == .queued && simulatedOnsets == 0,
                  "CONTROL: enqueue did not precede simulated onset")
            pcm.deliverPlayed(pcm.packet(token: token))
            guard await reached({ simulatedOnsets > 0 || !speech.isSpeaking }), simulatedOnsets == 1 else {
                failures.append("INPUT: one simulated PCM positive-buffer onset required")
                audio.noteUserSpeech()
                await capture.endSession(source: .done)
                speech.onPlaybackEvent = prior
                continue
            }
            check(callbackToken == token && speech.outputGeneration == generation,
                  "CONTROL: simulated onset did not retain current token/generation")
            check(holdOldReceipt ? (retained != nil && deliveredOnsets == 0)
                                 : (retained == nil && deliveredOnsets == 1),
                  "CONTROL: real listener barrier failed")
            capture.simulateCumulativeSpeech("Please stop speaking")
            check(speech.isPausedForListening && shadow.state.output?.status == .paused
                  && shadow.state.island == .listening,
                  "CONTROL: actual capture partial did not confirm reversible pause")
            capture.simulateCumulativeSpeech("mm hmm")
            capture.simulateSilence()
            audio.voiceResumeObserverForTesting = { observedCaptureID, observedGeneration in
                guard observedCaptureID == captureID, observedGeneration == generation else {
                    failures.append("INPUT: resume observer received an unrelated owner")
                    return
                }
                observedResumes += 1
                // Called synchronously after the real backing resume, before the
                // producer's first await. No newly delivered MainActor native
                // receipt can race these verdicts. This does not pause playback.
                resumeShadowStatus = String(describing: shadow.state.output?.status)
                resumeLegacyStatus = String(describing: audio.voiceShadowOutputSnapshot?.status)
                check(simulatedOnsets == 1 && deliveredOnsets == (holdOldReceipt ? 0 : 1),
                      "CONTROL: unexpected new onset before synchronous resume verdict")
                check(shadow.state.output?.status != .playing,
                      "TARGET R01: inputDiscarded promoted historical evidence before a fresh resume receipt")
                check(audio.voiceShadowOutputSnapshot?.status != .playing,
                      "TARGET R02: actual owner snapshot promoted historical heard/rendered after resume")
                if let event = retained {
                    // This exact real event reached the listener before pause.
                    // Deliver it AFTER actual resume, within the same actor turn.
                    prior?(event)
                    deliveredOnsets += 1
                    retained = nil
                    check(shadow.state.output?.status != .playing && shadow.state.island != .speaking,
                          "TARGET R03: old simulated onset crossed resume and manufactured speaking")
                } else {
                    check(shadow.state.output?.heard == true,
                          "CONTROL: resume discarded historical played evidence")
                }
                afterOldIsland = String(describing: shadow.state.island)
            }
            let discarded = await capture.considerEndpoint()
            audio.voiceResumeObserverForTesting = oldResumeObserver
            check(discarded, "CONTROL: actual backchannel endpoint did not settle")
            check(observedResumes == 1, "CONTROL: actual post-resume observer did not run exactly once")
            check(!speech.didStop && !speech.isPausedForListening
                  && speech.currentPlaybackToken == token && speech.outputGeneration == generation
                  && shadow.state.output?.id == output,
                  "CONTROL: actual discard did not resume the same live token/output")
            check(speech.isSpeaking && speech.currentPlaybackToken == token
                  && shadow.state.output?.id == output,
                  "CONTROL: clause naturally drained before bounded resume verdict")
            SelfTest.diagnostic("VOICE_PLAYBACK_RESUME_RECEIPT_PCM_FAKE: heldOld=\(holdOldReceipt) simulatedOnsets=\(simulatedOnsets) deliveredOnsets=\(deliveredOnsets) token=\(token) generation=\(generation) discarded=\(discarded) observedResumes=\(observedResumes) resumeShadowStatus=\(resumeShadowStatus) resumeLegacyStatus=\(resumeLegacyStatus) afterOldIsland=\(afterOldIsland) shadowStatus=\(String(describing: shadow.state.output?.status)) shadowIsland=\(shadow.state.island) legacyStatus=\(String(describing: audio.voiceShadowOutputSnapshot?.status)) divergences=\(shadow.divergenceCount)")
            audio.noteUserSpeech()
            await capture.endSession(source: .done)
            speech.onPlaybackEvent = prior
            check(shadow.state.phase == .closed && shadow.state.output == nil && !speech.isSpeaking,
                  "CONTROL: cleanup retained output or active playback")
        }
        // COMMON positive control: same reducer events before both producer versions.
        VoicePlaybackRepeatResumeSelfTest.originalCases { label, value in check(value, label) }
        check(unexpectedTurns == 0, "CONTROL: capture dispatched an unexpected model turn")
        check(SelfTestStoreGuard.diff(before, SelfTestStoreGuard.take()).isEmpty,
              "CONTROL: owner stores/defaults changed")
        for failure in failures { SelfTest.diagnostic("VOICE_PLAYBACK_RESUME_RECEIPT_WRONG: " + failure) }
        return failures.isEmpty && !SelfTest.failed
            ? "VOICE_PLAYBACK_RESUME_RECEIPT_OK: \(checks) checks"
            : "VOICE_PLAYBACK_RESUME_RECEIPT_FAILED: \(failures.count) assertions"
    }
}

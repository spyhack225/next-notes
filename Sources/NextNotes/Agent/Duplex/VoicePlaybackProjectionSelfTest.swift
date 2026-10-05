import Foundation

/// Off-source proposed common original/fixed fixture; commands remain shadow-only.
/// Native cases use real Apple PCM, no notifyTestingFirstAudio or fake backing.
@MainActor
enum VoicePlaybackProjectionSelfTest {
    private static func reached(_ predicate: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }

    static func run() async -> String {
        guard SelfTest.isRunning else { return "VOICE_PLAYBACK_PROJECTION_FAILED: harness required" }
        let capture = AgentCaptureController.shared
        let audio = RealtimeAudioSession.shared
        let speech = AgentSpeechSynthesizer.shared
        let shadow = VoiceSession.shared
        guard !capture.isSessionActive, !speech.isSpeaking,
              !CommandLine.arguments.contains("--voice-pocket-source") else {
            return "VOICE_PLAYBACK_PROJECTION_FAILED: isolated Apple playback required"
        }
        let before = SelfTestStoreGuard.take()
        var failures: [String] = []
        var checks = 0
        func check(_ condition: Bool, _ message: String) {
            checks += 1
            if !condition { failures.append(message) }
        }
        pureCases(check: check)
        let oldEngine = speech.engineOverrideForTesting
        let oldVolume = speech.utteranceVolume
        let oldTurnHandler = capture.turnHandlerForTesting
        let oldPlayback = speech.onPlaybackEvent
        let oldSettled = speech.onVoiceLifecycleSettled
        defer {
            speech.engineOverrideForTesting = oldEngine
            speech.utteranceVolume = oldVolume
            capture.turnHandlerForTesting = oldTurnHandler
            speech.onPlaybackEvent = oldPlayback
            speech.onVoiceLifecycleSettled = oldSettled
        }
        speech.restoreSystemBacking()
        speech.engineOverrideForTesting = "apple"
        var unexpectedTurns = 0
        capture.turnHandlerForTesting = { _ in unexpectedTurns += 1 }
        shadow.resetDiagnosticsForTesting()
        // One clause only: initial volume0 is captured by the actual backing before
        // RealtimeAudioSession's later enqueue projection updates future volume.
        let clause = "This single silent Apple playback clause is deliberately long enough to "
            + "observe its real played buffer acknowledgement and hold the same token before "
            + "the remaining queued audio has drained, without requesting any model or tool."
        for lateWhilePaused in [false, true] {
            await capture.beginSession(captureAudio: false)
            guard let captureID = capture.sessionID else {
                failures.append("native: capture session did not open")
                await capture.endSession(source: .done)
                continue
            }
            // Real capture helper primes the normal minimum-speech timestamp. Its
            // explicit turn-handler seam prevents model staging/speculation.
            capture.simulateCumulativeSpeech("Um")
            let prior = speech.onPlaybackEvent
            var acknowledged = false
            var pausedBeforeForward = false
            var acknowledgedToken: UInt64?
            speech.onPlaybackEvent = { event in
                if case .startAcknowledged = event, !acknowledged {
                    acknowledgedToken = speech.currentPlaybackToken
                    if lateWhilePaused {
                        // Intercept only the existing listener chain: actual Apple
                        // positive-buffer callback has arrived, but its existing
                        // consumer has not yet received it. No fabricated receipt.
                        capture.simulateCumulativeSpeech("Please stop speaking")
                        pausedBeforeForward = speech.isPausedForListening
                            && audio.voiceShadowOutputSnapshot?.status == .paused
                    }
                    prior?(event)
                    acknowledged = true
                } else { prior?(event) }
            }
            audio.beginSpokenReply(OutputScheduler.tokenForTesting())
            speech.utteranceVolume = 0
            audio.appendSpokenReply(clause)
            audio.finalizeSpokenReply()
            let output = shadow.state.output?.id
            let token = speech.currentPlaybackToken
            let generation = speech.outputGeneration
            check(output != nil && shadow.state.output?.status == .queued && !acknowledged,
                  "native: enqueue supplied speaking evidence before Apple PCM")
            guard await reached({ acknowledged || !speech.isSpeaking }) && acknowledged else {
                failures.append("native: actual Apple positive playback callback absent")
                audio.noteUserSpeech()
                await capture.endSession(source: .done)
                speech.onPlaybackEvent = prior
                continue
            }
            check(acknowledgedToken == token && speech.outputGeneration == generation
                  && shadow.state.output?.id == output && shadow.state.output?.heard == true,
                  "native: actual callback lost current token/generation/output played fact")
            if lateWhilePaused {
                check(pausedBeforeForward && speech.isPausedForListening,
                      "native: late callback case did not pass through real confirmed pause")
                check(shadow.state.output?.status == .paused && shadow.state.island == .listening
                      && audio.voiceShadowOutputSnapshot == shadow.state.output,
                      "native: late actual acknowledgement undid queued pause or presented speaking")
            } else {
                check(shadow.state.output?.status == .playing && shadow.state.island == .speaking,
                      "native: actual played callback did not produce initial speaking shadow")
                capture.simulateCumulativeSpeech("Please stop speaking")
                check(speech.isPausedForListening && shadow.state.output?.status == .paused
                      && shadow.state.island == .listening
                      && audio.voiceShadowOutputSnapshot == shadow.state.output,
                      "native: actual confirmed playing pause retained speaking projection")
            }
            check(speech.currentPlaybackToken == token && speech.outputGeneration == generation,
                  "native: provisional pause cancelled/replaced current playback")
            check(!audio.pauseForListening(captureID: UUID()),
                  "native: wrong capture acquired existing listening hold")
            audio.noteUserSpeech()
            check(shadow.state.output == nil && audio.voiceShadowOutputSnapshot == nil
                  && shadow.state.island == .listening,
                  "native: actual matched interruption retained speaking shadow")
            await Task.yield()
            check(shadow.divergenceCount == 0,
                  "native: actual output/floor/effect/turn producer diverged from shadow")
            SelfTest.diagnostic("VOICE_PLAYBACK_PROJECTION_NATIVE: lateWhilePaused=\(lateWhilePaused) acknowledged=\(acknowledged) pausedBeforeForward=\(pausedBeforeForward) outputMatched=\(output != nil) token=\(token) generation=\(generation) divergences=\(shadow.divergenceCount)")
            await capture.endSession(source: .done)
            speech.onPlaybackEvent = prior
            check(shadow.state.phase == .closed && shadow.state.output == nil,
                  "native: session close retained current output")
        }
        check(unexpectedTurns == 0, "native: capture fixture dispatched an unexpected model turn")
        check(SelfTestStoreGuard.diff(before, SelfTestStoreGuard.take()).isEmpty,
              "native: fixture changed owner stores or defaults")
        for failure in failures { SelfTest.diagnostic("VOICE_PLAYBACK_PROJECTION_WRONG: " + failure) }
        return failures.isEmpty && !SelfTest.failed
            ? "VOICE_PLAYBACK_PROJECTION_OK: \(checks) checks"
            : "VOICE_PLAYBACK_PROJECTION_FAILED: \(failures.count) assertions"
    }

    private static func pureCases(check: (Bool, String) -> Void) {
        let t1 = TurnID(raw: 100), t2 = TurnID(raw: 101)
        let o1 = OutputID(raw: 100), stale = OutputID(raw: 99)
        let now = VoiceSessionInstant(milliseconds: 200)
        var state = VoiceSessionState()
        state.phase = .open
        state.sessionID = UUID()
        state.response = .init(turn: t1, decided: true, output: o1)
        state.turnPending = t1
        state.output = .init(id: o1, kind: .answer(t1), status: .playing, heard: true)
        state.island = .speaking
        let paused = VoiceSessionReducer.reduce(state, .interruption(.provisional(t2)), at: now)
        check(paused.0.output?.status == .paused && paused.0.output?.heard == true
              && paused.0.island == .listening && paused.1.contains(.publishIsland(.listening)),
              "pure: confirmed provisional pause left speaking")
        let late = VoiceSessionReducer.reduce(paused.0, .playback(o1, .firstAudio), at: now)
        check(late.0.output?.status == .paused && late.0.output?.heard == true
              && late.0.island == .listening && !late.1.contains(.publishIsland(.speaking)),
              "pure: late first receipt undid pause")
        let staleFirst = VoiceSessionReducer.reduce(paused.0, .playback(stale, .firstAudio), at: now)
        check(staleFirst.0 == paused.0 && staleFirst.1.isEmpty,
              "pure: old output activated current paused output")
        let ended = VoiceSessionReducer.reduce(state, .responseEnded(t1, .answered), at: now)
        check(ended.0.response == nil && ended.0.output == state.output && ended.0.island == .speaking,
              "pure: model response end hid still-acknowledged playback")
        let committed = VoiceSessionReducer.reduce(state, .interruption(.committed(t2)), at: now)
        check(committed.0.output == nil && committed.0.response == nil && committed.0.island == .listening,
              "pure: committed interruption left speaking")
        let stopped = VoiceSessionReducer.reduce(ended.0, .playback(o1, .interrupted(byUser: false)), at: now)
        check(stopped.0.output == nil && stopped.0.island == .listening,
              "pure: matched playback interruption left speaking")
        var proposal = state
        proposal.pendingApproval = "owned-proposal"
        proposal.island = .proposal("owned-proposal")
        let firstUnderProposal = VoiceSessionReducer.reduce(proposal, .playback(o1, .firstAudio), at: now)
        check(firstUnderProposal.0.island == .proposal("owned-proposal"),
              "pure: onset displaced current actionable proposal")
        let endedUnderProposal = VoiceSessionReducer.reduce(proposal, .responseEnded(t1, .answered), at: now)
        check(endedUnderProposal.0.island == .proposal("owned-proposal"),
              "pure: model completion displaced current actionable proposal")
        let finishedUnderProposal = VoiceSessionReducer.reduce(proposal, .playback(o1, .finished), at: now)
        check(finishedUnderProposal.0.output == nil && finishedUnderProposal.0.island == .proposal("owned-proposal"),
              "pure: playback drain displaced current actionable proposal")
        let stoppedUnderProposal = VoiceSessionReducer.reduce(proposal, .playback(o1, .interrupted(byUser: true)), at: now)
        check(stoppedUnderProposal.0.output == nil && stoppedUnderProposal.0.island == .proposal("owned-proposal"),
              "pure: playback interruption displaced current actionable proposal")
        let staleApproval = VoiceSessionReducer.reduce(proposal, .approvalResolved(requestID: "old"), at: now)
        check(staleApproval.0 == proposal && staleApproval.1.isEmpty,
              "pure: stale approval resolution cleared current actionable proposal")
        var queued = state
        queued.output?.status = .queued
        queued.output?.heard = false
        queued.island = .thinking
        let queuedPause = VoiceSessionReducer.reduce(queued, .interruption(.provisional(t2)), at: now)
        check(queuedPause.0.output?.status == .paused && queuedPause.0.output?.heard == false
              && queuedPause.0.island == .listening,
              "pure: actual confirmed pre-onset pause was not represented")
        let closed = VoiceSessionReducer.reduce(proposal, .sessionClosed(.done), at: now)
        check(closed.0.phase == .closed && closed.0.island == .none && closed.0.output == nil,
              "pure: close retained proposal/playback projection")
    }
}

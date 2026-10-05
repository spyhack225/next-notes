import Foundation

/// SAME real audio/buffer/playback/history consumers with an existing recording
/// backing. No model, speaker, native audibility or new callback owner is claimed.
enum OutputTokenSelfTest {
    @MainActor
    static func run() async -> [String] {
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-voice-delivery" else {
            return ["OUTPUT_TOKEN_C00: exact existing delivery harness required"]
        }
        var failures: [String] = []
        var checks = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            print("OUTPUT_TOKEN_ASSERT label=\(label) passed=\(value)")
            if !value { failures.append("OUTPUT_TOKEN_" + label) }
        }
        let capture = AgentCaptureController.shared
        let audio = RealtimeAudioSession.shared
        let synth = AgentSpeechSynthesizer.shared
        let agent = RealtimeAgent.shared
        let recorder = RecordingSpeechBacking()
        synth.useTestingBacking(recorder)
        defer { synth.restoreSystemBacking() }
        func drain() {
            for _ in 0..<32 where synth.voiceLifecycleSnapshot.hasClause || synth.pendingClauseCount > 0 {
                let native = synth.currentPlaybackToken
                synth.notifyTestingFirstAudio(token: native)
                recorder.finishNaturallyForTesting(); synth.notifyTestingAudioFinished(token: native)
            }
        }

        // A real frontend/tracker answer is retained before a genuine scheduled
        // read-aloud replaces it. The same frontend's finish binds the saved row.
        await capture.beginSession(captureAudio: false)
        agent.userSpeechEnded()
        let turn = VoiceSession.shared.beginTurnIfNeeded()
        let owner = agent.beginVoiceFrontend(voiceTurn: turn)
        let tracker = AgentToolSpeechTracker(agent: agent, turn: owner, allowSpeech: true)
        tracker.beginResponse()
        tracker.receive("Owned answer first. ")
        let answerID = audio.retainedOutputID
        let firstGeneration = synth.outputGeneration
        let answerNativeToken = synth.currentPlaybackToken
        check(tracker.didStreamSpeech && answerID != nil && recorder.spoken == ["Owned answer first."], "C01_tracker_real_answer")
        LiveScheduleDelivery().speak("Scheduled notice current.")
        let noticeID = audio.retainedOutputID
        let noticeToken = synth.currentPlaybackToken
        check(noticeID != nil && noticeID != answerID && synth.outputGeneration > firstGeneration
              && recorder.spoken.last == "Scheduled notice current.", "C02_real_sessionless_replacement")
        _ = agent.finishVoiceFrontend("Owned answer first.", turn: owner, streamed: true)
        let rowID = AgentSession.shared.messages.last(where: { $0.role == "assistant" && $0.text == "Owned answer first." })?.id
        check(rowID != nil && agent.isCurrent(owner), "C03_actual_frontend_row")
        synth.notifyTestingFirstAudio(token: answerNativeToken)
        synth.notifyTestingAudioFinished(token: answerNativeToken)
        let lateNativeRefused = synth.currentPlaybackToken == noticeToken && synth.voiceLifecycleSnapshot.hasClause
            && audio.retainedOutputID == noticeID
        synth.notifyTestingFirstAudio(token: noticeToken)
        recorder.finishNaturallyForTesting(); synth.notifyTestingAudioFinished(token: noticeToken)
        let row = AgentSession.shared.messages.first(where: { $0.id == rowID })
        check(lateNativeRefused && !synth.voiceLifecycleSnapshot.hasClause && recorder.spoken.contains("Scheduled notice current."), "C04_old_callback_refused_current_callback_completed")
        check(row?.speechDelivery?.completedText.contains("Scheduled notice current.") != true, "F01_answer_not_bound_to_notice")
        check(row?.modelContextText.contains("Completed spoken clauses: Scheduled notice current.") != true, "F02_context_not_attributed_to_notice")
        await capture.endSession(source: .done)

        // Actual late model snapshots retain the tracker handle they began with.
        await capture.beginSession(captureAudio: false)
        agent.userSpeechEnded(); recorder.reset()
        let owner2 = agent.beginVoiceFrontend(voiceTurn: VoiceSession.shared.beginTurnIfNeeded())
        let late = AgentToolSpeechTracker(agent: agent, turn: owner2, allowSpeech: true)
        late.beginResponse(); late.receive("Prior model sentence.")
        let priorID = audio.retainedOutputID
        LiveScheduleDelivery().speak("New scheduled sentence.")
        let successorID = audio.retainedOutputID
        let successorGeneration = synth.outputGeneration
        check(priorID != nil && successorID != nil && priorID != successorID && late.didStreamSpeech
              && agent.isCurrent(owner2), "C05_actual_late_tracker_owner")
        late.receive("Prior model sentence. Late old model sentence.")
        late.finish(hasToolCalls: false)
        drain()
        check(!synth.voiceLifecycleSnapshot.hasClause && synth.pendingClauseCount == 0, "C06_actual_late_model_drain")
        check(!recorder.spoken.contains("Late old model sentence."), "F03_old_tracker_append_refused")
        check(synth.outputGeneration == successorGeneration, "C07_late_append_does_not_mint")
        _ = agent.finishVoiceFrontend("Prior model sentence.", turn: owner2, streamed: true)
        await capture.endSession(source: .done)

        await capture.beginSession(captureAudio: false)
        agent.userSpeechEnded(); recorder.reset()
        let oldHandle = OutputScheduler.shared.beginAnswer(turn: nil)
        oldHandle.append("Old complete sentence. ")
        let nextHandle = OutputScheduler.shared.beginAnswer(turn: nil)
        let nextGeneration = synth.outputGeneration
        recorder.reset()
        nextHandle.append("Current partial ")
        check(oldHandle.output != nextHandle.output && recorder.spoken.isEmpty
              && audio.retainedOutputID == nextHandle.output, "C08_two_streams_partial_not_queued")
        oldHandle.finish()
        check(recorder.spoken.isEmpty, "F04_old_handle_finish_refused")
        nextHandle.append("answer."); nextHandle.finish(); drain()
        check(synth.outputGeneration == nextGeneration && !synth.voiceLifecycleSnapshot.hasClause, "C09_successor_same_generation_drained")
        check(recorder.spoken == ["Current partial answer."], "F05_successor_buffer_preserved")
        await capture.endSession(source: .done)

        await capture.beginSession(captureAudio: false)
        agent.userSpeechEnded(); recorder.reset()
        let owner3 = agent.beginVoiceFrontend(voiceTurn: VoiceSession.shared.beginTurnIfNeeded())
        let cancelled = AgentToolSpeechTracker(agent: agent, turn: owner3, allowSpeech: true)
        cancelled.beginResponse(); cancelled.receive("Old cancellable sentence. ")
        LiveScheduleDelivery().speak("Current cancellable sentence.")
        let currentID = audio.retainedOutputID
        let currentNative = synth.currentPlaybackToken
        let currentGeneration = synth.outputGeneration
        let stopsBefore = recorder.stopCount
        check(cancelled.didStreamSpeech && synth.voiceLifecycleSnapshot.hasClause && recorder.spoken.last == "Current cancellable sentence.", "C10_actual_cancel_overlap")
        cancelled.cancel()
        check(synth.voiceLifecycleSnapshot.hasClause && synth.currentPlaybackToken == currentNative
              && synth.outputGeneration == currentGeneration && audio.retainedOutputID == currentID
              && recorder.stopCount == stopsBefore, "F06_old_tracker_cancel_refused")
        drain()
        _ = agent.finishVoiceFrontend("Old cancellable sentence.", turn: owner3, streamed: true)
        await capture.endSession(source: .done)

        await capture.beginSession(captureAudio: false)
        agent.userSpeechEnded(); recorder.reset()
        let oldOwner = agent.beginVoiceFrontend(voiceTurn: VoiceSession.shared.beginTurnIfNeeded())
        let nextOwner = agent.beginVoiceFrontend(voiceTurn: VoiceIDMint.shared.nextTurn())
        let current = OutputScheduler.shared.beginAnswer(turn: agent.voiceFrontendShadowTurn)
        current.append("Latest owner sentence. "); current.finish()
        let generation = synth.outputGeneration
        let native = synth.currentPlaybackToken
        let before = recorder.spoken
        check(nextOwner > oldOwner && !agent.isCurrent(oldOwner) && agent.isCurrent(nextOwner)
              && synth.voiceLifecycleSnapshot.hasClause, "C11_real_superseded_frontend_owner")
        let stale = OutputScheduler.shared.speakFixed("Stale fixed reply.", turn: nil, agent: agent, owner: oldOwner)
        check(stale == nil && recorder.spoken == before && synth.outputGeneration == generation
              && synth.currentPlaybackToken == native && audio.retainedOutputID == current.output,
              "F07_stale_fixed_reply_refused_before_mutation")
        drain()
        _ = agent.finishVoiceFrontend("Latest owner sentence.", turn: nextOwner, streamed: true)
        await capture.endSession(source: .done)

        await capture.beginSession(captureAudio: false)
        agent.userSpeechEnded(); recorder.reset()
        let original = OutputScheduler.shared.beginAnswer(turn: nil)
        original.append("Old begin sentence. "); original.finish()
        let replayToken = OutputScheduler.currentTokenForTesting()
        let newest = OutputScheduler.shared.beginAnswer(turn: nil)
        newest.append("Current begin sentence. "); newest.finish()
        let liveGeneration = synth.outputGeneration
        let liveNative = synth.currentPlaybackToken
        let spokenBefore = recorder.spoken
        check(original.output < newest.output && synth.voiceLifecycleSnapshot.hasClause
              && replayToken.output == original.output, "C12_actual_old_minted_capability")
        let replay = audio.beginSpokenReply(replayToken)
        check(!replay && synth.outputGeneration == liveGeneration
              && synth.currentPlaybackToken == liveNative && audio.retainedOutputID == newest.output
              && recorder.spoken == spokenBefore, "F08_old_begin_capability_refused")
        drain()
        await capture.endSession(source: .done)

        // Closed-session ordinary scheduled read-aloud still speaks, without an
        // invented voice turn, microphone session, or scheduler-window gate.
        recorder.reset()
        check(!capture.isSessionActive && !audio.isActive, "C13_session_closed_before_schedule")
        LiveScheduleDelivery().speak("Closed session schedule.")
        check(!capture.isSessionActive && !audio.isActive && recorder.spoken == ["Closed session schedule."]
              && audio.voiceShadowOutputSnapshot?.kind == .delivery([]), "C14_sessionless_normal_consumer")
        drain()
        check(!synth.voiceLifecycleSnapshot.hasClause && synth.pendingClauseCount == 0, "C15_all_owned_recording_callbacks_drained")
        print("OUTPUT_TOKEN_TRACE checks=\(checks) failures=\(failures.count) recordingOnly=true nativeAudibility=false")
        return failures
    }
}

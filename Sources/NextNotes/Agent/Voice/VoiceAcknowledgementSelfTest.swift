import Foundation

/// Same coordinator commit/scheduler/audio owner, held external model and playback recorder.
@MainActor
enum VoiceAcknowledgementSelfTest {
    static func run() async -> [String] {
        let ack = VoiceAcknowledgement.shared
        let coordinator = VoiceConversationCoordinator.shared
        let capture = AgentCaptureController.shared
        let synth = AgentSpeechSynthesizer.shared
        let recorder = RecordingSpeechBacking()
        var wrong: [String] = []
        var checks = 0
        func check(_ value: Bool, _ name: String) {
            checks += 1
            if !value { wrong.append(name) }
        }
        await capture.endSession(source: .done)
        coordinator.resetForTesting()
        synth.useTestingBacking(recorder)
        let priorEngine = synth.engineOverrideForTesting
        let synthesisBefore = synth.speechSynthesisCallsForTesting
        synth.engineOverrideForTesting = "pocket"
        ack.clipsForTesting = ["Mm.", "Okay."]
        var environment = VoiceAcknowledgement.Environment()
        ack.environmentForTesting = { environment }
        defer {
            ack.cancel(); ack.clipsForTesting = nil; ack.environmentForTesting = nil
            synth.restoreSystemBacking(); synth.engineOverrideForTesting = priorEngine
        }
        let never: [(String, String, VoiceAcknowledgement.Environment)] = [
            ("speaking", "Write a haiku about the rain", .init(speaking: true)),
            ("dictation", "Write a haiku about the rain", .init(dictating: true)),
            ("meeting", "Write a haiku about the rain", .init(meeting: true)),
            ("agent-speaking", "Write a haiku about the rain", .init(output: true)),
            ("apple-selected", "Write a haiku about the rain", .init()),
            ("closed", "Write a haiku about the rain", .init(session: false)),
            ("backchannel", "mm hmm", .init()),
            ("noise", "boys", .init()),
            ("hesitation", "um", .init()),
            ("approval", "yes", .init()),
            ("denial", "no", .init()),
            ("pure-answer", "Tuesday afternoon", .init(interaction: true))
        ]
        for (name, text, blocked) in never {
            coordinator.resetForTesting()
            await capture.beginSession(captureAudio: false)
            environment = blocked
            synth.engineOverrideForTesting = name == "apple-selected" ? "apple" : "pocket"
            let held = LockedBox<AsyncThrowingStream<String, Error>.Continuation?>(nil)
            coordinator.streamForTesting = { _, _ in AsyncThrowingStream { held.value = $0 } }
            let before = ack.playedForTesting.count
            let task = Task { await coordinator.handle(text) }
            try? await Task.sleep(for: .milliseconds(160))
            check(ack.playedForTesting.count == before && !ack.testActive, "never \(name)")
            task.cancel(); held.value?.finish(); _ = await task.value
            await capture.endSession(source: .done)
        }
        // Eligible neighbors expose a no-op producer, rotation, at-most-once and
        // real model/answer independence. Recorder supplies only playback callbacks.
        synth.engineOverrideForTesting = "pocket"
        var previous: String?
        for index in 0..<3 {
            coordinator.resetForTesting()
            await capture.beginSession(captureAudio: false)
            environment = .init()
            let held = LockedBox<AsyncThrowingStream<String, Error>.Continuation?>(nil)
            coordinator.streamForTesting = { _, _ in AsyncThrowingStream { held.value = $0 } }
            let before = ack.playedForTesting.count
            let history = AgentSession.shared.messages.count
            let task = Task { await coordinator.handle("Write a haiku about the rain") }
            try? await Task.sleep(for: .milliseconds(140))
            check(ack.playedForTesting.count == before + 1 && ack.testActive, "eligible \(index) starts ready clip")
            let last = ack.playedForTesting.last
            check(last != nil && last != previous, "rotation \(index)")
            previous = last
            check(AgentSession.shared.messages.count == history + 1, "ack not stored as reply \(index)")
            check(!RealtimeAudioSession.shared.isSpeaking, "ack not answer/barge floor \(index)")
            if index == 0 {
                coordinator.inputActivityStarted()
                check(!ack.testActive && !ack.pendingForTesting, "cancel at resumed activity")
            } else {
                let turn = VoiceSession.shared.currentTurn()
                let handle = OutputScheduler.shared.beginAnswer(turn: turn)
                check(!ack.testActive && !ack.pendingForTesting, "answer preempts synchronously \(index)")
                handle.append("The real answer."); handle.finish()
                check(recorder.spoken.last == "The real answer.", "answer no ack queue \(index)")
            }
            if let committed = VoiceSession.shared.state.lastCommittedTurn {
                OutputScheduler.shared.acknowledgeCommitted(committed,
                    text: "Write a haiku about the rain", interaction: false)
            }
            try? await Task.sleep(for: .milliseconds(80))
            check(ack.playedForTesting.count == before + 1, "at most once \(index)")
            task.cancel(); held.value?.finish(); _ = await task.value
            await capture.endSession(source: .done)
        }
        // Same actual coordinator commit, cancelled inside the grace window.
        environment = .init()
        coordinator.resetForTesting()
        await capture.beginSession(captureAudio: false)
        let graceHeld = LockedBox<AsyncThrowingStream<String, Error>.Continuation?>(nil)
        coordinator.streamForTesting = { _, _ in AsyncThrowingStream { graceHeld.value = $0 } }
        let before = ack.playedForTesting.count
        let graceTask = Task { await coordinator.handle("Write a haiku about rain") }
        try? await Task.sleep(for: .milliseconds(10))
        check(ack.pendingForTesting, "eligible commit schedules grace independently")
        coordinator.inputActivityStarted()
        check(!ack.pendingForTesting && !ack.testActive, "resume cancels grace synchronously")
        try? await Task.sleep(for: .milliseconds(100))
        check(ack.playedForTesting.count == before, "resume before grace plays nothing")
        graceTask.cancel(); graceHeld.value?.finish(); _ = await graceTask.value
        await capture.endSession(source: .done)
        coordinator.resetForTesting()
        await capture.beginSession(captureAudio: false)
        ack.clipsForTesting = []
        let unreadyHeld = LockedBox<AsyncThrowingStream<String, Error>.Continuation?>(nil)
        coordinator.streamForTesting = { _, _ in AsyncThrowingStream { unreadyHeld.value = $0 } }
        let unreadyTask = Task { await coordinator.handle("Write a haiku about rain") }
        try? await Task.sleep(for: .milliseconds(100))
        check(ack.playedForTesting.count == before, "unready voice stays silent")
        unreadyTask.cancel(); unreadyHeld.value?.finish(); _ = await unreadyTask.value
        await capture.endSession(source: .done)
        coordinator.resetForTesting()
        await capture.beginSession(captureAudio: false)
        ack.clipsForTesting = ["Mm.", "Okay."]
        coordinator.streamForTesting = { _, _ in AsyncThrowingStream {
            $0.yield("<answer/> The ready answer."); $0.finish()
        } }
        let fast = await coordinator.handle("What is two plus two?")
        try? await Task.sleep(for: .milliseconds(100))
        check(ack.playedForTesting.count == before && !ack.pendingForTesting && !ack.testActive,
              "ready answer in grace needs no acknowledgement")
        check(fast.reply == "The ready answer." && !fast.delegated, "ready answer remains unchanged")
        await capture.endSession(source: .done)
        coordinator.resetForTesting()
        check(synth.speechSynthesisCallsForTesting == synthesisBefore, "scripted playback performs no native synthesis")
        SelfTest.diagnostic("VOICE_ACK_CHECKS=\(checks) failures=\(wrong.count)")
        return wrong
    }
}

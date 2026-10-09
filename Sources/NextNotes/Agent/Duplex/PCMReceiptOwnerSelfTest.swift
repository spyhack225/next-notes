import Foundation

/// Migrated token/epoch/receipt invariants through the actual synth, capture,
/// audio and shadow owners. The PCM dependency is simulated; no audibility claim.
/// Positive receipts cover this capable fake only. Pocket/Kokoro have no qualified
/// post-resume receipts; the distinct timeline flag exercises native prepared PCM.
@MainActor
enum PCMReceiptOwnerSelfTest {
    static func run(marker: String) async -> String {
        guard SelfTest.isRunning else { return marker + "_FAILED: harness required" }
        let synth = AgentSpeechSynthesizer.shared
        let audio = RealtimeAudioSession.shared
        let capture = AgentCaptureController.shared
        let shadow = VoiceSession.shared
        guard !capture.isSessionActive, !synth.isSpeaking else { return marker + "_FAILED: isolated fixture required" }
        let before = SelfTestStoreGuard.take()
        let pcm = PCMReceiptSpeechBacking()
        let oldTurn = capture.turnHandlerForTesting
        var dispatched = 0
        capture.turnHandlerForTesting = { _ in dispatched += 1 }
        synth.useTestingBacking(pcm)
        var failures: [String] = [], checks = 0
        func check(_ okay: Bool, _ label: String) {
            checks += 1
            if !okay { failures.append(label) }
        }
        defer { synth.stop(); synth.restoreSystemBacking(); capture.turnHandlerForTesting = oldTurn }
        shadow.resetDiagnosticsForTesting()
        await capture.beginSession(captureAudio: false)
        capture.simulateCumulativeSpeech("Um")
        guard let captureID = capture.sessionID else {
            await capture.endSession(source: .done)
            return marker + "_FAILED: capture fixture absent"
        }
        let prior = synth.onPlaybackEvent
        var receipts: [PCMResumePlaybackReceipt] = []
        synth.onPlaybackEvent = { event in
            if case .resumeAcknowledged(let receipt) = event { receipts.append(receipt) }
            prior?(event)
        }
        let handle = OutputScheduler.tokenForTesting()
        check(audio.beginSpokenReply(handle), "output admission")
        let clause = "The reply remains available while we pause and resume."
        audio.appendSpokenReply(handle, clause); audio.finalizeSpokenReply(handle)
        let token = synth.currentPlaybackToken, generation = synth.outputGeneration
        let output = shadow.state.output?.id
        check(capture.sessionID == captureID, "output retains exact capture session")
        check(pcm.submissions.map(\.text) == [clause], "one exact clause submitted")
        check(pcm.events == [.enqueued(token)], "enqueue distinct from played/completed")
        check(shadow.state.output?.status == .queued && shadow.state.output?.heard == false, "enqueue is unheard")
        let packet = pcm.packet(token: token)
        pcm.deliverPlayed(packet)
        check(shadow.state.output?.status == .playing && shadow.state.output?.heard == true, "played receipt reaches current output")
        check(!pcm.events.contains(.completed(token)), "played is not complete")
        var previous: PCMResumePlaybackReceipt?
        for phase in [UInt64(4), UInt64(6)] {
            let old = pcm.packet(token: token, ordinal: 0)
            capture.simulateCumulativeSpeech("Please stop speaking")
            check(synth.isPausedForListening && shadow.state.output?.status == .paused, "capture pause preserves owner")
            check(synth.currentPlaybackToken == token && synth.outputGeneration == generation, "pause preserves token/generation")
            check(!audio.pauseForListening(captureID: UUID()), "wrong capture cannot acquire hold")
            pcm.complete(token)
            check(synth.currentPlaybackToken == token && synth.isSpeaking, "pause cannot complete")
            capture.simulateCumulativeSpeech("mm hmm"); capture.simulateSilence()
            let discarded = await capture.considerEndpoint()
            check(discarded && !synth.isPausedForListening && !synth.didStop, "actual backchannel resumes output")
            check(synth.voiceLifecycleSnapshot.resumeBinding == .init(token: token, phase: phase), "exact requested phase")
            check(synth.voiceLifecycleSnapshot.resumePending && shadow.state.output?.status == .awaitingResume,
                  "historical heard cannot restore speaking")
            pcm.deliverPlayed(old)
            check(shadow.state.output?.status == .awaitingResume, "old-phase played packet cannot restore")
            if let previous { pcm.deliverResume(previous); prior?(.resumeAcknowledged(previous)) }
            check(shadow.state.output?.status == .awaitingResume, "previous-phase receipt cannot restore")
            let receipt = pcm.resumeReceipt(token: token)
            check(receipt.packet.originPhase == phase && receipt.packet.buffer.token == token, "receipt ownership exact")
            check(receipt.earlier.frame < receipt.later.frame && receipt.earlier.nodeHostTime < receipt.later.nodeHostTime,
                  "advancing simulated cursor metadata")
            check(receipt.packet.buffer.upperFrame > receipt.checkpoint && receipt.checkpointBuffer.upperFrame == receipt.checkpoint,
                  "positive suffix strictly after checkpoint")
            check(receipt.packet.buffer.lowerFrame == receipt.checkpointBuffer.upperFrame
                  && receipt.packet.buffer.ordinal == receipt.checkpointBuffer.ordinal + 1
                  && receipt.packet.buffer.sampleRate == receipt.checkpointBuffer.sampleRate,
                  "contiguous common frame/rate domain")
            let malformed = PCMResumePlaybackReceipt(packet: receipt.packet, earlier: receipt.later,
                later: receipt.earlier, checkpoint: receipt.checkpoint, checkpointBuffer: receipt.checkpointBuffer)
            pcm.onResumePlaybackAcknowledged?(malformed) // bypass fake rejection, actual synth receiver
            check(synth.voiceLifecycleSnapshot.resumePending, "actual receiving boundary refuses reversed cursors")
            pcm.deliverResume(receipt)
            check(receipts.last == receipt && receipts.filter { $0 == receipt }.count == 1, "exact proof delivered once")
            check(!synth.voiceLifecycleSnapshot.resumePending && shadow.state.output?.status == .playing
                  && shadow.state.output?.id == output && audio.voiceShadowOutputSnapshot?.status == .playing,
                  "qualified resume reaches actual synth/audio/shadow owner")
            let count = receipts.count
            pcm.deliverResume(receipt)
            check(receipts.count == count, "duplicate proof ignored")
            check(synth.currentPlaybackToken == token && synth.outputGeneration == generation, "resume does not replace clause")
            previous = receipt
        }
        let stale = pcm.packet(token: token)
        audio.noteUserSpeech()
        check(synth.didStop && shadow.state.output == nil && !pcm.isSpeaking, "interruption retires owner")
        check(pcm.events.contains(.interrupted(token)), "interruption distinct from completion")
        let replacement = OutputScheduler.tokenForTesting()
        check(audio.beginSpokenReply(replacement), "replacement admitted")
        audio.appendSpokenReply(replacement, "A fresh written and spoken answer."); audio.finalizeSpokenReply(replacement)
        let successor = synth.currentPlaybackToken
        check(successor != token && synth.outputGeneration != generation && shadow.state.output?.id != output, "replacement has distinct identity")
        pcm.deliverPlayed(stale)
        if let previous { pcm.deliverResume(previous); prior?(.resumeAcknowledged(previous)) }
        synth.notifyTestingAudioFinished(token: token)
        check(shadow.state.output?.status == .queued && synth.currentPlaybackToken == successor, "stale packets/completion cannot promote or consume replacement")
        pcm.deliverPlayed(pcm.packet(token: successor))
        check(shadow.state.output?.status == .playing, "replacement remains playable")
        pcm.complete(successor)
        check(!synth.isSpeaking && pcm.events.contains(.completed(successor)), "completion independently drains exact replacement")
        await capture.endSession(source: .done)
        check(shadow.state.phase == .closed && shadow.state.output == nil && !capture.isSessionActive, "closed cleanup")
        check(dispatched == 0, "no model turn dispatched")
        check(SelfTestStoreGuard.diff(before, SelfTestStoreGuard.take()).isEmpty, "owner stores/defaults unchanged")
        check(pcm.events.contains(.paused(token, 3)) && pcm.events.contains(.resumed(token, 4))
              && pcm.events.contains(.paused(token, 5)) && pcm.events.contains(.resumed(token, 6)), "distinct pause/resume epochs recorded")
        check(pcm.pcm.count == 1920 && pcm.pcm.contains { $0 != 0 }, "fixed nonzero PCM frame domain")
        for failure in failures { SelfTest.diagnostic(marker + "_WRONG: " + failure) }
        return failures.isEmpty && !SelfTest.failed
            ? marker + "_OK: \(checks) simulated PCM checks; native playback unverified"
            : marker + "_FAILED: \(failures.count) assertions"
    }
}

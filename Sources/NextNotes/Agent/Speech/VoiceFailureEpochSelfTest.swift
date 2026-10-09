import Foundation

/// Holds the actual file adapter's old clause across explicit selection/recovery.
@MainActor enum VoiceFailureEpochSelfTest {
    private enum Failure: Error { case oldClause }
    static func run() async -> [String] {
        let synth = AgentSpeechSynthesizer.shared
        var failures: [String] = []
        synth.restoreSystemBacking()
        let settings = Settings.shared
        guard settings.usesHarnessPreferencesForTesting else { return ["R2: actual preference writer is not isolated"] }
        let priorEngine = settings.agentVoiceEngine
        settings.agentVoiceEngine = "pocket"
        synth.engineOverrideForTesting = nil
        synth.setVoiceReadinessForTesting(engine: "pocket", ready: true)
        synth.setVoiceReadinessForTesting(engine: "kokoro", ready: true)
        defer {
            LongFormSynthesisFactory.audioForTesting = nil
            synth.stop(); synth.restoreSystemBacking(); synth.clearVoiceReadinessForTesting()
            settings.agentVoiceEngine = priorEngine
        }
        for recovery in ["selection", "selection without preparation", "same-engine retry", "cancellation"] {
            await synth.prepareSelectedVoice()
            var held: CheckedContinuation<LongFormRenderer.Audio, Error>?
            LongFormSynthesisFactory.audioForTesting = {
                try await withCheckedThrowingContinuation { held = $0 }
            }
            let clause = Task { @MainActor in
                do { _ = try await LongFormSynthesisFactory.live()(.init(text: "Held old Pocket clause", speaker: nil)) }
                catch { }
            }
            for _ in 0..<100 where held == nil { await Task.yield() }
            guard let held else { failures.append("R2: held actual clause missing"); clause.cancel(); continue }
            if recovery.hasPrefix("selection") {
                settings.agentVoiceEngine = "kokoro"
                if recovery == "selection" { await synth.prepareSelectedVoice() }
                settings.agentVoiceEngine = "pocket"
                if recovery == "selection" { await synth.prepareSelectedVoice() }
            } else {
                let player = PCMReceiptSpeechBacking()
                synth.useTestingBacking(player)
                let text = "A concurrent playback failure."
                synth.speak(text)
                player.onFailure?(text, 1, synth.currentPlaybackToken)
                if synth.availability != .failed { failures.append("R2: concurrent failure control missing") }
                await synth.prepareSelectedVoice()
            }
            if synth.availability != .ready { failures.append("R2: explicit recovery control missing") }
            held.resume(throwing: recovery == "cancellation" ? CancellationError() : Failure.oldClause)
            await clause.value
            if synth.availability != .ready { failures.append("R2: old \(recovery) settlement poisoned recovered Pocket") }
            // Same consumer must still admit a new request, rather than just
            // displaying a ready label while file work is blocked.
            var entries = 0
            LongFormSynthesisFactory.audioForTesting = { entries += 1; return .init(samples: [0.1], sampleRate: 24_000) }
            do { _ = try await LongFormSynthesisFactory.live()(.init(text: "Recovered new clause", speaker: nil)) }
            catch { failures.append("R2: recovered \(recovery) actual consumer rejected") }
            if entries != 1 { failures.append("R2: recovered \(recovery) entry missing") }
        }
        failures += await heldReplyFailures()
        return failures
    }
}

@MainActor private extension VoiceFailureEpochSelfTest {
    static func heldReplyFailures() async -> [String] {
        let synth = AgentSpeechSynthesizer.shared
        let session = RealtimeAudioSession.shared
        let settings = Settings.shared
        var failures: [String] = []
        for engine in ["pocket", "kokoro"] {
            for change in ["selection", "cached preparation"] {
                synth.stop(); synth.restoreSystemBacking()
                synth.setVoiceReadinessForTesting(engine: "pocket", ready: true)
                synth.setVoiceReadinessForTesting(engine: "kokoro", ready: true)
                settings.agentVoiceEngine = engine
                await synth.prepareSelectedVoice()
                let player = PCMReceiptSpeechBacking()
                synth.useTestingBacking(player)
                session.begin()
                let listener = synth.onPlaybackEvent
                let lifecycle = synth.onVoiceLifecycleSettled
                var events: [AgentSpeechSynthesizer.PlaybackEvent] = []
                var releases = 0
                synth.onPlaybackEvent = { events.append($0); listener?($0) }
                synth.onVoiceLifecycleSettled = { releases += 1; lifecycle?() }
                let token = OutputScheduler.tokenForTesting()
                let head = "Held current reply."
                let queued = "Queued before failure."
                let subsequent = "Streamed after failure."
                let label = "R4: \(engine) \(change)"
                func require(_ condition: Bool, _ message: String) {
                    if !condition { failures.append("\(label): \(message)") }
                }
                require(session.beginSpokenReply(token), "stream refused")
                session.appendSpokenReply(token, head + " " + queued + " ")
                let heldToken = synth.currentPlaybackToken
                let request = synth.selectedVoiceRequest
                require(heldToken != 0 && synth.pendingClauseCount == 1 && player.submissions.count == 2,
                        "held head/queued production consumer control missing")
                player.deliverPlayed(player.packet(token: heldToken))
                synth.pauseForListening()
                require(session.isSpeaking && synth.isPausedForListening, "speaking/paused control missing")
                if change == "selection" {
                    settings.agentVoiceEngine = engine == "pocket" ? "kokoro" : "pocket"
                } else { await synth.prepareSelectedVoice() }
                let selected = settings.agentVoiceEngine
                require(request != synth.selectedVoiceRequest && synth.availability == .ready,
                        "changed epoch/ready control missing")
                let beforeRelease = releases
                let beforeInvalid = events
                player.fail(heldToken &+ 10_000)
                player.onFailure?("Different current text", 1, heldToken)
                require(events == beforeInvalid && releases == beforeRelease && synth.outputAvailability == nil,
                        "invalid token/text failure admitted")
                // Both real reply backings stop before delivering their held error.
                player.stop()
                player.fail(heldToken)
                require(events.contains(.interrupted(head, wasRendered: true)), "partial receipt missing")
                require(events.contains(.interrupted(queued, wasRendered: false)), "queued unheard receipt missing")
                let state = synth.voiceLifecycleSnapshot
                require(synth.didStop && synth.currentPlaybackToken == 0 && synth.pendingClauseCount == 0
                        && !state.hasClause && !state.rendered && !state.paused && !state.resumePending
                        && state.resumeBinding == nil && !synth.isSpeaking, "failed output lifecycle retained")
                require(releases == beforeRelease + 1, "failure lifecycle release missing")
                require(!session.isSpeaking && session.phase == .listening, "audio speaking state retained")
                require(synth.outputAvailability == .failed, "failed output snapshot missing")
                require(synth.availability == .ready && settings.agentVoiceEngine == selected,
                        "current selected/recovered availability poisoned")
                session.appendSpokenReply(token, subsequent + " ")
                session.finalizeSpokenReply(token)
                require(events.contains(.enqueued(subsequent))
                        && events.contains(.interrupted(subsequent, wasRendered: false)),
                        "subsequent streamed text lacks unheard settlement")
                require(player.submissions.count == 2 && !synth.isSpeaking && synth.pendingClauseCount == 0,
                        "failed reply replayed/submitted more speech")
                let settled = events
                player.fail(heldToken); player.complete(heldToken); synth.resumeAfterListening()
                require(events == settled, "late callback changed settled receipts")
                // The recovered/new selection admits the actual file consumer.
                var entries = 0
                LongFormSynthesisFactory.audioForTesting = { entries += 1; return .init(samples: [0.1], sampleRate: 24_000) }
                do { _ = try await LongFormSynthesisFactory.live()(.init(text: "New selected voice clause", speaker: nil)) }
                catch { failures.append("\(label): new file consumer refused") }
                require(entries == 1 && synth.availability == .ready, "new selected consumer entry missing")
                synth.stop()
                synth.enqueueClause("Discard explicitly stopped text.")
                require(events == settled, "explicit stop admitted later text")
                SelfTest.diagnostic("VOICE_REPLY_EPOCH_CASE engine=\(engine) change=\(change) fixture_assertions=17")
                synth.onPlaybackEvent = listener; synth.onVoiceLifecycleSettled = lifecycle
                session.end()
            }
        }
        return failures
    }
}

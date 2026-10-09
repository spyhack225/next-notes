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
        return failures
    }
}

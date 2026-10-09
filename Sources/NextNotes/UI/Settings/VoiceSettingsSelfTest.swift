import SwiftUI

/// Executes the actual Settings button callbacks with isolated preferences and counted PCM.
/// Cached readiness is substituted; no model is loaded, downloaded or heard.
@MainActor
enum VoiceSettingsSelfTest {
    private enum FixtureFailure: Error { case load }

    static func run() async -> [String] {
        let settings = Settings.shared
        guard SelfTest.isRunning, settings.usesHarnessPreferencesForTesting else {
            return ["isolated preferences required"]
        }
        let voice = AgentSpeechSynthesizer.shared
        let previous = settings.agentVoiceEngine
        let entries = voice.speechSynthesisCallsForTesting
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }
        defer {
            PocketAgentVoice.shared.initializeForTesting = nil
            PocketAgentVoice.shared.warmForTesting = nil
            KokoroAgentVoice.shared.initializeForTesting = nil
            LongFormSynthesisFactory.audioForTesting = nil
            voice.stop(); voice.restoreSystemBacking(); voice.clearVoiceReadinessForTesting()
            settings.agentVoiceEngine = previous
        }
        voice.restoreSystemBacking()
        voice.engineOverrideForTesting = nil
        voice.setVoiceReadinessForTesting(engine: "pocket", ready: true)
        voice.setVoiceReadinessForTesting(engine: "kokoro", ready: true)
        var previewStops = 0
        let section = VoiceSettingsSection(availability: .ready, isPreviewing: false,
                                          togglePreview: {}, stopPreview: { previewStops += 1 },
                                          details: EmptyView())
        for engine in VoiceSettingsSection<EmptyView>.Engine.allCases {
            if engine == .kokoro && !KokoroAgentVoice.isSupportedOS { continue }
            let selection = section.select(engine)
            check(settings.agentVoiceEngine == engine.rawValue, "selection wasn't saved at click")
            await selection?.value
            check(voice.availability == .ready, "cached selection wasn't ready")
            let backing = PCMReceiptSpeechBacking()
            voice.useTestingBacking(backing)
            let text = "Settings playback failure."
            voice.speak(text)
            backing.onFailure?(text, 1, voice.currentPlaybackToken)
            check(voice.availability == .failed, "ready-then-failed control missing: \(engine.rawValue)")
            let failedRequest = voice.selectedVoiceRequest
            await section.retry().value
            check(voice.availability == .ready, "Retry didn't clear cached failure: \(engine.rawValue)")
            check(voice.selectedVoiceRequest != failedRequest, "Retry didn't advance recovery identity")
            check(backing.submissions.count == 1 && !voice.isSpeaking, "Retry replayed the failed answer")
            voice.restoreSystemBacking()
        }
        // Capture an older click, then change the stored choice before its Task enters.
        // Returning to the same engine must still reject the old epoch.
        if KokoroAgentVoice.isSupportedOS {
            settings.agentVoiceEngine = "pocket"
            let oldSelection = section.select(.pocket)
            let oldRetry = section.retry()
            settings.agentVoiceEngine = "kokoro"
            settings.agentVoiceEngine = "pocket"
            voice.setVoiceFailureForTesting(true)
            let newer = voice.selectedVoiceRequest
            await oldSelection?.value
            await oldRetry.value
            check(voice.selectedVoiceRequest == newer && voice.availability == .failed,
                  "stale selection/Retry cleared the newer failure")
            await section.retry().value
            check(voice.availability == .ready, "current Retry didn't recover")
        }
        var unavailable = section
        unavailable.kokoroSupported = false
        let before = voice.selectedVoiceRequest
        check(unavailable.select(.kokoro) == nil && voice.selectedVoiceRequest == before,
              "unavailable Kokoro selection was admitted")
        check(previewStops >= 4, "button actions didn't stop the sample")
        // Exercise cold load failure -> Retry through the actual preparation owners.
        // Only the native initialize/warm boundaries are replaced, never the owners.
        voice.clearVoiceReadinessForTesting()
        for engine in VoiceSettingsSection<EmptyView>.Engine.allCases {
            if engine == .kokoro && !KokoroAgentVoice.isSupportedOS { continue }
            var attempts = 0
            let initialize: @MainActor () async throws -> Void = {
                attempts += 1
                check(voice.availability == .preparing(progress: nil), "owner didn't publish preparing")
                if attempts == 1 { throw FixtureFailure.load }
            }
            if engine == .pocket {
                PocketAgentVoice.shared.initializeForTesting = initialize
                PocketAgentVoice.shared.warmForTesting = {}
            } else {
                KokoroAgentVoice.shared.initializeForTesting = initialize
            }
            await section.select(engine)?.value
            check(attempts == 1 && voice.availability == .failed, "cold load failure control missing")
            await section.retry().value
            check(attempts == 2 && voice.availability == .ready, "Retry didn't re-enter the failed owner")
            var consumerEntries = 0
            LongFormSynthesisFactory.audioForTesting = {
                consumerEntries += 1
                return .init(samples: [0.1], sampleRate: 24_000)
            }
            do { _ = try await LongFormSynthesisFactory.live()(.init(text: "Recovered Settings voice", speaker: nil)) }
            catch { failures.append("recovered voice refused actual file consumer") }
            check(consumerEntries == 1, "recovered voice didn't reach the consumer")
        }
        check(voice.speechSynthesisCallsForTesting == entries, "Settings fixture entered native synthesis")
        return failures
    }
}

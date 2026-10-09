import Foundation

enum SettingsVoicePolicySelfTest {
    @MainActor
    static func run() -> [String] {
        guard SelfTest.isRunning else { return ["voice settings: harness required"] }
        let settings = Settings.shared
        guard settings.usesHarnessPreferencesForTesting else {
            return ["voice settings: actual preference writer is not isolated"]
        }
        let name = "ai.pivotstudio.nextnotes.voice-policy-test." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: name) else { return ["voice settings: isolated defaults unavailable"] }
        defer { defaults.removePersistentDomain(forName: name) }
        var failures: [String] = []
        let prior = settings.agentVoiceEngine
        defer { settings.agentVoiceEngine = prior }
        for (stored, expected) in [(nil, "pocket"), ("apple", "pocket"), ("invalid", "pocket"),
                                   ("", "pocket"), ("pocket", "pocket"), ("kokoro", "kokoro")] as [(String?, String)] {
            if let stored { defaults.set(stored, forKey: "agentVoiceEngine") }
            else { defaults.removeObject(forKey: "agentVoiceEngine") }
            if Settings.initialAgentVoiceEngine(from: defaults) != expected {
                failures.append("voice settings: stored selection was not normalized")
            }
            if defaults.string(forKey: "agentVoiceEngine") != stored {
                failures.append("voice settings: read rewrote stored choice")
            }
            if let stored {
                settings.agentVoiceEngine = stored
                if settings.agentVoiceEngine != expected {
                    failures.append("voice settings: production assignment did not normalize")
                }
            }
        }
        return failures
    }
}

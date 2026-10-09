import Foundation

enum SettingsVoicePolicySelfTest {
    static func run() -> [String] {
        guard SelfTest.isRunning else { return ["voice settings: harness required"] }
        let name = "ai.pivotstudio.nextnotes.voice-policy-test." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: name) else { return ["voice settings: isolated defaults unavailable"] }
        defer { defaults.removePersistentDomain(forName: name) }
        var failures: [String] = []
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
        }
        return failures
    }
}

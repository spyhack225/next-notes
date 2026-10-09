import Foundation

/// Static sink census plus deterministic production-route counters. The legacy
/// Settings catalog and standalone benchmark are explicit, non-playback exceptions.
@MainActor
enum AgentVoicePolicySelfTest {
    static func run() -> [String] {
        guard SelfTest.isRunning else { return ["voice policy: harness required"] }
        var root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while root.path != "/", !FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path) {
            root.deleteLastPathComponent()
        }
        guard root.path != "/" else { return ["voice policy: source tree unavailable; census not run"] }
        let allowed = [
            "Sources/NextNotes/UI/Settings/ModelsSettingsTab.swift": "legacy catalog only, replaced by parallel Settings agent",
            "Tools/tts_benchmark.swift": "historical standalone developer benchmark, never linked into NextNotes"
        ]
        let forbidden = ["AVSpeech" + "Synthesizer", "AVSpeech" + "SynthesisVoice", "AVSpeech" + "Backing"]
        var hits = 0, exceptions = 0, failures: [String] = []
        for folder in ["Sources", "Tools"] {
            guard let entries = FileManager.default.enumerator(at: root.appendingPathComponent(folder),
                includingPropertiesForKeys: nil) else { return ["voice policy: source census unavailable"] }
            for case let url as URL in entries where url.pathExtension == "swift" {
                guard let source = try? String(contentsOf: url, encoding: .utf8) else {
                    failures.append("voice policy: unreadable source"); continue
                }
                let relative = String(url.path.dropFirst(root.path.count + 1))
                let count = source.components(separatedBy: .newlines).filter { line in forbidden.contains { line.contains($0) } }.count
                if allowed[relative] != nil { exceptions += count; continue }
                hits += count
                if count > 0 { failures.append("voice policy: forbidden speech API in " + relative) }
            }
        }
        SelfTest.diagnostic("VOICE_POLICY_SOURCE_COUNTS forbidden=\(hits) explicit_nonplayback_exceptions=\(exceptions)")
        return failures
    }
}

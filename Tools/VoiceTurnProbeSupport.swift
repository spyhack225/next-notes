// Standalone model probe only. Compile with the real ModelDownloader,
// VerifiedModelArtifact, Log, VoiceTurnModels and SmartTurnEndpoint sources.
// No App/Settings/store instances; all paths resolve into the explicit fixture root.
import Foundation

enum SelfTest {
    static let isRunning = true
    static func value(after flag: String) -> String? {
        guard let i = CommandLine.arguments.firstIndex(of: flag), i + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[i + 1]
    }
}
enum AppIdentity {
    static let bundleIdentifier = "ai.pivotstudio.nextnotes.turn-native-probe"
    static var applicationSupportDirectoryURL: URL {
        URL(fileURLWithPath: SelfTest.value(after: "--turn-model-root") ?? "/nonexistent-nextnotes-turn-probe")
    }
    static var applicationSupportDirectory: URL { applicationSupportDirectoryURL }
}
// Only error identities used by the linked (unused here) resumable HTTP path.
enum HuggingFaceError: Error {
    case needsAccessKey
    case accessKeyRejected
    case gated(repoID: String)
}

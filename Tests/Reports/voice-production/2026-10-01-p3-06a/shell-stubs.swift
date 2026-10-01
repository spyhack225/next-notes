import Foundation
import OSLog
struct ActionOriginContext: Codable, Sendable, Hashable {}
enum AgentBackendKind: String, Codable, Sendable { case local }
enum Log { static let agent = Logger(subsystem: "NextNotesFixture", category: "shadow") }
enum SelfTest { @MainActor static var isRunning = true; @MainActor static var failed = false }
@MainActor final class VoiceConversationCoordinator {
    static let shared = VoiceConversationCoordinator()
    var inputPending = false
    var effectHoldEpoch: UInt64?
    var voiceShadowResponseTurn: TurnID?
}
@MainActor final class AgentCaptureController {
    static let shared = AgentCaptureController()
    var isSessionActive = false
    var heardSpeechForTesting = false
    var voiceShadowHasFloor = false
    var voiceShadowQueuedTurn: TurnID?
}
@MainActor final class RealtimeAudioSession {
    static let shared = RealtimeAudioSession()
    var voiceShadowOutputSnapshot: VoiceSessionState.Output?
}
@MainActor final class RealtimeAgent {
    static let shared = RealtimeAgent()
    var voiceInputActive = false
}
@main struct Main { @MainActor static func main() async {
    VoiceSession.shared.send(.sessionOpened(sessionID: UUID()))
    await Task.yield()
    VoiceSession.shared.printDiagnostics()
} }

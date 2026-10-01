import Foundation
struct ActionOriginContext: Codable, Sendable, Hashable {}
enum AgentBackendKind: String, Codable, Sendable { case local }
@main struct Main { static func main() { exit(VoiceSessionReducerSelfTest.runPure() ? 0 : 1) } }

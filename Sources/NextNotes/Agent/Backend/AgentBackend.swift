import Foundation

/// Qwen's BackendPort, as a Swift protocol: start, health, submit, status, cancel,
/// permission/input responses, events, shutdown. Optional behaviour is advertised by
/// `describe()` and refused explicitly — callers never infer support from a missing method.
enum AgentBackendKind: String, Codable, Sendable, CaseIterable {
    case local
    case acp
    case cloud
    case remote

    var displayName: String {
        switch self {
        case .local: "Local Agent"
        case .acp: "Coding Agent (ACP)"
        case .cloud: "Cloud Agent"
        case .remote: "Remote Agent"
        }
    }
}

struct AgentBackendDescription: Sendable {
    var id: String
    var displayName: String
    var capabilities: [String]
}

protocol AgentBackend: Sendable {
    func describe() async -> AgentBackendDescription
    func start() async throws
    func health() async -> String
    func submit(_ task: AgentTask) async throws -> AgentTaskOutcome
    func status(taskID: String) async -> AgentTaskStatus?
    func cancel(taskID: String) async
    func respondPermission(taskID: String, approved: Bool) async
    func respondInput(taskID: String, text: String) async
    func subscribe(_ listener: @escaping @Sendable (AgentBackendEvent) -> Void) async -> UUID
    func unsubscribe(_ token: UUID) async
    func close() async
}

extension AgentBackend {
    func subscribe(_ listener: @escaping @Sendable (AgentBackendEvent) -> Void) async -> UUID { UUID() }
    func unsubscribe(_ token: UUID) async {}
    func close() async {}
}

@MainActor
final class AgentBackendRegistry {
    static let shared = AgentBackendRegistry()

    private let local = LocalAgentBackend()
    private let acp = ACPAgentBackend()

    func backend(named name: String) -> any AgentBackend {
        switch AgentBackendKind(rawValue: name) {
        case .acp: acp
        case .cloud, .remote, .local, .none: local
        }
    }

    var preferred: any AgentBackend {
        backend(named: Settings.shared.agentBackend.rawValue)
    }
}

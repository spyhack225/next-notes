import Foundation

enum AgentTaskStatus: String, Codable, Sendable, CaseIterable {
    case queued
    case running
    case waitingForPermission
    case waitingForInput
    case completed
    case failed
    case cancelled
}

/// A unit of background work. The conversational agent sees status and a result, not the
/// backend's execution graph — the Qwen Task record, in Swift.
struct AgentTask: Identifiable, Sendable, Equatable, Codable {
    var id: String
    var objective: String
    var source: String
    var createdAt: Date
    var contextReferences: [String]
    var status: AgentTaskStatus
    var progress: String
    var result: String?
    var artifacts: [String]
    var tool: String?
    var arguments: [String: String]
    var meetingID: UUID?
    var backend: String
    var failure: String?
    var acpCLI: String

    init(
        id: String = UUID().uuidString,
        objective: String,
        source: String = "user",
        createdAt: Date = Date(),
        contextReferences: [String] = [],
        status: AgentTaskStatus = .queued,
        progress: String = "",
        result: String? = nil,
        artifacts: [String] = [],
        tool: String? = nil,
        arguments: [String: String] = [:],
        meetingID: UUID? = nil,
        backend: String = "local",
        failure: String? = nil,
        acpCLI: String = ""
    ) {
        self.id = id
        self.objective = objective
        self.source = source
        self.createdAt = createdAt
        self.contextReferences = contextReferences
        self.status = status
        self.progress = progress
        self.result = result
        self.artifacts = artifacts
        self.tool = tool
        self.arguments = arguments
        self.meetingID = meetingID
        self.backend = backend
        self.failure = failure
        self.acpCLI = acpCLI
    }

    enum CodingKeys: String, CodingKey {
        case id, objective, source, createdAt, contextReferences, status, progress
        case result, artifacts, tool, arguments, meetingID, backend, failure, acpCLI
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        objective = try container.decode(String.self, forKey: .objective)
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? "user"
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        contextReferences = try container.decodeIfPresent([String].self, forKey: .contextReferences) ?? []
        status = try container.decodeIfPresent(AgentTaskStatus.self, forKey: .status) ?? .queued
        progress = try container.decodeIfPresent(String.self, forKey: .progress) ?? ""
        result = try container.decodeIfPresent(String.self, forKey: .result)
        artifacts = try container.decodeIfPresent([String].self, forKey: .artifacts) ?? []
        tool = try container.decodeIfPresent(String.self, forKey: .tool)
        arguments = try container.decodeIfPresent([String: String].self, forKey: .arguments) ?? [:]
        meetingID = try container.decodeIfPresent(UUID.self, forKey: .meetingID)
        backend = try container.decodeIfPresent(String.self, forKey: .backend) ?? "local"
        failure = try container.decodeIfPresent(String.self, forKey: .failure)
        acpCLI = try container.decodeIfPresent(String.self, forKey: .acpCLI) ?? ""
    }
}

enum AgentContextReference {
    static let currentMeeting = "meeting://current"
    static let activeWindow = "window://active"
    static let currentSelection = "selection://current"
    static let currentFile = "file://current"
    static let activeProject = "project://active"
}

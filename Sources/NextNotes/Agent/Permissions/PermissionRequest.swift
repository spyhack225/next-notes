import Foundation

/// A mutating tool is waiting for a person. The island, the Agent tab and a notification
/// all show the same request.
struct PermissionRequest: Identifiable, Sendable, Equatable, Codable {
    let id: String
    let toolID: String
    let title: String
    let detail: String
    let risk: AgentRisk
    let arguments: [String: String]
    var scope: PermissionScope
    var meetingID: UUID?
    var taskID: String?
    var createdAt: Date

    init(
        id: String = UUID().uuidString,
        toolID: String,
        title: String,
        detail: String,
        risk: AgentRisk,
        arguments: [String: String],
        scope: PermissionScope = .any,
        meetingID: UUID? = nil,
        taskID: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.toolID = toolID
        self.title = title
        self.detail = detail
        self.risk = risk
        self.arguments = arguments
        self.scope = scope
        self.meetingID = meetingID
        self.taskID = taskID
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, toolID, title, detail, risk, arguments, scope, meetingID, taskID, createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        toolID = try container.decode(String.self, forKey: .toolID)
        title = try container.decode(String.self, forKey: .title)
        detail = try container.decode(String.self, forKey: .detail)
        risk = try container.decode(AgentRisk.self, forKey: .risk)
        arguments = try container.decode([String: String].self, forKey: .arguments)
        scope = try container.decodeIfPresent(PermissionScope.self, forKey: .scope) ?? .any
        meetingID = try container.decodeIfPresent(UUID.self, forKey: .meetingID)
        taskID = try container.decodeIfPresent(String.self, forKey: .taskID)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(toolID, forKey: .toolID)
        try container.encode(title, forKey: .title)
        try container.encode(detail, forKey: .detail)
        try container.encode(risk, forKey: .risk)
        try container.encode(arguments, forKey: .arguments)
        try container.encode(scope, forKey: .scope)
        try container.encodeIfPresent(meetingID, forKey: .meetingID)
        try container.encodeIfPresent(taskID, forKey: .taskID)
        try container.encode(createdAt, forKey: .createdAt)
    }
}

enum PermissionDecision: Sendable, Equatable {
    case allow
    case ask(PermissionRequest)
    case deny(String)
}

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
        self.meetingID = meetingID
        self.taskID = taskID
        self.createdAt = createdAt
    }
}

enum PermissionDecision: Sendable, Equatable {
    case allow
    case ask(PermissionRequest)
    case deny(String)
}

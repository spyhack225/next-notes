import Foundation

enum AgentActivityKind: String, Codable, Sendable, CaseIterable {
    case thinking
    case searching
    case reading
    case writing
    case executing
    case waiting
    case completed
}

/// Generic activity the island can show without leaking chain-of-thought.
struct AgentActivity: Identifiable, Sendable, Equatable, Codable {
    var id: String
    var taskID: String?
    var kind: AgentActivityKind
    var title: String
    var detail: String
    var progress: Double?
    var createdAt: Date

    init(
        id: String = UUID().uuidString,
        taskID: String? = nil,
        kind: AgentActivityKind,
        title: String,
        detail: String = "",
        progress: Double? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.taskID = taskID
        self.kind = kind
        self.title = title
        self.detail = detail
        self.progress = progress
        self.createdAt = createdAt
    }
}

struct AgentAuditEntry: Identifiable, Sendable, Equatable, Codable {
    enum Kind: String, Codable, Sendable {
        case tool
        case permission
        case task
        case wake
        case reply
    }

    var id: String
    var at: Date
    var kind: Kind
    var title: String
    var detail: String
    var toolID: String?
    var taskID: String?
    var meetingID: UUID?

    init(
        id: String = UUID().uuidString,
        at: Date = Date(),
        kind: Kind,
        title: String,
        detail: String = "",
        toolID: String? = nil,
        taskID: String? = nil,
        meetingID: UUID? = nil
    ) {
        self.id = id
        self.at = at
        self.kind = kind
        self.title = title
        self.detail = detail
        self.toolID = toolID
        self.taskID = taskID
        self.meetingID = meetingID
    }
}

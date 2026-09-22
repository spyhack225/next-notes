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
        /// A calibration attempt (or live window) where the configured listener did
        /// not fire. Written by `WakeWordTelemetry.recordMiss` beside `kind: "wake"`,
        /// so the D7 tally reads misses off-device from `agent-audit.jsonl`.
        case wakeMiss
        /// A wake that fired on speech the user disowned ("That wasn't for you").
        /// Written by `WakeWordTelemetry.recordFalseAccept`; the island button that
        /// produces it is owned by the surface agent (see the hook spec).
        case wakeFalse
        case request
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
    /// The routine behind a scheduled run's entries (Part 3). Absent on older lines.
    var scheduleID: UUID?

    init(
        id: String = UUID().uuidString,
        at: Date = Date(),
        kind: Kind,
        title: String,
        detail: String = "",
        toolID: String? = nil,
        taskID: String? = nil,
        meetingID: UUID? = nil,
        scheduleID: UUID? = nil
    ) {
        self.scheduleID = scheduleID
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

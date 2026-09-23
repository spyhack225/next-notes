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
    /// The sentence that caused an approval (P0-4): the trigger's own quote, kept so the
    /// audit row can be read against what the person actually said. Nil when nothing was
    /// quotable — an unattributed call quotes nothing, and nothing is invented for it.
    var triggerQuote: String?

    init(
        id: String = UUID().uuidString,
        at: Date = Date(),
        kind: Kind,
        title: String,
        detail: String = "",
        toolID: String? = nil,
        taskID: String? = nil,
        meetingID: UUID? = nil,
        scheduleID: UUID? = nil,
        triggerQuote: String? = nil
    ) {
        self.scheduleID = scheduleID
        self.triggerQuote = triggerQuote
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

extension AgentAuditEntry {
    /// Hand-written decode, like every store the app keeps on disk for years. Swift's
    /// synthesized `init(from:)` does not fall back to a default for a missing key, so a
    /// field added later would strand every line `agent-audit.jsonl` already holds — and
    /// `load` drops undecodable rows silently, which is the worst failure of all: the
    /// history would quietly become empty.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        at = try container.decode(Date.self, forKey: .at)
        kind = try container.decode(Kind.self, forKey: .kind)
        title = try container.decode(String.self, forKey: .title)
        detail = try container.decodeIfPresent(String.self, forKey: .detail) ?? ""
        toolID = try container.decodeIfPresent(String.self, forKey: .toolID)
        taskID = try container.decodeIfPresent(String.self, forKey: .taskID)
        meetingID = try container.decodeIfPresent(UUID.self, forKey: .meetingID)
        scheduleID = try container.decodeIfPresent(UUID.self, forKey: .scheduleID)
        triggerQuote = try container.decodeIfPresent(String.self, forKey: .triggerQuote)
    }
}

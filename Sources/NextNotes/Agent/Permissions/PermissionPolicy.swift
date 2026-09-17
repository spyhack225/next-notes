import Foundation

/// How long a "yes" lasts, once a person has given it.
enum PermissionDuration: String, Codable, Sendable, CaseIterable {
    case once
    case thisTask
    case thisMeeting
    case alwaysThisAction

    var displayName: String {
        switch self {
        case .once: "Allow once"
        case .thisTask: "Allow for this task"
        case .thisMeeting: "Allow for this meeting"
        case .alwaysThisAction: "Always allow this action"
        }
    }
}

/// What a person has already agreed to, persisted so a second identical ask in the same
/// meeting does not raise the same card.
struct PermissionGrant: Sendable, Equatable, Codable, Identifiable {
    var id: String
    var toolID: String
    var duration: PermissionDuration
    var scope: PermissionScope
    var meetingID: UUID?
    var taskID: String?
    var createdAt: Date

    init(
        id: String = UUID().uuidString,
        toolID: String,
        duration: PermissionDuration,
        scope: PermissionScope = .any,
        meetingID: UUID? = nil,
        taskID: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.toolID = toolID
        self.duration = duration
        self.scope = scope
        self.meetingID = meetingID
        self.taskID = taskID
        self.createdAt = createdAt
    }

    enum CodingKeys: String, CodingKey {
        case id, toolID, duration, scope, meetingID, taskID, createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        toolID = try container.decode(String.self, forKey: .toolID)
        duration = try container.decode(PermissionDuration.self, forKey: .duration)
        scope = try container.decodeIfPresent(PermissionScope.self, forKey: .scope) ?? .any
        meetingID = try container.decodeIfPresent(UUID.self, forKey: .meetingID)
        taskID = try container.decodeIfPresent(String.self, forKey: .taskID)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(toolID, forKey: .toolID)
        try container.encode(duration, forKey: .duration)
        try container.encode(scope, forKey: .scope)
        try container.encodeIfPresent(meetingID, forKey: .meetingID)
        try container.encodeIfPresent(taskID, forKey: .taskID)
        try container.encode(createdAt, forKey: .createdAt)
    }
}

/// The user's standing answers, read from Settings rather than invented per tool.
struct PermissionPolicy: Sendable {
    var autoObserve = true
    var autoRead = true
    var autoSearchFiles = false
    var autoComputerControl = false
    var grants: [PermissionGrant] = []

    @MainActor
    static func fromSettings() -> PermissionPolicy {
        PermissionPolicy(
            autoObserve: true,
            autoRead: Settings.shared.agentAutoRunReadTools,
            autoSearchFiles: Settings.shared.agentAutoSearchFiles,
            autoComputerControl: Settings.shared.agentAllowComputerControl,
            grants: PermissionGrantStore.shared.grants
        )
    }

    /// `--selftest-tools` / `--selftest-permissions`: nothing auto-runs, nothing is granted.
    static let denyMutations = PermissionPolicy(autoObserve: true, autoRead: false, autoSearchFiles: false)

    /// Self-tests that must actually run a read/search/click on a window this process owns.
    static let selfTest = PermissionPolicy(
        autoObserve: true,
        autoRead: true,
        autoSearchFiles: true,
        autoComputerControl: true
    )

    /// - Parameter authority: who supplied the authority for this call. Only the `memory`
    ///   namespace looks at it: memory writes save without a prompt (decision 1), but only
    ///   under the user's own conversation or the memory review. Every other tool ignores it.
    func allowsAutomatically(_ tool: AgentTool, authority: ActionAuthority? = nil) -> Bool {
        if tool.namespace == .memory, tool.risk == .modify {
            return authority == .user || authority == .memoryReview
        }
        switch tool.risk {
        case .observe:
            return autoObserve
        case .read:
            if tool.namespace == .filesystem { return autoSearchFiles }
            return autoRead
        case .modify:
            return tool.namespace == .computer && autoComputerControl
        case .write, .send, .destructive, .privileged:
            return false
        }
    }

    func existingGrant(
        for toolID: String,
        scope: PermissionScope = .any,
        meetingID: UUID?,
        taskID: String?
    ) -> PermissionGrant? {
        grants.first { grant in
            grant.toolID == toolID
                && grant.scope.covers(scope)
                && (grant.duration == .once || grant.covers(meetingID: meetingID, taskID: taskID))
        }
    }
}

extension PermissionGrant {
    func covers(meetingID: UUID?, taskID: String?) -> Bool {
        switch duration {
        case .once:
            return false
        case .thisTask:
            return taskID != nil && self.taskID == taskID
        case .thisMeeting:
            return meetingID != nil && self.meetingID == meetingID
        case .alwaysThisAction:
            return true
        }
    }
}

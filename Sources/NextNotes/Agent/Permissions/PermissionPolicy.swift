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
    var meetingID: UUID?
    var taskID: String?
    var createdAt: Date

    init(
        id: String = UUID().uuidString,
        toolID: String,
        duration: PermissionDuration,
        meetingID: UUID? = nil,
        taskID: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.toolID = toolID
        self.duration = duration
        self.meetingID = meetingID
        self.taskID = taskID
        self.createdAt = createdAt
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

    func allowsAutomatically(_ tool: AgentTool) -> Bool {
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

    func existingGrant(for toolID: String, meetingID: UUID?, taskID: String?) -> PermissionGrant? {
        grants.first { grant in
            grant.toolID == toolID && (
                grant.duration == .once || grant.covers(meetingID: meetingID, taskID: taskID)
            )
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

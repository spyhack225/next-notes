import Foundation

enum AgentTaskStatus: String, Codable, Sendable, CaseIterable {
    case queued
    case running
    case waitingForPermission
    /// ACP could not complete its protocol handshake. The task is parked until the
    /// person explicitly chooses the weaker, one-shot compatibility CLI path.
    case waitingForCompatibilityCLI
    case waitingForInput
    case completed
    case failed
    case cancelled

    /// Consumer state words (§8.3 naming map). "Task · WaitingForPermission" is
    /// machinery reaching the screen; "Waiting for you" is the state.
    var humanState: String {
        switch self {
        case .queued: "Ready"
        case .running: "Working"
        case .waitingForPermission: "Waiting for you"
        case .waitingForCompatibilityCLI: "Needs approval"
        case .waitingForInput: "Waiting for your answer"
        case .completed: "Done"
        case .failed: "Didn\u{2019}t work"
        case .cancelled: "Stopped"
        }
    }
}

/// A unit of background work. The conversational agent sees status and a result, not the
/// backend's execution graph — the local model Task record, in Swift.
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
    /// Frozen at the ACP failure so the review card can show precisely what a one-shot
    /// compatibility run would execute, even after a relaunch or settings change.
    var compatibilityCommand: String?
    var compatibilityCLI: String?
    var compatibilityDirectory: String?
    /// The routine a `"scheduled"` task ran for (Part 3).
    var scheduleID: UUID?

    static let scheduledSource = "scheduled"

    /// Whether creating this task was the user's own explicit action, which an ACP backend
    /// may treat as approval to start the session. Named sources, not "anything but a
    /// meeting": a scheduled run has nobody present, and a source added later must not
    /// inherit approval by default.
    var isUserInitiated: Bool {
        scheduleID == nil && ["user", "voice", "text", "selftest"].contains(source)
    }

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
        acpCLI: String = "",
        compatibilityCommand: String? = nil,
        compatibilityCLI: String? = nil,
        compatibilityDirectory: String? = nil,
        scheduleID: UUID? = nil
    ) {
        self.scheduleID = scheduleID
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
        self.compatibilityCommand = compatibilityCommand
        self.compatibilityCLI = compatibilityCLI
        self.compatibilityDirectory = compatibilityDirectory
    }

    enum CodingKeys: String, CodingKey {
        case id, objective, source, createdAt, contextReferences, status, progress
        case result, artifacts, tool, arguments, meetingID, backend, failure, acpCLI
        case compatibilityCommand, compatibilityCLI, compatibilityDirectory, scheduleID
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
        compatibilityCommand = try container.decodeIfPresent(String.self, forKey: .compatibilityCommand)
        compatibilityCLI = try container.decodeIfPresent(String.self, forKey: .compatibilityCLI)
        compatibilityDirectory = try container.decodeIfPresent(String.self, forKey: .compatibilityDirectory)
        scheduleID = try container.decodeIfPresent(UUID.self, forKey: .scheduleID)
    }
}

enum AgentContextReference {
    static let currentMeeting = "meeting://current"
    static let activeWindow = "window://active"
    static let currentSelection = "selection://current"
    static let currentFile = "file://current"
    static let activeProject = "project://active"
}

extension AgentTask {
    /// The failure card's first line: what did and did not happen (§8.2). The failure
    /// string itself is the "what went wrong" half; this adds the "what did not happen"
    /// half so the card is never a bare error.
    var failureSummary: String {
        let reason = (failure ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if artifacts.isEmpty {
            return reason.isEmpty
                ? "Nothing was created or sent."
                : "\(reason) Nothing was created or sent."
        }
        return reason.isEmpty
            ? "Something I was making did not finish."
            : reason
    }

    /// The explicit undo line. A failed run that wrote nothing is the common case and
    /// says so by name — "nothing to undo" is the honest answer, and silence here is
    /// what leaves a person hunting for a bag to empty.
    var failureUndoLine: String {
        if artifacts.isEmpty {
            return "Nothing was added anywhere, so nothing to undo."
        }
        return "Nothing was undone \u{2014} what I made is below."
    }
}

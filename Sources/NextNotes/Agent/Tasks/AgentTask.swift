import Foundation

enum AgentTaskStatus: String, Codable, Sendable, CaseIterable {
    case queued
    case running
    /// A launch-only held decision. No worker was reattached or started.
    case recovering
    case waitingForPermission
    /// ACP could not complete its protocol handshake. The task is parked until the
    /// person explicitly chooses the weaker, one-shot compatibility CLI path.
    case waitingForCompatibilityCLI
    case waitingForInput
    case completed
    case failed
    case cancelled

    var isTerminal: Bool { self == .completed || self == .failed || self == .cancelled }

    /// A stored running snapshot does not reveal delegated/finalizing/cancelling.
    /// Recovering remains a launch-held unknown, never reconstructed as active work.
    var contractState: TaskState? {
        switch self {
        case .queued: .queued
        case .running: .running
        case .waitingForInput: .needsInput
        case .waitingForPermission, .waitingForCompatibilityCLI: .needsPermission
        case .completed: .completed
        case .failed: .failed
        case .cancelled: .cancelled
        case .recovering: nil
        }
    }

    /// Consumer state words (§8.3 naming map). "Task · WaitingForPermission" is
    /// machinery reaching the screen; "Waiting for you" is the state.
    var humanState: String {
        switch self {
        case .queued: "Ready"
        case .running: "Working"
        case .recovering: "Paused after restart"
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
    /// Producer-supplied ownership metadata. Absent legacy values remain unknown;
    /// neither a source label nor a backend reconstructs a session or grant.
    var origin: TaskOrigin?
    /// Positive authored voice provenance only; legacy source strings confer no authority.
    var hasVoiceOrigin: Bool {
        guard source == "voice", scheduleID == nil,
              case .voice(_, let turn)? = origin else { return false }
        return turn.raw > 0
    }
    var userWords: String?
    /// Only owned encoding3 carries a live voice revision; legacy projects zero.
    var revision: Int
    var startedAt: Date?
    var finishedAt: Date?
    /// Delivery facts in the SAME task row; nil is historical/unknown.
    var delivery: TaskDelivery?
    var deliveryAttempts: Int
    var createdAt: Date
    var contextReferences: [String]
    var status: AgentTaskStatus
    var progress: String
    var result: String?
    var artifactRecords: [AgentArtifact]
    /// Compatibility view of the single canonical collection, not a second list.
    var artifacts: [String] {
        get { artifactRecords.map(\.value) }
        set { artifactRecords = AgentArtifact.replacingValues(newValue, in: artifactRecords) }
    }
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
    /// Absent on older history. Storage alone never grants recovery or retry authority.
    var durability: TaskDurability?
    /// Exact unanswered payload, written by its producer before a card is raised.
    var pendingInteraction: TaskPendingInteraction?

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
        scheduleID: UUID? = nil,
        durability: TaskDurability? = nil,
        pendingInteraction: TaskPendingInteraction? = nil,
        origin: TaskOrigin? = nil,
        userWords: String? = nil,
        revision: Int = 0,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        delivery: TaskDelivery? = nil, deliveryAttempts: Int = 0
    ) {
        self.origin = origin
        self.userWords = userWords
        self.revision = revision
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.delivery = delivery
        self.deliveryAttempts = deliveryAttempts
        self.scheduleID = scheduleID
        self.durability = durability
        self.pendingInteraction = pendingInteraction
        self.id = id
        self.objective = objective
        self.source = source
        self.createdAt = createdAt
        self.contextReferences = contextReferences
        self.status = status
        self.progress = progress
        self.result = result
        self.artifactRecords = artifacts.map { AgentArtifact($0) }
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
        case id, objective, source, origin, userWords, revision, startedAt, finishedAt, delivery, deliveryAttempts, createdAt, contextReferences, status, progress
        case result, artifacts, artifactRecords, tool, arguments, meetingID, backend, failure, acpCLI
        case compatibilityCommand, compatibilityCLI, compatibilityDirectory, scheduleID, durability, pendingInteraction
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        objective = try container.decode(String.self, forKey: .objective)
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? "user"
        origin = try container.decodeIfPresent(TaskOrigin.self, forKey: .origin)
        userWords = try container.decodeIfPresent(String.self, forKey: .userWords)
        revision = try container.decodeIfPresent(Int.self, forKey: .revision) ?? 0
        guard revision >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .revision, in: container, debugDescription: "Invalid work revision")
        }
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
        delivery = try container.decodeIfPresent(TaskDelivery.self, forKey: .delivery)
        deliveryAttempts = try container.decodeIfPresent(Int.self, forKey: .deliveryAttempts) ?? 0
        guard deliveryAttempts >= 0 else {
            throw DecodingError.dataCorruptedError(forKey: .deliveryAttempts, in: container, debugDescription: "Invalid delivery count")
        }
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        contextReferences = try container.decodeIfPresent([String].self, forKey: .contextReferences) ?? []
        status = try container.decodeIfPresent(AgentTaskStatus.self, forKey: .status) ?? .queued
        progress = try container.decodeIfPresent(String.self, forKey: .progress) ?? ""
        result = try container.decodeIfPresent(String.self, forKey: .result)
        let values = try container.decodeIfPresent([String].self, forKey: .artifacts) ?? []
        let records = try container.decodeIfPresent([AgentArtifact].self, forKey: .artifactRecords)
        guard records == nil || records?.map(\.value) == values else {
            throw DecodingError.dataCorruptedError(forKey: .artifactRecords, in: container,
                debugDescription: "Artifact metadata does not match the ordered values")
        }
        artifactRecords = records ?? values.map { AgentArtifact($0) }
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
        durability = try container.decodeIfPresent(TaskDurability.self, forKey: .durability)
        pendingInteraction = try container.decodeIfPresent(TaskPendingInteraction.self, forKey: .pendingInteraction)
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(objective, forKey: .objective)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(origin, forKey: .origin)
        try container.encodeIfPresent(userWords, forKey: .userWords)
        if revision != 0 { try container.encode(revision, forKey: .revision) }
        try container.encodeIfPresent(startedAt, forKey: .startedAt)
        try container.encodeIfPresent(finishedAt, forKey: .finishedAt)
        try container.encodeIfPresent(delivery, forKey: .delivery)
        if delivery != nil || deliveryAttempts != 0 { try container.encode(deliveryAttempts, forKey: .deliveryAttempts) }
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(contextReferences, forKey: .contextReferences)
        try container.encode(status, forKey: .status)
        try container.encode(progress, forKey: .progress)
        try container.encode(arguments, forKey: .arguments)
        try container.encode(backend, forKey: .backend)
        try container.encode(acpCLI, forKey: .acpCLI)
        try container.encodeIfPresent(result, forKey: .result)
        try container.encodeIfPresent(tool, forKey: .tool)
        try container.encodeIfPresent(meetingID, forKey: .meetingID)
        try container.encodeIfPresent(failure, forKey: .failure)
        try container.encodeIfPresent(compatibilityCommand, forKey: .compatibilityCommand)
        try container.encodeIfPresent(compatibilityCLI, forKey: .compatibilityCLI)
        try container.encodeIfPresent(compatibilityDirectory, forKey: .compatibilityDirectory)
        try container.encodeIfPresent(scheduleID, forKey: .scheduleID)
        try container.encodeIfPresent(durability, forKey: .durability)
        try container.encodeIfPresent(pendingInteraction, forKey: .pendingInteraction)
        try container.encode(artifacts, forKey: .artifacts)
        if artifactRecords.contains(where: { !$0.isLegacy }) {
            try container.encode(artifactRecords, forKey: .artifactRecords)
        }
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
    /// History records results, not complete effect receipts. Missing links cannot
    /// prove that nothing changed before failure or interruption.
    var failureSummary: String {
        let reason = (failure ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return reason.isEmpty ? "This task did not finish." : reason
    }

    /// No undo outcome is inferred from the artifact list.
    var failureUndoLine: String {
        "Review any changes before trying again."
    }
}

/// The existing permission value retains its exact tool, arguments, scope, trigger
/// and identity. The task's source remains the origin owner; a snapshot is never a
/// grant or proof that an interrupted worker can be reattached.
enum TaskPendingInteraction: Codable, Equatable, Sendable {
    case permission(request: PermissionRequest, origin: ActionOriginContext?, review: ToolCallReview? = nil)
    case input(TaskInputRequest)
}

struct TaskInputRequest: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let taskID: String
    let question: String
    let createdAt: Date
    /// An unanswered field is bound to its original tool/schema key. Older question-only
    /// payloads decode with nil bindings and remain visible without authorizing a retry.
    let toolID: String?
    let argumentName: String?

    init(id: String = UUID().uuidString, taskID: String, question: String, createdAt: Date = Date(),
         toolID: String? = nil, argumentName: String? = nil) {
        self.id = id
        self.taskID = taskID
        self.question = question
        self.createdAt = createdAt
        self.toolID = toolID
        self.argumentName = argumentName
    }
}

import Foundation

enum TaskResumePolicy: String, Codable, Sendable {
    case retry, resumeFromCheckpoint, verifyThenDecide, neverAuto
}

enum TaskRuntimeClass: String, Codable, Sendable {
    case localDeterministic, cloudModel, browserOrMCP, acpWorker, scheduledResearch, waitingOnPerson
}

/// Exact in-process handle binding captured at admitted typed-local start.
/// Presence records ownership metadata, never health or safe-to-retry authority.
struct TaskWorkerBinding: Equatable, Sendable {
    let taskID: String
    let attempt: Int
    let leaseOwner: String
    let startedAt: Date
}

/// A point-in-time result of the existing authority-bound primary row check.
/// Missing evidence is unknown; no health, effect or retry inference follows.
enum TaskWorkerPrimaryOutcome: String, Sendable { case accepted, mismatch, unavailable }

struct TaskWorkerPrimaryObservation: Equatable, Sendable {
    let expected: TaskWorkerWriteCondition
    let outcome: TaskWorkerPrimaryOutcome
    let observedAt: Date
    let state: AgentTaskStatus?
    let durability: TaskDurability?
}

/// LAST exact tool boundary, not complete per-worker active-call coverage.
/// Absence/return supplies no effect, health, cessation or retry authority.
enum TaskWorkerToolBackingState: String, Sendable {
    case entryAdmitted, backingReturned, backingThrew
}

struct TaskWorkerToolBackingObservation: Equatable, Sendable {
    let binding: TaskWorkerBinding
    let receiptID: UUID
    let toolID: String
    let state: TaskWorkerToolBackingState
}

/// Persisted optional execution metadata. Typed-local producers bind positive attempts
/// and admitted worker/tool progress; other owners remain explicitly unbound.
/// These fields alone authorize no recovery, retry or remote worker.
struct TaskDurability: Codable, Sendable, Equatable {
    var heartbeatAt: Date? = nil
    var attempt = 0
    var retryCount = 0
    var maxRetries = 0
    var lastProgressAt: Date? = nil
    var resumePolicy: TaskResumePolicy = .neverAuto
    var leaseOwner: String? = nil
    var runtimeClass: TaskRuntimeClass = .waitingOnPerson
    var receiptIDs: [String] = []
    /// The existing AgentTask string identity; no second id namespace.
    var parentTaskID: String? = nil
    var attemptStartedAt: Date? = nil
    var terminalReason: String? = nil

    /// Recognize admitted or damaged worker history without making its runtime
    /// classification an execution grant. Legacy metadata without worker identity stays unbound;
    /// a backend independently refuses every positive attempt lacking live validity.
    var hasTypedLocalAttemptRecord: Bool {
        attempt > 0 && (attemptStartedAt != nil || leaseOwner != nil || runtimeClass != .waitingOnPerson)
    }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case heartbeatAt, attempt, retryCount, maxRetries, lastProgressAt, resumePolicy
        case leaseOwner, runtimeClass, receiptIDs, parentTaskID, attemptStartedAt, terminalReason
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        heartbeatAt = try c.decodeIfPresent(Date.self, forKey: .heartbeatAt)
        attempt = try c.decodeIfPresent(Int.self, forKey: .attempt) ?? 0
        retryCount = try c.decodeIfPresent(Int.self, forKey: .retryCount) ?? 0
        maxRetries = try c.decodeIfPresent(Int.self, forKey: .maxRetries) ?? 0
        lastProgressAt = try c.decodeIfPresent(Date.self, forKey: .lastProgressAt)
        resumePolicy = try c.decodeIfPresent(TaskResumePolicy.self, forKey: .resumePolicy) ?? .neverAuto
        leaseOwner = try c.decodeIfPresent(String.self, forKey: .leaseOwner)
        runtimeClass = try c.decodeIfPresent(TaskRuntimeClass.self, forKey: .runtimeClass) ?? .waitingOnPerson
        receiptIDs = try c.decodeIfPresent([String].self, forKey: .receiptIDs) ?? []
        parentTaskID = try c.decodeIfPresent(String.self, forKey: .parentTaskID)
        attemptStartedAt = try c.decodeIfPresent(Date.self, forKey: .attemptStartedAt)
        terminalReason = try c.decodeIfPresent(String.self, forKey: .terminalReason)
    }
}

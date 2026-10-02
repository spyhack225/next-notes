import Foundation

enum TaskResumePolicy: String, Codable, Sendable {
    case retry, resumeFromCheckpoint, verifyThenDecide, neverAuto
}

enum TaskRuntimeClass: String, Codable, Sendable {
    case localDeterministic, cloudModel, browserOrMCP, acpWorker, scheduledResearch, waitingOnPerson
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

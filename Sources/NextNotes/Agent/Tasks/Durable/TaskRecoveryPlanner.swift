import Foundation

/// This foundation deliberately has no action that can start or reconnect a worker.
/// Actual attempt/lease/receipt producers and fencing are P6-05/P6-06 prerequisites.
enum TaskRecoveryAction: Sendable, Equatable {
    case noAction
    case restoreCard
    case reportFailed
    case holdForReview
}

struct TaskRecoveryPlan: Sendable, Equatable {
    let action: TaskRecoveryAction
    let reason: String
}

enum TaskRecoveryJournalCoverage: Sendable { case unknown, partial, complete }
enum TaskRecoveryEffectObservation: Sendable {
    case unknown, verifiedNotStarted, inFlight, completed, failed, outcomeUnknown
}
enum TaskRecoveryLeaseObservation: Sendable {
    case unknown, invalid, alive, possiblyAlive, gone
}
enum TaskRecoveryCheckpointObservation: Sendable { case unavailable, validated }

/// Observations are supplied by the caller; rows/ids do not prove complete history.
/// `possiblyAlive` includes EPERM. A completed artifact is not a checkpoint.
struct TaskRecoveryInput: Sendable {
    var task: AgentTask
    let now: Date
    var journalCoverage: TaskRecoveryJournalCoverage = .unknown
    var effect: TaskRecoveryEffectObservation = .unknown
    var observedReceiptIDs: [String] = []
    var lease: TaskRecoveryLeaseObservation = .unknown
    var checkpoint: TaskRecoveryCheckpointObservation = .unavailable
}

enum TaskRecoveryPlanner {
    /// Pure: no disk, process probe, clock read, model or backend dispatch.
    static func plan(_ input: TaskRecoveryInput) -> TaskRecoveryPlan {
        let task = input.task
        switch task.status {
        case .completed:
            return TaskRecoveryPlan(action: .noAction, reason: "This task is already done. Its history stays unchanged.")
        case .failed:
            return TaskRecoveryPlan(action: .noAction, reason: "This task already failed. Its history stays unchanged.")
        case .cancelled:
            return TaskRecoveryPlan(action: .noAction, reason: "This task was already stopped. Its history stays unchanged.")
        case .waitingForInput:
            return TaskRecoveryPlan(action: .restoreCard, reason: "This task is still waiting for your answer.")
        case .waitingForPermission:
            return TaskRecoveryPlan(action: .restoreCard, reason: "This task is still waiting for your approval. A previous one-time approval is not reused.")
        case .waitingForCompatibilityCLI:
            return TaskRecoveryPlan(action: .restoreCard, reason: "Compatibility mode still needs your one-time approval. It has not been started again.")
        case .queued:
            return TaskRecoveryPlan(action: .reportFailed, reason: "This task was waiting to start when Next Notes quit. I cannot verify that it is safe to run again.")
        case .running:
            return held(input)
        case .recovering:
            return TaskRecoveryPlan(action: .holdForReview, reason: "This task remains paused after restart. Nothing is being started again.")
        }
    }

    private static func held(_ input: TaskRecoveryInput) -> TaskRecoveryPlan {
        let task = input.task
        if task.source == "voice" {
            return hold("This voice task remains paused. Its conversation owner must decide what happens next.")
        }
        if task.source == AgentTask.scheduledSource || task.scheduleID != nil {
            return hold("This scheduled task remains paused. Its routine owner must decide what happens next.")
        }
        if task.backend == "remote" {
            return hold("This remote task remains paused. Its owner must decide what happens next.")
        }
        if !(task.durability?.receiptIDs.isEmpty ?? true) || !input.observedReceiptIDs.isEmpty {
            return hold("A saved action receipt needs checking before this interrupted task can continue.")
        }
        switch input.effect {
        case .inFlight, .outcomeUnknown:
            return hold("An action may already have happened. This interrupted task stays paused until its outcome is checked.")
        case .completed, .failed:
            return hold("An action outcome was recorded. This interrupted task stays paused until that outcome is checked.")
        case .unknown, .verifiedNotStarted: break
        }
        guard let durability = task.durability, durability.attempt > 0,
              durability.attemptStartedAt != nil else {
            return hold("This interrupted task has no verified execution attempt. It stays paused.")
        }
        if durability.resumePolicy == .neverAuto {
            return hold("This interrupted task requires review before it can continue. It stays paused.")
        }
        if input.journalCoverage != .complete {
            return hold("This interrupted task has incomplete execution history. It stays paused.")
        }
        switch input.lease {
        case .unknown, .invalid:
            return hold("The prior worker's ownership could not be verified. This interrupted task stays paused.")
        case .possiblyAlive:
            return hold("The prior worker may still be alive. This interrupted task stays paused.")
        case .alive:
            return hold("The prior worker is still alive. This task is not being started again.")
        case .gone: break
        }
        if durability.resumePolicy == .verifyThenDecide {
            return hold("This interrupted task needs its action outcome checked. Missing receipts do not prove that nothing happened.")
        }
        if input.checkpoint == .validated {
            return hold("Saved session information is not enough to reconnect safely. This interrupted task stays paused.")
        }
        // Even positive caller observations do not supply the runtime fencing contract
        // that does not exist yet. They cannot authorize execution in this foundation.
        return hold("This interrupted task stays paused until safe ownership and execution checks are available.")
    }

    private static func hold(_ reason: String) -> TaskRecoveryPlan {
        TaskRecoveryPlan(action: .holdForReview, reason: reason)
    }
}

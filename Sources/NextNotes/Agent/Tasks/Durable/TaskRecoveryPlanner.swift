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

    /// Explicit continuation accepts only complete ordered native READ attempt segments.
    /// Journal facts encode task/attempt/tool/order/count, not a persisted receipt UUID or path.
    static func explicitReadInstructions(task: AgentTask, journal: [TaskJournalEvent],
                                         receipts: [ActionReceipt]) -> [String]? {
        guard task.status == .recovering, task.source == "text", task.origin == .typed,
              task.backend == "local", task.scheduleID == nil, task.pendingInteraction == nil,
              let d = task.durability, d.attempt > 0, d.attempt < Int.max,
              let owner = d.leaseOwner, let primaryPID = Int32(owner), primaryPID > 1, String(primaryPID) == owner,
              d.attemptStartedAt != nil,
              !d.receiptIDs.isEmpty, Set(d.receiptIDs).count == d.receiptIDs.count,
              journal.count >= 5, d.attempt <= journal.count / 2,
              journal.allSatisfy({ $0.seq > 0 && $0.draft.taskID == task.id && $0.draft.attempt > 0 }),
              zip(journal, journal.dropFirst()).allSatisfy({ $0.seq < $1.seq }),
              journal.first?.draft.kind == .jobCreated, journal.first?.draft.attempt == 1,
              journal.last?.draft.kind == .recoveryHeld, journal.last?.draft.attempt == d.attempt else { return nil }
        let saved = receipts.filter { $0.taskID == task.id }
        guard saved.count == d.receiptIDs.count,
              Set(saved.map { $0.actionID.uuidString }) == Set(d.receiptIDs),
              saved.allSatisfy({ r in
                  guard let p = r.preparedAction, let receiptOwner = r.taskLeaseOwner,
                        let pid = Int32(receiptOwner), pid > 1, String(pid) == receiptOwner,
                        let attempt = r.taskAttempt, attempt > 0, attempt <= d.attempt else { return false }
                  return r.status == .completed && r.completedAt != nil
                      && r.toolID == "filesystem.read" && r.source == .agent && r.intent.source == .agent
                      && r.authority == .user && r.intent.authority == .user
                      && r.intent.id == r.intentID && r.intent.verb == r.toolID
                      && r.meetingID == nil && p.routing.meetingID == nil
                      && p.routing.taskID == task.id && p.routing.integration == nil
                      && r.intent.risk == .read && p.risk == .read && p.id == r.actionID
                      && p.intentID == r.intentID && p.executionPlan.toolID == r.toolID
                      && p.executionPlan.arguments == r.intent.arguments
                      && p.executionPlan.arguments.keys.sorted() == ["path"]
                      && p.executionPlan.arguments["path"]?.isEmpty == false
                      && r.events.filter({ $0.stage == .fired }).count == 1
                      && r.events.last?.stage == .completed
              }) else { return nil }
        let permitted: Set<TaskEventKind> = [.jobCreated, .workerRecovered, .workerStarted,
            .toolStarted, .toolCompleted, .artifactCaptured, .heartbeat, .revisionRecorded, .recoveryHeld]
        guard journal.allSatisfy({ permitted.contains($0.draft.kind) }) else { return nil }
        var cursor = 0
        var instructions: [String] = []
        for attempt in 1...d.attempt {
            let first = cursor
            while cursor < journal.count, journal[cursor].draft.attempt == attempt { cursor += 1 }
            guard cursor > first else { return nil }
            let segment = Array(journal[first..<cursor])
            let prefix: [TaskEventKind] = attempt == 1 ? [.jobCreated, .workerStarted] : [.workerRecovered, .workerStarted]
            guard segment.count >= 3, segment.prefix(2).map(\.draft.kind) == prefix,
                  segment.last?.draft.kind == .recoveryHeld,
                  segment.filter({ $0.draft.kind == .workerStarted }).count == 1,
                  segment.filter({ $0.draft.kind == .recoveryHeld }).count == 1,
                  segment.filter({ $0.draft.kind == .jobCreated }).count == (attempt == 1 ? 1 : 0),
                  segment.filter({ $0.draft.kind == .workerRecovered }).count == (attempt == 1 ? 0 : 1) else { return nil }
            let began = segment[1], held = segment[segment.count - 1]
            let revisions = segment.filter { $0.draft.kind == .revisionRecorded }
            guard revisions.allSatisfy({ $0.seq > began.seq && $0.seq < held.seq
                && $0.draft.detail?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }) else { return nil }
            instructions.append(contentsOf: revisions.compactMap { $0.draft.detail })
            let starts = segment.filter { $0.draft.kind == .toolStarted }
            let ends = segment.filter { $0.draft.kind == .toolCompleted }
            let group = saved.filter { $0.taskAttempt == attempt }
            guard starts.count == group.count, ends.count == starts.count,
                  starts.allSatisfy({ $0.seq > began.seq && $0.seq < held.seq && $0.draft.detail == "filesystem.read" }),
                  ends.allSatisfy({ $0.seq > began.seq && $0.seq < held.seq && $0.draft.detail == "filesystem.read:returned" }),
                  zip(starts, ends).allSatisfy({ $0.seq < $1.seq }),
                  zip(ends, starts.dropFirst()).allSatisfy({ $0.seq < $1.seq }),
                  Set(group.compactMap(\.taskLeaseOwner)).count <= 1,
                  attempt != d.attempt || group.allSatisfy({ $0.taskLeaseOwner == owner }) else { return nil }
        }
        guard cursor == journal.count, instructions.count == task.revision else { return nil }
        return instructions
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

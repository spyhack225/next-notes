import Foundation
import Observation

/// One visible approval, with an ordered queue for independent tool workers.
///
/// The island and the Agent sidebar show the same request. `AgentService` already owns
/// `IslandState.onProposalDecision` for meeting proposals; `start()` asks us first.
@MainActor
@Observable
final class PermissionGate {
    static let shared = PermissionGate()

    private(set) var pending: PermissionRequest?
    private var waiter: CheckedContinuation<Bool, Never>?
    private var queued: [(PermissionRequest, CheckedContinuation<Bool, Never>)] = []
    var queuedCount: Int { queued.count }
    /// How many times anything has asked. `--selftest-routine-authority` checks an unattended
    /// run leaves it unchanged: nobody is there to answer.
    private(set) var askCount = 0

    private init() {}

    func ask(_ request: PermissionRequest) async -> Bool {
        askCount += 1
        let requestID = request.id
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                if waiter == nil { present(request, continuation: continuation) }
                else { queued.append((request, continuation)) }
            }
        } onCancel: {
            Task { @MainActor in
                PermissionGate.shared.cancelPending(id: requestID)
            }
        }
    }

    private func present(_ request: PermissionRequest,
                         continuation: CheckedContinuation<Bool, Never>) {
        pending = request
        waiter = continuation
        // The review is built before the card is raised, so the island's first frame
        // already knows whether anything is missing. A card that says "Approve" for two
        // seconds and then changes its mind has already been pressed.
        ToolCallReviewStore.shared.begin(request)
        raiseIsland(for: request)
    }

    /// Puts the island card up from the current state of the review, so the two never
    /// disagree about whether anything is still owed.
    private func raiseIsland(for request: PermissionRequest) {
        let review = ToolCallReviewStore.shared.review(for: request)
        IslandState.shared.propose(IslandProposal(
            id: request.id,
            title: review.title,
            detail: review.isReadyToRun ? review.why : review.blockers[0].prompt,
            meetingID: request.meetingID,
            // Anything that needs an answer, or that speaks in the user's name, is
            // answered where the whole thing is on screen — never from two lines.
            needsReview: request.risk >= .modify || !review.isReadyToRun,
            canExecute: review.isReadyToRun,
            needsCount: review.blockers.count
        ))
    }

    /// The card for the request on screen. Built on demand so a view that appears late
    /// still gets fields rather than two sentences.
    var pendingReview: ToolCallReview? {
        guard let pending else { return nil }
        return ToolCallReviewStore.shared.review(for: pending)
    }

    private func advance() {
        guard waiter == nil, !queued.isEmpty else { return }
        let next = queued.removeFirst()
        present(next.0, continuation: next.1)
    }

    /// Returns true when this id was ours, so the island handler can stop.
    @discardableResult
    func respond(
        id: String,
        approved: Bool,
        duration: PermissionDuration = .once,
        scope: PermissionScope? = nil
    ) -> Bool {
        guard pending?.id == id else { return false }
        let review = ToolCallReviewStore.shared.review(id: id)
        // The last gate, and the one that cannot be got round by a view drawing the button
        // anyway: an approval for a call that is still missing a required value, or that
        // still carries a placeholder, is refused here rather than executed.
        if approved, let review, !review.isReadyToRun, let stillPending = pending {
            Log.agent.info("approval refused: \(review.blockers.count, privacy: .public) unanswered fields on \(review.toolID, privacy: .public)")
            // The request is still ours and still open. Put the card back — a surface that
            // took itself down on a refused press would leave the tool waiting on a
            // question nobody can see any more.
            raiseIsland(for: stillPending)
            return false
        }
        let request = pending
        pending = nil
        waiter?.resume(returning: approved)
        waiter = nil
        IslandState.shared.dismissNotice()
        if let review {
            AgentAuditLog.shared.record(
                kind: .permission,
                title: review.title,
                detail: approved ? review.auditNote : "Dismissed",
                toolID: review.toolID,
                taskID: request?.taskID,
                meetingID: request?.meetingID,
                // The sentence that caused the card, with the row (P0-4): a record of an
                // approval that cannot be read against what was said is a record that has
                // lost the only thing that made a wrong card obvious.
                triggerQuote: review.trigger.quote
            )
        }
        // The values the executor reads back are kept until it has read them; the caller
        // clears the review when the action has been fired or has failed.
        if !approved { ToolCallReviewStore.shared.remove(id: id) }
        if approved, let request {
            PermissionGrantStore.shared.add(
                PermissionGrant(
                    toolID: request.toolID,
                    duration: duration,
                    scope: scope ?? request.scope,
                    meetingID: request.meetingID,
                    taskID: request.taskID
                )
            )
        }
        advance()
        return true
    }

    /// Explicit global stop releases every approval waiter. Ordinary voice
    /// interruption does not call this; a task correction uses its own id.
    func cancelPending() {
        let abandoned = queued
        queued.removeAll()
        for (request, _) in abandoned { ToolCallReviewStore.shared.remove(id: request.id) }
        if let pending { ToolCallReviewStore.shared.remove(id: pending.id) }
        pending = nil
        waiter?.resume(returning: false)
        waiter = nil
        for (_, continuation) in abandoned { continuation.resume(returning: false) }
        IslandState.shared.dismissNotice()
    }

    func cancelPending(taskID: String) {
        cancelMatching { $0.taskID == taskID }
    }

    func cancelPending(id: String) {
        cancelMatching { $0.id == id }
    }

    private func cancelMatching(_ matches: (PermissionRequest) -> Bool) {
        let removed = queued.filter { matches($0.0) }
        queued.removeAll { matches($0.0) }
        for (request, continuation) in removed {
            ToolCallReviewStore.shared.remove(id: request.id)
            continuation.resume(returning: false)
        }
        if let pending, matches(pending) {
            ToolCallReviewStore.shared.remove(id: pending.id)
            self.pending = nil
            waiter?.resume(returning: false)
            waiter = nil
            IslandState.shared.dismissNotice()
        }
        advance()
    }
}

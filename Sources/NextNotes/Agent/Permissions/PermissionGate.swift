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
        // Only the original task-bound caller supplies journal provenance. Callback
        // transports without that context stay unbound until their own bridge is verified.
        let context = TaskEventJournal.current.flatMap { $0.taskID == request.taskID ? $0 : nil }
        var admitted = false
        let approved = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                admitted = true
                if let context {
                    context.record(TaskJournalEventDraft(taskID: context.taskID,
                        kind: .permissionRequested, attempt: context.attempt))
                }
                if waiter == nil { present(request, continuation: continuation) }
                else { queued.append((request, continuation)) }
            }
        } onCancel: {
            Task { @MainActor in
                PermissionGate.shared.cancelPending(id: requestID)
            }
        }
        if admitted, let context {
            // False includes cancellation/withdrawal. It does not assert a human denial.
            context.record(TaskJournalEventDraft(taskID: context.taskID,
                kind: approved ? .permissionApproved : .permissionDenied,
                detail: approved ? nil : "notApproved", attempt: context.attempt))
        }
        return approved
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
        // P1-29: a card that was **shown** is a moment the audit could not see, so "did the
        // person ever get asked?" had no answer in any log. The tool id and the request id,
        // never the arguments — a permission request carries the arguments, and this file is
        // read by `--usage-report`.
        AgentAuditLog.shared.record(
            kind: .permission, title: "Approval asked",
            detail: "Waiting for a person.",
            toolID: request.toolID, taskID: request.taskID,
            triggerQuote: request.trigger.quote)
        if VoiceConversationCoordinator.shared.voiceShadowOwnsTask(request.taskID), let task = request.taskID {
            VoiceSession.shared.send(.approvalPending(requestID: request.id, task: TaskID(task)))
        }
    }

    /// Puts the island card up from the current state of the review, so the two never
    /// disagree about whether anything is still owed.
    private func raiseIsland(for request: PermissionRequest) {
        IslandState.shared.propose(islandProposal(for: request))
    }

    /// The card for one request, built in one place.
    ///
    /// P1-16: extracted so the **live** island kind and the 8 s notice draw the same card. The
    /// notice used to be the only thing that could show a pending approval, which is why the
    /// approval vanished after eight seconds while `ask` was still waiting on the person — and
    /// why the live path had to be able to build the proposal itself.
    func islandProposal(for request: PermissionRequest) -> IslandProposal {
        let review = ToolCallReviewStore.shared.review(for: request)
        return IslandProposal(
            id: request.id,
            title: review.title,
            detail: review.isReadyToRun ? review.why : review.blockers[0].prompt,
            meetingID: request.meetingID,
            // Anything that needs an answer, or that speaks in the user's name, is
            // answered where the whole thing is on screen — never from two lines.
            needsReview: request.risk >= .modify || !review.isReadyToRun,
            canExecute: review.isReadyToRun,
            needsCount: review.blockers.count)
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
        if let request { VoiceSession.shared.send(.approvalResolved(requestID: request.id)) }
        advance()
        return true
    }

    /// Explicit global stop releases every approval waiter. Ordinary voice
    /// interruption does not call this; a task correction uses its own id.
    func cancelPending() {
        let shadowRequestID = pending?.id
        // P1-29: a card that went away unanswered is the other moment with no trace. Recorded
        // here rather than at each caller, because "cancelled" has five entry points
        // (`cancelPending()`, the task id, the request id, `cancelMatching`, ACP's cancel) and
        // a row at each is four rows that can be forgotten.
        noteCancelled(count: queued.count + (pending == nil ? 0 : 1))
        let abandoned = queued
        queued.removeAll()
        for (request, _) in abandoned { ToolCallReviewStore.shared.remove(id: request.id) }
        if let pending { ToolCallReviewStore.shared.remove(id: pending.id) }
        pending = nil
        waiter?.resume(returning: false)
        waiter = nil
        for (_, continuation) in abandoned { continuation.resume(returning: false) }
        IslandState.shared.dismissNotice()
        if let shadowRequestID { VoiceSession.shared.send(.approvalResolved(requestID: shadowRequestID)) }
    }

    func cancelPending(taskID: String) {
        cancelMatching { $0.taskID == taskID }
    }

    func cancelPending(id: String) {
        cancelMatching { $0.id == id }
    }

    /// P1-29, shared by the two cancel paths. Counted rather than itemised: a cancelled card
    /// is a fact about the turn, and a list of the requests that were abandoned is the kind of
    /// detail that ends up reading somebody's work back to them.
    private func noteCancelled(count: Int) {
        guard count > 0 else { return }
        AgentAuditLog.shared.record(
            kind: .permission, title: "Approval cancelled",
            detail: "\(count) request(s) went unanswered.")
    }

    private func cancelMatching(_ matches: (PermissionRequest) -> Bool) {
        let shadowRequestID = pending.flatMap { matches($0) ? $0.id : nil }
        noteCancelled(count: queued.filter { matches($0.0) }.count
            + (pending.map { matches($0) ? 1 : 0 } ?? 0))
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
        if let shadowRequestID { VoiceSession.shared.send(.approvalResolved(requestID: shadowRequestID)) }
        advance()
    }
}

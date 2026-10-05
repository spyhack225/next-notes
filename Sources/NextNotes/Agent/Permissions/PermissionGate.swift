import Foundation
import Observation

enum PermissionAnswerSurface: String, Sendable { case card, island, voice, withdrawn }

/// One visible approval, with an ordered queue for independent tool workers.
///
/// The island and the Agent sidebar show the same request. `AgentService` already owns
/// `IslandState.onProposalDecision` for meeting proposals; `start()` asks us first.
@MainActor
@Observable
final class PermissionGate {
    static let shared = PermissionGate()

    private(set) var pending: PermissionRequest?
    private struct WaitingApproval {
        let request: PermissionRequest
        var continuation: CheckedContinuation<Bool, Never>?
        var restoredDecision: ((Bool, [String: String]) -> Bool)?
        // Live bound workers commit the exact decision before this waiter can resume.
        var decisionAdmission: ((Bool) -> Bool)?
        var review: ToolCallReview?
        weak var voiceBridge: TaskBridge?
        weak var voiceRoute: TaskBridge?
        var voiceRouteRevision: Int?
        var voiceRouteGeneration: Int?
    }
    private var waiting: WaitingApproval?
    private var queued: [WaitingApproval] = []
    var queuedCount: Int { queued.count }
    /// A restored decision authorizes one exact retry, never a new standing grant.
    var pendingAllowsStandingGrant: Bool {
        pending != nil && waiting?.restoredDecision == nil
    }
    /// How many times anything has asked. `--selftest-routine-authority` checks an unattended
    /// run leaves it unchanged: nobody is there to answer.
    private(set) var askCount = 0

    private var sharedApprovalRouteObserverForTesting: (@MainActor (Bool, Bool) -> Void)?
    private var approvalRouteFixtureRoot: URL?
    @discardableResult
    func setSharedApprovalRouteObserverForTesting(_ observer: (@MainActor (Bool, Bool) -> Void)?, root: URL) -> Bool {
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let resolved = root.resolvingSymlinksInPath().standardizedFileURL
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-voice-delivery",
              root.standardizedFileURL.path == resolved.path,
              resolved.deletingLastPathComponent().path == temp.path,
              UUID(uuidString: resolved.lastPathComponent) != nil,
              FileManager.default.fileExists(atPath: resolved.path),
              observer == nil ? approvalRouteFixtureRoot?.path == resolved.path : sharedApprovalRouteObserverForTesting == nil else { return false }
        sharedApprovalRouteObserverForTesting = observer
        approvalRouteFixtureRoot = observer == nil ? nil : resolved
        return true
    }
    private func observeSharedApprovalRoute(_ selected: Bool, matched: Bool) {
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-voice-delivery",
              let root = approvalRouteFixtureRoot,
              root.path == root.resolvingSymlinksInPath().standardizedFileURL.path,
              FileManager.default.fileExists(atPath: root.path) else { return }
        sharedApprovalRouteObserverForTesting?(selected, matched)
    }

    private init() {}

    func ask(_ rawRequest: PermissionRequest, voiceBridge: TaskBridge? = nil,
             voiceGeneration: Int? = nil, voiceRevision: Int? = nil) async -> Bool {
        let request: PermissionRequest
        if let bridge = voiceBridge,
           bridge.approvalRouteRevision(rawRequest.taskID, generation: voiceGeneration, revision: voiceRevision) != nil {
            guard let canonical = try? AgentTaskStore.canonicalPermissionRequest(rawRequest) else { return false }
            request = canonical
        } else { request = rawRequest }
        askCount += 1
        let requestID = request.id
        // Only the original task-bound caller supplies journal provenance. Callback
        // transports without that context stay unbound until their own bridge is verified.
        let context = TaskEventJournal.current.flatMap { $0.taskID == request.taskID ? $0 : nil }
        let requiresAdmission = context?.isStillValid != nil
        var admitted = false
        var decisionCommitted = false
        let approved = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                if let context {
                    let saved = context.record(TaskJournalEventDraft(taskID: context.taskID,
                        kind: .permissionRequested, attempt: context.attempt))
                    guard !requiresAdmission || saved else {
                        continuation.resume(returning: false)
                        return
                    }
                }
                admitted = true
                var entry = WaitingApproval(request: request, continuation: continuation)
                if let bridge = voiceBridge, bridge.matchesLiveApprovalRoute(request.taskID, generation: voiceGeneration, revision: voiceRevision) {
                    entry.voiceRoute = bridge
                    entry.voiceRouteRevision = voiceRevision
                    entry.voiceRouteGeneration = voiceGeneration
                }
                if requiresAdmission, let context {
                    entry.decisionAdmission = { decision in
                        let saved = context.record(TaskJournalEventDraft(taskID: context.taskID,
                            kind: decision ? .permissionApproved : .permissionDenied,
                            detail: decision ? nil : "notApproved", attempt: context.attempt))
                        if saved { decisionCommitted = true }
                        return saved
                    }
                }
                if pending == nil { present(entry) }
                else { queued.append(entry) }
            }
        } onCancel: {
            Task { @MainActor in
                PermissionGate.shared.cancelPending(id: requestID)
            }
        }
        if admitted, let context, !requiresAdmission || !decisionCommitted {
            // Bound explicit decisions committed before resume. A cancellation still
            // releases false even when this best-effort denied fact cannot commit.
            // False includes cancellation/withdrawal. It does not assert a human denial.
            _ = context.record(TaskJournalEventDraft(taskID: context.taskID,
                kind: approved ? .permissionApproved : .permissionDenied,
                detail: approved ? nil : "notApproved", attempt: context.attempt))
        }
        return approved && (!requiresAdmission || decisionCommitted)
    }

    /// Restored cards have no suspended worker to resume. Their actual owner must
    /// commit a decision before the visible card can disappear or a grant can exist.
    @discardableResult
    func restore(_ request: PermissionRequest, review: ToolCallReview? = nil,
                 onReviewChange: ((ToolCallReview) -> Bool)? = nil,
                 onDecision: @escaping (Bool, [String: String]) -> Bool) -> Bool {
        guard request.taskID != nil,
              review == nil || (review?.id == request.id && review?.toolID == request.toolID) else { return false }
        if pending?.id == request.id || queued.contains(where: { $0.request.id == request.id }) { return true }
        ToolCallReviewStore.shared.setPersistenceHandler(id: request.id, handler: onReviewChange)
        let entry = WaitingApproval(request: request, restoredDecision: onDecision, review: review)
        if pending == nil { present(entry) } else { queued.append(entry) }
        return true
    }

    private func present(_ entry: WaitingApproval) {
        let request = entry.request
        var entry = entry
        // The review is built before the card is raised, so the island's first frame
        // already knows whether anything is missing. A card that says "Approve" for two
        // seconds and then changes its mind has already been pressed.
        ToolCallReviewStore.shared.begin(request, restoredReview: entry.review)
        let currentRouteRevision = entry.voiceRoute?.approvalRouteRevision(request.taskID,
            generation: entry.voiceRouteGeneration, revision: entry.voiceRouteRevision)
        observeSharedApprovalRoute(false, matched: currentRouteRevision != nil)
        if entry.continuation != nil, entry.restoredDecision == nil,
           let bridge = entry.voiceRoute,
           let revision = currentRouteRevision,
           let review = ToolCallReviewStore.shared.review(id: request.id) {
            guard bridge.approvalPresented(request, review: review, workRevision: revision, callerGeneration: entry.voiceRouteGeneration) else {
                ToolCallReviewStore.shared.remove(id: request.id)
                entry.continuation?.resume(returning: false)
                advance()
                return
            }
            entry.voiceBridge = bridge
        }
        // A mismatched local/canonical revision retains the inherited display-only
        // card path. It gets no spoken state, current pending transaction or voice
        // token; the unchanged captured revision/effect hold still fences backing.
        pending = request
        waiting = entry
        // Admission precedes presentation; enqueue only after this exact Gate is current.
        entry.voiceBridge?.offerApprovalPrompt(request.id)
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
        if entry.voiceRoute?.voiceShadowOwnsApprovalTask(request.taskID, generation: entry.voiceRouteGeneration, revision: entry.voiceRouteRevision) == true, let task = request.taskID {
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
    /// Session close invalidates playback authority even after the prompt ended.
    /// Only the retained proposal's existing weak voice owner is touched.
    func resetPendingVoiceApprovalPlayback() {
        guard let request = pending, let entry = waiting, entry.request == request else { return }
        entry.voiceBridge?.resetApprovalPlayback(request.id)
    }

    var pendingReview: ToolCallReview? {
        guard let pending else { return nil }
        return ToolCallReviewStore.shared.review(for: pending)
    }

    private func advance() {
        guard pending == nil, !queued.isEmpty else { return }
        let next = queued.removeFirst()
        present(next)
    }

    /// Returns true when this id was ours, so the island handler can stop.
    @discardableResult
    func respond(
        id: String,
        approved: Bool,
        duration: PermissionDuration = .once,
        scope: PermissionScope? = nil,
        via: PermissionAnswerSurface = .card,
        beforeResume: (() -> Void)? = nil
    ) -> Bool {
        guard pending?.id == id else { return false }
        // A displayed generic/restored/mismatched card has no heard-current voice
        // authority. Its existing card decision remains available.
        if via == .voice, waiting?.voiceBridge == nil { return false }
        if approved, waiting?.restoredDecision != nil, duration != .once {
            // Refuse the unsupported promise before committing or dispatching anything.
            // Hiding the duration picker alone would leave programmatic callers unsafe.
            if let pending { raiseIsland(for: pending) }
            return false
        }
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
        // Refuse obsolete callers and unheard/mismatched spoken decisions before
        // any journal/restored callback can emit an approval fact. The primary
        // proposal transition still occurs below, immediately before grant/resume.
        if let request = pending, let voiceBridge = waiting?.voiceBridge {
            guard voiceBridge.matchesLiveApprovalRoute(request.taskID,
                generation: waiting?.voiceRouteGeneration, revision: waiting?.voiceRouteRevision),
                  voiceBridge.approvalDecisionIsCurrent(request, approved: approved, via: via) else {
                raiseIsland(for: request); return false
            }
        }
        if let decision = waiting?.restoredDecision, let request = pending {
            // Preserve pinned/internal arguments that are deliberately absent from the
            // editable fields. Only the real review can replace visible values.
            let arguments = review?.executionArguments(mergedOver: request.arguments) ?? request.arguments
            guard decision(approved, arguments) else {
                raiseIsland(for: request)
                return false
            }
        }
        if let admission = waiting?.decisionAdmission, let request = pending {
            guard admission(approved) else {
                // Failed primary admission keeps the exact card, review and waiter.
                // No grant or authorizing continuation has been emitted yet.
                raiseIsland(for: request)
                return false
            }
        }
        if let request = pending, let voiceBridge = waiting?.voiceBridge {
            guard voiceBridge.matchesLiveApprovalRoute(request.taskID,
                generation: waiting?.voiceRouteGeneration, revision: waiting?.voiceRouteRevision) else {
                raiseIsland(for: request); return false
            }
            guard voiceBridge.approvalDecisionAdmitted(request, approved: approved, via: via) else {
                raiseIsland(for: request)
                return false
            }
        }
        // Spoken current-turn classification occurs only after primary admission,
        // before either the permission grant or the SAME suspended waiter is emitted.
        if via == .voice { beforeResume?() }
        let request = pending
        let wasRestored = waiting?.restoredDecision != nil
        if let request { waiting?.voiceBridge?.approvalWithdrawn(request.id) }
        if wasRestored {
            // The durable owner has accepted the decision. Keep execution values until
            // the executor consumes them, but this card can no longer persist edits.
            ToolCallReviewStore.shared.setPersistenceHandler(id: id, handler: nil)
        }
        pending = nil
        waiting?.continuation?.resume(returning: approved)
        waiting = nil
        IslandState.shared.dismissNotice()
        if let review {
            AgentAuditLog.shared.record(
                kind: .permission,
                title: review.title,
                detail: (approved ? review.auditNote : "Dismissed") + (via == .voice ? " · by voice" : ""),
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
        if approved, !wasRestored, let request {
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
        cancelMatching { _ in true }
        // Preserve the global stop's existing notice dismissal when no card remains.
        if pending == nil { IslandState.shared.dismissNotice() }
    }

    /// The manager uses this read-only seam to keep queued restored cards on the same
    /// durable decision path as the visible card.
    func hasRestoredRequest(taskID: String) -> Bool {
        (waiting.map { $0.request.taskID == taskID && $0.restoredDecision != nil } ?? false)
            || queued.contains { $0.request.taskID == taskID && $0.restoredDecision != nil }
    }

    /// Current task-owned approval waits, including the queue. This is a
    /// diagnostic exclusion, never approval or exact attempt/retry authority.
    func hasWaitingRequest(taskID: String) -> Bool {
        (waiting.map { $0.request.taskID == taskID } ?? false)
            || queued.contains { $0.request.taskID == taskID }
    }

    /// Simulate process loss in the isolated installed restart fixture. A restart drops
    /// ephemeral waiters/cards; it does not manufacture a durable approval or denial.
    func resetForRestartTesting() {
        guard SelfTest.isRunning else { return }
        let abandoned = queued
        let active = waiting
        queued = []
        pending = nil
        waiting = nil
        ToolCallReviewStore.shared.removeAll()
        if let active { active.voiceBridge?.approvalWithdrawn(active.request.id) }
        for entry in abandoned { entry.voiceBridge?.approvalWithdrawn(entry.request.id) }
        active?.continuation?.resume(returning: false)
        for entry in abandoned { entry.continuation?.resume(returning: false) }
        IslandState.shared.dismissNotice()
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

    /// Cancellation is a denied decision for a restored card. Its durable owner must
    /// accept that decision before either the review or its persistence handler is removed.
    private func canCancel(_ entry: WaitingApproval) -> Bool {
        guard let decision = entry.restoredDecision else { return true }
        let review = ToolCallReviewStore.shared.review(id: entry.request.id) ?? entry.review
        let arguments = review?.executionArguments(mergedOver: entry.request.arguments)
            ?? entry.request.arguments
        return decision(false, arguments)
    }

    private func cancelMatching(_ matches: (PermissionRequest) -> Bool) {
        var cancelledCount = 0
        var retained: [WaitingApproval] = []
        for entry in queued {
            guard matches(entry.request), canCancel(entry) else {
                retained.append(entry)
                continue
            }
            entry.voiceBridge?.approvalWithdrawn(entry.request.id)
            ToolCallReviewStore.shared.remove(id: entry.request.id)
            entry.continuation?.resume(returning: false)
            cancelledCount += 1
        }
        queued = retained
        if let pending, matches(pending), let waiting {
            if canCancel(waiting) {
                waiting.voiceBridge?.approvalWithdrawn(pending.id)
                ToolCallReviewStore.shared.remove(id: pending.id)
                self.pending = nil
                waiting.continuation?.resume(returning: false)
                self.waiting = nil
                IslandState.shared.dismissNotice()
                VoiceSession.shared.send(.approvalResolved(requestID: pending.id))
                cancelledCount += 1
            } else {
                // A rejected primary commit leaves the exact request and editable review
                // live, with its persistence handler available for the next attempt.
                raiseIsland(for: pending)
            }
        }
        noteCancelled(count: cancelledCount)
        advance()
    }
}

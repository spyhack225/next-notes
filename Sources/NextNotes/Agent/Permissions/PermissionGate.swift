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

    private init() {}

    func ask(_ request: PermissionRequest) async -> Bool {
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
        IslandState.shared.propose(IslandProposal(
            id: request.id, title: request.title, detail: request.detail,
            meetingID: request.meetingID, needsReview: request.risk >= .modify))
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
        let request = pending
        pending = nil
        waiter?.resume(returning: approved)
        waiter = nil
        IslandState.shared.dismissNotice()
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
        for (_, continuation) in removed { continuation.resume(returning: false) }
        if let pending, matches(pending) {
            self.pending = nil
            waiter?.resume(returning: false)
            waiter = nil
            IslandState.shared.dismissNotice()
        }
        advance()
    }
}

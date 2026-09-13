import Foundation
import Observation

/// One in-flight “may I?” for a computer (or other mutating) tool.
///
/// The island and the Agent sidebar show the same request. `AgentService` already owns
/// `IslandState.onProposalDecision` for meeting proposals; `start()` asks us first.
@MainActor
@Observable
final class PermissionGate {
    static let shared = PermissionGate()

    private(set) var pending: PermissionRequest?
    private var waiter: CheckedContinuation<Bool, Never>?

    private init() {}

    func ask(_ request: PermissionRequest) async -> Bool {
        if waiter != nil {
            return false
        }
        pending = request
        IslandState.shared.propose(
            IslandProposal(
                id: request.id,
                title: request.title,
                detail: request.detail,
                meetingID: request.meetingID
            )
        )
        return await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    /// Returns true when this id was ours, so the island handler can stop.
    @discardableResult
    func respond(id: String, approved: Bool) -> Bool {
        guard pending?.id == id else { return false }
        let request = pending
        pending = nil
        waiter?.resume(returning: approved)
        waiter = nil
        if approved, let request {
            PermissionGrantStore.shared.add(
                PermissionGrant(toolID: request.toolID, duration: .once, meetingID: request.meetingID)
            )
        }
        return true
    }
}

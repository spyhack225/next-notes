import Foundation

/// Explicit off-path diagnostic samples, not an atomic lease or a stale verdict.
/// A returned snapshot never permits state changes, effect replay or retry.
struct TaskWorkerHeartbeatObservation: Sendable {
    let binding: TaskWorkerBinding
    let observedAt: Date
    let primary: TaskWorkerPrimaryObservation
    let runtime: JSONRPCStdioObservation?
    let permissionWait: Bool
    /// LAST boundary remains incomplete active-call/effect coverage.
    let lastToolBoundary: TaskWorkerToolBackingObservation?
    let receiptSource: ActionReceiptCurrentSourceObservation?
    /// Only an accepted current primary supplies the age input. A mismatch is unknown.
    let age: TaskHeartbeatAge?
    let evidence: TaskHeartbeatEvidence
}

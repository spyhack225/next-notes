import Foundation

/// Called at the unchanged actual owned ACP fixture checkpoints, never a fake worker.
@MainActor
enum TaskHeartbeatIntegrationSelfTest {
    static func sample(manager: AgentTaskManager, binding: TaskWorkerBinding,
                       expectedPrimary: TaskWorkerPrimaryOutcome, expectedWait: Bool,
                       expectedAge: String?, expectedReceipt: Bool = true, check: (Bool, String) -> Void) async {
        let sample = await manager.workerHeartbeatObservation(taskID: binding.taskID)
        SelfTest.diagnostic("TASK_HEARTBEAT_CURRENT_TRACE: primary=\(sample?.primary.outcome.rawValue ?? "unavailable") state=\(sample?.primary.state?.rawValue ?? "unavailable") age=\(sample?.age?.diagnosticName ?? "unavailable") wait=\(sample?.permissionWait.description ?? "unavailable") source=\(sample?.receiptSource?.state.rawValue ?? "unavailable") rows=\(sample?.receiptSource?.receipts.count ?? -1) receipt=\(sample?.evidence.receiptCreated.rawValue ?? "unknown")")
        check(sample?.binding == binding && sample?.primary.expected.taskID == binding.taskID
            && sample?.primary.expected.attempt == binding.attempt
            && sample?.primary.expected.leaseOwner == binding.leaseOwner
            && sample?.primary.outcome == expectedPrimary,
            "Heartbeat integration: current exact primary sample missing or replaced by LAST/memory")
        check(sample?.runtime?.isRunning == true && sample?.runtime?.transportClosed == false
            && sample?.runtime?.pendingRequestCount == 1
            && sample?.runtime?.processID != ProcessInfo.processInfo.processIdentifier
            && sample?.evidence.processAlive == .yes,
            "Heartbeat integration: actual child observation missing or replaced by app owner PID")
        check(sample?.permissionWait == expectedWait && sample?.age?.diagnosticName == expectedAge,
            "Heartbeat integration: current primary age/wait exclusion missing or held row treated as live age")
        check(sample?.evidence.backendSessionAlive == .unknown
            && sample?.evidence.toolInFlight == .unknown
            && sample?.lastToolBoundary?.state == .entryAdmitted,
            "Heartbeat integration: transport/LAST fact was substituted for complete health/effect coverage")
        let exactReceipt = sample?.receiptSource?.state == .matchingSource
            && sample?.receiptSource?.receipts.count == 1
            && (sample?.receiptSource?.receipts.map { $0.actionID.uuidString }) == sample?.primary.durability?.receiptIDs
            && sample?.receiptSource?.receipts.first?.taskID == binding.taskID
            && sample?.receiptSource?.receipts.first?.taskAttempt == binding.attempt
            && sample?.receiptSource?.receipts.first?.taskLeaseOwner == binding.leaseOwner
            && sample?.receiptSource?.receipts.first?.status == .fired
            && sample?.evidence.receiptCreated == .yes
        let unavailablePrimaryReceipt = sample?.primary.outcome == .unavailable
            && sample?.primary.state == nil && sample?.primary.durability == nil
            && sample?.receiptSource?.state == .matchingSource
            && sample?.receiptSource?.receipts.isEmpty == true
            && sample?.evidence.receiptCreated == .unknown
        check(expectedReceipt ? exactReceipt : unavailablePrimaryReceipt,
            "Heartbeat integration: current source-bound retained startup receipt unavailable")
        check(await manager.workerHeartbeatObservation(taskID: "missing-heartbeat-worker") == nil,
            "Heartbeat integration: unrelated worker manufactured current observation")
    }
}

import Foundation

/// Real Manager/LocalBackend/Executor, exact card approval, linked receipt and temporary filesystem.
/// The external-effect collaborator invokes the actual FilesystemExecutor once; no fake tool result.
@MainActor
enum TaskScopedMutationReceiptSelfTest {
    private enum FixtureError: Error { case unsafeRoot, busyGate, missingTask, invalidBacking, timeout }

    private static func reached(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    static func originalCases(root: URL, check parentCheck: (Bool, String) -> Void) async throws {
        var checks = 0, problems = 0
        func check(_ condition: Bool, _ label: String) {
            checks += 1; if !condition { problems += 1 }; parentCheck(condition, label)
        }
        let safe = root.resolvingSymlinksInPath().standardizedFileURL
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-task-worker-attempt",
              root.isFileURL, safe.path.hasPrefix(temporary.path + "/"),
              !safe.pathComponents.contains("Application Support") else { throw FixtureError.unsafeRoot }
        guard PermissionGate.shared.pending == nil, PermissionGate.shared.queuedCount == 0 else { throw FixtureError.busyGate }
        let ownerBefore = SelfTestStoreGuard.take()
        let grantsBefore = PermissionGrantStore.shared.grants
        let oldFire = AgentToolExecutor.fireOverrideForTesting
        let oldFake = AgentToolExecutor.fakeForTesting
        let oldPolicy = AgentToolExecutor.policyOverrideForTesting
        defer {
            AgentToolExecutor.fireOverrideForTesting = oldFire
            AgentToolExecutor.fakeForTesting = oldFake
            AgentToolExecutor.policyOverrideForTesting = oldPolicy
        }
        AgentToolExecutor.fakeForTesting = nil
        AgentToolExecutor.policyOverrideForTesting = .selfTest
        let honestFailure = "The action ran, but its result could not be saved. Check it before trying again."

        for mode in ["write-accepted", "write-export-rejected", "write-source-changed", "write-primary-rejected", "read-control"] {
            let isRead = mode == "read-control"
            let changed = mode == "write-source-changed"
            let startRejected = mode == "write-primary-rejected"
            let directory = safe.appendingPathComponent("scoped-mutation-" + mode, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let sql = TaskStore(root: directory)
            defer { sql.close() }
            let export = directory.appendingPathComponent("agent-tasks.json")
            let store = AgentTaskStore(fileURL: export, mirror: sql)
            guard store.allowsHarnessPersistence else { throw FixtureError.unsafeRoot }
            let receiptFile = directory.appendingPathComponent("action-receipts.json")
            let receipts = ActionReceiptStore(fileURL: receiptFile)
            let manager = AgentTaskManager(store: store, receiptStore: receipts)
            let target = directory.appendingPathComponent("owned-result.txt")
            let body = "Exact approved scoped mutation fixture.\nSecond owned line."
            if isRead { try body.write(to: target, atomically: true, encoding: .utf8) }
            let toolID = isRead ? "filesystem.read" : "filesystem.write"
            let arguments = isRead ? ["path": target.path] : ["path": target.path, "text": body]
            var operations: [Task<Void, Never>] = []
            var submittedID: String?
            var context: TaskJournalContext?
            var effects = 0
            var exits = 0
            var announcements: [String] = []
            var fired: ActionReceipt?
            var firedMemory: ActionReceipt?
            var firedBytes: Data?
            var changedBytes: Data?
            var joinedAtFire = false
            var exactPayload = false
            var boundaryCalls = 0
            var boundaryReceipt: ActionReceipt?
            var boundaryPrimary: AgentTask?
            var boundaryProblems = 0
            var primaryTrigger = false
            var exportChanged = false
            func capture(_ id: String) {
                if let task = manager.capturedReceiptMutationWorkerForTesting(id: id), !operations.contains(task) {
                    operations.append(task)
                }
            }
            manager.announcementForTesting = { announcements.append($0) }
            manager.backendExitForTesting = { exits += 1 }
            manager.backendEntryForTesting = {
                guard let current = TaskEventJournal.current else { throw FixtureError.missingTask }
                context = current
                capture(current.taskID)
                if startRejected, current.attempt > 1, !primaryTrigger {
                    try sql.withConnection { db in
                        try TaskStore.exec(db, "CREATE TRIGGER reject_scoped_mutation_start BEFORE INSERT ON task_event WHEN NEW.kind='toolStarted' BEGIN SELECT RAISE(ABORT,'fixture primary refusal'); END")
                    }
                    primaryTrigger = true
                }
            }
            guard ActionOrchestrator.shared.setResultVerificationBoundaryForTesting(root: directory, { id in
                boundaryCalls += 1
                let reader = ActionReceiptStore(fileURL: receiptFile)
                boundaryReceipt = reader.receipt(for: id)
                do { boundaryPrimary = try sql.load().first { $0.id == submittedID } }
                catch { boundaryProblems += 1 }
            }) else { throw FixtureError.unsafeRoot }
            defer { _ = ActionOrchestrator.shared.setResultVerificationBoundaryForTesting(root: directory, nil) }
            AgentToolExecutor.fireOverrideForTesting = { tool, actual in
                guard let context, tool.id == toolID, actual == arguments else { throw FixtureError.invalidBacking }
                let reader = ActionReceiptStore(fileURL: receiptFile)
                guard let current = reader.receipts.first(where: { $0.taskID == context.taskID && $0.status == .fired }),
                      let row = try sql.load().first(where: { $0.id == context.taskID }) else { throw FixtureError.invalidBacking }
                fired = current
                firedMemory = receipts.receipt(for: current.actionID)
                firedBytes = try Data(contentsOf: receiptFile)
                joinedAtFire = row.status == .running && row.durability?.receiptIDs == [current.actionID.uuidString]
                    && current.taskAttempt == context.attempt && current.taskLeaseOwner == row.durability?.leaseOwner
                    && current.taskLeaseOwner == String(ProcessInfo.processInfo.processIdentifier)
                    && current.preparedAction?.id == current.actionID
                exactPayload = current.preparedAction?.executionPlan.arguments == arguments
                    && (!isRead ? !FileManager.default.fileExists(atPath: target.path) : true)
                let result = try FilesystemExecutor.run(tool, arguments: actual)
                effects += 1
                if mode == "write-export-rejected" {
                    try FileManager.default.removeItem(at: export)
                    try FileManager.default.createDirectory(at: export, withIntermediateDirectories: false)
                    exportChanged = true
                }
                if changed {
                    guard var objects = try JSONSerialization.jsonObject(with: Data(contentsOf: receiptFile)) as? [[String: Any]] else {
                        throw FixtureError.invalidBacking
                    }
                    objects.append(["unreadable_future_receipt": true])
                    let bytes = try JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys])
                    try bytes.write(to: receiptFile, options: .atomic)
                    changedBytes = bytes
                }
                return result
            }
            do {
                let submitted = manager.submit(objective: isRead ? "Read the exact owned result file." : "Write the exact owned result file.",
                    tool: toolID, arguments: arguments, source: "selftest")
                submittedID = submitted.id
                capture(submitted.id) // Before every admission/entry guard, retain the actual operation.
                guard !operations.isEmpty else { throw FixtureError.missingTask }
                if !isRead {
                    guard await reached({ manager.task(id: submitted.id)?.status == .waitingForPermission
                        && PermissionGate.shared.pending?.taskID == submitted.id }) else { throw FixtureError.timeout }
                    capture(submitted.id)
                    for operation in operations { await operation.value }
                    guard let request = PermissionGate.shared.pending, request.toolID == toolID,
                          request.arguments == arguments, effects == 0,
                          case .permission(let storedRequest, _, _) = manager.task(id: submitted.id)?.pendingInteraction,
                          storedRequest.id == request.id else { throw FixtureError.invalidBacking }
                    ToolCallReviewStore.shared.confirm(id: request.id, field: "path")
                    ToolCallReviewStore.shared.confirm(id: request.id, field: "text")
                    guard PermissionGate.shared.respond(id: request.id, approved: true, duration: .once) else {
                        throw FixtureError.invalidBacking
                    }
                    capture(submitted.id)
                }
                guard await reached({ exits == (isRead ? 1 : 2) }) else { throw FixtureError.timeout }
                capture(submitted.id)
                for operation in operations { await operation.value }
                guard startRejected || fired != nil else { throw FixtureError.invalidBacking }
                let cached = manager.task(id: submitted.id)
                let primary = try sql.load().first { $0.id == submitted.id }
                let journal = try sql.journal(taskID: submitted.id)
                let finalReader = ActionReceiptStore(fileURL: receiptFile)
                let linked = fired.flatMap { finalReader.receipt(for: $0.actionID) }
                let expectedEffects = startRejected ? 0 : 1
                check(effects == expectedEffects && manager.backendStartsForTesting == (isRead ? 1 : 2),
                    "scoped mutation receipt C01: original backing/start count changed (\(mode))")
                check(startRejected ? primaryTrigger && !FileManager.default.fileExists(atPath: target.path)
                    : joinedAtFire && exactPayload,
                    "scoped mutation receipt C02: exact approval/primary fired join was not exercised (\(mode))")
                check(startRejected ? primary?.durability?.receiptIDs.isEmpty == true
                    : primary?.durability?.receiptIDs == fired.map { [$0.actionID.uuidString] },
                    "scoped mutation receipt C03: same primary receipt link changed (\(mode))")
                check(startRejected ? !FileManager.default.fileExists(atPath: target.path)
                    : (try? String(contentsOf: target, encoding: .utf8)) == body,
                    "scoped mutation receipt C04: exact original file words/effect were lost (\(mode))")
                check(boundaryProblems == 0 && boundaryCalls == (startRejected || changed ? 0 : 1),
                    "scoped mutation receipt F01: refused stage continued to result verification (\(mode))")
                if !startRejected && !changed {
                    let observed = boundaryReceipt
                    let expectedStage: ActionReceiptStatus = isRead ? .fired : .verifying
                    check(observed?.status == expectedStage && observed?.events.last?.stage == expectedStage
                        && observed?.completedAt == nil && observed?.verification == nil,
                        "scoped mutation receipt F02: fresh receipt was not persisted before readback (\(mode))")
                    check(boundaryPrimary?.status == .running
                        && boundaryPrimary?.durability?.receiptIDs == observed.map { [$0.actionID.uuidString] }
                        && observed?.taskAttempt == boundaryPrimary?.durability?.attempt
                        && observed?.taskLeaseOwner == boundaryPrimary?.durability?.leaseOwner,
                        "scoped mutation receipt C05: actual readback consumer lacked the exact primary binding (\(mode))")
                    check(isRead ? observed?.artifacts.isEmpty == true
                        : observed?.artifacts == [target.path] && observed?.result == "Wrote owned-result.txt."
                            && observed?.preparedAction?.executionPlan.arguments == arguments,
                        "scoped mutation receipt F03: returned scoped path/payload absent before readback (\(mode))")
                    check(cached?.status == .completed && primary?.status == .completed && linked?.status == .completed
                        && linked?.artifacts == [target.path],
                        "scoped mutation receipt C06: unchanged successful task/receipt consumer failed (\(mode))")
                    check(isRead ? linked?.events.allSatisfy { $0.stage != .verifying } == true
                        : linked?.events.filter { $0.stage == .verifying }.count == 1
                            && linked?.events.last?.stage == .completed,
                        "scoped mutation receipt F04: scoped mutation stage lost or duplicated in final history (\(mode))")
                    check(journal.contains { $0.draft.kind == .jobCompleted }
                        && announcements.contains(isRead ? body : "Wrote owned-result.txt."),
                        "scoped mutation receipt C07: actual final delivery/journal did not receive the original result (\(mode))")
                    check(mode != "write-export-rejected" || exportChanged && manager.lastPersistenceResult == .exportFailed,
                        "scoped mutation receipt C08: failed export revoked accepted SQL/receipt admission")
                } else {
                    check(cached?.status == .failed && primary?.status == .failed && cached?.result == nil
                        && !journal.contains { $0.draft.kind == .jobCompleted },
                        "scoped mutation receipt C09: rejected admission delivered successful task result (\(mode))")
                    if changed {
                        check(try Data(contentsOf: receiptFile) == changedBytes && changedBytes != firedBytes
                            && linked == fired && receipts.receipt(for: fired!.actionID) == firedMemory,
                            "scoped mutation receipt C10: changed source or committed fired evidence was erased")
                        check(cached?.failure == honestFailure && primary?.failure == honestFailure
                            && announcements.contains(honestFailure),
                            "scoped mutation receipt C11: receipt refusal did not report action-ran/result-not-saved")
                    } else {
                        // Runtime fired precedes primary toolStarted. Rejection throws before
                        // backing, then the existing catch commits failed with fired history.
                        let refused = finalReader.receipts.filter {
                            $0.taskID == submitted.id && $0.events.contains { $0.stage == .fired }
                        }
                        check(!journal.contains { $0.draft.kind == .toolStarted }
                            && refused.count == 1 && refused.allSatisfy { receipt in
                                receipt.status == .failed && (receipt.taskAttempt ?? 0) > 0
                                    && receipt.taskAttempt == context?.attempt
                                    && receipt.taskLeaseOwner == context?.leaseOwner
                                    && receipt.preparedAction?.id == receipt.actionID
                                    && receipt.preparedAction?.intentID == receipt.intentID
                                    && receipt.preparedAction?.routing.taskID == submitted.id
                                    && receipt.preparedAction?.executionPlan.toolID == toolID
                                    && receipt.preparedAction?.executionPlan.arguments == arguments
                                    && receipt.events.filter { $0.stage == .fired }.count == 1
                                    && receipt.events.suffix(2).map(\.stage) == [.fired, .failed]
                                    && !receipt.events.contains { $0.stage == .verifying || $0.stage == .completed }
                                    && receipt.result.isEmpty && receipt.verification == nil
                                    && receipt.completedAt == nil && receipt.artifacts.isEmpty
                            },
                            "scoped mutation receipt C12: primary refusal erased runtime evidence or admitted backing")
                        SelfTest.diagnostic("SCOPED_MUTATION_PRIMARY_REFUSAL_TRACE: retained=\(refused.count) failed=\(refused.first?.status == .failed) firedEvents=\(refused.first?.events.filter { $0.stage == .fired }.count ?? 0) firedThenFailed=\(refused.first?.events.suffix(2).map(\.stage) == [.fired, .failed]) exactAttempt=\(refused.first?.taskAttempt == context?.attempt) exactPreparedPayload=\(refused.first?.preparedAction?.executionPlan.arguments == arguments) noToolStarted=\(!journal.contains { $0.draft.kind == .toolStarted }) effects=\(effects) boundaryCalls=\(boundaryCalls)")
                    }
                }
                let reload = AgentTaskManager(store: AgentTaskStore(fileURL: export, mirror: sql),
                    receiptStore: ActionReceiptStore(fileURL: receiptFile))
                for _ in 0..<16 { await Task.yield() }
                let afterReload = try sql.load().first { $0.id == submitted.id }
                check(reload.backendStartsForTesting == 0 && effects == expectedEffects
                    && afterReload == primary,
                    "scoped mutation receipt C13: fresh terminal reader re-fired or changed original history (\(mode))")
                SelfTest.diagnostic("SCOPED_MUTATION_RECEIPT_TRACE: mode=\(mode) effects=\(effects) boundaryCalls=\(boundaryCalls) verifying=\(boundaryReceipt?.status == .verifying) finalCompleted=\(linked?.status == .completed) exactPath=\(boundaryReceipt?.artifacts == [target.path])")
            } catch {
                if let id = submittedID { capture(id); manager.cancel(id) }
                PermissionGate.shared.resetForRestartTesting()
                for operation in operations { operation.cancel() }
                for operation in operations { await operation.value }
                _ = ActionOrchestrator.shared.setResultVerificationBoundaryForTesting(root: directory, nil)
                throw error
            }
            guard ActionOrchestrator.shared.setResultVerificationBoundaryForTesting(root: directory, nil) else {
                throw FixtureError.unsafeRoot
            }
            PermissionGate.shared.resetForRestartTesting()
        }
        check(PermissionGrantStore.shared.grants == grantsBefore && SelfTestStoreGuard.take() == ownerBefore,
            "scoped mutation receipt C14: real proof changed owner files/defaults/standing grants")
        SelfTest.diagnostic("SCOPED_MUTATION_RECEIPT_CHECKS: \(checks) problems=\(problems)")
    }
}

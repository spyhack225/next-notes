import Foundation

/// Original Manager → LocalBackend → Executor → runtime receipt → temporary read path.
/// No future producer API is required: the same cases must fail before its repair.
@MainActor
enum TaskReceiptCompletionSelfTest {
    private enum FixtureError: Error { case unsafeRoot, invalidBacking }

    static func originalCases(root: URL, input: URL, text: String,
                              check: (Bool, String) -> Void) async throws {
        let safeRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard SelfTest.isRunning, safeRoot.isFileURL,
              safeRoot.path.hasPrefix(temporary.path + "/"),
              !safeRoot.pathComponents.contains("Application Support") else { throw FixtureError.unsafeRoot }
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
        for mode in ["accepted", "terminal-write-rejected"] {
            let directory = safeRoot.appendingPathComponent("receipt-completion-" + mode, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let sql = TaskStore(root: directory)
            defer { sql.close() }
            let export = directory.appendingPathComponent("agent-tasks.json")
            let store = AgentTaskStore(fileURL: export, mirror: sql)
            guard store.allowsHarnessPersistence else { throw FixtureError.unsafeRoot }
            let receiptFile = directory.appendingPathComponent("action-receipts.json")
            let retainedFile = directory.appendingPathComponent("retained-fired.json")
            let receipts = ActionReceiptStore(fileURL: receiptFile)
            let manager = AgentTaskManager(store: store, receiptStore: receipts)
            var context: TaskJournalContext?
            var effects = 0
            var announcements: [String] = []
            var firedBeforeBacking: ActionReceipt?
            var memoryBeforeBacking: ActionReceipt?
            var bytesBeforeBacking: Data?
            var preBackingJoined = false
            var didRejectTerminalPath = false
            manager.announcementForTesting = { announcements.append($0) }
            manager.backendEntryForTesting = { context = TaskEventJournal.current }
            AgentToolExecutor.fireOverrideForTesting = { tool, arguments in
                guard let context, tool.id == "filesystem.read", arguments == ["path": input.path] else {
                    throw FixtureError.invalidBacking
                }
                let freshSQL = TaskStore(root: directory)
                defer { freshSQL.close() }
                let row = try freshSQL.load().first { $0.id == context.taskID }
                let fresh = ActionReceiptStore(fileURL: receiptFile)
                guard let fired = fresh.receipts.first(where: { $0.taskID == context.taskID && $0.status == .fired }) else {
                    throw FixtureError.invalidBacking
                }
                firedBeforeBacking = fired
                memoryBeforeBacking = receipts.receipt(for: fired.actionID)
                bytesBeforeBacking = try Data(contentsOf: receiptFile)
                preBackingJoined = row?.status == .running
                    && row?.durability?.receiptIDs == [fired.actionID.uuidString]
                    && fired.taskAttempt == context.attempt
                    && fired.taskLeaseOwner == row?.durability?.leaseOwner
                    && fired.taskLeaseOwner == String(ProcessInfo.processInfo.processIdentifier)
                    && fired.preparedAction?.id == fired.actionID
                    && fired.preparedAction?.executionPlan.arguments == arguments
                // This is the original real read, not a helper returning invented output.
                let result = try FilesystemExecutor.run(tool, arguments: arguments)
                effects += 1
                if mode == "terminal-write-rejected" {
                    // Preserve the exact admitted evidence, then make atomic terminal writes fail.
                    try FileManager.default.moveItem(at: receiptFile, to: retainedFile)
                    try FileManager.default.createDirectory(at: receiptFile, withIntermediateDirectories: false)
                    didRejectTerminalPath = true
                }
                return result
            }
            let submitted = manager.submit(objective: "Read original terminal receipt fixture", tool: "filesystem.read",
                arguments: ["path": input.path], source: "selftest")
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(5))
            while clock.now < deadline,
                  manager.task(id: submitted.id)?.status == .queued || manager.task(id: submitted.id)?.status == .running {
                await Task.yield()
            }
            let final = manager.task(id: submitted.id)
            let primary = try sql.load().first { $0.id == submitted.id }
            let events = try sql.journal(taskID: submitted.id)
            let linkedIDs = firedBeforeBacking.map { [$0.actionID.uuidString] } ?? []
            check(effects == 1 && preBackingJoined && manager.backendStartsForTesting == 1,
                "receipt completion: original read lacked exact fresh pre-backing receipt/primary binding (\(mode))")
            check(!linkedIDs.isEmpty && primary?.durability?.receiptIDs == linkedIDs
                && final?.durability?.receiptIDs == primary?.durability?.receiptIDs,
                "receipt completion: terminal primary/memory history lost the exact receipt link (\(mode))")
            if mode == "accepted" {
                let fresh = ActionReceiptStore(fileURL: receiptFile)
                let receipt = fresh.receipts.first { $0.actionID == firedBeforeBacking?.actionID }
                check(final?.status == .completed && primary?.status == .completed
                    && final?.result?.contains(text) == true && receipt?.status == .completed,
                    "receipt completion: control did not persist the real original read and terminal receipt")
                check(announcements.contains { $0.contains(text) }
                    && events.contains { $0.draft.kind == .jobCompleted },
                    "receipt completion: control did not exercise the actual successful task delivery")
            } else {
                let retainedBytes = try Data(contentsOf: retainedFile)
                let retained = ActionReceiptStore(fileURL: retainedFile)
                let retainedReceipt = retained.receipts.first { $0.actionID == firedBeforeBacking?.actionID }
                let memoryReceipt = firedBeforeBacking.flatMap { receipts.receipt(for: $0.actionID) }
                let refusedContents = try FileManager.default.contentsOfDirectory(atPath: receiptFile.path)
                check(didRejectTerminalPath && retainedBytes == bytesBeforeBacking
                    && refusedContents.isEmpty,
                    "receipt completion: terminal disk rejection did not retain exact fired bytes and empty refused path")
                check(retainedReceipt == firedBeforeBacking && memoryReceipt == memoryBeforeBacking
                    && memoryReceipt?.status == .fired
                    && retainedReceipt?.status == .fired,
                    "receipt completion: failed terminal persistence invented or erased committed receipt evidence")
                check(final?.status == .failed && primary?.status == .failed && final?.result == nil,
                    "receipt completion: original task completed after terminal receipt persistence failed")
                check(!announcements.contains { $0.contains(text) }
                    && !events.contains { $0.draft.kind == .jobCompleted }
                    && events.contains { $0.draft.kind == .jobFailed },
                    "receipt completion: terminal receipt rejection delivered original result or successful task fact")
                let failure = "The action ran, but its result could not be saved. Check it before trying again."
                check(final?.failure == failure && primary?.failure == failure && announcements.contains(failure),
                    "receipt completion: terminal receipt rejection did not report that the action ran but its result was not saved")
                SelfTest.diagnostic("TASK_RECEIPT_COMPLETION_TRACE: terminal=\(final?.status.rawValue ?? "absent") effects=\(effects) resultDelivered=\(announcements.contains { $0.contains(text) }) retainedFired=\(retainedReceipt?.status == .fired) primaryLink=\(primary?.durability?.receiptIDs == linkedIDs)")
            }
            // Fresh-object observation is bounded restart evidence, not a process-crash claim.
            let reloaded = AgentTaskManager(store: AgentTaskStore(fileURL: export, mirror: sql),
                receiptStore: ActionReceiptStore(fileURL: mode == "accepted" ? receiptFile : retainedFile))
            for _ in 0..<16 { await Task.yield() }
            let afterReload = try sql.load().first { $0.id == submitted.id }
            check(reloaded.backendStartsForTesting == 0 && effects == 1
                && afterReload == primary,
                "receipt completion: terminal history auto-started or re-executed the original read (\(mode))")
        }
    }
}

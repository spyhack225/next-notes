import Foundation

/// Actual task/backend/executor/receipt store and original temporary-file backing.
/// These original cases also compile against the unjoined receipt producer.
@MainActor
enum TaskReceiptJoinSelfTest {
    private enum FixtureError: Error { case invalid }

    static func originalCases(root: URL, input: URL, text: String,
                              check: (Bool, String) -> Void) async throws {
        for mode in ["accepted", "export-rejected", "start-rejected", "completion-rejected"] {
            let directory = root.appendingPathComponent("receipt-join-" + mode, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let sql = TaskStore(root: directory)
            defer { sql.close() }
            let export = directory.appendingPathComponent("agent-tasks.json")
            let store = AgentTaskStore(fileURL: export, mirror: sql)
            guard store.allowsHarnessPersistence else { throw FixtureError.invalid }
            let receiptFile = directory.appendingPathComponent("action-receipts.json")
            let receipts = ActionReceiptStore(fileURL: receiptFile)
            let manager = AgentTaskManager(store: store, receiptStore: receipts)
            var context: TaskJournalContext?
            var effects = 0
            var joinedBeforeBacking = false
            var boundBeforeBacking = false
            manager.backendEntryForTesting = {
                context = TaskEventJournal.current
                if mode == "export-rejected" {
                    try FileManager.default.removeItem(at: export)
                    try FileManager.default.createDirectory(at: export, withIntermediateDirectories: false)
                }
                if mode == "start-rejected" || mode == "completion-rejected" {
                    let kind = mode == "start-rejected" ? "toolStarted" : "toolCompleted"
                    try sql.withConnection { db in
                        try TaskStore.exec(db, "CREATE TRIGGER reject_receipt_join BEFORE INSERT ON task_event WHEN NEW.kind='\(kind)' BEGIN SELECT RAISE(ABORT,'fixture receipt-join rejection'); END")
                    }
                }
            }
            AgentToolExecutor.fireOverrideForTesting = { tool, arguments in
                guard let context, tool.id == "filesystem.read", arguments == ["path": input.path] else {
                    throw FixtureError.invalid
                }
                let fresh = ActionReceiptStore(fileURL: receiptFile)
                guard let fired = fresh.receipts.first(where: { $0.taskID == context.taskID && $0.status == .fired }) else {
                    throw FixtureError.invalid
                }
                let row = try TaskStore(root: directory).load().first { $0.id == context.taskID }
                joinedBeforeBacking = row?.durability?.receiptIDs == [fired.actionID.uuidString]
                let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fired)) as? [String: Any]
                boundBeforeBacking = object?["taskAttempt"] as? Int == context.attempt
                    && object?["taskLeaseOwner"] as? String == row?.durability?.leaseOwner
                    && row?.durability?.leaseOwner == String(ProcessInfo.processInfo.processIdentifier)
                effects += 1
                return try FilesystemExecutor.run(tool, arguments: arguments)
            }
            let submitted = manager.submit(objective: "Read exact receipt join fixture", tool: "filesystem.read",
                arguments: ["path": input.path], source: "selftest")
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(5))
            while clock.now < deadline, manager.task(id: submitted.id)?.status == .queued
                || manager.task(id: submitted.id)?.status == .running { await Task.yield() }
            let final = manager.task(id: submitted.id)
            let freshRows = try sql.load()
            let finalIDs = freshRows.first(where: { $0.id == submitted.id })?.durability?.receiptIDs ?? []
            let finalReceipts = ActionReceiptStore(fileURL: receiptFile).receipts.filter { $0.taskID == submitted.id }
            if mode == "start-rejected" {
                check(effects == 0 && final?.status == .failed && finalIDs.isEmpty,
                    "receipt join: rejected SQL start leaked backing or a receipt link")
                check(finalReceipts.count == 1 && finalReceipts[0].events.contains(where: { $0.stage == .fired }),
                    "receipt join: rejected SQL start erased retained runtime evidence")
            } else {
                check(effects == 1 && joinedBeforeBacking,
                    "receipt join: fresh primary row had no exact receipt ID before actual backing (\(mode))")
                check(boundBeforeBacking,
                    "receipt join: fresh fired receipt lacked admitted attempt/process binding (\(mode))")
                check(finalIDs.count == 1 && finalReceipts.count == 1
                    && finalIDs.first == finalReceipts.first?.actionID.uuidString,
                    "receipt join: terminal primary row lost exact durable receipt link (\(mode))")
                if mode == "completion-rejected" {
                    check(final?.status == .failed && finalReceipts.first?.status == .completed,
                        "receipt join: completion journal rejection lost runtime receipt or delivered task success")
                } else {
                    check(final?.status == .completed && final?.result?.contains(text) == true
                        && finalReceipts.first?.status == .completed,
                        "receipt join: admitted actual original read did not complete (\(mode))")
                }
            }
        }
    }
}

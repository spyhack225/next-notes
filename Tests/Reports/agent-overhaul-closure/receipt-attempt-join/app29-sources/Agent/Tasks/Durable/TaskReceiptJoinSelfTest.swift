import Foundation

/// Actual task/backend/executor/receipt store and original temporary-file backing.
/// These original cases also compile against the unjoined receipt producer.
@MainActor
enum TaskReceiptJoinSelfTest {
    private enum FixtureError: Error { case invalid }

    static func originalCases(root: URL, input: URL, text: String,
                              check: (Bool, String) -> Void) async throws {
        for mode in ["accepted", "export-rejected", "start-rejected", "completion-rejected", "boundaries", "receipt-write-rejected"] {
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
            var boundaryResults: [(Bool, String)] = []
            manager.backendEntryForTesting = {
                context = TaskEventJournal.current
                if mode == "export-rejected" {
                    try FileManager.default.removeItem(at: export)
                    try FileManager.default.createDirectory(at: export, withIntermediateDirectories: false)
                }
                if mode == "receipt-write-rejected" {
                    try FileManager.default.createDirectory(at: receiptFile, withIntermediateDirectories: false)
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
                if mode == "boundaries" {
                    boundaryResults = try await boundaryCases(receipt: fired, context: context,
                        sql: sql, receipts: receipts, input: input)
                }
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
            for (passed, message) in boundaryResults { check(passed, message) }
            if mode == "receipt-write-rejected" {
                check(effects == 0 && final?.status == .failed && finalIDs.isEmpty,
                    "receipt join: receipt write rejection leaked backing or primary link")
                check(receipts.receipts.isEmpty && finalReceipts.isEmpty,
                    "receipt join: failed receipt persistence invented committed evidence")
            } else if mode == "start-rejected" {
                check(effects == 0 && final?.status == .failed && finalIDs.isEmpty,
                    "receipt join: rejected SQL start leaked backing or a receipt link")
                check(finalReceipts.count == 1 && finalReceipts[0].events.contains(where: { $0.stage == .fired }),
                    "receipt join: rejected SQL start erased retained runtime evidence")
            } else {
                check(effects == 1 && joinedBeforeBacking,
                    "receipt join: fresh primary row had no exact receipt ID before actual backing (\(mode))")
                check(boundBeforeBacking,
                    "receipt join: fresh fired receipt lacked admitted attempt/process binding (\(mode))")
                let linkedReceipt = finalReceipts.first { $0.actionID.uuidString == finalIDs.first }
                check(finalIDs.count == 1 && (mode == "boundaries" || finalReceipts.count == 1)
                    && finalIDs.first == linkedReceipt?.actionID.uuidString,
                    "receipt join: terminal primary row lost exact durable receipt link (\(mode))")
                if mode == "completion-rejected" {
                    check(final?.status == .failed && finalReceipts.first?.status == .completed,
                        "receipt join: completion journal rejection lost runtime receipt or delivered task success")
                } else {
                    check(final?.status == .completed && final?.result?.contains(text) == true
                        && linkedReceipt?.status == .completed,
                        "receipt join: admitted actual original read did not complete (\(mode))")
                }
            }
        }
        try await continuationCases(root: root, input: input, text: text, check: check)
    }

    private static func boundaryCases(receipt original: ActionReceipt, context: TaskJournalContext,
                                      sql: TaskStore, receipts: ActionReceiptStore, input: URL) async throws
        -> [(Bool, String)] {
        var results: [(Bool, String)] = []
        let names = ["missing-id", "missing-receipt", "legacy-unbound", "wrong-attempt", "wrong-owner",
                     "wrong-task", "wrong-tool", "wrong-prepared-id", "wrong-prepared-task",
                     "wrong-intent", "wrong-prepared-tool", "not-fired", "missing-fired-event", "duplicate"]
        for name in names {
            var receipt = original
            receipt.actionID = name == "duplicate" ? original.actionID : UUID()
            receipt.preparedAction?.id = receipt.actionID
            switch name {
            case "legacy-unbound":
                // Decode the actual old shape; optional fields must stay absent, never invented.
                var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as! [String: Any]
                object.removeValue(forKey: "taskAttempt")
                object.removeValue(forKey: "taskLeaseOwner")
                receipt = try JSONDecoder().decode(ActionReceipt.self,
                    from: JSONSerialization.data(withJSONObject: object))
                results.append((receipt.taskAttempt == nil && receipt.taskLeaseOwner == nil,
                    "receipt join: legacy decode invented live ownership"))
            case "wrong-attempt": receipt.taskAttempt = context.attempt + 1
            case "wrong-owner": receipt.taskLeaseOwner = "another-process"
            case "wrong-task": receipt.taskID = "another-task"
            case "wrong-tool": receipt.toolID = "filesystem.write"
            case "wrong-prepared-id": receipt.preparedAction?.id = UUID()
            case "wrong-prepared-task": receipt.preparedAction?.routing.taskID = "another-task"
            case "wrong-intent": receipt.preparedAction?.intentID = UUID()
            case "wrong-prepared-tool": receipt.preparedAction?.executionPlan.toolID = "filesystem.write"
            case "not-fired": receipt.status = .approved
            case "missing-fired-event": receipt.events.removeAll { $0.stage == .fired }
            default: break
            }
            if !["missing-id", "missing-receipt", "duplicate"].contains(name) {
                guard receipts.record(receipt) else { throw FixtureError.invalid }
            }
            let rows = try sql.load()
            let events = try sql.journal(taskID: context.taskID)
            var effects = 0
            var exactRefusal = false
            do {
                _ = try TaskEventJournal.toolStarted(taskID: context.taskID, tool: "filesystem.read",
                    receiptID: name == "missing-id" ? nil : receipt.actionID)
                effects += 1
                guard let tool = AgentToolRegistry.shared.tool(named: "filesystem.read") else { throw FixtureError.invalid }
                _ = try FilesystemExecutor.run(tool, arguments: ["path": input.path])
            } catch let error as AgentError {
                if case .backendUnavailable(let message) = error {
                    exactRefusal = message == "The action could not be saved. It was not run."
                }
            }
            results.append((exactRefusal && effects == 0,
                "receipt join: malformed/duplicate binding reached actual backing (\(name))"))
            results.append((try sql.load() == rows && sql.journal(taskID: context.taskID) == events,
                "receipt join: refused binding changed primary history (\(name))"))
        }
        return results
    }

    private static func continuationCases(root: URL, input: URL, text: String,
                                           check: (Bool, String) -> Void) async throws {
        guard PermissionGate.shared.pending == nil else { throw FixtureError.invalid }
        let oldPolicy = AgentToolExecutor.policyOverrideForTesting
        defer {
            AgentToolExecutor.policyOverrideForTesting = oldPolicy
            PermissionGate.shared.resetForRestartTesting()
        }
        func wait(_ condition: () -> Bool) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(5))
            while clock.now < deadline { if condition() { return true }; await Task.yield() }
            return condition()
        }
        for mode in ["permission", "input"] {
            let directory = root.appendingPathComponent("receipt-continuation-" + mode, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let sql = TaskStore(root: directory)
            defer { sql.close() }
            let export = directory.appendingPathComponent("agent-tasks.json")
            let store = AgentTaskStore(fileURL: export, mirror: sql)
            let receiptFile = directory.appendingPathComponent("action-receipts.json")
            let receipts = ActionReceiptStore(fileURL: receiptFile)
            let original = AgentTaskManager(store: store, receiptStore: receipts)
            let output = directory.appendingPathComponent("approved.txt")
            let initial = "Original proposed receipt fixture"
            let edited = "Exact approved receipt fixture"
            let isPermission = mode == "permission"
            let toolID = isPermission ? "filesystem.write" : "filesystem.read"
            let arguments = isPermission ? ["path": output.path, "text": initial] : [:]
            AgentToolExecutor.policyOverrideForTesting = isPermission ? .denyMutations : .selfTest
            let objective = isPermission ? "Write \(initial) to \(output.path)." : "Read the file I will choose."
            AgentSession.shared.recordUser(objective, source: .text)
            var oldContext: TaskJournalContext?
            original.backendEntryForTesting = { oldContext = TaskEventJournal.current }
            var effects = 0
            var backingJoined = false
            var oldContextRefused = false
            AgentToolExecutor.fireOverrideForTesting = { _, _ in effects += 1; throw FixtureError.invalid }
            let submitted = original.submit(objective: objective, tool: toolID, arguments: arguments, source: "text")
            check(await wait {
                original.task(id: submitted.id)?.status == (isPermission ? .waitingForPermission : .waitingForInput)
                    && (!isPermission || PermissionGate.shared.pending?.taskID == submitted.id)
            }, "receipt join: original continuation was not genuinely parked (\(mode))")
            guard let saved = try sql.load().first, let attempt = saved.durability?.attempt, let oldContext else {
                throw FixtureError.invalid
            }
            let initialReceipts = ActionReceiptStore(fileURL: receiptFile).receipts
            check(effects == 0 && saved.durability?.receiptIDs.isEmpty == true
                && (isPermission ? initialReceipts.count == 1
                    && initialReceipts[0].status == .waitingPermission && initialReceipts[0].taskAttempt == attempt
                    : initialReceipts.isEmpty),
                "receipt join: parked attempt linked an unfired action or lost original receipt (\(mode))")
            PermissionGate.shared.resetForRestartTesting()
            let fresh = AgentTaskManager(store: AgentTaskStore(fileURL: export, mirror: sql), receiptStore: receipts)
            fresh.restorePendingInteractions()
            fresh.backendEntryForTesting = {
                let rows = try sql.load()
                let events = try sql.journal(taskID: submitted.id)
                oldContextRefused = try !oldContext.record(TaskJournalEventDraft(taskID: submitted.id,
                    kind: .toolStarted, detail: toolID, attempt: oldContext.attempt,
                    receiptID: initialReceipts.first?.actionID))
                    && sql.load() == rows && sql.journal(taskID: submitted.id) == events
            }
            AgentToolExecutor.fireOverrideForTesting = { tool, actual in
                let row = try sql.load().first
                let fired = ActionReceiptStore(fileURL: receiptFile).receipts.first { $0.status == .fired }
                backingJoined = row?.durability?.attempt == attempt + 1
                    && row?.durability?.receiptIDs == fired.map { [$0.actionID.uuidString] }
                    && fired?.taskAttempt == attempt + 1
                    && fired?.taskLeaseOwner == String(ProcessInfo.processInfo.processIdentifier)
                    && fired?.taskID == submitted.id && fired?.preparedAction?.executionPlan.arguments == actual
                guard tool.id == toolID, actual == (isPermission ? ["path": output.path, "text": edited] : ["path": input.path]) else {
                    throw FixtureError.invalid
                }
                effects += 1
                return try FilesystemExecutor.run(tool, arguments: actual)
            }
            if isPermission {
                guard case .permission(let request, _, _) = saved.pendingInteraction else { throw FixtureError.invalid }
                ToolCallReviewStore.shared.update(id: request.id, field: "text", to: edited)
                ToolCallReviewStore.shared.confirm(id: request.id, field: "path")
                check(PermissionGate.shared.respond(id: request.id, approved: true),
                    "receipt join: genuine restored approval was rejected")
            } else {
                guard case .input(let request) = saved.pendingInteraction else { throw FixtureError.invalid }
                check(fresh.respondInput(taskID: submitted.id, text: input.path, requestID: request.id),
                    "receipt join: genuine restored answer was rejected")
            }
            check(await wait { fresh.task(id: submitted.id)?.status == .completed },
                "receipt join: exact continuation did not complete (\(mode))")
            check(effects == 1 && backingJoined && oldContextRefused,
                "receipt join: continuation lost successor binding or admitted old context (\(mode))")
            let completed = try sql.load().first
            let final = ActionReceiptStore(fileURL: receiptFile).receipts
            let linked = final.filter { completed?.durability?.receiptIDs.contains($0.actionID.uuidString) == true }
            check(completed?.durability?.attempt == attempt + 1 && linked.count == 1
                && linked[0].status == .completed && linked[0].taskAttempt == attempt + 1
                && (!isPermission || linked[0].actionID != initialReceipts.first?.actionID),
                "receipt join: terminal continuation did not retain its distinct successor receipt (\(mode))")
            check(isPermission ? (try? String(contentsOf: output, encoding: .utf8)) == edited
                : fresh.task(id: submitted.id)?.result?.contains(text) == true,
                "receipt join: original approved write/read result was lost (\(mode))")
        }
    }
}

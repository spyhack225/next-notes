import Foundation

/// Existing actual Manager -> LocalBackend -> Executor ->
/// Orchestrator -> original temporary Filesystem read. No stale/health/retry claim.
@MainActor
enum TaskWorkerBindingSelfTest {
    private enum FixtureError: Error { case unsafeRoot, missingContext, timeout, heldRestart }

    @MainActor
    private final class State {
        var entered = 0
        var ended = false
        var effects = 0
        var context: TaskJournalContext?
        var entryBinding: TaskWorkerBinding?
        var backingBinding: TaskWorkerBinding?
        var entryMatches = false
        var backingMatches = false
        var backing: CheckedContinuation<Void, Never>?
    }

    @MainActor
    private static func reached(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    private static func canonicalDate(_ date: Date) throws -> Date {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Date.self, from: encoder.encode(date))
    }

    /// Compare captured producer time exactly in memory, and via the store's
    /// existing ISO8601 representation on disk. No replacement clock/tolerance.
    private static func matches(_ binding: TaskWorkerBinding?, manager: AgentTaskManager,
                                sql: TaskStore, taskID: String) throws -> Bool {
        guard let binding, let memory = manager.task(id: taskID),
              let metadata = memory.durability, let started = metadata.attemptStartedAt,
              let disk = try sql.load().first(where: { $0.id == taskID }),
              let diskMetadata = disk.durability else { return false }
        let canonical = try canonicalDate(started)
        return memory.status == .running && disk.status == .running
            && binding.taskID == taskID && binding.attempt > 0
            && binding.attempt == metadata.attempt && binding.attempt == diskMetadata.attempt
            && binding.leaseOwner == String(ProcessInfo.processInfo.processIdentifier)
            && binding.leaseOwner == metadata.leaseOwner && binding.leaseOwner == diskMetadata.leaseOwner
            && binding.startedAt == started && diskMetadata.attemptStartedAt == canonical
    }

    static func originalCases(root: URL, input: URL, text: String,
                              check: (Bool, String) -> Void) async throws {
        let safeRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard SelfTest.isRunning, safeRoot.path.hasPrefix(temporary.path + "/"),
              input.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(safeRoot.path + "/"),
              !safeRoot.pathComponents.contains("Application Support") else { throw FixtureError.unsafeRoot }
        let oldFake = AgentToolExecutor.fakeForTesting
        let oldFire = AgentToolExecutor.fireOverrideForTesting
        let oldPolicy = AgentToolExecutor.policyOverrideForTesting
        defer {
            AgentToolExecutor.fakeForTesting = oldFake
            AgentToolExecutor.fireOverrideForTesting = oldFire
            AgentToolExecutor.policyOverrideForTesting = oldPolicy
        }
        AgentToolExecutor.fakeForTesting = nil
        AgentToolExecutor.policyOverrideForTesting = .selfTest

        for mode in ["normal", "cancel", "restart"] {
            let directory = safeRoot.appendingPathComponent("worker-binding-" + mode, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let sql = TaskStore(root: directory)
            defer { sql.close() }
            let export = directory.appendingPathComponent("agent-tasks.json")
            let store = AgentTaskStore(fileURL: export, mirror: sql)
            guard store.allowsHarnessPersistence else { throw FixtureError.unsafeRoot }
            let receiptFile = directory.appendingPathComponent("action-receipts.json")
            let receipts = ActionReceiptStore(fileURL: receiptFile)
            let manager = AgentTaskManager(store: store, receiptStore: receipts)
            let state = State()
            manager.backendEntryForTesting = {
                guard let context = TaskEventJournal.current else { throw FixtureError.missingContext }
                state.entered += 1
                state.context = context
                state.entryBinding = manager.workerBinding(taskID: context.taskID)
                state.entryMatches = try matches(state.entryBinding, manager: manager, sql: sql,
                    taskID: context.taskID)
            }
            manager.backendExitForTesting = { state.ended = true }
            AgentToolExecutor.fireOverrideForTesting = { tool, arguments in
                guard let context = TaskEventJournal.current, tool.id == "filesystem.read",
                      arguments == ["path": input.path] else { throw FixtureError.missingContext }
                state.backingBinding = manager.workerBinding(taskID: context.taskID)
                state.backingMatches = try matches(state.backingBinding, manager: manager, sql: sql,
                    taskID: context.taskID)
                // The hold is only after actual fired receipt/tool-start admission.
                // It deliberately ignores cancellation until explicitly resumed.
                await withCheckedContinuation { state.backing = $0 }
                if mode == "restart" { throw FixtureError.heldRestart }
                state.effects += 1
                return try FilesystemExecutor.run(tool, arguments: arguments)
            }
            let submitted = manager.submit(objective: "Observe an admitted temporary read",
                tool: "filesystem.read", arguments: ["path": input.path], source: "selftest")
            check(manager.workerBinding(taskID: submitted.id) == nil,
                "worker binding: queued handle claimed an admitted worker (\(mode))")
            var caught: Error?
            do {
                guard await reached({ state.backing != nil }) else { throw FixtureError.timeout }
                check(state.entered == 1 && state.entryMatches,
                    "worker binding: actual backend entry lacked exact admitted handle identity (\(mode))")
                check(state.backingMatches && state.backingBinding == state.entryBinding,
                    "worker binding: original held backing lacked the same admitted handle identity (\(mode))")

                let memoryBefore = manager.tasks
                let rowsBefore = try sql.load()
                let eventsBefore = try sql.journal(taskID: submitted.id)
                let authorityBefore = try sql.probeAuthority(includeTasks: false)?.authority
                let exportBefore = try Data(contentsOf: export)
                let receiptsBefore = ActionReceiptStore(fileURL: receiptFile).receipts
                let ownerBefore = SelfTestStoreGuard.take()
                var unchangedBinding = true
                for _ in 0..<8 {
                    if manager.workerBinding(taskID: submitted.id) != state.entryBinding { unchangedBinding = false }
                }
                let rowsAfter = try sql.load()
                let eventsAfter = try sql.journal(taskID: submitted.id)
                let authorityAfter = try sql.probeAuthority(includeTasks: false)?.authority
                let exportAfter = try Data(contentsOf: export)
                let receiptsAfter = ActionReceiptStore(fileURL: receiptFile).receipts
                check(unchangedBinding && manager.tasks == memoryBefore && rowsAfter == rowsBefore
                    && eventsAfter == eventsBefore && authorityAfter == authorityBefore
                    && exportAfter == exportBefore && receiptsAfter == receiptsBefore && state.effects == 0,
                    "worker binding: observation changed actual primary/export/receipt/backing state (\(mode))")
                check(SelfTestStoreGuard.diff(ownerBefore, SelfTestStoreGuard.take()).isEmpty,
                    "worker binding: observation changed an owner store/default (\(mode))")
                check(state.context?.isStillValid?() == true,
                    "worker binding: positive control lost existing authoritative validity (\(mode))")

                if mode == "cancel" {
                    manager.cancel(submitted.id)
                    let cancelled = try sql.load().first { $0.id == submitted.id }
                    check(cancelled?.status == .cancelled && state.backing != nil && !state.ended,
                        "worker binding: cancellation did not overlap the actual held backing")
                    check(manager.workerBinding(taskID: submitted.id) == nil
                        && state.context?.isStillValid?() == false,
                        "worker binding: cancelled handle retained positive observation/authority")
                    // Removing a handle is not cessation of its already-entered backing.
                    // The one restricted read below is cooperative-cancellation evidence,
                    // never successful delivery, retry or proof of no effect.
                } else if mode == "restart" {
                    let fresh = AgentTaskManager(store: AgentTaskStore(fileURL: export, mirror: sql),
                        receiptStore: receipts)
                    let held = try sql.load().first { $0.id == submitted.id }
                    check(held?.status == .recovering && fresh.workerBinding(taskID: submitted.id) == nil,
                        "worker binding: fresh held manager invented a live worker")
                    check(state.context?.isStillValid?() == false,
                        "worker binding: retained old handle passed authoritative restart hold")
                    // Original Manager may still report its old captured handle; this
                    // API deliberately performs no SQL probe or external mutation check.
                    check(manager.workerBinding(taskID: submitted.id) == state.entryBinding,
                        "worker binding: restart changed the original captured handle observation")
                }
            } catch { caught = error }

            if caught != nil { manager.cancel(submitted.id) }
            let continuation = state.backing
            state.backing = nil
            continuation?.resume()
            let joined = await reached { state.ended }
            check(joined, "worker binding: actual held worker failed bounded cleanup (\(mode))")
            if let caught { throw caught }
            check(manager.workerBinding(taskID: submitted.id) == nil,
                "worker binding: exited handle retained positive observation (\(mode))")
            let final = try sql.load().first { $0.id == submitted.id }
            if mode == "normal" {
                check(state.effects == 1 && final?.status == .completed && final?.result?.contains(text) == true,
                    "worker binding: unchanged original temporary read did not complete")
                check(ActionReceiptStore(fileURL: receiptFile).receipts.contains {
                    $0.taskID == submitted.id && $0.status == .completed
                        && $0.taskAttempt == state.context?.attempt
                }, "worker binding: original read lost its exact completed receipt")
            } else if mode == "cancel" {
                check(state.effects == 1 && final?.status == .cancelled && final?.result == nil,
                    "worker binding: late cancellation-ignoring backing became successful task delivery")
            } else {
                check(state.effects == 0 && final?.status == .recovering,
                    "worker binding: old worker replaced committed held history or entered the stopped read")
            }
        }

        for mode in ["worker-start-rejected", "tool-start-rejected"] {
            let directory = safeRoot.appendingPathComponent("worker-binding-" + mode, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let sql = TaskStore(root: directory)
            defer { sql.close() }
            let store = AgentTaskStore(fileURL: directory.appendingPathComponent("agent-tasks.json"), mirror: sql)
            guard store.allowsHarnessPersistence else { throw FixtureError.unsafeRoot }
            let receipts = ActionReceiptStore(fileURL: directory.appendingPathComponent("action-receipts.json"))
            let manager = AgentTaskManager(store: store, receiptStore: receipts)
            let state = State()
            if mode == "worker-start-rejected" {
                try sql.withConnection { db in
                    try TaskStore.exec(db, "CREATE TRIGGER reject_binding_start BEFORE INSERT ON task_event WHEN NEW.kind='workerStarted' BEGIN SELECT RAISE(ABORT,'fixture worker start rejection'); END")
                }
            }
            manager.backendEntryForTesting = {
                guard let context = TaskEventJournal.current else { throw FixtureError.missingContext }
                state.entered += 1
                state.entryMatches = try matches(manager.workerBinding(taskID: context.taskID),
                    manager: manager, sql: sql, taskID: context.taskID)
                try sql.withConnection { db in
                    try TaskStore.exec(db, "CREATE TRIGGER reject_binding_tool_start BEFORE INSERT ON task_event WHEN NEW.kind='toolStarted' BEGIN SELECT RAISE(ABORT,'fixture tool start rejection'); END")
                }
            }
            manager.backendExitForTesting = { state.ended = true }
            AgentToolExecutor.fireOverrideForTesting = { tool, arguments in
                state.effects += 1
                return try FilesystemExecutor.run(tool, arguments: arguments)
            }
            let submitted = manager.submit(objective: "Refuse a rejected admitted read", tool: "filesystem.read",
                arguments: ["path": input.path], source: "selftest")
            let settled = await reached {
                if mode == "worker-start-rejected" { return manager.task(id: submitted.id)?.status == .failed }
                return state.ended
            }
            check(settled && state.effects == 0 && manager.workerBinding(taskID: submitted.id) == nil,
                "worker binding: primary rejection leaked backing/live observation (\(mode))")
            if mode == "worker-start-rejected" {
                check(state.entered == 0 && receipts.receipts.isEmpty,
                    "worker binding: rejected worker start reached backend/receipts")
            } else {
                check(state.entered == 1 && state.entryMatches,
                    "worker binding: tool rejection lost prior admitted backend binding")
            }
        }
    }
}

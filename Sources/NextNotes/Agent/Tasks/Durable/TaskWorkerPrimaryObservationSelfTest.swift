import Foundation

/// Actual worker/primary validity path, held after the existing fired/tool-start
/// admission. Cache metadata is last-read evidence, never current health/effects.
@MainActor
enum TaskWorkerPrimaryObservationSelfTest {
    private enum FixtureError: Error { case unsafeRoot, missingContext, timeout, stoppedRead }
    @MainActor
    private final class State {
        var entered = 0
        var exited = 0
        var effects = 0
        var contexts: [TaskJournalContext] = []
        var entryCacheAbsent = true
        var backingObservation: TaskWorkerPrimaryObservation?
        var backing: CheckedContinuation<Void, Never>?
    }

    private static func reached(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    private static func matches(_ observed: TaskWorkerPrimaryObservation?, task: AgentTask?) -> Bool {
        guard let observed, let task, let durability = task.durability else { return false }
        return observed.outcome == .accepted && observed.expected.taskID == task.id
            && observed.expected.status == .running && observed.state == .running
            && observed.expected.attempt == durability.attempt
            && observed.expected.leaseOwner == durability.leaseOwner
            && observed.durability == durability && observed.observedAt <= Date()
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

        for mode in ["normal", "lock-unavailable", "row-damage", "restart", "input-successor"] {
            let directory = safeRoot.appendingPathComponent("primary-observation-" + mode, isDirectory: true)
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
                state.contexts.append(context)
                // This checkpoint is before the first existing LocalBackend probe.
                state.entryCacheAbsent = state.entryCacheAbsent
                    && manager.workerPrimaryObservation(taskID: context.taskID) == nil
            }
            manager.backendExitForTesting = { state.exited += 1 }
            AgentToolExecutor.fireOverrideForTesting = { tool, arguments in
                guard let context = TaskEventJournal.current, tool.id == "filesystem.read",
                      arguments == ["path": input.path] else { throw FixtureError.missingContext }
                // The last existing probe precedes the tool-start/link transaction.
                // Do not compare this retained cache to the later current SQL row.
                state.backingObservation = manager.workerPrimaryObservation(taskID: context.taskID)
                await withCheckedContinuation { state.backing = $0 }
                if mode == "row-damage" || mode == "restart" { throw FixtureError.stoppedRead }
                state.effects += 1
                return try FilesystemExecutor.run(tool, arguments: arguments)
            }
            let submitted = manager.submit(objective: "Observe the existing primary read",
                tool: "filesystem.read", arguments: mode == "input-successor" ? [:] : ["path": input.path],
                source: "selftest")
            check(manager.workerPrimaryObservation(taskID: submitted.id) == nil,
                "primary observation: queued handle invented a primary check (\(mode))")
            var caught: Error?
            do {
                if mode == "input-successor" {
                    guard await reached({ manager.task(id: submitted.id)?.status == .waitingForInput && state.exited == 1 }),
                          case .input(let question) = manager.task(id: submitted.id)?.pendingInteraction else {
                        throw FixtureError.timeout
                    }
                    check(manager.workerPrimaryObservation(taskID: submitted.id) == nil && state.effects == 0,
                        "primary observation: waiting input retained a live primary cache")
                    check(manager.respondInput(taskID: submitted.id, text: input.path, requestID: question.id),
                        "primary observation: exact original input continuation was rejected")
                    check(manager.workerPrimaryObservation(taskID: submitted.id) == nil,
                        "primary observation: queued successor inherited the predecessor cache")
                }
                guard await reached({ state.backing != nil }), let context = state.contexts.last else {
                    throw FixtureError.timeout
                }
                check(state.entryCacheAbsent && state.entered == (mode == "input-successor" ? 2 : 1),
                    "primary observation: backend entry fabricated a not-yet-run primary probe (\(mode))")
                let backing = state.backingObservation
                check(backing?.outcome == .accepted && backing?.state == .running
                    && backing?.expected.taskID == submitted.id && backing?.expected.attempt == context.attempt,
                    "primary observation: actual backing lacked metadata from the existing admitted read (\(mode))")

                let memoryBefore = manager.tasks
                let rowsBefore = try sql.load()
                let eventsBefore = try sql.journal(taskID: submitted.id)
                let authorityBefore = try sql.probeAuthority(includeTasks: false)?.authority
                let exportBefore = try Data(contentsOf: export)
                let receiptBefore = try Data(contentsOf: receiptFile)
                let ownerBefore = SelfTestStoreGuard.take()
                var opens = 0
                sql.authorityBoundaryForTesting = { name, _ in if name == "existingOpened" { opens += 1 } }
                let valid = context.isStillValid?() ?? false
                check(valid, "primary observation: unchanged actual primary validity refused control (\(mode))")
                let refreshedDisk = try sql.load().first { $0.id == submitted.id }
                check(opens == 2 && matches(manager.workerPrimaryObservation(taskID: submitted.id),
                    task: refreshedDisk),
                    "primary observation: existing two-open validity path lost exact decoded row metadata (\(mode))")
                sql.authorityBoundaryForTesting = nil
                let refreshed = manager.workerPrimaryObservation(taskID: submitted.id)
                let rowsAfter = try sql.load()
                let eventsAfter = try sql.journal(taskID: submitted.id)
                let authorityAfter = try sql.probeAuthority(includeTasks: false)?.authority
                let exportAfter = try Data(contentsOf: export)
                let receiptAfter = try Data(contentsOf: receiptFile)
                check(manager.tasks == memoryBefore && rowsAfter == rowsBefore && eventsAfter == eventsBefore
                    && authorityAfter == authorityBefore && exportAfter == exportBefore && receiptAfter == receiptBefore
                    && state.effects == 0 && SelfTestStoreGuard.diff(ownerBefore, SelfTestStoreGuard.take()).isEmpty,
                    "primary observation: real validity metadata changed stores/backing/owner state (\(mode))")
                opens = 0
                sql.authorityBoundaryForTesting = { name, _ in if name == "existingOpened" { opens += 1 } }
                var stable = true
                for _ in 0..<8 {
                    if manager.workerPrimaryObservation(taskID: submitted.id) != refreshed { stable = false }
                }
                check(stable && opens == 0 && state.effects == 0,
                    "primary observation: last-check getter probed SQL or changed metadata (\(mode))")
                sql.authorityBoundaryForTesting = nil

                if mode == "lock-unavailable" {
                    // Actual mirror NSLock contention, not a substituted reader result.
                    let refused = try sql.withConnection { _ in context.isStillValid?() == false }
                    let unavailable = manager.workerPrimaryObservation(taskID: submitted.id)
                    check(refused && unavailable?.outcome == .unavailable && unavailable?.state == nil
                        && unavailable?.durability == nil && unavailable?.expected.attempt == context.attempt,
                        "primary observation: fail-fast contention became accepted/missing-row metadata")
                    check(try sql.load() == rowsAfter && sql.journal(taskID: submitted.id) == eventsAfter
                        && Data(contentsOf: export) == exportAfter && Data(contentsOf: receiptFile) == receiptAfter
                        && state.effects == 0, "primary observation: unavailable read changed existing evidence")
                    check(context.isStillValid?() == true
                        && manager.workerPrimaryObservation(taskID: submitted.id)?.outcome == .accepted,
                        "primary observation: released contention did not restore actual primary read")
                } else if mode == "row-damage" {
                    // Isolated boundary damage: preserve generation deliberately so the
                    // existing exact-row predicate, rather than generation guard, refuses.
                    try sql.withConnection { db in try TaskStore.run(db,
                        "UPDATE task SET state=? WHERE id=?", [.text("recovering"), .text(submitted.id)]) }
                    check(try sql.probeAuthority(includeTasks: false)?.authority == authorityAfter,
                        "primary observation: damaged-row fixture accidentally changed authority generation")
                    let refused = context.isStillValid?() == false
                    let mismatch = manager.workerPrimaryObservation(taskID: submitted.id)
                    let damaged = try sql.load().first { $0.id == submitted.id }
                    check(refused && mismatch?.outcome == .mismatch && mismatch?.state == .recovering
                        && mismatch?.durability == damaged?.durability && mismatch?.expected.status == .running,
                        "primary observation: readable row mismatch lost exact primary metadata")
                } else if mode == "restart" {
                    let fresh = AgentTaskManager(store: AgentTaskStore(fileURL: export, mirror: sql), receiptStore: receipts)
                    check(fresh.task(id: submitted.id)?.status == .recovering
                        && fresh.workerPrimaryObservation(taskID: submitted.id) == nil,
                        "primary observation: fresh held manager invented a worker primary observation")
                    // Its real new authority generation makes the retained store refuse
                    // before reading a row; weakening generation equality is not allowed.
                    let refused = context.isStillValid?() == false
                    let unavailable = manager.workerPrimaryObservation(taskID: submitted.id)
                    check(refused && unavailable?.outcome == .unavailable && unavailable?.state == nil
                        && unavailable?.durability == nil,
                        "primary observation: generation mismatch pretended to be a readable row verdict")
                } else if mode == "input-successor" {
                    guard let old = state.contexts.first else { throw FixtureError.missingContext }
                    opens = 0
                    sql.authorityBoundaryForTesting = { name, _ in if name == "existingOpened" { opens += 1 } }
                    let refused = old.isStillValid?() == false
                    check(refused && opens == 0 && context.attempt == old.attempt + 1
                        && manager.workerPrimaryObservation(taskID: submitted.id) == refreshed
                        && refreshed?.outcome == .accepted,
                        "primary observation: obsolete real continuation context stamped successor metadata")
                    sql.authorityBoundaryForTesting = nil
                }
            } catch { caught = error }

            sql.authorityBoundaryForTesting = nil
            if caught != nil { manager.cancel(submitted.id) }
            let continuation = state.backing
            state.backing = nil
            continuation?.resume()
            let expectedExits = mode == "input-successor" ? 2 : 1
            let joined = await reached { state.exited == expectedExits }
            check(joined, "primary observation: original held backing failed bounded cleanup (\(mode))")
            if let caught { throw caught }
            check(manager.workerPrimaryObservation(taskID: submitted.id) == nil,
                "primary observation: exited handle retained live primary cache (\(mode))")
            let final = try sql.load().first { $0.id == submitted.id }
            if mode == "row-damage" || mode == "restart" {
                check(state.effects == 0 && final?.status == .recovering,
                    "primary observation: stopped backing replayed/overwrote retained held evidence (\(mode))")
            } else {
                check(state.effects == 1 && final?.status == .completed && final?.result?.contains(text) == true,
                    "primary observation: same original temporary read did not complete exactly once (\(mode))")
            }
        }
    }
}

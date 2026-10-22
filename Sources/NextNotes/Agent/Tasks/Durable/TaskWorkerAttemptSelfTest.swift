import Foundation

/// Actual Manager -> LocalBackend -> Executor with isolated primary storage.
/// No process crash, lease liveness, automatic recovery or remote-host claim.
@MainActor
enum TaskWorkerAttemptSelfTest {
    private enum FixtureError: Error { case absentContext, invalidFixture }

    static func run() async -> String {
        guard SelfTest.isRunning else { return "TASK_WORKER_ATTEMPT_FAILED: harness required" }
        let before = SelfTestStoreGuard.take()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NextNotesWorkerAttempt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldFake = AgentToolExecutor.fakeForTesting
        let oldFire = AgentToolExecutor.fireOverrideForTesting
        let oldPolicy = AgentToolExecutor.policyOverrideForTesting
        defer {
            AgentToolExecutor.fakeForTesting = oldFake
            AgentToolExecutor.fireOverrideForTesting = oldFire
            AgentToolExecutor.policyOverrideForTesting = oldPolicy
        }
        var failures: [String] = []
        var cases = 0
        func check(_ condition: Bool, _ message: String) {
            cases += 1
            if !condition { failures.append(message) }
        }
        func settled(_ manager: AgentTaskManager, id: String) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(5))
            while clock.now < deadline {
                if let status = manager.task(id: id)?.status,
                   status != .queued && status != .running { return true }
                await Task.yield()
            }
            return false
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            let input = root.appendingPathComponent("original.txt")
            let text = "Actual isolated worker attempt read"
            try text.write(to: input, atomically: true, encoding: .utf8)
            AgentToolExecutor.fakeForTesting = nil
            AgentToolExecutor.fireOverrideForTesting = nil
            AgentToolExecutor.policyOverrideForTesting = .selfTest
            let positiveRoot = root.appendingPathComponent("positive", isDirectory: true)
            try FileManager.default.createDirectory(at: positiveRoot, withIntermediateDirectories: false)
            let sql = TaskStore(root: positiveRoot)
            defer { sql.close() }
            let store = AgentTaskStore(fileURL: positiveRoot.appendingPathComponent("agent-tasks.json"), mirror: sql)
            guard store.allowsHarnessPersistence else { throw FixtureError.invalidFixture }
            let manager = AgentTaskManager(store: store)
            var entered = 0
            var context: TaskJournalContext?
            var durableBeforeBackend = false
            manager.backendEntryForTesting = {
                entered += 1
                context = TaskEventJournal.current
                guard let bound = context else { throw FixtureError.absentContext }
                let row = try TaskStore(root: positiveRoot).load().first { $0.id == bound.taskID }
                durableBeforeBackend = row?.status == .running
                    && (row?.durability?.attempt ?? 0) > 0
                    && row?.durability?.attempt == bound.attempt
                    && row?.durability?.leaseOwner == String(ProcessInfo.processInfo.processIdentifier)
                    && row?.durability?.attemptStartedAt != nil
                    && row?.durability?.resumePolicy == .neverAuto
            }
            let task = manager.submit(objective: "Read the isolated original", tool: "filesystem.read",
                arguments: ["path": input.path], source: "selftest")
            check(await settled(manager, id: task.id), "real local read did not settle within its fixture budget")
            check(entered == 1 && manager.task(id: task.id)?.status == .completed
                && manager.task(id: task.id)?.result?.contains(text) == true,
                "actual Manager/local backend did not consume the original temporary read")
            check(durableBeforeBackend, "actual backend entered without positive committed attempt and process ownership")
            guard let captured = context else { throw FixtureError.absentContext }
            let terminal = try sql.load()
            let events = try sql.journal(taskID: task.id)
            captured.record(TaskJournalEventDraft(taskID: task.id, kind: .toolStarted,
                detail: "filesystem.read", attempt: captured.attempt))
            let after = try sql.journal(taskID: task.id)
            check(try sql.load() == terminal
                && after.filter { $0.draft.kind != .staleAttemptDropped } == events.filter { $0.draft.kind != .staleAttemptDropped },
                "retained execution context committed a tool fact after its task was terminal")

            // A real primary SQL rejection at toolStarted must prevent the actual effect.
            let rejectedRoot = root.appendingPathComponent("rejected-journal", isDirectory: true)
            try FileManager.default.createDirectory(at: rejectedRoot, withIntermediateDirectories: false)
            let rejectedSQL = TaskStore(root: rejectedRoot)
            defer { rejectedSQL.close() }
            let rejectedStore = AgentTaskStore(fileURL: rejectedRoot.appendingPathComponent("agent-tasks.json"), mirror: rejectedSQL)
            let rejectedManager = AgentTaskManager(store: rejectedStore)
            var rejectionInstalled = false
            rejectedManager.backendEntryForTesting = {
                try rejectedSQL.withConnection { db in
                    try TaskStore.exec(db, "CREATE TRIGGER reject_worker_tool_started BEFORE INSERT ON task_event WHEN NEW.kind='toolStarted' BEGIN SELECT RAISE(ABORT,'fixture primary rejection'); END")
                }
                rejectionInstalled = true
            }
            var effects = 0
            var ignoredPrimaryFailureReachedBacking = false
            AgentToolExecutor.fireOverrideForTesting = { tool, arguments in
                guard tool.id == "filesystem.read", arguments == ["path": input.path] else { throw FixtureError.invalidFixture }
                ignoredPrimaryFailureReachedBacking = rejectedManager.lastPersistenceResult == .sqlFailed
                effects += 1
                return try FilesystemExecutor.run(tool, arguments: arguments)
            }
            let rejected = rejectedManager.submit(objective: "Refuse a read after rejected primary journal admission",
                tool: "filesystem.read", arguments: ["path": input.path], source: "selftest")
            check(await settled(rejectedManager, id: rejected.id), "rejected real local read did not settle")
            if ignoredPrimaryFailureReachedBacking {
                SelfTest.diagnostic("TASK_WORKER_ATTEMPT_ORIGINAL_TRACE: sqlFailed observed at actual backing boundary")
            }
            check(rejectionInstalled && effects == 0 && rejectedManager.task(id: rejected.id)?.status == .failed,
                "actual local backing ran after primary tool-start commit rejection")
            check(try rejectedSQL.journal(taskID: rejected.id).allSatisfy { $0.draft.kind != .toolStarted },
                "rejected SQL fixture did not actually reject the tool-start event")
            try await boundaryCases(root: root, input: input, text: text, check: check)
            try await ownerRecognitionCases(root: root, input: input, text: text, check: check)
            try await heartbeatCases(root: root, input: input, text: text, check: check)
            try await TaskReceiptJoinSelfTest.originalCases(root: root, input: input, text: text, check: check)
            try await TaskScopedMutationReceiptSelfTest.originalCases(root: root, check: check)
            try await TaskCalendarDuplicateReceiptSelfTest.originalCases(root: root, check: check)
            try await TaskCalendarUnknownOutcomeSelfTest.originalCases(root: root, check: check)
            try await TaskCalendarUnknownOutcomeSelfTest.postReadOwnerCases(root: root, check: check)
            try await TaskReceiptCompletionSelfTest.originalCases(root: root, input: input, text: text, check: check)
            try await TaskRuntimeClassSelfTest.originalCases(root: root, input: input, text: text, check: check)
            try await TaskWorkerBindingSelfTest.originalCases(root: root, input: input, text: text, check: check)
            try await TaskReceiptSourceSelfTest.originalCases(root: root, input: input, text: text, check: check)
            try TaskReceiptSourceBoundarySelfTest.run(root: root, check: check)
            try await TaskWorkerPrimaryObservationSelfTest.originalCases(root: root, input: input, text: text, check: check)
            try await TaskWorkerToolBackingSelfTest.originalCases(root: root, input: input, text: text, check: check)
            try TaskHarnessReadIsolationSelfTest.originalCases(root: root, check: check)
            try await TaskACPPrimaryAdmissionSelfTest.originalCases(root: root, check: check)
            try await TaskWorkerReleasedContextSelfTest.originalCases(root: root, input: input, text: text, check: check)
            try await TaskACPUnverifiedReceiptSelfTest.originalCases(root: root, check: check)
            try await TaskACPReceiptStartSelfTest.originalCases(root: root, check: check)
            try await TaskACPReceiptCompletionSelfTest.originalCases(root: root, check: check)
            try await TaskReceiptQualitySelfTest.originalCases(root: root, input: input, text: text, check: check)
            try await TaskACPNestedAttemptSelfTest.originalCases(root: root, check: check)
            try await TaskACPGateAdmissionSelfTest.originalCases(root: root, check: check)
            try await TaskACPPostGateSelfTest.originalCases(root: root, check: check)
            try await ACPSessionReviewMetadataSelfTest.originalCases(root: root, check: check)
            try await TaskACPRuntimeObservationSelfTest.originalCases(root: root, check: check)
            try await TaskACPPermissionWaitSelfTest.originalCases(root: root, check: check)
            try await TaskACPPostBrokerPrimarySelfTest.originalCases(root: root, check: check)
            TaskHeartbeatSelfTest.cases(check: check)
            try await TaskReceiptObservationSelfTest.originalCases(root: root, input: input, text: text, check: check)
            try await TaskArtifactMetadataSelfTest.originalCases(root: root, input: input, text: text, check: check)
            try await VerifiedMailEvidenceSelfTest.originalCases(root: root, input: input, text: text, check: check)
            try await BasedOnEvidenceSelfTest.originalCases(root: root, input: input, text: text, check: check)
            try await TaskACPActivityHeartbeatSelfTest.originalCases(root: root, check: check)
            try await TaskACPActivityStorageSelfTest.originalCases(root: root, check: check)
            try TaskEventCompactionParitySelfTest.originalCases(root: root, check: check)
            try await TaskScheduledPrimaryAdmissionSelfTest.originalCases(root: root, input: input, text: text, check: check)
            try await TaskScheduledRunOwnerSelfTest.originalCases(root: root, input: input, text: text, check: check)
            try await TaskACPStaleMonitorSelfTest.originalCases(root: root, check: check)
            try await TaskACPPeriodicHeartbeatSelfTest.originalCases(root: root, check: check)
            try await TaskACPSchedulerCadenceSelfTest.originalCases(root: root, check: check)
            try await TaskLocalInvocationMonitorSelfTest.originalCases(root: root, input: input, text: text, check: check)
        } catch { failures.append("actual worker fixture: \(error)") }
        let after = SelfTestStoreGuard.take()
        SelfTest.diagnostic(SelfTestStoreGuard.cachedMetricsChangeDiagnostic(
            before, after, scope: "workerAttempt"))
        failures += SelfTestStoreGuard.diff(before, after).map { "owner changed: \($0)" }
        for failure in failures { SelfTest.diagnostic("TASK_WORKER_ATTEMPT_WRONG: \(failure)") }
        return failures.isEmpty ? "TASK_WORKER_ATTEMPT_OK: \(cases) cases"
            : "TASK_WORKER_ATTEMPT_FAILED: \(failures.count) assertions"
    }
}

// These original boundary cases retain the first seven inputs and assertions.
extension TaskWorkerAttemptSelfTest {
    @MainActor
    private static func boundaryCases(root: URL, input: URL, text: String,
                                      check: (Bool, String) -> Void) async throws {
        struct BoundaryError: Error {}
        func fixture(_ name: String) throws -> (TaskStore, AgentTaskStore, AgentTaskManager) {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let sql = TaskStore(root: directory)
            let store = AgentTaskStore(fileURL: directory.appendingPathComponent("agent-tasks.json"), mirror: sql)
            guard store.allowsHarnessPersistence else { throw BoundaryError() }
            return (sql, store, AgentTaskManager(store: store))
        }
        func reached(_ predicate: () -> Bool) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(5))
            while clock.now < deadline {
                if predicate() { return true }
                await Task.yield()
            }
            return false
        }

        for throwsAfterRead in [false, true] {
            let (sql, _, manager) = try fixture(throwsAfterRead ? "completion-threw" : "completion-returned")
            defer { sql.close() }
            var ended = false
            var effects = 0
            var announcements: [String] = []
            manager.backendExitForTesting = { ended = true }
            manager.announcementForTesting = { announcements.append($0) }
            manager.backendEntryForTesting = {
                try sql.withConnection { try TaskStore.exec($0,
                    "CREATE TRIGGER reject_completion BEFORE INSERT ON task_event WHEN NEW.kind='toolCompleted' BEGIN SELECT RAISE(ABORT,'fixture completion rejection'); END") }
            }
            AgentToolExecutor.fireOverrideForTesting = { tool, arguments in
                guard tool.id == "filesystem.read", arguments == ["path": input.path] else { throw BoundaryError() }
                effects += 1
                let result = try FilesystemExecutor.run(tool, arguments: arguments)
                if throwsAfterRead { throw BoundaryError() }
                return result
            }
            let task = manager.submit(objective: "Retain effect evidence when completion fact rejects",
                tool: "filesystem.read", arguments: ["path": input.path], source: "selftest")
            check(await reached { ended }, "completion rejection did not unwind through actual Manager")
            let row = try sql.load().first { $0.id == task.id }
            let receipt = ActionReceiptStore.shared.receipts.last { $0.taskID == task.id }
            check(effects == 1 && row?.status == .failed && row?.result == nil
                && row?.failure?.contains(AgentTaskPersistenceResult.sqlFailed.diagnostic!) == true
                && announcements.allSatisfy { !$0.contains(text) && !$0.hasPrefix("fixture artifact announcement:") },
                "completion rejection silently lost history or emitted task success (threw=\(throwsAfterRead))")
            check(receipt?.status == (throwsAfterRead ? .failed : .completed)
                && receipt?.events.contains { $0.stage == .fired } == true
                && (throwsAfterRead || receipt?.result.contains(text) == true),
                "completion admission refusal changed the runtime's actual receipt evidence")
            check(try sql.journal(taskID: task.id).contains { $0.draft.kind == .toolStarted }
                && !sql.journal(taskID: task.id).contains { $0.draft.kind == .toolCompleted },
                "completion-only SQL fixture did not reach and reject its exact producer")
        }

        do {
            let (sql, _, manager) = try fixture("terminal-rejected")
            defer { sql.close() }
            var ended = false
            var effects = 0
            var announcements: [String] = []
            manager.backendExitForTesting = { ended = true }
            manager.announcementForTesting = { announcements.append($0) }
            manager.backendEntryForTesting = {
                try sql.withConnection { try TaskStore.exec($0,
                    "CREATE TRIGGER reject_terminal BEFORE UPDATE ON task WHEN NEW.state='completed' BEGIN SELECT RAISE(ABORT,'fixture terminal rejection'); END") }
            }
            AgentToolExecutor.fireOverrideForTesting = { tool, arguments in
                guard tool.id == "filesystem.read", arguments == ["path": input.path] else { throw BoundaryError() }
                effects += 1
                return try FilesystemExecutor.run(tool, arguments: arguments)
            }
            let task = manager.submit(objective: "Refuse success delivery without primary terminal admission",
                tool: "filesystem.read", arguments: ["path": input.path], source: "selftest")
            check(await reached { ended }, "terminal rejection did not finish actual Manager callback")
            let row = try sql.load().first { $0.id == task.id }
            check(effects == 1 && row?.status == .running && row?.result == nil
                && manager.lastPersistenceResult == .sqlFailed
                && !announcements.contains { $0.contains(text) || $0.hasPrefix("fixture artifact announcement:") }
                && announcements.contains(AgentTaskPersistenceResult.sqlFailed.diagnostic!),
                "rejected terminal save emitted actual success/artifact announcement entry")
            let receipt = ActionReceiptStore.shared.receipts.last { $0.taskID == task.id }
            check(receipt?.status == .completed && receipt?.result.contains(text) == true,
                "terminal primary rejection lost actual completed receipt evidence")
        }

        do {
            let (sql, store, manager) = try fixture("primary-state-mismatch")
            defer { sql.close() }
            var ended = false
            var effects = 0
            var changedPrimary = false
            var context: TaskJournalContext?
            manager.backendExitForTesting = { ended = true }
            manager.backendEntryForTesting = {
                context = TaskEventJournal.current
                guard let bound = context else { throw BoundaryError() }
                store.migrationBoundaryForTesting = { name in
                    guard name == "beforePrimaryCommit", !changedPrimary else { return }
                    // Deliberately change only the exact primary row immediately
                    // before its actual commit. Keep the authority marker unchanged
                    // so the per-worker transaction predicate itself is exercised.
                    try sql.withConnection { db in
                        try TaskStore.run(db, "UPDATE task SET state='cancelled' WHERE id=?", [.text(bound.taskID)])
                    }
                    changedPrimary = true
                }
            }
            AgentToolExecutor.fireOverrideForTesting = { tool, arguments in
                guard tool.id == "filesystem.read", arguments == ["path": input.path] else { throw BoundaryError() }
                effects += 1
                return try FilesystemExecutor.run(tool, arguments: arguments)
            }
            let task = manager.submit(objective: "Refuse a stale primary task before tool-start admission",
                tool: "filesystem.read", arguments: ["path": input.path], source: "selftest")
            check(await reached { ended }, "primary-state mismatch did not unwind its real worker")
            let row = try sql.load().first { $0.id == task.id }
            check(changedPrimary && effects == 0 && row?.status == .cancelled
                && manager.lastPersistenceResult == .sqlFailed,
                "actual transaction replaced a changed primary state or admitted its backing")
            check(try sql.journal(taskID: task.id).allSatisfy { $0.draft.kind != .toolStarted },
                "stale primary worker transaction committed a new tool fact")
        }

        for genericError in [false, true] {
            let (sql, _, manager) = try fixture(genericError ? "cancel-generic" : "cancel-agent-error")
            defer { sql.close() }
            var ended = false
            var backing: CheckedContinuation<AgentToolResult, Error>?
            var context: TaskJournalContext?
            var announcements: [String] = []
            manager.backendExitForTesting = { ended = true }
            manager.announcementForTesting = { announcements.append($0) }
            AgentToolExecutor.fireOverrideForTesting = { tool, arguments in
                guard tool.id == "filesystem.read", arguments == ["path": input.path] else { throw BoundaryError() }
                context = TaskEventJournal.current
                // This actual final callback deliberately ignores task cancellation.
                return try await withCheckedThrowingContinuation { backing = $0 }
            }
            let task = manager.submit(objective: "Keep a committed stop when the backing throws late",
                tool: "filesystem.read", arguments: ["path": input.path], source: "selftest")
            guard await reached({ backing != nil }), let suspended = backing else {
                manager.cancel(task.id)
                throw BoundaryError()
            }
            manager.cancel(task.id)
            let cancelled = try sql.load()
            let beforeEvents = try sql.journal(taskID: task.id)
            check(cancelled.first { $0.id == task.id }?.status == .cancelled,
                "cancel did not commit primary stopped state before releasing its backing")
            announcements.removeAll()
            if genericError { suspended.resume(throwing: BoundaryError()) }
            else { suspended.resume(throwing: AgentError.backendUnavailable("Late cancellation-ignoring backing")) }
            check(await reached { ended }, "late error did not causally unwind through Manager")
            context?.record(TaskJournalEventDraft(taskID: task.id, kind: .toolStarted,
                detail: "filesystem.read", attempt: context?.attempt ?? 0))
            check(try sql.load() == cancelled
                && sql.journal(taskID: task.id).filter { $0.draft.kind != .staleAttemptDropped }
                    == beforeEvents.filter { $0.draft.kind != .staleAttemptDropped }
                && announcements.isEmpty,
                "late backing/error/context replaced committed cancellation or announced stale work (generic=\(genericError))")
        }
        try await unboundLateReturnCases(root: root, input: input, check: check)
    }
}

// Ownership and cancellation negatives derive metadata from a real admitted worker.
// They follow the unchanged original 27 checks; no process-liveness claim is made.
extension TaskWorkerAttemptSelfTest {
    @MainActor
    private static func ownerRecognitionCases(root: URL, input: URL, text: String,
                                              check: (Bool, String) -> Void) async throws {
        struct OwnerFixtureError: Error {}
        func reached(_ predicate: () -> Bool) async -> Bool {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(5))
            while clock.now < deadline {
                if predicate() { return true }
                await Task.yield()
            }
            return false
        }
        func fixture(_ name: String) throws -> (TaskStore, AgentTaskStore) {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let sql = TaskStore(root: directory)
            let store = AgentTaskStore(fileURL: directory.appendingPathComponent("agent-tasks.json"), mirror: sql)
            guard store.allowsHarnessPersistence else { throw OwnerFixtureError() }
            return (sql, store)
        }
        let (sourceSQL, sourceStore) = try fixture("owner-source")
        defer { sourceSQL.close() }
        let producer = AgentTaskManager(store: sourceStore)
        var actualRunning: AgentTask?
        var ended = false
        producer.backendExitForTesting = { ended = true }
        producer.backendEntryForTesting = {
            guard let context = TaskEventJournal.current else { throw OwnerFixtureError() }
            actualRunning = try TaskStore(root: sourceSQL.fileURL.deletingLastPathComponent()).load()
                .first { $0.id == context.taskID }
        }
        AgentToolExecutor.fireOverrideForTesting = nil
        let produced = producer.submit(objective: "Derive owner fixture from actual admitted local execution",
            tool: "filesystem.read", arguments: ["path": input.path], source: "selftest")
        guard await reached({ ended }), let running = actualRunning,
              (running.durability?.attempt ?? 0) > 0,
              running.durability?.runtimeClass == .localDeterministic,
              running.durability?.attemptStartedAt != nil else { throw OwnerFixtureError() }
        check(producer.task(id: produced.id)?.status == .completed
            && producer.task(id: produced.id)?.result?.contains(text) == true,
            "owner substitution fixture did not derive fields from real producer/disk/original read")
        var absentContextEffects = 0
        AgentToolExecutor.fireOverrideForTesting = { tool, arguments in
            guard tool.id == "filesystem.read", arguments == ["path": input.path] else { throw OwnerFixtureError() }
            absentContextEffects += 1
            return try FilesystemExecutor.run(tool, arguments: arguments)
        }
        var missingContextRefused = false
        do {
            _ = try await TaskEventJournal.$current.withValue(nil) {
                try await LocalAgentBackend().submit(running)
            }
        } catch { missingContextRefused = true }
        check(missingContextRefused && absentContextEffects == 0,
            "genuine current-owner LocalBackend ran without its bound TaskLocal")

        let ownerVariants: [(String, String?, Bool)] = [
            ("old-pid", String(ProcessInfo.processInfo.processIdentifier + 100_000), true),
            ("missing-owner", nil, true),
            ("wrong-owner", "not-a-process", true),
            ("missing-start", String(ProcessInfo.processInfo.processIdentifier), false)
        ]
        for (name, owner, hasStart) in ownerVariants {
            let (sql, store) = try fixture("owner-\(name)")
            defer { sql.close() }
            var saved = running
            saved.id = "isolated-owner-\(name)"
            saved.durability?.leaseOwner = owner
            if !hasStart { saved.durability?.attemptStartedAt = nil }
            guard store.save([saved]).primaryCommitted else { throw OwnerFixtureError() }
            let fresh = AgentTaskManager(store: store)
            check(fresh.task(id: saved.id)?.status == .recovering && fresh.backendStartsForTesting == 0,
                "owner variant fresh manager did not hold actual saved work")
            guard let context = fresh.journalContext(taskID: saved.id) else { throw OwnerFixtureError() }
            let valid = await context.isStillValid?() ?? true
            check(context.isStillValid != nil && !valid,
                "recognized local attempt downgraded to unbound or gained live validity (\(name))")
            let before = try sql.load()
            let events = try sql.journal(taskID: saved.id)
            let accepted = context.record(TaskJournalEventDraft(taskID: saved.id, kind: .toolStarted,
                detail: "filesystem.read", attempt: context.attempt))
            let request = PermissionRequest(id: "isolated-owner-request-\(name)", toolID: "filesystem.read",
                title: "Read the isolated fixture", detail: "Isolated owner guard", risk: .read,
                arguments: ["path": input.path], taskID: saved.id, createdAt: saved.createdAt)
            let captured = context.capturePermission?(request, nil, nil) ?? false
            check(!accepted && !captured && context.consumePermissionApproval?() != true,
                "invalid owner context accepted a fact/permission/token (\(name))")
            var effects = 0
            AgentToolExecutor.fireOverrideForTesting = { tool, arguments in
                guard tool.id == "filesystem.read", arguments == ["path": input.path] else { throw OwnerFixtureError() }
                effects += 1
                return try FilesystemExecutor.run(tool, arguments: arguments)
            }
            var refused = 0
            for attached in [false, true] {
                do {
                    _ = try await TaskEventJournal.$current.withValue(attached ? context : nil) {
                        try await LocalAgentBackend().submit(saved)
                    }
                } catch { refused += 1 }
            }
            check(refused == 2 && effects == 0,
                "actual LocalBackend accepted wrong/missing owner or absent/old context (\(name))")
            check(try sql.load() == before && sql.journal(taskID: saved.id) == events,
                "invalid owner context/backend changed held primary history (\(name))")

            let held = fresh.task(id: saved.id)
            try sql.withConnection { try TaskStore.exec($0,
                "CREATE TRIGGER reject_owner_cancel BEFORE UPDATE ON task WHEN NEW.state='cancelled' BEGIN SELECT RAISE(ABORT,'fixture held cancel rejection'); END") }
            fresh.cancel(saved.id)
            check(try fresh.lastPersistenceResult == .sqlFailed
                && fresh.task(id: saved.id) == held && held?.status == .recovering
                && sql.load() == before && sql.journal(taskID: saved.id) == events
                && fresh.backendStartsForTesting == 0 && effects == 0
                && context.consumePermissionApproval?() != true,
                "rejected held cancel lost recovering state/history or dispatched work (\(name))")
            try sql.withConnection { try TaskStore.exec($0, "DROP TRIGGER reject_owner_cancel") }
            fresh.cancel(saved.id)
            let cancelled = try sql.load().first { $0.id == saved.id }
            let cancelledEvents = try sql.journal(taskID: saved.id)
            check(fresh.lastPersistenceResult?.primaryCommitted == true
                && cancelled?.status == .cancelled
                && cancelled?.durability?.attempt == saved.durability?.attempt
                && cancelled?.durability?.leaseOwner == saved.durability?.leaseOwner
                && cancelledEvents.last?.draft.kind == .jobCancelled
                && cancelledEvents.last?.draft.attempt == saved.durability?.attempt
                && fresh.backendStartsForTesting == 0 && effects == 0,
                "held cancel did not commit same-attempt cancellation without dispatch (\(name))")
            let reopened = AgentTaskManager(store: store)
            check(reopened.task(id: saved.id)?.status == .cancelled
                && reopened.backendStartsForTesting == 0 && effects == 0,
                "cancelled held attempt was not retained on fresh manager load (\(name))")
        }
    }
}

// Actual admitted activity fields, transactional rollback and explicit unbound coverage.
extension TaskWorkerAttemptSelfTest {
    @MainActor
    private static func heartbeatCases(root: URL, input: URL, text: String,
                                       check: (Bool, String) -> Void) async throws {
        struct HeartbeatFixtureError: Error {}
        func reached(_ predicate: () -> Bool) async -> Bool {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while ContinuousClock.now < deadline {
                if predicate() { return true }
                await Task.yield()
            }
            return false
        }
        func canonical<T: Codable>(_ value: T) throws -> T {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(T.self, from: encoder.encode(value))
        }
        func fixture(_ name: String) throws -> (TaskStore, AgentTaskStore, AgentTaskManager) {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let sql = TaskStore(root: directory)
            let store = AgentTaskStore(fileURL: directory.appendingPathComponent("agent-tasks.json"), mirror: sql)
            guard store.allowsHarnessPersistence else { throw HeartbeatFixtureError() }
            return (sql, store, AgentTaskManager(store: store))
        }
        let modes = ["normal", "start-rejected", "completion-returned-rejected",
                     "completion-threw-rejected", "export-failed"]
        for mode in modes {
            let (sql, store, manager) = try fixture("heartbeat-\(mode)")
            defer { sql.close() }
            let base = Date(timeIntervalSince1970: 1_700_000_000)
            let startTime = base
            let toolTime = base.addingTimeInterval(60)
            let completionTime = base.addingTimeInterval(120)
            var ticks = 0
            manager.progressDateForTesting = {
                ticks += 1
                return ticks == 1 ? startTime : (ticks == 2 ? toolTime : completionTime)
            }
            var ended = false
            var effects = 0
            var enteredTaskID: String?
            var context: TaskJournalContext?
            var startBound = false
            var toolBound = false
            var exportAcceptedAtEffect = false
            var pendingWrites: [TaskDurability] = []
            var announcements: [String] = []
            manager.backendExitForTesting = { ended = true }
            manager.announcementForTesting = { announcements.append($0) }
            manager.backendEntryForTesting = {
                guard let bound = TaskEventJournal.current else { throw HeartbeatFixtureError() }
                context = bound
                enteredTaskID = bound.taskID
                let row = try TaskStore(root: sql.fileURL.deletingLastPathComponent()).load()
                    .first { $0.id == bound.taskID }
                startBound = try row?.status == .running && row?.durability?.attempt == bound.attempt
                    && row?.durability?.leaseOwner == String(ProcessInfo.processInfo.processIdentifier)
                    && row?.durability?.attemptStartedAt == startTime
                    && row?.durability?.heartbeatAt == startTime && row?.durability?.lastProgressAt == startTime
                    && sql.journal(taskID: bound.taskID).last?.draft.at == startTime
                store.migrationBoundaryForTesting = { phase in
                    if phase == "beforePrimaryCommit", let metadata = manager.task(id: bound.taskID)?.durability {
                        pendingWrites.append(metadata)
                    }
                }
                if mode == "start-rejected" {
                    try sql.withConnection { try TaskStore.exec($0,
                        "CREATE TRIGGER reject_heartbeat_tool_start BEFORE INSERT ON task_event WHEN NEW.kind='toolStarted' BEGIN SELECT RAISE(ABORT,'fixture heartbeat start rejection'); END") }
                } else if mode.hasPrefix("completion-") {
                    try sql.withConnection { try TaskStore.exec($0,
                        "CREATE TRIGGER reject_heartbeat_tool_completion BEFORE INSERT ON task_event WHEN NEW.kind='toolCompleted' BEGIN SELECT RAISE(ABORT,'fixture heartbeat completion rejection'); END") }
                } else if mode == "export-failed" {
                    try FileManager.default.removeItem(at: store.storageURL)
                    try FileManager.default.createDirectory(at: store.storageURL, withIntermediateDirectories: false)
                }
            }
            AgentToolExecutor.fakeForTesting = nil
            AgentToolExecutor.policyOverrideForTesting = .selfTest
            AgentToolExecutor.fireOverrideForTesting = { tool, arguments in
                guard tool.id == "filesystem.read", arguments == ["path": input.path],
                      let id = enteredTaskID, let current = TaskEventJournal.current else { throw HeartbeatFixtureError() }
                let row = try TaskStore(root: sql.fileURL.deletingLastPathComponent()).load().first { $0.id == id }
                toolBound = try row?.status == .running && row?.durability?.attempt == current.attempt
                    && row?.durability?.heartbeatAt == toolTime && row?.durability?.lastProgressAt == toolTime
                    && row?.durability?.attemptStartedAt == startTime
                    && sql.journal(taskID: id).last?.draft.kind == .toolStarted
                    && sql.journal(taskID: id).last?.draft.at == toolTime
                exportAcceptedAtEffect = manager.lastPersistenceResult == .exportFailed
                effects += 1
                let result = try FilesystemExecutor.run(tool, arguments: arguments)
                if mode == "completion-threw-rejected" { throw HeartbeatFixtureError() }
                return result
            }
            let task = manager.submit(objective: "Track actual admitted worker and tool activity",
                tool: "filesystem.read", arguments: ["path": input.path], source: "selftest")
            guard await reached({ ended }) else { throw HeartbeatFixtureError() }
            check(startBound, "actual backend entry lacked committed start heartbeat/progress (\(mode))")
            let primary = try sql.load().first { $0.id == task.id }
            let memory = manager.task(id: task.id)
            let eventKinds = try sql.journal(taskID: task.id).map { $0.draft.kind }
            if mode == "start-rejected" {
                check(effects == 0 && primary?.status == .failed
                    && primary?.durability?.heartbeatAt == startTime && primary?.durability?.lastProgressAt == startTime
                    && memory?.durability?.heartbeatAt == startTime && memory?.durability?.lastProgressAt == startTime
                    && pendingWrites.first?.heartbeatAt == toolTime
                    && pendingWrites.first?.lastProgressAt == toolTime,
                    "rejected genuine tool start lost exact heartbeat rollback or reached backing")
            } else {
                check(effects == 1 && toolBound && (mode != "export-failed" || exportAcceptedAtEffect),
                    "actual backing lacked accepted SQL progress or export failure revoked SQL admission (\(mode))")
            }
            if mode.hasPrefix("completion-") {
                check(primary?.status == .failed && primary?.result == nil
                    && primary?.durability?.heartbeatAt == toolTime && primary?.durability?.lastProgressAt == toolTime
                    && memory?.durability?.heartbeatAt == toolTime && memory?.durability?.lastProgressAt == toolTime
                    && pendingWrites.dropFirst().first?.heartbeatAt == completionTime
                    && pendingWrites.dropFirst().first?.lastProgressAt == completionTime
                    && !announcements.contains { $0.contains(text) || $0.hasPrefix("fixture artifact announcement:") },
                    "rejected genuine completion beat did not roll back exact fields or announced success (\(mode))")
            } else if mode == "start-rejected" {
                check(ticks == 2 && memory?.durability?.attemptStartedAt == startTime,
                    "rejected start generated another beat for failure metadata")
            } else {
                check(try primary?.status == .completed && primary?.result?.contains(text) == true
                    && primary?.durability?.heartbeatAt == completionTime && primary?.durability?.lastProgressAt == completionTime
                    && memory?.durability?.heartbeatAt == completionTime && memory?.durability?.lastProgressAt == completionTime
                    && sql.journal(taskID: task.id).first(where: { $0.draft.kind == .toolCompleted })?.draft.at == completionTime,
                    "actual completion did not persist exact final progress fields (\(mode))")
            }
            let expectedKinds: [TaskEventKind] = mode == "start-rejected"
                ? [.jobCreated, .workerStarted, .jobFailed]
                : (mode.hasPrefix("completion-")
                   ? [.jobCreated, .workerStarted, .toolStarted, .jobFailed]
                   : [.jobCreated, .workerStarted, .toolStarted, .toolCompleted, .jobCompleted, .artifactCaptured])
            check(eventKinds == expectedKinds && pendingWrites.count == (mode == "start-rejected" ? 2 : 3)
                && ticks == (mode == "start-rejected" ? 2 : 3),
                "heartbeat added a save/event or beat unrelated to admitted worker/tool facts (\(mode))")
            check(try sql.load() == canonical(manager.tasks),
                "fresh primary snapshot lost exact payload/arguments/status/progress fields (\(mode))")
            guard let context else { throw HeartbeatFixtureError() }
            let terminalRows = try sql.load()
            let terminalEvents = try sql.journal(taskID: task.id)
            let oldTicks = ticks
            let accepted = context.record(TaskJournalEventDraft(taskID: task.id, kind: .toolStarted,
                detail: "filesystem.read", attempt: context.attempt))
            check(try !accepted && ticks == oldTicks && sql.load() == terminalRows
                && sql.journal(taskID: task.id) == terminalEvents,
                "obsolete context refreshed heartbeat or primary history (\(mode))")
        }
        for hasManualDurability in [false, true] {
            let (sql, store, _) = try fixture(hasManualDurability ? "heartbeat-manual" : "heartbeat-unbound")
            defer { sql.close() }
            var row = AgentTask(id: hasManualDurability ? "manual-heartbeat" : "unbound-heartbeat",
                objective: "Unbound fixture metadata", source: "selftest", status: .running,
                tool: "filesystem.read")
            if hasManualDurability {
                var metadata = TaskDurability()
                metadata.attempt = 3
                metadata.heartbeatAt = Date(timeIntervalSince1970: 1_600_000_000)
                metadata.lastProgressAt = metadata.heartbeatAt
                row.durability = metadata
            }
            guard store.save([row]).primaryCommitted else { throw HeartbeatFixtureError() }
            let manager = AgentTaskManager(store: store)
            var ticks = 0
            manager.progressDateForTesting = { ticks += 1; return Date(timeIntervalSince1970: 1_700_000_000) }
            let beforeRows = try sql.load()
            guard let context = manager.journalContext(taskID: row.id) else { throw HeartbeatFixtureError() }
            let accepted = context.record(TaskJournalEventDraft(taskID: row.id, kind: .toolStarted,
                detail: "filesystem.read", attempt: context.attempt))
            check(try accepted && context.isStillValid == nil && ticks == 0 && sql.load() == beforeRows
                && beforeRows.first?.durability == row.durability
                && manager.backendStartsForTesting == 0,
                "unbound/manual metadata produced a worker heartbeat or dispatch")
        }
    }
}

// Same held final-callback seam as cancel-agent-error/cancel-generic above, with
// a genuinely unbound meeting-source local worker and retained actual Task.
extension TaskWorkerAttemptSelfTest {
    @MainActor
    private static func unboundLateReturnCases(root: URL, input: URL,
                                               check: (Bool, String) -> Void) async throws {
        struct BoundaryError: Error {}
        func reached(_ predicate: () -> Bool) async -> Bool {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while ContinuousClock.now < deadline {
                if predicate() { return true }
                await Task.yield()
            }
            return predicate()
        }
        let oldFire = AgentToolExecutor.fireOverrideForTesting
        defer { AgentToolExecutor.fireOverrideForTesting = oldFire }
        for genericError in [false, true] {
            let mode = genericError ? "unbound-cancel-generic" : "unbound-cancel-agent-error"
            let directory = root.appendingPathComponent(mode, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let sql = TaskStore(root: directory); defer { sql.close() }
            let export = directory.appendingPathComponent("agent-tasks.json")
            let store = AgentTaskStore(fileURL: export, mirror: sql)
            guard store.allowsHarnessPersistence, store.save([]).primaryCommitted else { throw BoundaryError() }
            let receipts = ActionReceiptStore(fileURL: directory.appendingPathComponent("action-receipts.json"))
            let manager = AgentTaskManager(store: store, receiptStore: receipts)
            let state = LateUnboundWorkerProbe()
            let id = UUID().uuidString
            var operation: Task<Void, Never>?
            let authored = try Data(contentsOf: input)
            manager.backendExitForTesting = { state.backendReturns += 1 }
            AgentToolExecutor.fireOverrideForTesting = { tool, arguments in
                guard tool.id == "filesystem.read", arguments == ["path": input.path],
                      let context = TaskEventJournal.current, context.taskID == id,
                      context.attempt == 0, context.isStillValid == nil,
                      context.receiptStore === receipts else { throw BoundaryError() }
                state.contextMatched = true
                // This SAME entered final callback deliberately ignores cancellation.
                await state.park()
                _ = try FilesystemExecutor.run(tool, arguments: arguments)
                state.reads += 1
                if genericError { throw BoundaryError() }
                throw AgentError.backendUnavailable("Late cancellation-ignoring unbound backing")
            }
            do {
                let admitted = manager.submit(objective: "Keep a committed stop when the unbound backing throws late",
                    id: id, tool: "filesystem.read", arguments: ["path": input.path], source: "meeting")
                // Capture immediately before any await/qualification can throw.
                operation = manager.capturedUnboundWorkerForTesting(id: id)
                guard let operation else { throw BoundaryError() }
                guard await reached({ state.parked }) else { throw BoundaryError() }
                let entered = try sql.load().first { $0.id == id }
                check(admitted.status == .queued && entered?.status == .running
                    && entered?.source == "meeting" && entered?.durability == nil
                    && manager.backendStartsForTesting == 1 && state.contextMatched
                    && receipts.receipts.count == 1 && receipts.receipts.first?.status == .fired,
                    "late unbound C01 actual worker/backing/receipt did not qualify (\(mode))")
                manager.cancel(id)
                let stoppedRows = try sql.load(); let stoppedCache = manager.tasks
                let stoppedJournal = try sql.journal(taskID: id)
                guard let stoppedAuthority = try sql.probeAuthority(includeTasks: false)?.authority else { throw BoundaryError() }
                check(stoppedRows.count == 1 && stoppedRows[0].status == .cancelled
                    && stoppedCache.first?.status == .cancelled && operation.isCancelled
                    && state.parked && state.reads == 0 && state.backendReturns == 0,
                    "late unbound C02 stop did not precede SAME backing return (\(mode))")
                state.release()
                await operation.value
                let finalRows = try sql.load(); let finalJournal = try sql.journal(taskID: id)
                let finalAuthority = try sql.probeAuthority(includeTasks: false)?.authority
                let receipt = receipts.receipts.first
                check(state.reads == 1 && state.backendReturns == 1 && !state.parked
                    && manager.capturedUnboundWorkerForTesting(id: id) == nil
                    && receipt?.taskID == id && receipt?.taskAttempt == nil
                    && receipt?.status == .failed && receipt?.events.contains { $0.stage == .fired } == true,
                    "late unbound C03 actual read/error/return/receipt did not qualify (\(mode))")
                check(finalRows == stoppedRows && manager.tasks == stoppedCache,
                    "late unbound F01 returned error replaced committed ended task (\(mode))")
                let appended = Array(finalJournal.dropFirst(stoppedJournal.count))
                check(Array(finalJournal.prefix(stoppedJournal.count)) == stoppedJournal
                    && appended.count == 1 && appended.first?.draft.kind == .toolCompleted
                    && appended.first?.draft.taskID == id && appended.first?.draft.attempt == 0
                    && appended.first?.draft.receiptID == nil
                    && finalAuthority?.databaseID == stoppedAuthority.databaseID
                    && finalAuthority?.generation == stoppedAuthority.generation + 1,
                    "late unbound F02 callback added terminal rewrite beyond genuine tool completion (\(mode))")
                let fresh = AgentTaskStore(fileURL: export, mirror: sql)
                let exported = try fresh.load()
                check(exported == stoppedRows && manager.lastPersistenceResult?.diagnostic
                    == "This task has already ended. Its saved result was kept.",
                    "late unbound F03 ended-task refusal/export lost actual stopped row (\(mode))")
                check(try Data(contentsOf: input) == authored && PermissionGate.shared.pending == nil,
                    "late unbound C04 safe entered read changed bytes/acquired approval (\(mode))")
                print("LATE_UNBOUND_WORKER mode=\(mode) entered=\(state.contextMatched) reads=\(state.reads) returned=\(state.backendReturns) cancelled=\(finalRows.first?.status == .cancelled) appended=\(appended.count) generationDelta=\((finalAuthority?.generation ?? stoppedAuthority.generation) - stoppedAuthority.generation)")
            } catch {
                // Capture before cancellation removes the unbound existing slot.
                if operation == nil { operation = manager.capturedUnboundWorkerForTesting(id: id) }
                manager.cancel(id)
                state.release()
                if let operation { await operation.value }
                throw error
            }
        }
    }
}

@MainActor
private final class LateUnboundWorkerProbe {
    var contextMatched = false
    var reads = 0
    var backendReturns = 0
    private var continuation: CheckedContinuation<Void, Never>?
    var parked: Bool { continuation != nil }
    func park() async { await withCheckedContinuation { continuation = $0 } }
    func release() { let held = continuation; continuation = nil; held?.resume() }
}

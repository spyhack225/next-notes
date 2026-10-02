import Foundation

/// Producer-derived ownership records exercise the original backend and temporary read.
/// Changing execution classification must never turn a retained attempt into unbound work.
@MainActor
enum TaskRuntimeClassSelfTest {
    private enum FixtureError: Error { case unsafeRoot, missingProducer, stoppedBeforeBacking }
    private static let classes: [TaskRuntimeClass] = [.localDeterministic, .cloudModel, .browserOrMCP,
                                                     .acpWorker, .scheduledResearch, .waitingOnPerson]

    static func originalCases(root: URL, input: URL, text: String,
                              check: (Bool, String) -> Void) async throws {
        let safeRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard SelfTest.isRunning, safeRoot.path.hasPrefix(temporary.path + "/"),
              input.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(safeRoot.path + "/"),
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
        func stores(_ name: String) throws -> (TaskStore, AgentTaskStore, ActionReceiptStore) {
            let directory = safeRoot.appendingPathComponent("runtime-class-" + name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let sql = TaskStore(root: directory)
            let store = AgentTaskStore(fileURL: directory.appendingPathComponent("agent-tasks.json"), mirror: sql)
            guard store.allowsHarnessPersistence else { throw FixtureError.unsafeRoot }
            return (sql, store, ActionReceiptStore(fileURL: directory.appendingPathComponent("action-receipts.json")))
        }
        let (sourceSQL, sourceStore, sourceReceipts) = try stores("actual-producer")
        defer { sourceSQL.close() }
        let producer = AgentTaskManager(store: sourceStore, receiptStore: sourceReceipts)
        var running: AgentTask?
        var producerEnded = false
        var sourceEffects = 0
        producer.backendEntryForTesting = {
            guard let context = TaskEventJournal.current else { throw FixtureError.missingProducer }
            running = try sourceSQL.load().first { $0.id == context.taskID }
        }
        producer.backendExitForTesting = { producerEnded = true }
        AgentToolExecutor.fireOverrideForTesting = { tool, arguments in
            guard tool.id == "filesystem.read", arguments == ["path": input.path] else { throw FixtureError.missingProducer }
            sourceEffects += 1
            return try FilesystemExecutor.run(tool, arguments: arguments)
        }
        let submitted = producer.submit(objective: "Derive actual runtime ownership fixture", tool: "filesystem.read",
            arguments: ["path": input.path], source: "selftest")
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !producerEnded && ContinuousClock.now < deadline { await Task.yield() }
        guard producerEnded, let original = running, (original.durability?.attempt ?? 0) > 0,
              original.durability?.attemptStartedAt != nil,
              original.durability?.leaseOwner == String(ProcessInfo.processInfo.processIdentifier) else {
            throw FixtureError.missingProducer
        }
        check(sourceEffects == 1 && producer.task(id: submitted.id)?.status == .completed
            && producer.task(id: submitted.id)?.result?.contains(text) == true,
            "runtime class: control did not derive ownership from the actual manager/backend/original read")

        // Real catalogue + real committed admission, stopped before the backend can
        // authorize or inspect any browser. This proves metadata, not browser execution.
        guard let browser = AgentToolRegistry.shared.tool(named: "browser.snapshot"),
              browser.source == .native, browser.namespace == .browser else { throw FixtureError.missingProducer }
        let (browserSQL, browserStore, browserReceipts) = try stores("browser-admission")
        defer { browserSQL.close() }
        let browserManager = AgentTaskManager(store: browserStore, receiptStore: browserReceipts)
        var browserRow: AgentTask?
        var browserEnded = false
        var browserEffects = 0
        browserManager.backendEntryForTesting = {
            guard let context = TaskEventJournal.current else { throw FixtureError.missingProducer }
            browserRow = try browserSQL.load().first { $0.id == context.taskID }
            throw FixtureError.stoppedBeforeBacking
        }
        browserManager.backendExitForTesting = { browserEnded = true }
        AgentToolExecutor.fireOverrideForTesting = { _, _ in
            browserEffects += 1
            throw FixtureError.stoppedBeforeBacking
        }
        let browserTask = browserManager.submit(objective: "Inspect browser admission metadata only",
            tool: browser.id, arguments: [:], source: "selftest")
        let browserDeadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !browserEnded && ContinuousClock.now < browserDeadline { await Task.yield() }
        guard browserEnded, let browserRow else { throw FixtureError.missingProducer }
        check(browserRow.tool == browser.id && browserRow.status == .running
            && (browserRow.durability?.attempt ?? 0) > 0
            && browserRow.durability?.attemptStartedAt != nil
            && browserRow.durability?.leaseOwner == String(ProcessInfo.processInfo.processIdentifier)
            && browserRow.durability?.runtimeClass == .browserOrMCP,
            "runtime class: actual browser descriptor was admitted with incorrect execution classification")
        let browserEvents = try browserSQL.journal(taskID: browserTask.id)
        check(browserEffects == 0 && browserReceipts.receipts.isEmpty
            && !browserEvents.contains { [.toolStarted, .toolCompleted, .permissionRequested,
                .permissionApproved, .permissionDenied].contains($0.draft.kind) },
            "runtime class: browser metadata fixture crossed authorization or backing boundary")

        for runtime in classes {
            for variant in ["held-current", "old-owner", "missing-owner", "wrong-owner", "missing-start", "stale-attempt"] {
                let label = runtime.rawValue + "-" + variant
                let (sql, store, receipts) = try stores(label)
                defer { sql.close() }
                var saved = original
                saved.durability?.runtimeClass = runtime
                switch variant {
                case "old-owner": saved.durability?.leaseOwner = String(ProcessInfo.processInfo.processIdentifier + 100_000)
                case "missing-owner": saved.durability?.leaseOwner = nil
                case "wrong-owner": saved.durability?.leaseOwner = "not-a-process"
                case "missing-start": saved.durability?.attemptStartedAt = nil
                case "stale-attempt":
                    let nextAttempt = (saved.durability?.attempt ?? 0) + 1
                    saved.durability?.attempt = nextAttempt
                default: break
                }
                guard store.save([saved]).primaryCommitted else { throw FixtureError.missingProducer }
                let fresh = AgentTaskManager(store: store, receiptStore: receipts)
                guard let context = fresh.journalContext(taskID: saved.id) else { throw FixtureError.missingProducer }
                let before = try sql.load()
                let events = try sql.journal(taskID: saved.id)
                let beforeReceipts = receipts.receipts
                let valid = await context.isStillValid?() ?? true
                check(fresh.task(id: saved.id)?.status == .recovering && fresh.backendStartsForTesting == 0
                    && context.isStillValid != nil && !valid,
                    "runtime class: changed classification downgraded held ownership or supplied validity (\(label))")
                var effects = 0
                AgentToolExecutor.fireOverrideForTesting = { tool, arguments in
                    guard tool.id == "filesystem.read", arguments == ["path": input.path] else {
                        throw FixtureError.missingProducer
                    }
                    effects += 1
                    return try FilesystemExecutor.run(tool, arguments: arguments)
                }
                var caller = saved
                if variant == "stale-attempt" { caller.durability?.attempt = original.durability?.attempt ?? 0 }
                var refusals = 0
                for attached in [false, true] {
                    do {
                        _ = try await TaskEventJournal.$current.withValue(attached ? context : nil) {
                            try await LocalAgentBackend().submit(caller)
                        }
                    } catch { refusals += 1 }
                }
                check(refusals == 2 && effects == 0,
                    "runtime class: actual backend re-read held/stale work after class change (\(label))")
                let after = try sql.load()
                let afterEvents = try sql.journal(taskID: saved.id)
                check(after == before && afterEvents == events && receipts.receipts == beforeReceipts,
                    "runtime class: refused held/stale backend changed primary/receipt evidence (\(label))")
                // A caller-supplied positive attempt must not gain tool-fact authority either.
                let accepted = context.record(TaskJournalEventDraft(taskID: saved.id, kind: .toolStarted,
                    detail: "filesystem.read", attempt: context.attempt))
                let afterFact = try sql.load()
                let afterFactEvents = try sql.journal(taskID: saved.id)
                check(!accepted && afterFact == after && afterFactEvents == afterEvents,
                    "runtime class: changed classification admitted a tool fact on held work (\(label))")
                // Preserve the existing atomic held-cancel admission and refusal contract.
                let held = fresh.task(id: saved.id)
                try sql.withConnection { try TaskStore.exec($0,
                    "CREATE TRIGGER reject_runtime_cancel BEFORE UPDATE ON task WHEN NEW.state='cancelled' BEGIN SELECT RAISE(ABORT,'fixture runtime cancel rejection'); END") }
                fresh.cancel(saved.id)
                let afterCancel = try sql.load()
                let afterCancelEvents = try sql.journal(taskID: saved.id)
                check(fresh.lastPersistenceResult == .sqlFailed && fresh.task(id: saved.id) == held
                    && afterCancel == afterFact && afterCancelEvents == afterFactEvents,
                    "runtime class: rejected held cancel changed original history (\(label))")
                try sql.withConnection { try TaskStore.exec($0, "DROP TRIGGER reject_runtime_cancel") }
            }
        }
        // These exact manual metadata shapes predate the admitted attempt producer.
        for hasBareMetadata in [false, true] {
            let (sql, store, receipts) = try stores(hasBareMetadata ? "manual" : "unbound")
            defer { sql.close() }
            var task = AgentTask(id: "runtime-manual", objective: "Manual runtime fixture", source: "selftest",
                status: .running, tool: "filesystem.read")
            if hasBareMetadata { var metadata = TaskDurability(); metadata.attempt = 3; task.durability = metadata }
            guard store.save([task]).primaryCommitted else { throw FixtureError.missingProducer }
            let manager = AgentTaskManager(store: store, receiptStore: receipts)
            let rows = try sql.load()
            guard let context = manager.journalContext(taskID: task.id) else { throw FixtureError.missingProducer }
            var ticks = 0
            manager.progressDateForTesting = { ticks += 1; return Date() }
            let accepted = context.record(TaskJournalEventDraft(taskID: task.id, kind: .toolStarted,
                detail: "filesystem.read", attempt: context.attempt))
            let after = try sql.load()
            check(accepted && context.isStillValid == nil && ticks == 0 && after == rows
                && manager.backendStartsForTesting == 0 && receipts.receipts.isEmpty,
                "runtime class: bare manual/default metadata became a worker or gained receipt authority")
        }
    }
}

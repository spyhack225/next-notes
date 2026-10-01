import Foundation
import SQLite3

/// P6-01 characterizes today's restart behavior. It does not resume or retry work.
@MainActor
enum TaskStoreSelfTest {
    private enum FixtureError: Error { case unsafeStoreLocation, backingFailure }

    static func run() -> String {
        let before = SelfTestStoreGuard.take()
        var failures: [String] = []
        var caseCount = 5
        func check(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NextNotesTaskDurability-\(UUID().uuidString)", isDirectory: true)
        let file = directory.appendingPathComponent("agent-tasks.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            // Establish the exact isolated file before saving any task. The injected store
            // never retries against its default path if this directory/write is unavailable.
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let fixtureStore = AgentTaskStore(fileURL: file)
            guard fixtureStore.storageURL.standardizedFileURL == file.standardizedFileURL else {
                throw FixtureError.unsafeStoreLocation
            }
            check(!FileManager.default.fileExists(atPath: file.path), "fixture ledger was not fresh")
            check(fixtureStore.load().isEmpty, "fresh isolated store was not empty")

            // Whole-second dates survive the production ISO-8601 round trip exactly.
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            let fixtures = [
                AgentTask(id: "durability-running", objective: "Fixture running task", source: "selftest",
                    createdAt: date, status: .running, progress: "Fixture progress"),
                AgentTask(id: "durability-queued", objective: "Fixture queued task", source: "selftest",
                    createdAt: date, status: .queued),
                AgentTask(id: "durability-permission", objective: "Fixture permission task", source: "selftest",
                    createdAt: date, status: .waitingForPermission, progress: "Waiting for you", tool: "fixture.write"),
                AgentTask(id: "durability-completed", objective: "Fixture completed task", source: "selftest",
                    createdAt: date, contextReferences: ["fixture://reference"], status: .completed,
                    progress: "Finished", result: "Fixture result", artifacts: ["fixture://result"],
                    tool: "fixture.read", arguments: ["fixture": "value"],
                    meetingID: UUID(uuidString: "11111111-1111-1111-1111-111111111111"), backend: "acp",
                    acpCLI: "fixture-cli", compatibilityCommand: "fixture-cli fixture-command",
                    compatibilityCLI: "fixture-cli", compatibilityDirectory: "fixture://project",
                    scheduleID: UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
            ]
            fixtureStore.save(fixtures)
            let reopenedStore = AgentTaskStore(fileURL: file)
            guard reopenedStore.storageURL.standardizedFileURL == file.standardizedFileURL else {
                throw FixtureError.unsafeStoreLocation
            }
            check(reopenedStore !== fixtureStore, "restart reused the same store instance")
            check(reopenedStore.load() == fixtures, "fresh store cannot reach the exact persisted ledger")

            // Use the actual fresh-manager initializer, not a duplicated recovery table.
            let restarted = AgentTaskManager(store: reopenedStore)
            let quitMessage = "Next Notes quit while this task was running."
            for id in ["durability-running", "durability-queued"] {
                check(restarted.task(id: id)?.status == .failed, "\(id) did not become failed")
                check(restarted.task(id: id)?.failure == quitMessage, "\(id) lost the exact quit message")
            }
            check(restarted.task(id: "durability-permission") == fixtures[2], "permission record changed on restart")
            check(!restarted.consumePermissionApproval(taskID: "durability-permission"),
                "persisted permission record incorrectly supplied a live one-shot approval")
            check(restarted.task(id: "durability-completed") == fixtures[3], "completed task changed on restart")
            check(restarted.tasks.count == fixtures.count, "restart added or dropped a task")

            // Today the restart mapping is in memory; initialization does not rewrite JSON.
            check(AgentTaskStore(fileURL: file).load() == fixtures, "restart unexpectedly rewrote the persisted ledger")
            caseCount += try storageCases(in: directory, check: check)
            caseCount += try journalProducerCases(in: directory, check: check)
            caseCount += try journalRetentionCases(in: directory, check: check)
        } catch {
            failures.append("isolated fixture construction failed: \(error.localizedDescription)")
        }

        failures += SelfTestStoreGuard.diff(before, SelfTestStoreGuard.take()).map { "owner store changed: \($0)" }
        if failures.isEmpty { return "TASK_DURABILITY_OK: \(caseCount) cases" }
        for failure in failures { SelfTest.diagnostic("TASK_DURABILITY_WRONG: \(failure)") }
        return "TASK_DURABILITY_FAILED: \(failures.count) assertions"
    }

#if !TASK_DURABILITY_STANDALONE
    /// Registered app path additionally exercises the real manager/backend/executor.
    static func runIncludingToolBoundary() async -> String {
        let stores = run()
        guard stores.hasPrefix("TASK_DURABILITY_OK:") else { return stores }
        let before = SelfTestStoreGuard.take()
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NextNotesJournalTools-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let previousFake = AgentToolExecutor.fakeForTesting
        let previousFire = AgentToolExecutor.fireOverrideForTesting
        let previousPolicy = AgentToolExecutor.policyOverrideForTesting
        defer {
            AgentToolExecutor.fakeForTesting = previousFake
            AgentToolExecutor.fireOverrideForTesting = previousFire
            AgentToolExecutor.policyOverrideForTesting = previousPolicy
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let mirror = TaskStore(root: directory)
            defer { mirror.close() }
            let store = AgentTaskStore(fileURL: directory.appendingPathComponent("agent-tasks.json"), mirror: mirror)
            guard store.allowsHarnessPersistence else { throw FixtureError.unsafeStoreLocation }
            let manager = AgentTaskManager(store: store)
            AgentToolExecutor.fakeForTesting = nil
            AgentToolExecutor.policyOverrideForTesting = .selfTest
            var backingCalls = 0
            AgentToolExecutor.fireOverrideForTesting = { _, _ in
                backingCalls += 1
                return AgentToolResult(summary: "Private backing result", reference: "fixture://private-reference",
                    link: URL(string: "https://fixture.invalid/private-link"))
            }
            // This is the production call-site proof: submit -> execute -> local backend
            // -> final authorized fire. No manually supplied TaskLocal context here.
            let task = manager.submit(objective: "Private fixture objective", tool: "filesystem.read",
                arguments: ["path": directory.appendingPathComponent("private-fixture.txt").path], source: "selftest")
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(5))
            while clock.now < deadline, manager.task(id: task.id)?.status == .queued || manager.task(id: task.id)?.status == .running {
                await Task.yield()
            }
            check(manager.task(id: task.id)?.status == .completed && backingCalls == 1,
                "actual manager/local backend did not reach one final-boundary backing")
            let second = TaskStore(root: directory)
            defer { second.close() }
            let events = try second.journal(taskID: task.id)
            check(events.map(\.draft.kind) == [.jobCreated, .workerStarted, .toolStarted, .toolCompleted, .jobCompleted, .artifactCaptured],
                "actual manager execution context did not journal its real tool and terminal transitions")
            check(events.allSatisfy { $0.draft.attempt == 0 && !($0.draft.detail ?? "").contains("Private") },
                "tool facts fabricated a bound attempt or copied private results")
            check(try second.load().first?.artifacts.count == 2
                && events.last?.draft.detail == "count:2", "actual local-backend artifact capture did not reach task/journal")

            // Additional boundary tests use the same production context factory, and
            // deliberately do not stand in for the primary submit/execute proof above.
            let context = manager.journalContext(taskID: task.id)
            let count = events.count
            await TaskEventJournal.$current.withValue(context) {
                do {
                    _ = try await AgentToolExecutor.run("filesystem.read", arguments: [:], policy: .selfTest, taskID: task.id)
                    check(false, "missing-argument call unexpectedly fired")
                } catch {}
                do {
                    _ = try await AgentToolExecutor.run("filesystem.write", arguments: ["path": "/fixture/path", "text": "Private body"],
                        policy: .denyMutations, taskID: task.id)
                    check(false, "denied mutation unexpectedly fired")
                } catch {}
            }
            check(try second.journal(taskID: task.id).count == count && backingCalls == 1,
                "denied/validation-refused call falsely journalled tool execution")

            AgentToolExecutor.fireOverrideForTesting = { _, _ in
                backingCalls += 1
                throw FixtureError.backingFailure
            }
            await TaskEventJournal.$current.withValue(context) {
                do {
                    _ = try await AgentToolExecutor.run("filesystem.read", arguments: ["path": "/fixture/path"], policy: .selfTest, taskID: task.id)
                    check(false, "throwing backing unexpectedly returned")
                } catch {}
            }
            let failed = try second.journal(taskID: task.id)
            check(failed.suffix(2).map(\.draft.kind) == [.toolStarted, .toolCompleted]
                && failed.last?.draft.detail == "filesystem.read:threw" && backingCalls == 2,
                "actual failed backing did not journal its bounded factual outcome")
            AgentToolExecutor.fakeForTesting = { _, _ in AgentToolResult(summary: "Private early fake") }
            try await TaskEventJournal.$current.withValue(context) {
                _ = try await AgentToolExecutor.run("filesystem.read", arguments: [:], policy: .selfTest, taskID: task.id)
            }
            check(try second.journal(taskID: task.id).count == failed.count, "pre-broker fake fabricated execution events")
            AgentToolExecutor.fakeForTesting = nil
            AgentToolExecutor.fireOverrideForTesting = { _, _ in AgentToolResult(summary: "Private unrelated backing") }
            try await TaskEventJournal.$current.withValue(context) {
                _ = try await AgentToolExecutor.run("filesystem.read", arguments: ["path": "/fixture/path"],
                    policy: .selfTest, taskID: "unrelated-task")
                _ = try await AgentToolExecutor.run("filesystem.read", arguments: ["path": "/fixture/path"], policy: .selfTest)
            }
            check(try second.journal(taskID: task.id).count == failed.count,
                "unbound or mismatching tool task identity was routed into the bound manager")
        } catch { failures.append("tool boundary fixture failed: \(error.localizedDescription)") }
        let permissions = await TaskPermissionJournalSelfTest.run()
        failures += permissions.failures
        failures += SelfTestStoreGuard.diff(before, SelfTestStoreGuard.take()).map { "owner store changed: \($0)" }
        for failure in failures { SelfTest.diagnostic("TASK_DURABILITY_WRONG: \(failure)") }
        if !failures.isEmpty { return "TASK_DURABILITY_FAILED: \(failures.count) tool assertions" }
        guard let base = stores.split(separator: " ").dropFirst().first.flatMap({ Int($0) }) else {
            return "TASK_DURABILITY_FAILED: missing base case count"
        }
        return "TASK_DURABILITY_OK: \(base + 5 + permissions.cases) cases"
    }
#endif

    private static func storageCases(in directory: URL, check: (Bool, String) -> Void) throws -> Int {
        var cases = 0
        let root = directory.appendingPathComponent("mirror", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let mirror = TaskStore(root: root)
        let json = AgentTaskStore(fileURL: root.appendingPathComponent("agent-tasks.json"), mirror: mirror)
        guard json.allowsHarnessPersistence,
              json.storageURL.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL,
              mirror.fileURL.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL else {
            throw FixtureError.unsafeStoreLocation
        }
        defer { mirror.close() }
        let manager = AgentTaskManager(store: json)
        var durability = TaskDurability()
        durability.attempt = 2
        durability.retryCount = 1
        durability.maxRetries = 3
        durability.resumePolicy = .verifyThenDecide
        durability.runtimeClass = .acpWorker
        durability.receiptIDs = ["fixture-receipt-b", "fixture-receipt-a"]
        durability.parentTaskID = "legacy-parent-id"
        durability.leaseOwner = "fixture-process"
        durability.heartbeatAt = Date(timeIntervalSince1970: 1_700_000_010.875)
        durability.lastProgressAt = durability.heartbeatAt
        durability.attemptStartedAt = durability.heartbeatAt
        durability.terminalReason = "Fixture reason"
        let detailed = AgentTask(id: "legacy-not-a-uuid", objective: "Requested draft: hello ☕\u{0}world",
            source: "scheduled", createdAt: Date(timeIntervalSince1970: 1_700_000_010.875),
            contextReferences: ["fixture://two", "fixture://one"], status: .completed, progress: "",
            result: "Existing result summary", artifacts: ["fixture://z", "fixture://a", "fixture://z", ""],
            tool: "", arguments: ["body": "Explicit requested content", "path": "/fixture/requested/path"],
            meetingID: UUID(uuidString: "11111111-1111-1111-1111-111111111111"), backend: "acp",
            failure: "", acpCLI: "fixture-cli", compatibilityCommand: "fixture-cli --fixture",
            compatibilityCLI: "", compatibilityDirectory: "/fixture/project",
            scheduleID: UUID(uuidString: "22222222-2222-2222-2222-222222222222"), durability: durability)
        let other = AgentTask(id: "fixture-other", objective: "Other fixture", source: "unknown-source",
            createdAt: detailed.createdAt, status: .completed)
        manager.beginScheduledRun(detailed)
        manager.beginScheduledRun(other)
        let canonical = json.load()
        check(manager.lastPersistenceResult == .saved, "real manager did not report successful JSON/mirror save")
        check(canonical.map(\.id) == [other.id, detailed.id], "JSON lost same-time original task order")
        check(try mirror.load() == canonical, "SQLite lost actual fields, nil/empty values, Unicode/NUL or artifact order/duplicates")
        check(canonical.last?.isUserInitiated == detailed.isUserInitiated && canonical.first?.source == other.source,
            "source/schedule authority semantics changed")
        check(canonical.last?.createdAt == Date(timeIntervalSince1970: 1_700_000_010), "canonical legacy ISO precision changed")
        cases += 1

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let legacy = try decoder.decode(AgentTask.self, from: Data(#"{"id":"legacy-id","objective":"Legacy fixture"}"#.utf8))
        check(legacy.durability == nil && legacy.acpCLI.isEmpty && legacy.compatibilityDirectory == nil,
            "old task without durability no longer decodes")
        check(try JSONDecoder().decode(TaskDurability.self, from: Data("{}".utf8)) == TaskDurability(),
            "absent durability keys did not use conservative defaults")
        let partial = try JSONDecoder().decode(TaskDurability.self, from: Data(#"{"attempt":7}"#.utf8))
        check(partial.attempt == 7 && partial.resumePolicy == .neverAuto && partial.maxRetries == 0,
            "partial durability invented retry authority")
        cases += 1

        let second = TaskStore(root: root)
        defer { second.close() }
        check(try second.load() == canonical, "a second connection did not see the committed snapshot")
        cases += 1
        check(try mirror.integrityProblems().isEmpty, "SQLite integrity/foreign-key checks found problems")
        try mirror.withConnection { db in
            check(try TaskStore.integer(db, "PRAGMA foreign_keys") == 1, "foreign keys were not read back as on")
            check(try TaskStore.integer(db, "PRAGMA busy_timeout") == 2000, "busy timeout changed")
            check(try TaskStore.integer(db, "PRAGMA synchronous") == 1, "synchronous mode was not NORMAL")
            check(try TaskStore.stringColumn(db, "PRAGMA journal_mode") == ["wal"], "journal mode was not WAL")
            check(try TaskStore.integer(db, "PRAGMA user_version") == TaskStoreSchema.version, "schema version was not installed")
            check(try TaskStore.stringColumn(db, "SELECT origin||title||user_words||delivery FROM task") == ["", ""],
                "future projections fabricated content")
        }
        cases += 1

        // The real MainActor JSON->mirror seam must never spend its general 2 s busy
        // allowance waiting for another writer, including the initial connection open.
        for cold in [false, true] {
            let beforeContention = try mirror.load()
            try second.withConnection { db in
                try TaskStore.exec(db, "BEGIN IMMEDIATE")
                defer { try? TaskStore.exec(db, "ROLLBACK") }
                if cold { mirror.close() }
                let started = ContinuousClock.now
                manager.finishScheduledRun(id: other.id, status: .completed,
                    result: cold ? "Cold contention fixture" : "Contention fixture", failure: nil)
                let elapsed = started.duration(to: .now)
                check(elapsed <= .milliseconds(50), "mirror contention stalled the real manager beyond 50 ms")
                check(manager.lastPersistenceResult == .mirrorFailed,
                    "writer contention was not visible through the real manager")
                check(json.load().first?.result == (cold ? "Cold contention fixture" : "Contention fixture"),
                    "writer contention made successful JSON history unavailable")
                SelfTest.diagnostic("TASK_DURABILITY_CONTENTION: cold=\(cold) elapsed=\(elapsed)")
            }
            check(try mirror.load() == beforeContention, "writer contention partially changed SQLite history")
            manager.finishScheduledRun(id: other.id, status: .completed, result: "Explicit convergence fixture", failure: nil)
            check(manager.lastPersistenceResult == .saved, "next explicit save did not converge after contention")
            check(try mirror.load() == json.load(), "next explicit save left SQLite stale")
            try mirror.withConnection { db in
                check(try TaskStore.integer(db, "PRAGMA busy_timeout") == 2000,
                    "fail-fast save did not restore the general busy allowance")
            }
        }
        cases += 1

        try mirror.withConnection { db in
            try TaskStore.run(db, "INSERT INTO task_event(task_id,at,kind) VALUES(?,1,'fixture')", [.text(detailed.id)])
            try TaskStore.run(db, "INSERT INTO task_dependency(upstream,downstream,requirement) VALUES(?,?,'fixture')",
                [.text(detailed.id), .text(other.id)])
            try TaskStore.run(db, "UPDATE task_artifact SET kind='document',title='Fixture metadata' WHERE task_id=? AND ordinal=0",
                [.text(detailed.id)])
        }
        manager.finishScheduledRun(id: other.id, status: .completed, result: "Updated fixture", failure: nil)
        let updated = json.load()
        check(try manager.lastPersistenceResult == .saved && mirror.load() == updated,
            "real manager update did not mirror its canonical JSON rows")
        try mirror.withConnection { db in
            check(try TaskStore.integer(db, "SELECT count(*) FROM task_event WHERE kind='fixture'") == 1, "task upsert deleted its event journal")
            check(try TaskStore.integer(db, "SELECT count(*) FROM task_dependency") == 1, "task upsert deleted dependency rows")
            check(try TaskStore.stringColumn(db, "SELECT title FROM task_artifact WHERE ordinal=0 AND title IS NOT NULL") == ["Fixture metadata"],
                "unchanged artifact ordinal/path lost existing metadata")
        }
        cases += 1

        try mirror.withConnection { db in
            try TaskStore.exec(db, """
                CREATE TRIGGER fixture_reject BEFORE INSERT ON task_artifact WHEN NEW.path='blocked'
                BEGIN SELECT RAISE(ABORT,'fixture rejection'); END
                """)
        }
        var rejected = updated
        rejected[0].objective = "Must roll back"
        rejected[0].artifacts = ["blocked"]
        do { try mirror.replaceSnapshot(rejected); check(false, "partial SQLite transaction unexpectedly committed") }
        catch { check(try mirror.load() == updated, "failed SQLite snapshot did not roll back state/artifacts") }
        try mirror.withConnection { try TaskStore.exec($0, "DROP TRIGGER fixture_reject") }
        cases += 1

        let blockedJSON = directory.appendingPathComponent("blocked-json", isDirectory: true)
        try FileManager.default.createDirectory(at: blockedJSON, withIntermediateDirectories: false)
        let jsonFailureManager = AgentTaskManager(store: AgentTaskStore(fileURL: blockedJSON, mirror: mirror))
        jsonFailureManager.beginScheduledRun(other)
        check(jsonFailureManager.lastPersistenceResult == .jsonFailed, "JSON failure was not reported by the real manager")
        check(try mirror.load() == updated, "JSON failure still changed the SQLite mirror")
        cases += 1

        let blockedRoot = directory.appendingPathComponent("blocked-sqlite")
        try Data("Fixture path blocker".utf8).write(to: blockedRoot)
        let survivingJSON = AgentTaskStore(fileURL: directory.appendingPathComponent("surviving-json.json"),
            mirror: TaskStore(root: blockedRoot))
        let mirrorFailureManager = AgentTaskManager(store: survivingJSON)
        mirrorFailureManager.beginScheduledRun(other)
        check(mirrorFailureManager.lastPersistenceResult == .mirrorFailed, "mirror failure was not reported by the real manager")
        check(survivingJSON.load().map(\.id) == [other.id], "mirror failure made successfully saved JSON unavailable")
        check(try Data(contentsOf: blockedRoot) == Data("Fixture path blocker".utf8), "mirror failure deleted its blocker")
        cases += 1

        let unknownRoot = directory.appendingPathComponent("unknown-version", isDirectory: true)
        try FileManager.default.createDirectory(at: unknownRoot, withIntermediateDirectories: false)
        let unknownFile = unknownRoot.appendingPathComponent(TaskStore.fileName)
        try rawSQLite(unknownFile) { db in
            try TaskStore.exec(db, "CREATE TABLE sentinel(value TEXT); INSERT INTO sentinel VALUES('Keep history'); PRAGMA user_version=99")
        }
        let unknownBefore = try Data(contentsOf: unknownFile)
        let unknown = TaskStore(root: unknownRoot)
        defer { unknown.close() }
        do { _ = try unknown.load(); check(false, "newer schema was accepted") }
        catch TaskStoreError.unsupportedVersion(99) {}
        check(try Data(contentsOf: unknownFile) == unknownBefore, "newer schema file was mutated/deleted")
        cases += 1

        let corruptRoot = directory.appendingPathComponent("corrupt", isDirectory: true)
        try FileManager.default.createDirectory(at: corruptRoot, withIntermediateDirectories: false)
        let corruptFile = corruptRoot.appendingPathComponent(TaskStore.fileName)
        let corruptBytes = Data("Corrupt fixture: keep these bytes".utf8)
        try corruptBytes.write(to: corruptFile)
        let corrupt = TaskStore(root: corruptRoot)
        defer { corrupt.close() }
        do { _ = try corrupt.load(); check(false, "corrupt schema was accepted") } catch {}
        check(try Data(contentsOf: corruptFile) == corruptBytes, "corrupt history was removed/rebuilt")
        cases += 1

        let malformedRoot = directory.appendingPathComponent("malformed", isDirectory: true)
        let malformed = TaskStore(root: malformedRoot)
        try malformed.replaceSnapshot([other])
        try malformed.withConnection { try TaskStore.exec($0, "DROP INDEX task_event_task") }
        malformed.close()
        let malformedBefore = try Data(contentsOf: malformed.fileURL)
        do { _ = try malformed.load(); check(false, "malformed known-version shape was accepted") } catch {}
        malformed.close()
        check(try Data(contentsOf: malformed.fileURL) == malformedBefore, "malformed known schema was rebuilt/mutated")
        cases += 1

        // Replacing a closed source file atomically changes the inode under an open reader.
        let replacementRoot = directory.appendingPathComponent("replacement", isDirectory: true)
        let replacement = TaskStore(root: replacementRoot)
        try replacement.replaceSnapshot([other])
        replacement.close()
        second.close()
        mirror.close()
        _ = try mirror.load() // open the original reader before atomic replacement
        try Data(contentsOf: replacement.fileURL).write(to: mirror.fileURL, options: .atomic)
        check(try mirror.load() == [other], "inode replacement kept serving the old ledger")
        cases += 1
        return cases
    }

    private static func journalProducerCases(in directory: URL, check: (Bool, String) -> Void) throws -> Int {
        let root = directory.appendingPathComponent("journal-producer", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let mirror = TaskStore(root: root)
        defer { mirror.close() }
        let json = AgentTaskStore(fileURL: root.appendingPathComponent("agent-tasks.json"), mirror: mirror)
        guard json.allowsHarnessPersistence else { throw FixtureError.unsafeStoreLocation }
        let manager = AgentTaskManager(store: json)
        let task = AgentTask(id: "journal-real-manager", objective: "Private objective must not enter journal",
            source: "scheduled", status: .running)
        manager.beginScheduledRun(task)
        manager.finishScheduledRun(id: task.id, status: .completed, result: "Private result", failure: nil)
        let kinds = try mirror.withConnection { try TaskStore.stringColumn($0,
            "SELECT kind FROM task_event WHERE task_id='journal-real-manager' ORDER BY seq") }
        check(kinds == ["jobCreated", "workerStarted", "jobCompleted"],
            "actual manager creation/start/completion did not journal exact transitions")
        manager.finishScheduledRun(id: task.id, status: .completed, result: "Private result", failure: nil)
        let repeated = try mirror.withConnection { try TaskStore.stringColumn($0,
            "SELECT kind FROM task_event WHERE task_id='journal-real-manager' ORDER BY seq") }
        check(repeated == kinds, "duplicate terminal callback fabricated a second transition")
        let beforeFailure = try mirror.load()
        try mirror.withConnection { db in
            try TaskStore.exec(db, """
                CREATE TRIGGER fixture_journal_failure BEFORE INSERT ON task_event
                WHEN NEW.kind='jobFailed' BEGIN SELECT RAISE(ABORT,'fixture journal rejection'); END
                """)
        }
        manager.finishScheduledRun(id: task.id, status: .failed, result: nil, failure: "Private failure")
        check(manager.lastPersistenceResult == .mirrorFailed, "failed journal append was invisible to real manager")
        check(json.load().first?.status == .failed, "failed SQLite journal made successful JSON inaccessible")
        let second = TaskStore(root: root)
        defer { second.close() }
        check(try second.load() == beforeFailure, "state committed without its event after injected journal failure")
        let afterFailureKinds = try second.withConnection { try TaskStore.stringColumn($0,
            "SELECT kind FROM task_event WHERE task_id='journal-real-manager' ORDER BY seq") }
        check(afterFailureKinds == kinds, "failed state transaction partially changed the journal")
        try mirror.withConnection { try TaskStore.exec($0, "DROP TRIGGER fixture_journal_failure") }
        let input = AgentTask(id: "journal-input", objective: "Fixture input", status: .running)
        manager.beginScheduledRun(input)
        manager.finishScheduledRun(id: input.id, status: .waitingForInput, result: nil, failure: nil)
        manager.respondInput(taskID: input.id, text: "Private entered text")
        check(try mirror.journal(taskID: input.id).map(\.draft.kind) == [.jobCreated, .workerStarted, .inputRequested, .inputProvided],
            "actual input-wait/input-response producer journal changed")
        check(json.load().first?.arguments["input"] == "Private entered text", "existing input execution payload changed")
        let permission = AgentTask(id: "journal-permission", objective: "Fixture permission", status: .running, tool: "filesystem.read")
        manager.beginScheduledRun(permission)
        manager.finishScheduledRun(id: permission.id, status: .waitingForPermission, result: nil, failure: nil)
        manager.respondPermission(taskID: permission.id, approved: false)
        check(try mirror.journal(taskID: permission.id).map(\.draft.kind) ==
            [.jobCreated, .workerStarted, .permissionRequested, .permissionDenied, .jobCancelled],
            "actual permission denial/cancellation producer journal changed")
        let all = try mirror.withConnection { try TaskStore.stringColumn($0, "SELECT COALESCE(detail,'') FROM task_event") }
        check(!all.joined().contains("Private"), "journal copied objective/result/failure/entered text")
        check(try mirror.withConnection { try TaskStore.integer($0, "SELECT count(*) FROM task_event WHERE attempt<>0") } == 0,
            "legacy task events fabricated an attempt binding")
        var durability = TaskDurability()
        durability.attempt = 3
        let attempted = AgentTask(id: "journal-attempt", objective: "Fixture attempt", status: .running, durability: durability)
        manager.beginScheduledRun(attempted)
        manager.finishScheduledRun(id: attempted.id, status: .completed, result: nil, failure: nil)
        let attemptedEvents = try mirror.journal(taskID: attempted.id)
        check(attemptedEvents.count == 3 && attemptedEvents.allSatisfy { $0.draft.attempt == 3 }
            && manager.journalContext(taskID: attempted.id)?.attempt == 3,
            "existing attempt metadata was not captured consistently")
        return 6
    }

    private static func journalRetentionCases(in directory: URL, check: (Bool, String) -> Void) throws -> Int {
        let root = directory.appendingPathComponent("journal-retention", isDirectory: true)
        let mirror = TaskStore(root: root)
        defer { mirror.close() }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let old = now.addingTimeInterval(-31 * 86_400)
        let recent = now.addingTimeInterval(-1 * 86_400)
        var receipt = TaskDurability()
        receipt.receiptIDs = ["fixture-retained-receipt"]
        let tasks = [
            AgentTask(id: "old-terminal", objective: "Fixture old", createdAt: recent, status: .completed, artifacts: ["fixture://keep"]),
            AgentTask(id: "recent-terminal", objective: "Fixture recent", createdAt: old, status: .failed),
            AgentTask(id: "receipt-terminal", objective: "Fixture receipt", createdAt: now, status: .completed, durability: receipt),
            AgentTask(id: "active", objective: "Fixture active", createdAt: now, status: .running),
            AgentTask(id: "unknown-age", objective: "Fixture unknown", createdAt: old, status: .completed),
            AgentTask(id: "latest-terminal", objective: "Fixture latest", createdAt: now, status: .cancelled)
        ]
        let events = [
            TaskJournalEventDraft(taskID: tasks[0].id, kind: .jobCompleted, at: old),
            TaskJournalEventDraft(taskID: tasks[1].id, kind: .jobFailed, at: recent),
            TaskJournalEventDraft(taskID: tasks[2].id, kind: .jobCompleted, at: old),
            TaskJournalEventDraft(taskID: tasks[3].id, kind: .jobFailed, at: old),
            TaskJournalEventDraft(taskID: tasks[4].id, kind: .jobCreated, at: old),
            TaskJournalEventDraft(taskID: tasks[5].id, kind: .jobCancelled, at: old),
            TaskJournalEventDraft(taskID: tasks[5].id, kind: .jobCancelled, at: recent)
        ]
        try mirror.replaceSnapshot(tasks, events: events, now: now)
        check(try mirror.journal(taskID: tasks[0].id).isEmpty, "old terminal journal was not compacted")
        for task in tasks.dropFirst() {
            check(try !mirror.journal(taskID: task.id).isEmpty, "receipt/active/recent/unknown-age journal was incorrectly deleted")
        }
        check(try mirror.load() == tasks, "journal compaction changed task/artifact rows")
        try mirror.withConnection { db in
            try TaskStore.exec(db, "INSERT INTO task_dependency(upstream,downstream,requirement) VALUES('old-terminal','active','fixture')")
        }
        let json = AgentTaskStore(fileURL: root.appendingPathComponent("agent-tasks.json"), mirror: mirror)
        check(json.save(tasks) == .saved && json.load() == tasks, "compaction changed JSON history")
        check(try mirror.withConnection { try TaskStore.integer($0, "SELECT count(*) FROM task_dependency") } == 1,
            "journal compaction deleted dependencies")
        var burst: [TaskJournalEventDraft] = []
        for index in 0..<40 { burst.append(TaskJournalEventDraft(taskID: "active", kind: .heartbeat,
            at: now, detail: "fixture:\(index)")) }
        try mirror.replaceSnapshot(tasks, events: burst, now: now)
        let seq = try mirror.journal(taskID: "active").map(\.seq)
        check(zip(seq, seq.dropFirst()).allSatisfy { $0 < $1 }, "journal sequence did not increase across burst")
        let previous = seq.last!
        try mirror.replaceSnapshot(tasks, events: [TaskJournalEventDraft(taskID: "active", kind: .heartbeat, at: now)], now: now)
        check(try mirror.journal(taskID: "active").last!.seq > previous, "journal sequence reused a compacted identity")
        try mirror.withConnection { db in
            try TaskStore.exec(db, "INSERT INTO task_event(task_id,at,kind,attempt) VALUES('active','unknown','heartbeat',0)")
        }
        do { _ = try mirror.journal(taskID: "active"); check(false, "invalid journal time silently became epoch zero") }
        catch TaskStoreError.invalidRecord {}
        check(try mirror.withConnection { try TaskStore.integer($0, "SELECT count(*) FROM task_event WHERE at='unknown'") } == 1,
            "journal rejection erased the corrupt row")
        try mirror.withConnection { db in
            try TaskStore.exec(db, "DELETE FROM task_event WHERE at='unknown'; INSERT INTO task_event(task_id,at,kind,attempt) VALUES('active',1,'heartbeat','oops')")
        }
        do { _ = try mirror.journal(taskID: "active"); check(false, "invalid journal attempt silently became unbound zero") }
        catch TaskStoreError.invalidRecord {}
        return 4
    }

    private static func rawSQLite(_ file: URL, body: (OpaquePointer) throws -> Void) throws {
        var handle: OpaquePointer?
        let code = sqlite3_open_v2(file.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard code == SQLITE_OK, let handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw TaskStoreError.sqlite(code)
        }
        defer { sqlite3_close_v2(handle) }
        try body(handle)
    }
}

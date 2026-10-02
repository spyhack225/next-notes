import Foundation
import SQLite3

/// Explicit repair uses the retained prepared snapshot and the same bound ledger.
/// All fixtures are injected temporary files; no worker, backend or owner history runs.
@MainActor
enum TaskHistoryRepairSelfTest {
    private enum Failure: Error { case interrupted, wrong(String) }

    @MainActor
    private struct Fixture {
        let root: URL
        let file: URL
        let sql: TaskStore
        var store: AgentTaskStore { AgentTaskStore(fileURL: file, mirror: sql) }
        init(_ parent: URL, _ name: String) throws {
            root = parent.appendingPathComponent(name)
            file = root.appendingPathComponent("agent-tasks.json")
            sql = TaskStore(root: root)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            guard store.allowsHarnessPersistence else { throw Failure.wrong("unsafe fixture") }
        }
        func prepared(_ tasks: [AgentTask]) throws {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(tasks).write(to: file)
            let pending = store
            pending.migrationBoundaryForTesting = { phase in
                if phase == "prepared" { throw Failure.interrupted }
            }
            do { _ = try pending.load(); throw Failure.wrong("preparation did not stop") }
            catch Failure.interrupted {}
        }
    }

    private static func raw<T>(_ url: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        var db: OpaquePointer?
        let code = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil)
        guard code == SQLITE_OK, let db else {
            if let db { sqlite3_close_v2(db) }
            throw TaskStoreError.sqlite(code)
        }
        defer { sqlite3_close_v2(db) }
        sqlite3_busy_timeout(db, 0)
        return try body(db)
    }

    private static func row(_ id: String = "fixture") -> AgentTask {
        AgentTask(id: id, objective: "Restore this saved task", source: "text",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), status: .running,
            progress: "Working", tool: "fixture.read", backend: "local")
    }

    private static func legacyPendingChecks(_ parent: URL) throws -> (Int, [String]) {
        let fixture = try Fixture(parent, "legacy-v1-pending")
        guard FileManager.default.createFile(atPath: fixture.sql.fileURL.path, contents: Data()) else {
            throw Failure.wrong("could not create isolated legacy fixture")
        }
        try raw(fixture.sql.fileURL) { db in
            try TaskStore.exec(db, TaskStoreSchema.sql)
            try TaskStore.exec(db, "ALTER TABLE task DROP COLUMN pending_interaction; PRAGMA user_version=1")
            try TaskStore.exec(db, """
                INSERT INTO task(id,state,source,backend,objective,progress,context_references,arguments,acp_cli,sort_order,created_at)
                VALUES('v1-legacy','completed','text','local','Legacy fixture','','[]','{}','',0,1700000000)
                """)
        }
        var count = 0
        var failures: [String] = []
        func check(_ value: Bool, _ label: String) {
            count += 1
            if !value { failures.append(label) }
        }
        let legacy = AgentTask(id: "v1-legacy", objective: "Legacy fixture", source: "text",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), status: .completed,
            progress: "", backend: "local")
        check(try fixture.sql.load() == [legacy], "true v1 nil projection changed")
        try raw(fixture.sql.fileURL) { db in
            check(try TaskStore.integer(db, "PRAGMA user_version") == 1 &&
                !TaskStore.stringColumn(db, "PRAGMA table_info(task)", column: 1).contains("pending_interaction") &&
                TaskStore.integer(db, "SELECT count(*) FROM sqlite_master WHERE name='task_authority'") == 0,
                "legacy read upgraded or marked the schema")
        }
        for kind in ["permission", "input"] {
            var task = legacy
            task.id = "v1-\(kind)"
            if kind == "permission" {
                task.status = .waitingForPermission
                task.tool = "filesystem.write"
                task.arguments = ["path": "/fixture/retained.md", "content": "Reviewed fixture content"]
                let request = PermissionRequest(id: "v1-retained-permission", toolID: task.tool!,
                    title: "Save fixture note", detail: "Retained fixture detail", risk: .modify,
                    arguments: task.arguments, taskID: task.id, createdAt: task.createdAt,
                    trigger: .youSaid("Save this fixture note"))
                task.pendingInteraction = .permission(request: request, origin: nil)
            } else {
                task.status = .waitingForInput
                task.pendingInteraction = .input(TaskInputRequest(id: "v1-retained-question",
                    taskID: task.id, question: "Which fixture folder?", createdAt: task.createdAt))
            }
            try fixture.sql.replaceSnapshot([task])
            try raw(fixture.sql.fileURL) { db in
                check(try TaskStore.integer(db, "SELECT count(*) FROM task WHERE pending_interaction IS NOT NULL") == 1,
                    "\(kind) snapshot did not physically retain its pending payload")
            }
            let fresh = TaskStore(root: fixture.root)
            defer { fresh.close() }
            check(try fresh.load() == [task], "accepted v1 \(kind) write lost pending payload on fresh read")
            check(try fresh.probeAuthority()?.authority == nil,
                "v1 \(kind) snapshot acquired authority")
            try raw(fixture.sql.fileURL) { db in
                check(try TaskStore.integer(db, "PRAGMA user_version") == 1 &&
                    TaskStore.integer(db, "SELECT count(*) FROM sqlite_master WHERE name='task_authority'") == 0,
                    "v1 \(kind) snapshot changed version or authority schema")
            }
        }
        return (count, failures)
    }

    #if !TASK_HISTORY_REPAIR_ORIGINAL
    private static func cachedEligibilityChecks(_ parent: URL) throws -> (Int, [String]) {
        let fixture = try Fixture(parent, "cached-repair-eligibility")
        try fixture.prepared([row()])
        var probes = 0
        fixture.sql.authorityBoundaryForTesting = { phase, _ in
            if phase == "preparedImportProbe" { probes += 1 }
        }
        let manager = AgentTaskManager(store: fixture.store)
        let initializedProbes = probes
        var failures: [String] = []
        var count = 0
        func check(_ value: Bool, _ label: String) {
            count += 1
            if !value { failures.append(label) }
        }
        check(initializedProbes > 0, "initial failure did not probe repair eligibility")
        check((0..<20).allSatisfy { _ in manager.canRepairTaskHistory }, "valid cached repair unavailable")
        check(probes == initializedProbes, "repair affordance repeatedly opened the ledger")
        let retained = fixture.root.appendingPathComponent("retained-original.sqlite")
        try FileManager.default.moveItem(at: fixture.sql.fileURL, to: retained)
        try Data().write(to: fixture.sql.fileURL)
        let witness = try Data(contentsOf: fixture.file)
        check(manager.canRepairTaskHistory && probes == initializedProbes,
            "affordance reread a changed file instead of using its cached state")
        check(!manager.repairTaskHistory() && manager.historyReadFailure != nil &&
            manager.backendStartsForTesting == 0 && manager.tasks.isEmpty,
            "explicit repair trusted stale eligibility after replacement")
        check(!manager.canRepairTaskHistory && probes > initializedProbes,
            "failed action did not refresh repair eligibility")
        check(try Data(contentsOf: fixture.file) == witness && Data(contentsOf: fixture.sql.fileURL).isEmpty,
            "rejected replacement changed retained files")
        return (count, failures)
    }
    #endif

    static func run() -> String {
        guard SelfTest.isRunning else { return "TASK_HISTORY_REPAIR_FAILED: harness required" }
        let before = SelfTestStoreGuard.take()
        let result = runFixtures()
        let changes = SelfTestStoreGuard.diff(before, SelfTestStoreGuard.take())
        for change in changes { SelfTest.diagnostic("TASK_HISTORY_REPAIR_WRONG: owner changed: \(change)") }
        return changes.isEmpty ? result : "TASK_HISTORY_REPAIR_FAILED: owner store changed"
    }

    private static func runFixtures() -> String {
        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("NextNotesHistoryRepair-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: parent) }
            #if TASK_REPAIR_CACHE_ORIGINAL
            let (count, failures) = try cachedEligibilityChecks(parent)
            for failure in failures { SelfTest.diagnostic("TASK_HISTORY_REPAIR_WRONG: \(failure)") }
            return failures.isEmpty ? "TASK_HISTORY_REPAIR_OK: \(count) cache cases"
                : "TASK_HISTORY_REPAIR_FAILED: \(failures.count) cache assertions"
            #elseif TASK_PENDING_V1_ORIGINAL
            let (count, failures) = try legacyPendingChecks(parent)
            for failure in failures { SelfTest.diagnostic("TASK_HISTORY_REPAIR_WRONG: \(failure)") }
            return failures.isEmpty ? "TASK_HISTORY_REPAIR_OK: \(count) v1 cases"
                : "TASK_HISTORY_REPAIR_FAILED: \(failures.count) v1 assertions"
            #elseif TASK_HISTORY_REPAIR_ORIGINAL
            let fixture = try Fixture(parent, "original-prepared-empty")
            try fixture.prepared([row()])
            let saved = try Data(contentsOf: fixture.file)
            let empty = try Data(contentsOf: fixture.sql.fileURL)
            let fresh = fixture.store
            do {
                try fresh.reconcilePreparedForTesting()
                guard try fresh.load() == [row()] else { throw Failure.wrong("payload changed") }
            } catch {
                guard try Data(contentsOf: fixture.file) == saved,
                      try Data(contentsOf: fixture.sql.fileURL) == empty else {
                    throw Failure.wrong("original refusal changed saved files")
                }
                return "TASK_HISTORY_REPAIR_FAILED: explicit prepared schema-zero repair is unavailable: \(error.localizedDescription)"
            }
            return "TASK_HISTORY_REPAIR_OK: original prepared fixture"
            #else
            var count = 0
            func check(_ condition: Bool, _ label: String) throws {
                guard condition else { throw Failure.wrong(label) }
                count += 1
            }
            let (legacyCases, legacyFailures) = try legacyPendingChecks(parent)
            guard legacyFailures.isEmpty else { throw Failure.wrong(legacyFailures.joined(separator: "; ")) }
            count += legacyCases
            let (cacheCases, cacheFailures) = try cachedEligibilityChecks(parent)
            guard cacheFailures.isEmpty else { throw Failure.wrong(cacheFailures.joined(separator: "; ")) }
            count += cacheCases
            func refused(_ fixture: Fixture, _ label: String) throws {
                let before = try Data(contentsOf: fixture.file)
                let sqlBefore = try? Data(contentsOf: fixture.sql.fileURL)
                let store = fixture.store
                try check(!store.canRepairPreparedHistory, "\(label): repair offered")
                do { try store.repairPreparedHistory(); throw Failure.wrong("\(label): repair accepted") }
                catch is TaskStoreError {} catch is DecodingError {}
                try check(try Data(contentsOf: fixture.file) == before &&
                    (try? Data(contentsOf: fixture.sql.fileURL)) == sqlBefore, "\(label): files changed")
            }
            // Original failure, now exercised through the product manager API. The
            // same planner commits a held restart decision; no backend is dispatched.
            let emptyFixture = try Fixture(parent, "prepared-empty")
            try emptyFixture.prepared([row()])
            let preparedBytes = try Data(contentsOf: emptyFixture.file)
            let blankBytes = try Data(contentsOf: emptyFixture.sql.fileURL)
            let manager = AgentTaskManager(store: emptyFixture.store)
            try check(manager.historyReadFailure != nil && manager.tasks.isEmpty, "startup silently repaired")
            try check(manager.canRepairTaskHistory, "matching empty preparation unavailable")
            try check(try Data(contentsOf: emptyFixture.file) == preparedBytes &&
                Data(contentsOf: emptyFixture.sql.fileURL) == blankBytes, "affordance changed files")
            try check(manager.repairTaskHistory(), "explicit repair failed")
            try check(manager.task(id: "fixture")?.status == .recovering &&
                manager.backendStartsForTesting == 0, "repair dispatched or did not hold")
            try check(!manager.canRepairTaskHistory && !manager.repairTaskHistory(), "marked history repair offered")
            let freshManager = AgentTaskManager(store: emptyFixture.store)
            try check(freshManager.historyReadFailure == nil &&
                freshManager.task(id: "fixture")?.status == .recovering &&
                freshManager.backendStartsForTesting == 0, "fresh restart lost held history")

            let known = try Fixture(parent, "prepared-known")
            var completed = row(); completed.status = .completed
            completed.artifacts = ["/fixture/kept.md"]
            try known.sql.replaceSnapshot([completed], events: [
                TaskJournalEventDraft(taskID: completed.id, kind: .jobCompleted, detail: "fixture")])
            let oldJournal = try known.sql.journal(taskID: completed.id)
            try known.prepared([completed])
            try check(known.store.canRepairPreparedHistory, "matching unmarked history unavailable")
            try known.store.repairPreparedHistory()
            try check(try known.store.load() == [completed] &&
                known.sql.journal(taskID: completed.id) == oldJournal, "existing children changed")

            for label in ["missing", "replacement", "future", "unknown-schema-zero", "foreign-application",
                          "corrupt", "generation", "format", "malformed", "conflicting", "known-foreign-table", "invalid-journal", "marked"] {
                let fixture = try Fixture(parent, label)
                try fixture.prepared([row()])
                switch label {
                case "missing": try FileManager.default.removeItem(at: fixture.sql.fileURL)
                case "replacement":
                    try FileManager.default.moveItem(at: fixture.sql.fileURL,
                        to: fixture.root.appendingPathComponent("retained.sqlite"))
                    try Data().write(to: fixture.sql.fileURL)
                case "future": try raw(fixture.sql.fileURL) { try TaskStore.exec($0, "PRAGMA user_version=5000") }
                case "unknown-schema-zero": try raw(fixture.sql.fileURL) { try TaskStore.exec($0, "CREATE TABLE foreign_history(value TEXT)") }
                case "foreign-application": try raw(fixture.sql.fileURL) { try TaskStore.exec($0, "PRAGMA application_id=123") }
                case "corrupt": try Data("not a database".utf8).write(to: fixture.sql.fileURL)
                case "generation", "format":
                    var envelope = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.file)) as! [String: Any]
                    if label == "generation" {
                        var authority = envelope["preparedAuthority"] as! [String: Any]
                        authority["generation"] = 2; envelope["preparedAuthority"] = authority
                    } else { envelope["formatVersion"] = 2 }
                    try JSONSerialization.data(withJSONObject: envelope).write(to: fixture.file)
                case "malformed": try Data("{}".utf8).write(to: fixture.file)
                case "conflicting":
                    var other = row(); other.objective = "A different task"
                    try fixture.sql.replaceSnapshot([other])
                case "known-foreign-table":
                    try fixture.sql.replaceSnapshot([row()])
                    try raw(fixture.sql.fileURL) { try TaskStore.exec($0, "CREATE TABLE foreign_history(value TEXT)") }
                case "invalid-journal":
                    try fixture.sql.replaceSnapshot([row()])
                    try raw(fixture.sql.fileURL) {
                        try TaskStore.exec($0, "INSERT INTO task_event(task_id,at,kind,attempt) VALUES('fixture',1,'unknown',0)")
                    }
                case "marked": try fixture.store.repairPreparedHistory()
                default: break
                }
                try refused(fixture, label)
            }

            // A mutation after the read-only affordance but inside the write
            // transaction must be rejected and rolled back, not installed over.
            let raced = try Fixture(parent, "transaction-race")
            try raced.prepared([row()])
            try check(raced.store.canRepairPreparedHistory, "race fixture unavailable")
            raced.sql.authorityBoundaryForTesting = { phase, db in
                if phase == "preparedRepairLocked", let db {
                    try TaskStore.exec(db, "CREATE TABLE unexpected(value TEXT)")
                }
            }
            do { try raced.store.repairPreparedHistory(); throw Failure.wrong("empty check was not repeated") }
            catch is TaskStoreError {}
            raced.sql.authorityBoundaryForTesting = nil
            try check(raced.store.canRepairPreparedHistory, "failed race did not roll back")
            try raw(raced.sql.fileURL) { db in
                try check(try TaskStore.integer(db, "PRAGMA user_version") == 0 &&
                    TaskStore.integer(db, "SELECT count(*) FROM sqlite_master") == 0, "race schema was committed")
            }

            let changed = try Fixture(parent, "changed-witness")
            try changed.prepared([row()])
            changed.sql.authorityBoundaryForTesting = { phase, _ in
                if phase == "beforeAuthorityCommit" { try Data("{}".utf8).write(to: changed.file) }
            }
            do { try changed.store.repairPreparedHistory(); throw Failure.wrong("changed witness accepted") }
            catch is TaskStoreError {}
            changed.sql.authorityBoundaryForTesting = nil
            try raw(changed.sql.fileURL) { db in
                try check(try TaskStore.integer(db, "PRAGMA user_version") == 0 &&
                    TaskStore.integer(db, "SELECT count(*) FROM sqlite_master") == 0, "witness failure marked SQL")
            }

            let interrupted = try Fixture(parent, "failed-primary")
            try interrupted.prepared([row()])
            let blocked = AgentTaskManager(store: interrupted.store)
            interrupted.sql.authorityBoundaryForTesting = { phase, _ in
                if phase == "beforeAuthorityCommit" { throw Failure.interrupted }
            }
            try check(!blocked.repairTaskHistory() && blocked.historyReadFailure != nil &&
                blocked.tasks.isEmpty && blocked.backendStartsForTesting == 0, "failed repair admitted work")
            interrupted.sql.authorityBoundaryForTesting = nil
            try check(blocked.canRepairTaskHistory && blocked.repairTaskHistory() &&
                blocked.task(id: "fixture")?.status == .recovering && blocked.backendStartsForTesting == 0,
                "retained repair could not be retried")
            return "TASK_HISTORY_REPAIR_OK: \(count) cases"
            #endif
        } catch { return "TASK_HISTORY_REPAIR_FAILED: \(error.localizedDescription)" }
    }
}

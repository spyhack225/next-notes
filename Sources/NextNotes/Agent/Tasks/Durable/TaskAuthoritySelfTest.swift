import Foundation
import SQLite3
import Darwin

/// Actual existing store/manager authority contracts; no worker recovery or retry.
@MainActor
enum TaskAuthoritySelfTest {
    private enum FixtureError: Error { case assertion(String), interrupted }
    @MainActor private struct Fixture {
        let root: URL
        let file: URL
        let sql: TaskStore
        let store: AgentTaskStore
        init(_ parent: URL, _ name: String) throws {
            root = parent.appendingPathComponent(name)
            file = root.appendingPathComponent("agent-tasks.json")
            sql = TaskStore(root: root)
            store = AgentTaskStore(fileURL: file, mirror: sql)
            guard store.allowsHarnessPersistence else { throw FixtureError.assertion("unsafe fixture path") }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        }
        func legacy(_ tasks: [AgentTask]) throws {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(tasks).write(to: file)
        }
        func marked(_ tasks: [AgentTask]) throws {
            try legacy(tasks)
            guard try store.load() == tasks else { throw FixtureError.assertion("migration payload changed") }
        }
    }
    private static func require(_ value: Bool, _ message: String) throws {
        if !value { throw FixtureError.assertion(message) }
    }
    private static func rejects(_ action: () throws -> Void) throws {
        do { try action() } catch { return }
        throw FixtureError.assertion("uncertain/corrupt storage was accepted")
    }
    private static func row(_ id: String = "fixture") -> AgentTask {
        AgentTask(id: id, objective: "Fixture requested local history", source: "selftest",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            contextReferences: ["fixture://one", "fixture://two"], status: .completed,
            progress: "Finished", result: "Fixture result", artifacts: ["fixture://same", "fixture://same"],
            tool: "fixture.read", arguments: ["path": "fixture://path", "input": "Fixture explicit input"],
            meetingID: UUID(uuidString: "11111111-1111-1111-1111-111111111111"), backend: "acp",
            acpCLI: "fixture-cli", compatibilityCommand: "fixture-cli fixture-command",
            compatibilityCLI: "fixture-cli", compatibilityDirectory: "fixture://project",
            scheduleID: UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
    }
    private static func rawChildren(_ sql: TaskStore) throws -> [[String]] {
        try sql.withConnection { db in
            try [
                "SELECT quote(seq)||'|'||quote(task_id)||'|'||quote(at)||'|'||quote(kind)||'|'||quote(detail)||'|'||quote(attempt) FROM task_event ORDER BY seq",
                "SELECT quote(task_id)||'|'||quote(ordinal)||'|'||quote(path)||'|'||quote(added_at)||'|'||quote(kind)||'|'||quote(title) FROM task_artifact ORDER BY task_id,ordinal",
                "SELECT quote(upstream)||'|'||quote(downstream)||'|'||quote(requirement) FROM task_dependency ORDER BY upstream,downstream",
                "SELECT quote(id)||'|'||quote(origin)||'|'||quote(title)||'|'||quote(user_words)||'|'||quote(revision)||'|'||quote(started_at)||'|'||quote(finished_at)||'|'||quote(question)||'|'||quote(pending_request_id)||'|'||quote(delivery)||'|'||quote(delivery_attempts) FROM task ORDER BY id"
            ].map { try TaskStore.stringColumn(db, $0) }
        }
    }
    private static func editHeader(_ file: URL, _ edit: (inout [String: Any]) -> Void) throws {
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        edit(&object)
        try JSONSerialization.data(withJSONObject: object).write(to: file)
    }

    static func run() -> String {
        let before = SelfTestStoreGuard.take()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextNotesTaskAuthority-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var failures: [String] = []
        var count = 0
        do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false) }
        catch { return "TASK_AUTHORITY_FAILED: fixture directory" }
        func test(_ name: String, _ action: (Fixture) throws -> Void) {
            count += 1
            do {
                let fixture = try Fixture(root, name)
                defer {
                    fixture.store.migrationBoundaryForTesting = nil
                    fixture.sql.authorityBoundaryForTesting = nil
                    fixture.sql.close()
                }
                try action(fixture)
            }
            catch { failures.append("\(name): \(error)") }
        }
        test("default-harness-read-only") { _ in
            let ownerBefore = SelfTestStoreGuard.take()
            _ = try? AgentTaskStore().load()
            _ = try? AgentTaskStore.shared.load()
            try require(SelfTestStoreGuard.diff(ownerBefore, SelfTestStoreGuard.take()).isEmpty,
                "default/shared harness reader migrated or changed owner files")
        }
        test("fresh") { f in
            try require(try f.store.load().isEmpty, "fresh primary was not empty")
            try require(try f.sql.probeAuthority()?.authority != nil, "fresh import lacks marker")
        }
        test("full-payload-and-v1-children") { f in
            let rows = [row("second"), row("first")]
            try f.legacy(rows)
            try f.sql.replaceSnapshot(rows)
            try f.sql.withConnection { db in
                try TaskStore.exec(db, "DROP TABLE task_authority; PRAGMA user_version=1")
                try TaskStore.exec(db, "UPDATE task SET origin='fixture-origin',title='fixture-title',user_words='fixture-request',revision=7,started_at=1700000000,finished_at=1700000001,question='fixture-question',pending_request_id='fixture-pending',delivery='fixture-delivery',delivery_attempts=2")
                try TaskStore.exec(db, "UPDATE task_artifact SET kind='fixture-kind',title='fixture-title',added_at=1700000042")
                try TaskStore.exec(db, "INSERT INTO task_event(task_id,at,kind,detail,attempt) VALUES('first',1700000001,'jobCompleted','fixture-detail',3)")
                try TaskStore.exec(db, "INSERT INTO task_dependency VALUES('first','second','fixture-requirement')")
            }
            let original = try rawChildren(f.sql)
            try require(try f.store.load() == rows, "ordered full payload/duplicates changed")
            try require(try rawChildren(f.sql) == original, "import changed raw children/future columns")
            try require(try f.sql.withConnection { try TaskStore.integer($0, "PRAGMA user_version") } == 3, "schema not upgraded transactionally")
            try require(try f.sql.integrityProblems().isEmpty, "import integrity failed")
        }
        test("artifact-suffix-preservation") { f in
            var old = row(); old.artifacts = ["fixture://same"]
            var current = row(); current.artifacts += ["fixture://new"]
            try f.sql.replaceSnapshot([old]); try f.legacy([current])
            try f.sql.withConnection { try TaskStore.exec($0, "UPDATE task_artifact SET added_at=1700000042,kind='retained-kind',title='retained-title'") }
            let prefix = try rawChildren(f.sql)[1]
            try require(try f.store.load() == [current], "artifact suffix was not imported in order")
            let after = try rawChildren(f.sql)[1]
            try require(after.count == 3 && Array(after.prefix(1)) == prefix, "suffix import changed original prefix metadata")
        }
        for phase in ["beforePreparation", "authorityCommitted"] {
            test("migration-interruption-\(phase)") { f in
                try f.legacy([row()])
                f.store.migrationBoundaryForTesting = { observed in if observed == phase { throw FixtureError.interrupted } }
                try rejects { _ = try f.store.load() }
                let fresh = AgentTaskStore(fileURL: f.file)
                if phase == "beforePreparation" {
                    try rejects { _ = try fresh.load() }
                    try require(try Data(contentsOf: f.sql.fileURL).isEmpty, "orphan created before tag was reconstructed")
                } else {
                    try require(try fresh.load() == [row()], "marker commit with retained prepared export lost authority")
                }
            }
        }
        for value in ["unknown", "x'00'"] {
            test("strict-date-\(value)") { f in
                try f.sql.replaceSnapshot([row()])
                let sqlValue = value == "unknown" ? "'unknown'" : value
                try f.sql.withConnection { try TaskStore.exec($0, "UPDATE task SET created_at=\(sqlValue)") }
                try rejects { _ = try f.sql.load() }
                try rejects { _ = try f.sql.probeAuthority() }
            }
        }
        for mutation in ["objective=x'00'", "sort_order='unknown'", "id=''", "durability='{\"attempt\":-1}'"] {
            test("strict-row-\(count)") { f in
                try f.sql.replaceSnapshot([AgentTask(id: "fixture", objective: "Fixture", source: "selftest")])
                try f.sql.withConnection { try TaskStore.exec($0, "UPDATE task SET \(mutation)") }
                try rejects { _ = try f.sql.load() }
            }
        }
        for mutation in ["ordinal=7", "ordinal='unknown'", "path=x'00'", "added_at='unknown'", "kind=x'00'"] {
            test("strict-artifact-\(count)") { f in
                try f.sql.replaceSnapshot([row()])
                try f.sql.withConnection { try TaskStore.exec($0, "UPDATE task_artifact SET \(mutation) WHERE ordinal=0") }
                try rejects { _ = try f.sql.probeAuthority() }
            }
        }
        test("fk-orphan") { f in
            try f.sql.replaceSnapshot([row()])
            try f.sql.withConnection { db in
                try TaskStore.exec(db, "PRAGMA foreign_keys=OFF")
                try TaskStore.exec(db, "INSERT INTO task_event(task_id,at,kind) VALUES('absent',1700000000,'jobCreated')")
                try TaskStore.exec(db, "PRAGMA foreign_keys=ON")
            }
            try rejects { _ = try f.sql.probeAuthority() }
        }
        for text in ["damaged", "[{}]"] {
            test("strict-json-\(count)") { f in
                try f.sql.replaceSnapshot([row()])
                let original = try rawChildren(f.sql)
                try Data(text.utf8).write(to: f.file)
                let database = try Data(contentsOf: f.sql.fileURL)
                try rejects { _ = try f.store.load() }
                try require(try Data(contentsOf: f.file) == Data(text.utf8), "damaged JSON overwritten")
                try require(try Data(contentsOf: f.sql.fileURL) == database && rawChildren(f.sql) == original, "strict preflight changed original SQL")
                try require(f.store.save([]) == .loadFailed, "failed read erased history")
            }
        }
        test("duplicate-json") { f in
            try f.legacy([row(), row()])
            try rejects { _ = try f.store.load() }
            try require(!FileManager.default.fileExists(atPath: f.sql.fileURL.path), "invalid JSON created SQL")
        }
        test("missing-json-orphan-rows") { f in
            try f.sql.replaceSnapshot([row()])
            try rejects { _ = try f.store.load() }
            try require(!FileManager.default.fileExists(atPath: f.file.path), "missing JSON resurrected orphan rows")
        }
        test("orphan-mirror-id") { f in
            try f.sql.replaceSnapshot([row("orphan")]); try f.legacy([row()])
            let json = try Data(contentsOf: f.file); let sql = try Data(contentsOf: f.sql.fileURL)
            try rejects { _ = try f.store.load() }
            try require(try Data(contentsOf: f.file) == json && Data(contentsOf: f.sql.fileURL) == sql, "conflict changed originals")
        }
        test("artifact-conflict") { f in
            var old = row(); old.artifacts = ["fixture://other"]
            try f.sql.replaceSnapshot([old]); try f.legacy([row()])
            let children = try rawChildren(f.sql)
            try rejects { _ = try f.store.load() }
            try require(try rawChildren(f.sql) == children, "artifact conflict overwrote metadata")
        }
        test("import-rollback") { f in
            try f.legacy([row()]); try f.sql.replaceSnapshot([row()])
            try f.sql.withConnection { db in
                try TaskStore.exec(db, "DROP TABLE task_authority; PRAGMA user_version=1")
                try TaskStore.exec(db, "CREATE TRIGGER reject_import BEFORE UPDATE ON task BEGIN SELECT RAISE(ABORT,'fixture'); END")
            }
            let children = try rawChildren(f.sql)
            try rejects { _ = try f.store.load() }
            try require(try f.sql.withConnection { try TaskStore.integer($0, "PRAGMA user_version") } == 1, "failed import left upgraded version")
            try require(try f.sql.probeAuthority()?.authority == nil && rawChildren(f.sql) == children, "failed import committed marker/children")
            try rejects { _ = try AgentTaskStore(fileURL: f.file).load() } // uncertain prepared export
        }
        test("prepared-explicit-only") { f in
            try f.legacy([row()]); try f.sql.replaceSnapshot([row()])
            f.store.migrationBoundaryForTesting = { phase in if phase == "prepared" { throw FixtureError.interrupted } }
            try rejects { _ = try f.store.load() }
            let fresh = AgentTaskStore(fileURL: f.file)
            try rejects { _ = try fresh.load() }
            try fresh.reconcilePreparedForTesting()
            try require(try fresh.load() == [row()], "explicit injected repair failed")
        }
        test("schema-zero-orphan") { f in
            try f.legacy([row()]); try Data().write(to: f.sql.fileURL)
            try rejects { _ = try f.store.load() }
            try require(try Data(contentsOf: f.sql.fileURL).isEmpty, "schema-zero orphan reconstructed")
        }
        test("orphan-wal") { f in
            try f.legacy([row()]); let wal = URL(fileURLWithPath: f.sql.fileURL.path + "-wal")
            try Data("fixture-orphan".utf8).write(to: wal)
            try rejects { _ = try f.store.load() }
            try require(!FileManager.default.fileExists(atPath: f.sql.fileURL.path), "orphan WAL caused DB creation")
        }
        test("marked-missing-new-instance") { f in
            try f.marked([row()]); f.sql.close()
            try FileManager.default.removeItem(at: f.sql.fileURL)
            for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: f.sql.fileURL.path + suffix) }
            let json = try Data(contentsOf: f.file)
            let fresh = AgentTaskStore(fileURL: f.file)
            try rejects { _ = try fresh.load() }
            try require(fresh.save([]) == .loadFailed && !FileManager.default.fileExists(atPath: f.sql.fileURL.path), "missing marked DB recreated")
            try require(try Data(contentsOf: f.file) == json, "retained authority witness overwritten")
        }
        test("committed-export-failure-then-missing-db") { f in
            try f.marked([row()])
            let witness = try Data(contentsOf: f.file)
            f.store.migrationBoundaryForTesting = { phase in if phase == "primaryCommitted" { throw FixtureError.interrupted } }
            try require(f.store.save([row("new")]) == .exportFailed, "postcommit export failure lost commit result")
            try require(try Data(contentsOf: f.file) == witness, "prepared witness changed on export failure")
            f.sql.close()
            try FileManager.default.removeItem(at: f.sql.fileURL)
            for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: f.sql.fileURL.path + suffix) }
            try rejects { _ = try AgentTaskStore(fileURL: f.file).load() }
            try require(!FileManager.default.fileExists(atPath: f.sql.fileURL.path), "prepared stale export recreated lost committed DB")
        }
        test("marked-replaced-with-unmarked") { f in
            try f.marked([row()])
            try f.sql.withConnection { try TaskStore.exec($0, "DELETE FROM task_authority") }
            try rejects { _ = try AgentTaskStore(fileURL: f.file).load() }
            try require(try f.sql.probeAuthority()?.authority == nil, "uncertain backup automatically remarked")
        }
        test("marked-corrupt") { f in
            try f.marked([row()]); f.sql.close()
            let corrupt = Data("fixture corrupt SQL".utf8); try corrupt.write(to: f.sql.fileURL)
            try rejects { _ = try AgentTaskStore(fileURL: f.file).load() }
            try require(try Data(contentsOf: f.sql.fileURL) == corrupt, "corrupt authority discarded")
        }
        test("marked-unknown-version") { f in
            try f.marked([row()])
            try f.sql.withConnection { try TaskStore.exec($0, "PRAGMA user_version=999") }
            let original = try Data(contentsOf: f.sql.fileURL)
            try rejects { _ = try AgentTaskStore(fileURL: f.file).load() }
            try require(try Data(contentsOf: f.sql.fileURL) == original, "unknown schema discarded")
        }
        for variant in ["missing", "corrupt", "payload-corrupt"] {
            test("marked-export-\(variant)") { f in
                try f.marked([row()])
                if variant == "missing" { try FileManager.default.removeItem(at: f.file) }
                else if variant == "corrupt" { try Data("damaged export".utf8).write(to: f.file) }
                else { try editHeader(f.file) { $0["tasks"] = "damaged payload" } }
                try require(try AgentTaskStore(fileURL: f.file).load() == [row()], "valid SQL hidden by damaged export")
            }
        }
        for variant in ["higher-generation", "different-id"] {
            test("witness-\(variant)") { f in
                try f.marked([row()])
                try editHeader(f.file) { object in
                    var marker = object["preparedAuthority"] as! [String: Any]
                    if variant == "higher-generation" { marker["generation"] = 100 }
                    else { marker["databaseID"] = UUID().uuidString }
                    object["preparedAuthority"] = marker
                }
                try rejects { _ = try AgentTaskStore(fileURL: f.file).load() }
            }
        }
        test("fresh-save-without-load") { f in
            try f.marked([row()])
            let fresh = AgentTaskStore(fileURL: f.file)
            try f.sql.withConnection { try TaskStore.exec($0, "CREATE TRIGGER reject_save BEFORE UPDATE ON task BEGIN SELECT RAISE(ABORT,'fixture'); END") }
            let json = try Data(contentsOf: f.file)
            var newer = row(); newer.progress = "Fixture new request"
            try require(fresh.save([newer]) == .sqlFailed, "fresh save ignored marked authority")
            try require(try Data(contentsOf: f.file) == json && f.sql.load() == [row()], "failed SQL write changed history/export")
        }
        test("generation-conflict") { f in
            try f.marked([row()])
            let second = AgentTaskStore(fileURL: f.file); _ = try second.load()
            var newer = row(); newer.progress = "Newer external primary snapshot"
            try require(second.save([newer]) == .saved, "second writer did not commit")
            try require(f.store.save([row()]) == .sqlFailed, "stale loaded writer replaced newer generation")
            try require(try AgentTaskStore(fileURL: f.file).load() == [newer], "stale writer lost newer data")
        }
        test("export-failure-then-new-reader") { f in
            try f.marked([row()])
            // Real filesystem export blocker; existing SQL/WAL remains writable.
            try FileManager.default.removeItem(at: f.file)
            try FileManager.default.createDirectory(at: f.file, withIntermediateDirectories: false)
            var newer = row(); newer.progress = "SQL primary committed"
            try require(f.store.save([newer]) == .exportFailed, "SQL commit/export failure not distinguished")
            try require(try AgentTaskStore(fileURL: f.file).load() == [newer], "new store lost SQL commit after export failure")
        }
        test("writer-contention") { f in
            try f.marked([row()]); let original = try Data(contentsOf: f.file)
            try f.sql.withConnection { db in
                try TaskStore.exec(db, "BEGIN IMMEDIATE"); defer { try? TaskStore.exec(db, "ROLLBACK") }
                let start = Date()
                try require(f.store.save([row("new")]) == .sqlFailed, "busy primary save accepted")
                try require(Date().timeIntervalSince(start) <= 0.050, "main actor save waited for writer")
                try require(try Data(contentsOf: f.file) == original, "contention wrote JSON first")
                let independent = TaskStore(root: f.root)
                try require(try independent.probeAuthority()?.tasks == [row()], "contention changed SQL history")
            }
            try require(f.store.save([row("new")]) == .saved, "next explicit save did not converge")
        }
        test("probe-single-snapshot") { f in
            try f.marked([row()])
            let writer = TaskStore(root: f.root)
            f.sql.authorityBoundaryForTesting = { phase, _ in
                guard phase == "probeMarkerRead" else { return }
                f.sql.authorityBoundaryForTesting = nil
                try writer.withConnection { db in
                    try TaskStore.transaction(db) {
                        try TaskStore.exec(db, "UPDATE task SET progress='Concurrent commit'; UPDATE task_authority SET generation=generation+1")
                    }
                }
            }
            let probe = try f.sql.probeAuthority()
            try require(probe?.authority?.generation == 1 && probe?.tasks == [row()], "probe mixed marker and payload generations")
            // Writer remains open, so the new committed generation is still WAL-visible.
            let cold = try TaskStore(root: f.root).probeAuthority()
            var concurrent = row(); concurrent.progress = "Concurrent commit"
            try require(cold?.authority?.generation == 2 && cold?.tasks == [concurrent],
                "cold authority probe missed committed WAL")
        }
        test("removed-before-final-open") { f in
            try f.marked([row()])
            f.store.migrationBoundaryForTesting = { phase in
                if phase == "beforePrimaryCommit" { try FileManager.default.removeItem(at: f.sql.fileURL) }
            }
            let original = try Data(contentsOf: f.file)
            try require(f.store.save([row("new")]) == .sqlFailed, "removed primary accepted/recreated")
            try require(!FileManager.default.fileExists(atPath: f.sql.fileURL.path) && Data(contentsOf: f.file) == original, "TOCTOU created DB or export")
        }
        test("moved-before-commit-rollback") { f in
            try f.marked([row()])
            f.sql.authorityBoundaryForTesting = { phase, db in
                if phase == "beforeAuthorityCommit" {
                    // Move actual backing file and keep transaction handle. Unix VFS's
                    // HAS_MOVED detects this before COMMIT; old handle must roll back.
                    try FileManager.default.moveItem(at: f.sql.fileURL, to: f.root.appendingPathComponent("retained.sqlite"))
                    _ = db
                }
            }
            try require(f.store.save([row("new")]) == .sqlFailed, "detached backing committed")
            f.sql.authorityBoundaryForTesting = nil
            try FileManager.default.moveItem(at: f.root.appendingPathComponent("retained.sqlite"), to: f.sql.fileURL)
            try require(try f.sql.load() == [row()], "precommit relocation failed to roll back rows")
        }
        test("open-aba-file-identity") { f in
            try f.marked([row()]); f.sql.close()
            let other = try Fixture(root, "aba-other")
            try other.marked([row("other")]); other.sql.close()
            let retained = f.root.appendingPathComponent("original.sqlite")
            f.sql.authorityBoundaryForTesting = { phase, _ in
                if phase == "beforeExistingOpen" {
                    try FileManager.default.moveItem(at: f.sql.fileURL, to: retained)
                    try FileManager.default.moveItem(at: other.sql.fileURL, to: f.sql.fileURL)
                } else if phase == "existingOpened" {
                    try FileManager.default.moveItem(at: f.sql.fileURL, to: other.sql.fileURL)
                    try FileManager.default.moveItem(at: retained, to: f.sql.fileURL)
                }
            }
            try rejects { _ = try f.sql.probeAuthority() }
            f.sql.authorityBoundaryForTesting = nil
            try require(try f.sql.probeAuthority()?.tasks == [row()], "ABA probe damaged original history")
        }
        test("manager-primary-admission") { f in
            let manager = AgentTaskManager(store: f.store)
            try f.sql.withConnection { try TaskStore.exec($0, "CREATE TRIGGER reject_admission BEFORE INSERT ON task BEGIN SELECT RAISE(ABORT,'fixture'); END") }
            let rejected = manager.submit(objective: "Fixture rejected admission", backend: .acp)
            try require(rejected.status == .failed && manager.tasks.isEmpty, "failed primary accepted queued row")
            try require(manager.lastPersistenceResult == .sqlFailed && rejected.failure != nil, "rejected admission lacks diagnostic")
        }
        for status in [AgentTaskStatus.waitingForInput, .waitingForPermission] {
            test("callback-rejected-\(status.rawValue)") { f in
                var pending = row(); pending.scheduleID = nil; pending.status = status; pending.backend = "local"
                if status == .waitingForInput {
                    pending.pendingInteraction = .input(TaskInputRequest(id: "original-input", taskID: pending.id,
                        question: "Which fixture value should I use?", createdAt: pending.createdAt))
                } else {
                    pending.pendingInteraction = .permission(request: PermissionRequest(id: "original-permission",
                        toolID: pending.tool!, title: "Approve original fixture", detail: "Original fixture payload",
                        risk: .read, arguments: pending.arguments, taskID: pending.id, createdAt: pending.createdAt), origin: nil)
                }
                try f.marked([pending]); let manager = AgentTaskManager(store: f.store)
                try f.sql.withConnection { try TaskStore.exec($0, "CREATE TRIGGER reject_callback BEFORE UPDATE ON task BEGIN SELECT RAISE(ABORT,'fixture'); END") }
                if status == .waitingForInput { manager.respondInput(taskID: pending.id, text: "Fixture input") }
                else { _ = manager.respondRestoredPermission(taskID: pending.id, requestID: "original-permission",
                    approved: true, arguments: pending.arguments) }
                try require(manager.task(id: pending.id) == pending && manager.lastPersistenceResult == .sqlFailed
                    && !manager.consumePermissionApproval(taskID: pending.id), "failed callback changed pending state or retained token")
                try require(try f.sql.load() == [pending], "failed callback changed durable pending row")
            }
        }
        failures += SelfTestStoreGuard.diff(before, SelfTestStoreGuard.take()).map { "owner changed: \($0)" }
        for failure in failures { SelfTest.diagnostic("TASK_AUTHORITY_WRONG: \(failure)") }
        return failures.isEmpty ? "TASK_AUTHORITY_OK: \(count) cases" : "TASK_AUTHORITY_FAILED: \(failures.count) assertions"
    }

#if TASK_DURABILITY_STANDALONE
    /// Tiny driver subprocess exits at real boundaries; app tests do not spawn an app.
    static func runCrashFixtureIfRequested() throws -> Bool {
        let args = CommandLine.arguments
        guard let position = args.firstIndex(of: "--authority-process"), args.count > position + 3 else { return false }
        let mode = args[position + 1]
        let phase = args[position + 2]
        let directory = URL(fileURLWithPath: args[position + 3])
        guard directory.resolvingSymlinksInPath().path.hasPrefix(FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/") else {
            throw FixtureError.assertion("unsafe subprocess path")
        }
        if mode == "crash" {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fixture = try Fixture(directory, "retained")
            try fixture.legacy([row()])
            if phase == "prepared" { try fixture.sql.replaceSnapshot([row()]) }
            if phase == "primaryCommitted" { _ = try fixture.store.load() }
            fixture.store.migrationBoundaryForTesting = { observed in if observed == phase { Darwin._exit(73) } }
            if phase == "primaryCommitted" {
                var newer = row(); newer.progress = "Committed before process exit"
                _ = fixture.store.save([newer])
            } else { _ = try fixture.store.load() }
            throw FixtureError.assertion("process crash boundary was not reached")
        }
        let file = directory.appendingPathComponent("retained/agent-tasks.json")
        let store = AgentTaskStore(fileURL: file)
        if phase == "beforePreparation" || phase == "prepared" {
            try rejects { _ = try store.load() }
        } else {
            var expected = row()
            if phase == "primaryCommitted" { expected.progress = "Committed before process exit" }
            try require(try store.load() == [expected], "fresh process lost committed authority")
        }
        print("TASK_AUTHORITY_PROCESS_OK: \(phase)")
        return true
    }
#endif

#if !TASK_DURABILITY_STANDALONE
    static func runIncludingSubmission() async -> String {
        let pure = run()
        guard pure.hasPrefix("TASK_AUTHORITY_OK:") else { return pure }
        let baseCount = Int(pure.split(separator: " ")[1]) ?? 0
        let before = SelfTestStoreGuard.take()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextNotesTaskAuthorityAsync-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var failures: [String] = []
        var count = 0
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            // Keep the original JSON-writer failure scenario after the intentional
            // authority switch: committed SQL means accepted work with exportFailed.
            count += 1
            let f = try Fixture(root, "export-accepted")
            try f.marked([])
            let manager = AgentTaskManager(store: f.store)
            try FileManager.default.removeItem(at: f.file)
            try FileManager.default.createDirectory(at: f.file, withIntermediateDirectories: false)
            let accepted = manager.submit(objective: "Fixture safe local empty tool", backend: .local)
            try require(accepted.status == .queued && manager.lastPersistenceResult == .exportFailed,
                "SQL committed/export failure was incorrectly rejected")
            try require(try f.sql.load().contains { $0.id == accepted.id && $0.status == .queued }, "accepted submission missing from SQL")
            for _ in 0..<100 where manager.task(id: accepted.id)?.status == .queued || manager.task(id: accepted.id)?.status == .running { await Task.yield() }
            try require(manager.backendStartsForTesting == 1 && manager.task(id: accepted.id)?.status == .failed,
                "real local:nil backend did not run its existing no-tool failure")
            let completionEncoder = JSONEncoder(); completionEncoder.dateEncodingStrategy = .iso8601
            let completionDecoder = JSONDecoder(); completionDecoder.dateDecodingStrategy = .iso8601
            let canonicalCompletion = try completionDecoder.decode([AgentTask].self,
                from: completionEncoder.encode(manager.tasks))
            let reopenedCompletion = try AgentTaskStore(fileURL: f.file).load()
            try require(reopenedCompletion == canonicalCompletion, "export failure hid canonical actual backend completion")
            guard let memory = manager.task(id: accepted.id), let primary = reopenedCompletion.first else {
                throw FixtureError.assertion("backend completion lost its task identity")
            }
            try require(primary.id == accepted.id && primary.status == .failed && primary.result == memory.result
                && primary.failure == memory.failure
                && primary.createdAt == Date(timeIntervalSince1970: floor(memory.createdAt.timeIntervalSince1970)),
                "backend completion lost fields or changed legacy whole-second timestamp precision")
            SelfTest.diagnostic("TASK_AUTHORITY_CANONICAL: createdAt_delta=\(memory.createdAt.timeIntervalSince(primary.createdAt))")

            // Exercise the real execute caller: callback admission commits, then the
            // workerStarted UPDATE fails. No backend starts; approval is consumed/cleared.
            count += 1
            let start = try Fixture(root, "worker-start-rejected")
            var pending = AgentTask(id: "start-pending", objective: "Fixture waiting approval", source: "selftest",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000), status: .waitingForPermission,
                tool: "fixture.invalid-read")
            pending.arguments = ["fixture": "value"]
            pending.pendingInteraction = .permission(request: PermissionRequest(id: "start-original-request",
                toolID: pending.tool!, title: "Approve original start", detail: "Original fixture payload", risk: .read,
                arguments: pending.arguments, taskID: pending.id, createdAt: pending.createdAt), origin: nil)
            try start.marked([pending])
            let starter = AgentTaskManager(store: start.store)
            starter.backendEntryForTesting = { throw FixtureError.assertion("rejected start entered backend boundary") }
            start.store.migrationBoundaryForTesting = { phase in
                if phase == "primaryCommitted" {
                    start.store.migrationBoundaryForTesting = nil
                    try start.sql.withConnection { try TaskStore.exec($0,
                        "CREATE TRIGGER reject_start BEFORE UPDATE ON task WHEN new.state='running' BEGIN SELECT RAISE(ABORT,'fixture'); END") }
                }
            }
            _ = starter.respondRestoredPermission(taskID: pending.id, requestID: "start-original-request",
                approved: true, arguments: pending.arguments)
            for _ in 0..<100 where starter.task(id: pending.id)?.status == .queued { await Task.yield() }
            try require(starter.task(id: pending.id)?.status == .failed && starter.lastPersistenceResult == .sqlFailed,
                "failed worker start was not rejected")
            try require(starter.backendStartsForTesting == 0 && !starter.consumePermissionApproval(taskID: pending.id),
                "failed worker start entered backend or retained one-shot approval")
            try require(try start.sql.load().first?.status == .queued, "worker-start failure changed prior committed queued snapshot")
            try require(try start.sql.journal(taskID: pending.id).map { $0.draft.kind } == [.permissionApproved],
                "failed worker-start fabricated durable started event")

            count += 1
            let compatibility = try Fixture(root, "compatibility-callback-rejected")
            var parked = AgentTask(id: "compat-pending", objective: "Fixture safe CLI review", source: "selftest",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000), status: .waitingForCompatibilityCLI,
                backend: "acp", acpCLI: "fixture-cli")
            parked.compatibilityCLI = "fixture-cli"
            parked.compatibilityCommand = ACPCompatibilityCLIBackend.commandLine(cli: "fixture-cli", objective: parked.objective)
            try compatibility.marked([parked])
            let cli = AgentTaskManager(store: compatibility.store)
            cli.backendEntryForTesting = { throw FixtureError.assertion("rejected approval entered CLI boundary") }
            try compatibility.sql.withConnection { try TaskStore.exec($0,
                "CREATE TRIGGER reject_compat BEFORE UPDATE ON task BEGIN SELECT RAISE(ABORT,'fixture'); END") }
            cli.approveCompatibilityCLI(taskID: parked.id)
            try require(cli.task(id: parked.id)?.status == .failed && !cli.hasCompatibilityApprovalForTesting(taskID: parked.id),
                "failed compatibility transition kept approval/queued state")
            await Task.yield()
            try require(cli.backendStartsForTesting == 0, "failed compatibility approval dispatched CLI")

            // Real explicit parser -> delegate -> actual rejected Manager.submit -> reply.
            // Probe synchronous admission first to prevent unsafe ACP dispatch if a future
            // producer regression is present; original installed ACP red is never run.
            for mode in ["trigger", "writer-busy"] {
                count += 1
                let route = try Fixture(root, "delegate-\(mode)")
                try route.marked([])
                let rejectedManager = AgentTaskManager(store: route.store)
                rejectedManager.backendEntryForTesting = { throw FixtureError.assertion("rejected route entered backend boundary") }
                var writer: OpaquePointer?
                if mode == "trigger" {
                    try route.sql.withConnection { try TaskStore.exec($0,
                        "CREATE TRIGGER reject_route BEFORE INSERT ON task BEGIN SELECT RAISE(ABORT,'fixture'); END") }
                } else {
                    let code = sqlite3_open_v2(route.sql.fileURL.path, &writer, SQLITE_OPEN_READWRITE, nil)
                    guard code == SQLITE_OK, let writer else { throw FixtureError.assertion("fixture writer did not open") }
                    try TaskStore.exec(writer, "BEGIN IMMEDIATE")
                }
                defer { if let writer { try? TaskStore.exec(writer, "ROLLBACK"); sqlite3_close_v2(writer) } }
                let preliminary = rejectedManager.submit(objective: "Fixture admission safety probe", backend: .local)
                guard preliminary.status == .failed, rejectedManager.tasks.isEmpty else {
                    rejectedManager.cancel(preliminary.id)
                    throw FixtureError.assertion("primary producer regression: real ACP route was not attempted")
                }
                let oldManager = RealtimeAgent.shared.taskManagerForTesting
                let oldProbe = AgentHarnessRouter.shared.availabilityProbe
                RealtimeAgent.shared.taskManagerForTesting = rejectedManager
                AgentHarnessRouter.shared.availabilityProbe = { _ in true }
                defer {
                    RealtimeAgent.shared.taskManagerForTesting = oldManager
                    AgentHarnessRouter.shared.availabilityProbe = oldProbe
                }
                let audits = AgentAuditLog.shared.entries.filter { $0.kind == .task }.count
                let json = try Data(contentsOf: route.file)
                let response = await RealtimeAgent.shared.handle("Use OpenCode to inspect this fixture.", source: .text)
                try require(!response.delegated && response.reply == AgentTaskPersistenceResult.sqlFailed.diagnostic,
                    "SQL-rejected delegation promised background work instead of actual diagnostic")
                try require(rejectedManager.tasks.isEmpty && rejectedManager.backendStartsForTesting == 0,
                    "SQL-rejected delegation inserted or executed work")
                try require(AgentAuditLog.shared.entries.filter { $0.kind == .task }.count == audits,
                    "SQL-rejected delegation recorded success audit")
                try require(try Data(contentsOf: route.file) == json && route.sql.probeAuthority()?.tasks.isEmpty == true,
                    "SQL-rejected delegation changed committed history")
                await Task.yield()
            }
        } catch { failures.append("actual submission fixture: \(error)") }
        failures += SelfTestStoreGuard.diff(before, SelfTestStoreGuard.take()).map { "owner changed: \($0)" }
        for failure in failures { SelfTest.diagnostic("TASK_AUTHORITY_WRONG: \(failure)") }
        return failures.isEmpty ? "TASK_AUTHORITY_OK: \(baseCount + count) cases" : "TASK_AUTHORITY_FAILED: \(failures.count) assertions"
    }
#endif
}

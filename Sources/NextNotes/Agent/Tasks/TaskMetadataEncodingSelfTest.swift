import Foundation
import SQLite3

/// Explicit row-domain ownership through the actual existing SQL writer/reader.
@MainActor
enum TaskMetadataEncodingSelfTest {
    private enum FixtureError: Error { case unsafe }
    static func run() -> (checks: Int, failures: [String]) {
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-voice-work-lifecycle" else {
            return (0, ["task metadata encoding: INVALID diagnostic required"])
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextNotesMetadata-" + UUID().uuidString, isDirectory: true)
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard root.resolvingSymlinksInPath().standardizedFileURL.deletingLastPathComponent().path == temp.path,
              !FileManager.default.fileExists(atPath: root.path) else {
            return (0, ["task metadata encoding: INVALID unsafe root"])
        }
        let owner = SelfTestStoreGuard.take()
        defer { try? FileManager.default.removeItem(at: root) }
        var count = 0; var failures: [String] = []
        func check(_ value: Bool, _ label: String) {
            count += 1; if !value { failures.append("task metadata encoding: " + label) }
        }
        func raw(_ sql: TaskStore) throws -> [String] {
            try sql.withConnection { try TaskStore.stringColumn($0,
                "SELECT quote(origin)||'|'||quote(user_words)||'|'||quote(started_at)||'|'||quote(finished_at)||'|'||quote(revision)||'|'||quote(delivery)||'|'||quote(delivery_attempts) FROM task") }
        }
        func neutral(_ task: AgentTask?) -> Bool {
            task != nil && task?.origin == nil && task?.userWords == nil && task?.startedAt == nil && task?.finishedAt == nil
        }
        func refused(_ operation: () throws -> Void) -> Bool {
            do { try operation(); return false } catch { return true }
        }
        func test(_ name: String, _ body: (TaskStore, AgentTask) throws -> Void) throws {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let sql = TaskStore(root: directory); defer { sql.close() }
            let row = AgentTask(id: UUID().uuidString, objective: "Owned encoding fixture", createdAt: Date(timeIntervalSince1970: 1000))
            try sql.replaceSnapshot([row]); try body(sql, row)
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            for (name, values) in [
                ("arbitrary", "origin='fixture-origin',user_words='fixture-request',started_at=1700000000,finished_at=1700000001"),
                ("prefix", "origin='metadata-v1:typed',user_words='metadata-v1:request',started_at='not-a-date',finished_at=X'0102'"),
                ("typed-looking", "origin='{\"kind\":\"typed\"}',user_words='Owned words',started_at=1000,finished_at=2000"),
                ("opaque", "origin=X'FF00',user_words=X'ABCD',started_at='later',finished_at=-1")
            ] {
                try test(name) { sql, row in
                    try sql.withConnection { try TaskStore.exec($0, "UPDATE task SET " + values + ",revision=7,delivery='pending',delivery_attempts=2") }
                    let retained = try raw(sql)
                    check(neutral(try sql.load().first), name + " neutral read")
                    try sql.replaceSnapshot([row])
                    check(try raw(sql) == retained, name + " neutral save exact reserved bytes")
                    var typed = row; typed.origin = .typed; typed.userWords = "Owned current words"
                    check(refused { try sql.replaceSnapshot([typed]) }, name + " activation refused")
                    let afterRaw = try raw(sql); let afterRows = try sql.load()
                    check(afterRaw == retained && afterRows == [row], name + " activation rollback")
                }
            }
            try test("owned") { sql, row in
                var typed = row; typed.origin = .typed; typed.userWords = "Owned words"
                typed.startedAt = Date(timeIntervalSince1970: 1000); typed.finishedAt = Date(timeIntervalSince1970: 2000)
                try sql.replaceSnapshot([typed])
                check(try sql.load() == [typed], "owned roundtrip")
                check(try sql.withConnection { try TaskStore.integer($0, "SELECT metadata_encoding_version FROM task") } == 1, "owned positive marker")
                try sql.withConnection { try TaskStore.exec($0, "UPDATE task SET delivery=X'ABCD',delivery_attempts='opaque',revision=X'FFFF'") }
                check(try sql.load() == [typed], "owned1 ignores unowned delivery and revision")
                try sql.replaceSnapshot([row])
                check(try sql.load() == [row], "owned metadata explicit clearing")
                check(try sql.withConnection { try TaskStore.integer($0, "SELECT metadata_encoding_version FROM task") } == 1,
                      "owned marker remains positive after clearing")
            }
            for (name, edit) in [("unknown-marker", "metadata_encoding_version=4"), ("text-marker", "metadata_encoding_version='future'"),
                                  ("bad-origin", "origin='broken'"), ("bad-date", "started_at='broken'")] {
                try test(name) { sql, row in
                    var typed = row; typed.origin = .typed; try sql.replaceSnapshot([typed])
                    try sql.withConnection { try TaskStore.exec($0, "UPDATE task SET " + edit) }
                    let bytes = try raw(sql)
                    check(refused { _ = try sql.load() }, name + " read refuses")
                    check(try raw(sql) == bytes, name + " refusal retains raw bytes")
                }
            }
            for version in 1...4 {
                try test("old\(version)") { sql, row in
                    try sql.withConnection { db in
                        try TaskStore.exec(db, "ALTER TABLE task DROP COLUMN metadata_encoding_version; UPDATE task SET origin='fixture-origin',user_words='fixture-request',started_at='opaque',delivery='pending',revision=7")
                        if version < 4 { try TaskStore.exec(db, "ALTER TABLE task_artifact DROP COLUMN encoding_version") }
                        if version < 3 { try TaskStore.exec(db, "ALTER TABLE task DROP COLUMN pending_interaction") }
                        if version == 1 { try TaskStore.exec(db, "DROP TABLE task_authority") }
                        try TaskStore.exec(db, "PRAGMA user_version=\(version)")
                    }
                    let bytes = try raw(sql)
                    check(try sql.load() == [row], "old\(version) read neutral")
                    check(try sql.withConnection { try TaskStore.integer($0, "PRAGMA user_version") } == Int64(version), "old\(version) read no upgrade")
                    try sql.replaceSnapshot([row])
                    check(try raw(sql) == bytes, "old\(version) migration exact reserved bytes")
                    check(try sql.withConnection { try TaskStore.integer($0, "PRAGMA user_version") } == (version == 1 ? 1 : 5), "old\(version) writer version")
                    if version == 1 {
                        var typed = row; typed.origin = .typed
                        check(refused { try sql.replaceSnapshot([typed]) }, "v1 typed write refuses unreadable domain")
                    }
                }
            }
            try test("actual-import") { sql, row in
                try sql.withConnection { db in
                    try TaskStore.exec(db, "ALTER TABLE task DROP COLUMN metadata_encoding_version; DROP TABLE task_authority; PRAGMA user_version=1; UPDATE task SET origin='fixture-origin',user_words='fixture-request',started_at='opaque',delivery='pending',revision=7")
                }
                let bytes = try raw(sql)
                let file = sql.fileURL.deletingLastPathComponent().appendingPathComponent("agent-tasks.json")
                let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                try encoder.encode([row]).write(to: file)
                let store = AgentTaskStore(fileURL: file, mirror: sql)
                guard store.allowsHarnessPersistence else { throw FixtureError.unsafe }
                check(try store.load() == [row], "actual legacy import neutral")
                check(try raw(sql) == bytes, "actual import exact opaque raw")
                let witness = try Data(contentsOf: file)
                let authority = try sql.probeAuthority()?.authority
                var typed = row; typed.origin = .typed; typed.userWords = "Owned current words"
                check(!store.save([typed]).primaryCommitted, "actual store activation refusal")
                let afterWitness = try Data(contentsOf: file)
                let afterAuthority = try sql.probeAuthority()?.authority
                let afterRaw = try raw(sql)
                check(afterWitness == witness && afterAuthority == authority && afterRaw == bytes,
                      "actual refusal witness authority and raw preserved")
                check(store.save([row]).primaryCommitted, "actual neutral save accepted")
                check(try raw(sql) == bytes, "actual neutral save retains opaque bytes")
            }
            for (name, declaration, value) in [("old-positive", "INTEGER NOT NULL DEFAULT 0", "1"),
                                               ("old-fractional", "INTEGER NOT NULL DEFAULT 0", "0.5"),
                                               ("old-text", "TEXT NOT NULL DEFAULT '0'", "'0'")] {
                try test(name) { sql, row in
                    try sql.withConnection { db in
                        try TaskStore.exec(db, "ALTER TABLE task DROP COLUMN metadata_encoding_version; ALTER TABLE task ADD COLUMN metadata_encoding_version " + declaration)
                        try TaskStore.exec(db, "UPDATE task SET metadata_encoding_version=" + value + "; PRAGMA user_version=4")
                    }
                    let bytes = try raw(sql)
                    check(try sql.load() == [row], name + " old read ignores extra marker")
                    check(refused { try sql.replaceSnapshot([row]) }, name + " migration refuses unknown domain")
                    let afterRaw = try raw(sql)
                    let afterVersion = try sql.withConnection { try TaskStore.integer($0, "PRAGMA user_version") }
                    check(afterRaw == bytes && afterVersion == 4,
                          name + " migration rollback")
                }
            }
            try test("rollback") { sql, row in
                try sql.withConnection { try TaskStore.exec($0, "ALTER TABLE task DROP COLUMN metadata_encoding_version; PRAGMA user_version=4; CREATE TRIGGER reject_fixture BEFORE UPDATE ON task BEGIN SELECT RAISE(ABORT,'fixture'); END") }
                let bytes = try raw(sql)
                check(refused { try sql.replaceSnapshot([row]) }, "migration primary write rejection")
                let columns = try sql.withConnection { try TaskStore.stringColumn($0, "PRAGMA table_info(task)", column: 1) }
                let version = try sql.withConnection { try TaskStore.integer($0, "PRAGMA user_version") }
                let afterRaw = try raw(sql)
                check(!columns.contains("metadata_encoding_version") && version == 4 && afterRaw == bytes,
                      "migration column version and raw rollback")
            }
            check(SelfTestStoreGuard.diff(owner, SelfTestStoreGuard.take()).isEmpty, "owner guard")
        } catch { failures.append("task metadata encoding: INVALID \(error)") }
        print("TASK_METADATA_ENCODING_TRACE: checks=\(count) problems=\(failures.count)")
        return (count, failures)
    }
}

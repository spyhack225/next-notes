import Foundation
import SQLite3

/// The existing reserved revision gains meaning only under positive owned marker3.
@MainActor
enum TaskRevisionEncodingSelfTest {
    private enum Invalid: Error { case unsafe }
    static func run(root: URL) throws -> (checks: Int, failures: [String]) {
        var checks = 0; var failures: [String] = []
        func check(_ value: Bool, _ label: String) { checks += 1; if !value { failures.append("revision encoding: " + label) } }
        func refused(_ operation: () throws -> Void) -> Bool { do { try operation(); return false } catch { return true } }
        func raw(_ sql: TaskStore) throws -> [String] {
            try sql.withConnection { try TaskStore.stringColumn($0,
                "SELECT quote(metadata_encoding_version)||'|'||quote(origin)||'|'||quote(user_words)||'|'||quote(started_at)||'|'||quote(finished_at)||'|'||quote(delivery)||'|'||quote(delivery_attempts)||'|'||quote(revision) FROM task") }
        }
        var index = 0
        func test(_ body: (TaskStore, AgentTask) throws -> Void) throws {
            index += 1
            let directory = root.appendingPathComponent("encoding-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let sql = TaskStore(root: directory); defer { sql.close() }
            let row = AgentTask(id: UUID().uuidString, objective: "Owned revision codec", createdAt: Date(timeIntervalSince1970: 1000))
            print("REVISION_ENCODING_CASE begin=\(index) checks=\(checks)")
            do {
                try sql.replaceSnapshot([row]); try body(sql, row)
                print("REVISION_ENCODING_CASE end=\(index) checks=\(checks)")
            } catch {
                print("REVISION_ENCODING_CASE invalid=\(index) checks=\(checks) error=\(error)")
                throw error
            }
        }
        for domain in 0...2 {
            for value in ["7", "'revision-v3:1'", "X'FF00'", "-2", "0.5"] {
                try test { sql, row in
                    var owned = row
                    if domain > 0 { owned.origin = .typed; owned.userWords = "Owned words" }
                    if domain == 2 {
                        // Delivery activation owns only an already-admitted metadata1 row.
                        try sql.replaceSnapshot([owned])
                        owned.delivery = .pending
                    }
                    try sql.replaceSnapshot([owned])
                    try sql.withConnection { try TaskStore.exec($0, "UPDATE task SET revision=" + value) }
                    let before = try raw(sql)
                    check(try sql.load() == [owned], "C01 prior\(domain) ignores opaque revision \(value)")
                    try sql.replaceSnapshot([owned])
                    check(try raw(sql) == before, "C02 prior\(domain) same save retains exact opaque revision \(value)")
                    var promoted = owned; promoted.revision = 1
                    check(refused { try sql.replaceSnapshot([promoted]) }, "C03 prior\(domain) nonneutral revision activation refuses \(value)")
                    let after = try raw(sql); let rows = try sql.load()
                    check(after == before && rows == [owned], "C04 refused activation retains complete raw domain \(value)")
                }
            }
        }
        try test { sql, row in
            var owned = row; owned.origin = .voice(sessionID: UUID(), turn: TurnID(raw: 1)); owned.userWords = "Owned current words"
            try sql.replaceSnapshot([owned])
            var revised = owned; revised.revision = 1
            try sql.replaceSnapshot([revised])
            let marker = try sql.withConnection { try TaskStore.integer($0, "SELECT metadata_encoding_version FROM task") }
            let actual = try sql.load()
            check(marker == 3 && actual == [revised], "C05 positive actual marker3 and revision roundtrip")
            let encoded = try JSONEncoder().encode(revised)
            let decoded = try JSONDecoder().decode(AgentTask.self, from: encoded)
            check(decoded == revised, "C06 owned revision JSON roundtrip")
            revised.revision = 2; try sql.replaceSnapshot([revised])
            let before = try raw(sql)
            check(refused { try sql.replaceSnapshot([owned]) }, "C07 owned current revision cannot silently downgrade")
            check(try raw(sql) == before, "C08 refused downgrade preserves owned bytes")
        }
        for edit in ["revision=-1", "revision='future'", "revision=X'FF00'", "revision=1.5", "metadata_encoding_version=4"] {
            try test { sql, row in
                var owned = row; owned.origin = .typed; owned.userWords = "Owned words"
                // Establish the same explicit metadata ownership before revision3.
                try sql.replaceSnapshot([owned])
                owned.revision = 1
                try sql.replaceSnapshot([owned]); try sql.withConnection { try TaskStore.exec($0, "UPDATE task SET " + edit) }
                let before = try raw(sql)
                check(refused { _ = try sql.load() }, "C09 owned malformed/future read refuses \(edit)")
                check(try raw(sql) == before, "C10 owned refusal retains damaged bytes \(edit)")
            }
        }
        try test { sql, row in
            var owned = row; owned.origin = .typed; owned.userWords = "Owned words"
            try sql.replaceSnapshot([owned])
            try sql.withConnection { try TaskStore.exec($0,
                "CREATE TRIGGER reject_revision_marker BEFORE UPDATE ON task WHEN NEW.metadata_encoding_version=3 BEGIN SELECT RAISE(ABORT,'owned revision marker refusal'); END") }
            let before = try raw(sql)
            owned.revision = 1
            check(refused { try sql.replaceSnapshot([owned]) }, "C11 actual marker activation trigger rejects")
            check(try raw(sql) == before, "C12 marker activation rolls back raw fields")
        }
        return (checks, failures)
    }
}

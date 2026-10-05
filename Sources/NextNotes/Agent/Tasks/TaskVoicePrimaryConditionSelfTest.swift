import Foundation
import SQLite3

/// SAME existing SQL/export writer and row predicate; no worker, model or task is seeded
/// into an owner store. This is a standalone persistence prerequisite, not voice recovery.
@MainActor
enum TaskVoicePrimaryConditionSelfTest {
    private enum Invalid: Error { case unsafe }
    static func run() -> (checks: Int, failures: [String]) {
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-voice-work-lifecycle",
              AgentSession.shared.fileURL == nil else { return (0, ["voice primary: INVALID scope"]) }
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let root = temp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard root.path == root.resolvingSymlinksInPath().standardizedFileURL.path,
              root.deletingLastPathComponent().path == temp.path,
              !FileManager.default.fileExists(atPath: root.path) else { return (0, ["voice primary: INVALID root"]) }
        var checks = 0; var failures: [String] = []; var created = false
        let owner = SelfTestStoreGuard.take()
        func check(_ value: Bool, _ label: String) {
            checks += 1; if !value { failures.append("voice primary: " + label) }
        }
        defer { if created { try? FileManager.default.removeItem(at: root) } }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false); created = true
            for mode in ["current-zero", "current-positive", "wrong-session", "wrong-turn", "wrong-revision",
                         "primary-state", "primary-source", "primary-origin", "primary-revision",
                         "opaque-origin", "partial-condition", "SQL-rejected"] {
                let beforeChecks = checks
                let dir = root.appendingPathComponent(mode, isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
                let sql = TaskStore(root: dir); defer { sql.close() }
                let file = dir.appendingPathComponent("agent-tasks.json")
                let store = AgentTaskStore(fileURL: file, mirror: sql)
                guard store.allowsHarnessPersistence, store.save([]).primaryCommitted else { throw Invalid.unsafe }
                let session = UUID(); let id = UUID().uuidString
                let origin = TaskOrigin.voice(sessionID: session, turn: TurnID(raw: 17))
                let revision = mode == "current-positive" ? 2 : 0
                let row = AgentTask(id: id, objective: "Owned public progress", source: "voice",
                    status: .running, progress: "Working locally", origin: origin, revision: revision)
                guard store.save([row]).primaryCommitted else { throw Invalid.unsafe }
                var condition = TaskWorkerWriteCondition(taskID: id, attempt: 0, leaseOwner: nil,
                    status: .running, voiceOrigin: origin, voiceRevision: revision)
                if mode == "wrong-session" { condition.voiceOrigin = .voice(sessionID: UUID(), turn: TurnID(raw: 17)) }
                if mode == "wrong-turn" { condition.voiceOrigin = .voice(sessionID: session, turn: TurnID(raw: 18)) }
                if mode == "wrong-revision" { condition.voiceRevision = revision + 1 }
                if mode == "partial-condition" { condition.voiceOrigin = nil }
                try sql.withConnection { db in
                    if mode == "primary-state" { try TaskStore.run(db, "UPDATE task SET state='recovering' WHERE id=?", [.text(id)]) }
                    if mode == "primary-source" { try TaskStore.run(db, "UPDATE task SET source='typed' WHERE id=?", [.text(id)]) }
                    if mode == "primary-origin" {
                        let data = try JSONEncoder().encode(TaskOrigin.voice(sessionID: UUID(), turn: TurnID(raw: 17)))
                        try TaskStore.run(db, "UPDATE task SET origin=? WHERE id=?", [.text(String(decoding: data, as: UTF8.self)), .text(id)])
                    }
                    if mode == "primary-revision" { try TaskStore.run(db, "UPDATE task SET metadata_encoding_version=3,revision=1 WHERE id=?", [.text(id)]) }
                    if mode == "opaque-origin" { try TaskStore.run(db, "UPDATE task SET metadata_encoding_version=0,origin='retained unowned bytes' WHERE id=?", [.text(id)]) }
                    if mode == "SQL-rejected" {
                        try TaskStore.exec(db, "CREATE TRIGGER refuse_owned_progress BEFORE UPDATE ON task BEGIN SELECT RAISE(ABORT,'fixture primary refusal'); END")
                    }
                }
                let before = try sql.load(); let journal = try sql.journal(taskID: id)
                let bytes = try Data(contentsOf: file); let authority = try sql.probeAuthority(includeTasks: false)?.authority
                check(before.count == 1 && before[0].id == id && row.durability == nil,
                    "C01 genuine marked nil-durability primary did not qualify (\(mode))")
                var next = row; next.progress = "Step 1: Reading a file…"
                let result = store.save([next], worker: condition)
                if mode.hasPrefix("current-") {
                    let savedRows = try sql.load()
                    check(result.primaryCommitted && savedRows.first?.progress == next.progress,
                        "F01 exact owned current voice primary condition refused (\(mode))")
                    // Original rejects every nil-durability condition; it must still preserve history.
                    check(try result.primaryCommitted || (sql.load() == before && Data(contentsOf: file) == bytes),
                        "C02 refused prerequisite mutated retained rows/export (\(mode))")
                } else {
                    check(try !result.primaryCommitted && sql.load() == before && Data(contentsOf: file) == bytes,
                        "C03 mismatched/refused exact primary lost rows/export (\(mode))")
                    check(try sql.journal(taskID: id) == journal
                        && sql.probeAuthority(includeTasks: false)?.authority == authority,
                        "C04 mismatched/refused condition changed journal/generation (\(mode))")
                }
                print("VOICE_PRIMARY_CONDITION_CASE mode=\(mode) checks=\(checks-beforeChecks) committed=\(result.primaryCommitted)")
            }
            check(SelfTestStoreGuard.diff(owner, SelfTestStoreGuard.take()).isEmpty, "C05 owner state changed")
        } catch { failures.append("voice primary: INVALID \(error)") }
        return (checks, failures)
    }
}

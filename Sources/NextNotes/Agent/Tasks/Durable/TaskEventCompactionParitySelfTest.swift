import Foundation
import SQLite3

/// SAME existing ledger/SQLite seam; compares actual producer with retained old SQL
/// on identical safe inputs, then checks independent expected retention semantics.
@MainActor
enum TaskEventCompactionParitySelfTest {
    private enum InputError: Error { case unsafe }
    private struct Input {
        let name: String
        let state: AgentTaskStatus
        let durability: String?
        let events: [(TaskEventKind, TaskStore.SQLValue)]
        let expected: Int
        var orphan = false
    }
    private static let oldSQL = #"""
            DELETE FROM task_event WHERE task_id IN (
              SELECT t.id FROM task t JOIN task_event last ON last.seq=(
                SELECT e.seq FROM task_event e WHERE e.task_id=t.id
                  AND e.kind IN ('jobCompleted','jobFailed','jobCancelled') ORDER BY e.seq DESC LIMIT 1
              ) WHERE t.state IN ('completed','failed','cancelled') AND typeof(last.at)='integer' AND last.at<?
                AND (t.durability IS NULL OR (json_valid(t.durability)
                  AND (json_type(t.durability,'$.receiptIDs') IS NULL
                    OR (json_type(t.durability,'$.receiptIDs')='array'
                      AND json_array_length(t.durability,'$.receiptIDs')=0))))
            )
    """#
    private static func events(_ db: OpaquePointer) throws -> [String] {
        try TaskStore.stringColumn(db, "SELECT seq||'|'||task_id||'|'||kind||'|'||typeof(at)||'|'||quote(at) FROM task_event ORDER BY seq")
    }
    private static func tasks(_ db: OpaquePointer) throws -> [String] {
        try TaskStore.stringColumn(db, "SELECT id||'|'||state||'|'||quote(durability)||'|'||objective||'|'||sort_order FROM task ORDER BY id")
    }
    static func originalCases(root: URL, check: (Bool, String) -> Void) throws {
        let safe = root.standardizedFileURL.resolvingSymlinksInPath()
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard SelfTest.isRunning, safe.path.hasPrefix(temporary.path + "/"),
              !safe.pathComponents.contains("Application Support") else { throw InputError.unsafe }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let old = Int64(now.addingTimeInterval(-31 * 86_400).timeIntervalSince1970)
        let recent = Int64(now.addingTimeInterval(-86_400).timeIntervalSince1970)
        let cutoff = now.addingTimeInterval(-Double(TaskEventJournal.terminalRetentionDays * 86_400)).timeIntervalSince1970
        let inputs = [
            Input(name: "nil-durability", state: .completed, durability: nil, events: [(.jobCompleted, .integer(old))], expected: 0),
            Input(name: "latest-seq-not-max-date", state: .completed, durability: nil, events: [(.jobCompleted, .integer(recent)), (.jobCompleted, .integer(old))], expected: 0),
            Input(name: "latest-seq-recent", state: .cancelled, durability: nil, events: [(.jobCancelled, .integer(old)), (.jobCancelled, .integer(recent))], expected: 2),
            Input(name: "noninteger-age", state: .failed, durability: nil, events: [(.jobFailed, .real(1.5))], expected: 1),
            Input(name: "unknown-age", state: .failed, durability: nil, events: [(.jobFailed, .text("owned-unknown-time"))], expected: 1),
            Input(name: "running-state", state: .running, durability: nil, events: [(.jobFailed, .integer(old))], expected: 1),
            Input(name: "missing-receipt-field", state: .completed, durability: "{}", events: [(.jobCompleted, .integer(old))], expected: 0),
            Input(name: "malformed-durability", state: .completed, durability: "{owned-invalid", events: [(.jobCompleted, .integer(old))], expected: 1),
            Input(name: "receipt-bound", state: .completed, durability: #"{"receiptIDs":["owned-receipt"]}"#, events: [(.jobCompleted, .integer(old))], expected: 1),
            Input(name: "receipt-shape-unknown", state: .completed, durability: #"{"receiptIDs":"owned-unknown"}"#, events: [(.jobCompleted, .integer(old))], expected: 1),
            Input(name: "receipt-null", state: .completed, durability: #"{"receiptIDs":null}"#, events: [(.jobCompleted, .integer(old))], expected: 1),
            Input(name: "latest-age-unknown", state: .completed, durability: nil, events: [(.jobCompleted, .integer(old)), (.jobCompleted, .text("owned-unknown-time"))], expected: 2),
            Input(name: "orphan-event", state: .completed, durability: nil, events: [(.jobCompleted, .integer(old))], expected: 1, orphan: true),
            Input(name: "no-terminal-event", state: .completed, durability: nil, events: [(.jobCreated, .integer(old))], expected: 1),
            Input(name: "empty-receipts", state: .completed, durability: #"{"receiptIDs":[]}"#, events: [(.jobCompleted, .integer(old))], expected: 0)
        ]
        var checks = 0
        for input in inputs {
            let directory = safe.appendingPathComponent("event-compaction-" + input.name, isDirectory: true)
            let sql = TaskStore(root: directory)
            defer { sql.close() }
            let taskID = "owned-compaction-task"
            let task = AgentTask(id: taskID, objective: "Owned compaction semantics", source: "selftest",
                createdAt: now, status: input.state, artifacts: ["fixture://owned-retained-artifact"])
            try sql.replaceSnapshot([task], now: now)
            try sql.withConnection { db in
                try TaskStore.run(db, "UPDATE task SET durability=? WHERE id=?", [.optionalText(input.durability), .text(taskID)])
                if input.orphan { try TaskStore.exec(db, "PRAGMA foreign_keys=OFF") }
                for event in input.events {
                    try TaskStore.run(db, "INSERT INTO task_event(task_id,at,kind,attempt) VALUES(?,?,?,0)",
                        [.text(input.orphan ? "owned-missing-task" : taskID), event.1, .text(event.0.rawValue)])
                }
                if input.orphan { try TaskStore.exec(db, "PRAGMA foreign_keys=ON") }
                let beforeTasks = try tasks(db)
                let beforeArtifacts = try TaskStore.integer(db, "SELECT count(*) FROM task_artifact")
                let beforeSequence = try TaskStore.integer(db, "SELECT seq FROM sqlite_sequence WHERE name='task_event'")
                // Same actual DB and raw rows; rollback reference DELETE before calling
                // current production compact. No second ledger or alternate decoder.
                try TaskStore.exec(db, "SAVEPOINT owned_old_compaction")
                let retainedOld: [String]
                do {
                    try TaskStore.run(db, oldSQL, [.real(cutoff)])
                    retainedOld = try events(db)
                    try TaskStore.exec(db, "ROLLBACK TO owned_old_compaction; RELEASE owned_old_compaction")
                } catch {
                    try? TaskStore.exec(db, "ROLLBACK TO owned_old_compaction; RELEASE owned_old_compaction")
                    throw error
                }
                try TaskEventJournal.compact(in: db, now: now)
                let retainedActual = try events(db)
                check(retainedActual == retainedOld,
                    "event compaction: actual producer differs from retained old SQL (\(input.name))"); checks += 1
                check(retainedOld.count == input.expected && retainedActual.count == input.expected,
                    "event compaction: latest-seq/unknown-age/state/receipt/orphan semantics changed (\(input.name))"); checks += 1
                check(try tasks(db) == beforeTasks
                    && TaskStore.integer(db, "SELECT count(*) FROM task_artifact") == beforeArtifacts
                    && TaskStore.integer(db, "SELECT seq FROM sqlite_sequence WHERE name='task_event'") == beforeSequence,
                    "event compaction: primary/child rows or sequence owner changed (\(input.name))"); checks += 1
            }
        }
        SelfTest.diagnostic("EVENT_COMPACTION_PARITY_TRACE: modes=\(inputs.count) checks=\(checks) expectedChecks=45")
    }
}

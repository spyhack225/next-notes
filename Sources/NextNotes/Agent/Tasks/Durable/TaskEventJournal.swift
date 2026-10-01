import Foundation
import SQLite3

enum TaskEventKind: String, Codable, Sendable {
    case jobCreated, workerStarted, toolStarted, toolCompleted
    case permissionRequested, permissionApproved, permissionDenied
    case inputRequested, inputProvided
    case artifactCaptured, heartbeat, retryScheduled, workerRecovered
    case jobCompleted, jobFailed, jobCancelled
    case revisionRecorded, dependencySatisfied, staleAttemptDropped, outcomeResolved
}

/// A fact supplied by its producer, never a reconstruction from Activity or a reply.
struct TaskJournalEventDraft: Sendable, Equatable {
    let taskID: String
    let kind: TaskEventKind
    var at: Date = Date()
    var detail: String? = nil
    // Zero is unbound until the actual attempt/lease producer exists.
    var attempt: Int = 0
}

struct TaskJournalEvent: Sendable, Equatable {
    let seq: Int64
    let draft: TaskJournalEventDraft
}

/// Ephemeral execution context binds facts to the one manager/store owning this task.
/// It neither stores events nor routes unscoped calls to the shared owner's ledger.
struct TaskJournalContext: Sendable {
    let taskID: String
    let attempt: Int
    let record: @MainActor @Sendable (TaskJournalEventDraft) -> Void
}

enum TaskEventJournal {
    static let terminalRetentionDays = 30
    @TaskLocal static var current: TaskJournalContext?

    @MainActor
    static func toolStarted(taskID: String?, tool: String) -> TaskJournalContext? {
        guard let context = current, taskID == context.taskID else { return nil }
        context.record(TaskJournalEventDraft(taskID: context.taskID, kind: .toolStarted,
            detail: tool, attempt: context.attempt))
        return context
    }

    @MainActor
    static func toolCompleted(_ context: TaskJournalContext?, tool: String, succeeded: Bool) {
        guard let context else { return }
        context.record(TaskJournalEventDraft(taskID: context.taskID, kind: .toolCompleted,
            detail: "\(tool):\(succeeded ? "returned" : "threw")", attempt: context.attempt))
    }

    static func append(_ events: [TaskJournalEventDraft], to db: OpaquePointer) throws {
        for event in events {
            let time = event.at.timeIntervalSince1970
            guard time.isFinite, time > Double(Int64.min), time < Double(Int64.max), event.attempt >= 0 else {
                throw TaskStoreError.invalidRecord
            }
            try TaskStore.run(db, "INSERT INTO task_event(task_id,at,kind,detail,attempt) VALUES(?,?,?,?,?)",
                [.text(event.taskID), .integer(Int64(time)), .text(event.kind.rawValue),
                 .optionalText(event.detail), .integer(Int64(event.attempt))])
        }
    }

    /// Compaction removes journal rows only. Unknown ages and receipt-linked rows stay.
    static func compact(in db: OpaquePointer, now: Date) throws {
        let cutoff = now.addingTimeInterval(-Double(terminalRetentionDays * 86_400)).timeIntervalSince1970
        guard cutoff.isFinite else { throw TaskStoreError.invalidRecord }
        // A single indexed SQL operation; no synchronous per-history-row Swift scan.
        // Malformed/unknown receipt shapes are conservatively retained.
        try TaskStore.run(db, """
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
            """, [.real(cutoff)])
    }

    static func load(from db: OpaquePointer, taskID: String) throws -> [TaskJournalEvent] {
        let statement = try TaskStore.prepare(db,
            "SELECT seq,at,kind,detail,attempt FROM task_event WHERE task_id=? ORDER BY seq")
        defer { sqlite3_finalize(statement) }
        try TaskStore.bind(statement, [.text(taskID)])
        var result: [TaskJournalEvent] = []
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            let seq = sqlite3_column_int64(statement, 0)
            let at = sqlite3_column_int64(statement, 1)
            let attempt = sqlite3_column_int64(statement, 4)
            guard sqlite3_column_type(statement, 0) == SQLITE_INTEGER, seq > 0,
                  sqlite3_column_type(statement, 1) == SQLITE_INTEGER,
                  Double(at) > Double(Int64.min), Double(at) < Double(Int64.max),
                  sqlite3_column_type(statement, 4) == SQLITE_INTEGER, attempt >= 0,
                  let text = try TaskStore.text(statement, 2), let kind = TaskEventKind(rawValue: text) else {
                throw TaskStoreError.invalidRecord
            }
            result.append(TaskJournalEvent(seq: seq,
                draft: TaskJournalEventDraft(taskID: taskID, kind: kind,
                    at: Date(timeIntervalSince1970: Double(at)),
                    detail: try TaskStore.text(statement, 3), attempt: Int(attempt))))
            code = sqlite3_step(statement)
        }
        guard code == SQLITE_DONE else { throw TaskStoreError.sqlite(code) }
        return result
    }
}

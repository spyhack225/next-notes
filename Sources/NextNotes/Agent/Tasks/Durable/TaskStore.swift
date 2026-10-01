import Foundation
import SQLite3

enum TaskStoreError: LocalizedError {
    case sqlite(Int32)
    case unsupportedVersion(Int64)
    case foreignKeysOff
    case invalidRecord
    case fileRemoved

    var errorDescription: String? {
        switch self {
        case .sqlite(let code): "Task storage failed (SQLite \(code))."
        case .unsupportedVersion(let version): "Task storage has an unsupported schema version (\(version))."
        case .foreignKeysOff: "Task storage could not enable foreign keys."
        case .invalidRecord: "Task storage encountered an invalid record."
        case .fileRemoved: "Task storage was removed while it was open."
        }
    }
}

/// The planned durable ledger, mirrored behind JSON until P6-04a. No recovery or retries.
/// Unlike the derived indexes, an unreadable/newer database is never deleted or rebuilt.
final class TaskStore: @unchecked Sendable {
    static let fileName = "agent-tasks.sqlite"
    let fileURL: URL
    private let lock = NSLock()
    private var db: OpaquePointer?
    private var openedInode: UInt64?

    init(root: URL) {
        fileURL = root.appendingPathComponent(Self.fileName)
    }

    static func isolated() -> TaskStore {
        TaskStore(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("NextNotesTaskStore-\(UUID().uuidString)", isDirectory: true))
    }

    deinit { if let db { sqlite3_close_v2(db) } }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        closeLocked()
    }

    func withConnection<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(openLocked())
    }

    private func openLocked(busyMilliseconds: Int32 = 2_000) throws -> OpaquePointer {
        if let db {
            if let inode = openedInode, Self.inode(fileURL) == inode { return db }
            closeLocked()
            // Do not silently replace missing authoritative history with an empty ledger.
            guard FileManager.default.fileExists(atPath: fileURL.path) else { throw TaskStoreError.fileRemoved }
        }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let opened = sqlite3_open_v2(fileURL.path, &handle, flags, nil)
        guard opened == SQLITE_OK, let handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw TaskStoreError.sqlite(opened)
        }
        do {
            sqlite3_busy_timeout(handle, busyMilliseconds)
            try Self.exec(handle, "PRAGMA foreign_keys = ON")
            guard try Self.integer(handle, "PRAGMA foreign_keys") == 1 else { throw TaskStoreError.foreignKeysOff }
            // Reject unsupported/corrupt files before changing their persistent journal mode.
            let version = try Self.integer(handle, "PRAGMA user_version")
            guard version == 0 || version == TaskStoreSchema.version else { throw TaskStoreError.unsupportedVersion(version) }
            try TaskStoreSchema.install(on: handle)
            try Self.exec(handle, "PRAGMA journal_mode = WAL")
            guard try Self.stringColumn(handle, "PRAGMA journal_mode") == ["wal"] else {
                throw TaskStoreError.invalidRecord
            }
            try Self.exec(handle, "PRAGMA synchronous = NORMAL")
        } catch {
            sqlite3_close_v2(handle)
            throw error
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        db = handle
        openedInode = Self.inode(fileURL)
        return handle
    }

    private func closeLocked() {
        if let db { sqlite3_close_v2(db) }
        db = nil
        openedInode = nil
    }

    private static func inode(_ url: URL) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    /// One transaction replaces the canonical JSON snapshot's current rows. UPSERT updates
    /// retained identities without deleting their event/dependency rows. No second owner.
    func replaceSnapshot(_ tasks: [AgentTask], failFast: Bool = false) throws {
        guard Set(tasks.map(\.id)).count == tasks.count,
              tasks.allSatisfy({ $0.createdAt.timeIntervalSince1970.isFinite }) else {
            throw TaskStoreError.invalidRecord
        }
        if failFast {
            guard lock.try() else { throw TaskStoreError.sqlite(SQLITE_BUSY) }
        } else {
            lock.lock()
        }
        defer { lock.unlock() }
        let db = try openLocked(busyMilliseconds: failFast ? 0 : 2_000)
        if failFast { sqlite3_busy_timeout(db, 0) }
        defer { if failFast { sqlite3_busy_timeout(db, 2_000) } }
            try Self.transaction(db) {
                let oldIDs = try Self.stringColumn(db, "SELECT id FROM task")
                let incoming = Set(tasks.map(\.id))
                for id in oldIDs where !incoming.contains(id) {
                    try Self.run(db, "DELETE FROM task WHERE id = ?", [.text(id)])
                }
                for (position, task) in tasks.enumerated() {
                    let values: [SQLValue] = [
                        .text(task.id), .text(task.status.rawValue), .text(task.source), .text(task.backend),
                        .text(task.objective), .text(task.progress), .text(try Self.json(task.contextReferences)),
                        .optionalText(task.tool), .text(try Self.json(task.arguments)),
                        .optionalText(task.meetingID?.uuidString), .text(task.acpCLI),
                        .optionalText(task.compatibilityCommand), .optionalText(task.compatibilityCLI),
                        .optionalText(task.compatibilityDirectory), .optionalText(task.scheduleID?.uuidString),
                        .integer(Int64(position)), .real(task.createdAt.timeIntervalSince1970),
                        .optionalText(task.result), .optionalText(task.failure),
                        .optionalText(try task.durability.map(Self.json))
                    ]
                    try Self.run(db, Self.upsert, values)
                    for (ordinal, path) in task.artifacts.enumerated() {
                        // Legacy links have neutral metadata until P6-02b's real producers.
                        // Retain existing metadata only when this ordinal still names that path.
                        try Self.run(db, """
                            INSERT INTO task_artifact(task_id,path,ordinal,added_at) VALUES(?,?,?,CAST(? AS INTEGER))
                            ON CONFLICT(task_id,ordinal) DO UPDATE SET
                              kind=CASE WHEN path=excluded.path THEN kind ELSE 'link' END,
                              title=CASE WHEN path=excluded.path THEN title ELSE NULL END,
                              path=excluded.path
                            """, [.text(task.id), .text(path), .integer(Int64(ordinal)), .real(task.createdAt.timeIntervalSince1970)])
                    }
                    try Self.run(db, "DELETE FROM task_artifact WHERE task_id=? AND ordinal>=?",
                        [.text(task.id), .integer(Int64(task.artifacts.count))])
                }
            }
    }

    /// Diagnostics and later migration use this; AgentTaskManager still reads only JSON.
    func load() throws -> [AgentTask] {
        try withConnection { db in
            let statement = try Self.prepare(db, "SELECT \(Self.columns) FROM task ORDER BY sort_order,id")
            defer { sqlite3_finalize(statement) }
            var tasks: [AgentTask] = []
            var code = sqlite3_step(statement)
            while code == SQLITE_ROW {
                func required(_ column: Int32) throws -> String {
                    guard let value = try Self.text(statement, column) else { throw TaskStoreError.invalidRecord }
                    return value
                }
                guard let status = AgentTaskStatus(rawValue: try required(1)) else { throw TaskStoreError.invalidRecord }
                let id = try required(0)
                let artifacts = try Self.stringColumn(db,
                    "SELECT path FROM task_artifact WHERE task_id=? ORDER BY ordinal", [.text(id)])
                let task = AgentTask(id: id, objective: try required(4), source: try required(2),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 16)),
                    contextReferences: try Self.decode([String].self, required(6)), status: status,
                    progress: try required(5), result: try Self.text(statement, 17), artifacts: artifacts,
                    tool: try Self.text(statement, 7), arguments: try Self.decode([String: String].self, required(8)),
                    meetingID: try Self.uuid(Self.text(statement, 9)), backend: try required(3),
                    failure: try Self.text(statement, 18), acpCLI: try required(10),
                    compatibilityCommand: try Self.text(statement, 11), compatibilityCLI: try Self.text(statement, 12),
                    compatibilityDirectory: try Self.text(statement, 13), scheduleID: try Self.uuid(Self.text(statement, 14)),
                    durability: try Self.text(statement, 19).map { try Self.decode(TaskDurability.self, $0) })
                tasks.append(task)
                code = sqlite3_step(statement)
            }
            guard code == SQLITE_DONE else { throw TaskStoreError.sqlite(code) }
            return tasks
        }
    }

    func integrityProblems() throws -> [String] {
        try withConnection { db in
            var problems: [String] = []
            for sql in ["PRAGMA integrity_check", "PRAGMA foreign_key_check"] {
                let statement = try Self.prepare(db, sql)
                defer { sqlite3_finalize(statement) }
                var code = sqlite3_step(statement)
                while code == SQLITE_ROW {
                    let value = try Self.text(statement, 0) ?? "invalid"
                    if sql.contains("foreign_key") || value != "ok" { problems.append(value) }
                    code = sqlite3_step(statement)
                }
                guard code == SQLITE_DONE else { throw TaskStoreError.sqlite(code) }
            }
            return problems
        }
    }

    static let columns = """
        id,state,source,backend,objective,progress,context_references,tool,arguments,
        meeting_id,acp_cli,compatibility_command,compatibility_cli,compatibility_directory,
        schedule_id,sort_order,created_at,result,failure,durability
        """
    private static let upsert = """
        INSERT INTO task(\(columns)) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
          state=excluded.state,source=excluded.source,backend=excluded.backend,
          objective=excluded.objective,progress=excluded.progress,
          context_references=excluded.context_references,tool=excluded.tool,arguments=excluded.arguments,
          meeting_id=excluded.meeting_id,acp_cli=excluded.acp_cli,
          compatibility_command=excluded.compatibility_command,compatibility_cli=excluded.compatibility_cli,
          compatibility_directory=excluded.compatibility_directory,schedule_id=excluded.schedule_id,
          sort_order=excluded.sort_order,created_at=excluded.created_at,result=excluded.result,
          failure=excluded.failure,durability=excluded.durability
        """

    private static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(type, from: Data(text.utf8))
    }

    private static func uuid(_ text: String?) throws -> UUID? {
        guard let text else { return nil }
        guard let id = UUID(uuidString: text) else { throw TaskStoreError.invalidRecord }
        return id
    }

    enum SQLValue { case integer(Int64), real(Double), text(String), optionalText(String?) }
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else { throw TaskStoreError.sqlite(code) }
        return statement
    }

    static func bind(_ statement: OpaquePointer, _ values: [SQLValue]) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch value {
            case .integer(let value): code = sqlite3_bind_int64(statement, index, value)
            case .real(let value): code = sqlite3_bind_double(statement, index, value)
            case .optionalText(nil): code = sqlite3_bind_null(statement, index)
            case .text(let value), .optionalText(.some(let value)):
                guard value.utf8.count <= Int(Int32.max) else { throw TaskStoreError.invalidRecord }
                code = value.withCString { sqlite3_bind_text(statement, index, $0, Int32(value.utf8.count), transient) }
            }
            guard code == SQLITE_OK else { throw TaskStoreError.sqlite(code) }
        }
    }

    static func exec(_ db: OpaquePointer, _ sql: String) throws {
        let code = sqlite3_exec(db, sql, nil, nil, nil)
        guard code == SQLITE_OK else { throw TaskStoreError.sqlite(code) }
    }

    static func run(_ db: OpaquePointer, _ sql: String, _ values: [SQLValue] = []) throws {
        let statement = try prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        try bind(statement, values)
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE else { throw TaskStoreError.sqlite(code) }
    }

    static func integer(_ db: OpaquePointer, _ sql: String) throws -> Int64 {
        let statement = try prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        guard code == SQLITE_ROW else { throw TaskStoreError.sqlite(code) }
        return sqlite3_column_int64(statement, 0)
    }

    static func stringColumn(_ db: OpaquePointer, _ sql: String, _ values: [SQLValue] = [],
                             column: Int32 = 0) throws -> [String] {
        let statement = try prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        try bind(statement, values)
        var result: [String] = []
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            guard let value = try text(statement, column) else { throw TaskStoreError.invalidRecord }
            result.append(value)
            code = sqlite3_step(statement)
        }
        guard code == SQLITE_DONE else { throw TaskStoreError.sqlite(code) }
        return result
    }

    static func text(_ statement: OpaquePointer, _ column: Int32) throws -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        if count == 0 { return "" }
        guard let raw = sqlite3_column_text(statement, column),
              let value = String(bytes: UnsafeBufferPointer(start: raw, count: count), encoding: .utf8) else {
            throw TaskStoreError.invalidRecord
        }
        return value
    }

    static func transaction<T>(_ db: OpaquePointer, _ body: () throws -> T) throws -> T {
        try exec(db, "BEGIN IMMEDIATE")
        do {
            let value = try body()
            try exec(db, "COMMIT")
            return value
        } catch {
            try? exec(db, "ROLLBACK")
            throw error
        }
    }
}

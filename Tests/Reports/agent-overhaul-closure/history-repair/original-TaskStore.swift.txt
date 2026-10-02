import Foundation
import SQLite3
import Darwin

struct TaskStoreAuthority: Codable, Equatable, Sendable {
    let databaseID: UUID
    let generation: Int64
}

struct TaskStoreFileIdentity: Codable, Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
}

struct TaskStoreAuthorityProbe: Sendable {
    let identity: TaskStoreFileIdentity
    let authority: TaskStoreAuthority?
    let tasks: [AgentTask]
}

enum TaskStoreError: LocalizedError {
    case sqlite(Int32)
    case unsupportedVersion(Int64)
    case foreignKeysOff
    case invalidRecord
    case fileRemoved
    case authorityConflict

    var errorDescription: String? {
        switch self {
        case .sqlite(let code): "Task storage failed (SQLite \(code))."
        case .unsupportedVersion(let version): "Task storage has an unsupported schema version (\(version))."
        case .foreignKeysOff: "Task storage could not enable foreign keys."
        case .invalidRecord: "Task storage encountered an invalid record."
        case .fileRemoved: "Task storage was removed while it was open."
        case .authorityConflict: "Task history changed or its saved copies disagree. The original files were kept."
        }
    }
}

/// The existing task ledger. P6-04a authority uses guarded, noncreating operations;
/// generic creator APIs remain for diagnostics/fixtures. No recovery or retries.
/// Unlike derived indexes, an unreadable/newer database is never deleted or rebuilt.
final class TaskStore: @unchecked Sendable {
    static let fileName = "agent-tasks.sqlite"
    let fileURL: URL
    private let lock = NSLock()
    private var db: OpaquePointer?
    private var openedInode: UInt64?
    var authorityBoundaryForTesting: ((String, OpaquePointer?) throws -> Void)?

    private func boundary(_ name: String, db: OpaquePointer?) throws {
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"
        if SelfTest.isRunning, fileURL.resolvingSymlinksInPath().path.hasPrefix(temporary) {
            try authorityBoundaryForTesting?(name, db)
        }
    }

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
            guard (0...TaskStoreSchema.version).contains(version) else { throw TaskStoreError.unsupportedVersion(version) }
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

    static func validate(_ tasks: [AgentTask]) throws {
        guard Set(tasks.map(\.id)).count == tasks.count, tasks.allSatisfy({ task in
            guard !task.id.isEmpty, task.createdAt.timeIntervalSince1970.isFinite else { return false }
            switch task.pendingInteraction {
            case .permission(let request, _, let review):
                guard !request.id.isEmpty, !request.toolID.isEmpty,
                      request.taskID == task.id, request.toolID == task.tool,
                      request.createdAt.timeIntervalSince1970.isFinite,
                      review == nil || (review?.id == request.id && review?.toolID == request.toolID) else { return false }
            case .input(let request):
                guard !request.id.isEmpty, request.taskID == task.id,
                      !request.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      request.createdAt.timeIntervalSince1970.isFinite else { return false }
            case nil: break
            }
            guard let d = task.durability else { return true }
            return d.attempt >= 0 && d.retryCount >= 0 && d.maxRetries >= 0
                && [d.heartbeatAt, d.lastProgressAt, d.attemptStartedAt].compactMap { $0 }
                    .allSatisfy { $0.timeIntervalSince1970.isFinite }
        }) else { throw TaskStoreError.invalidRecord }
    }

    /// ENOENT alone is absence. Permission errors and orphan journal files are not fresh.
    private func fileIdentity() throws -> TaskStoreFileIdentity? {
        var value = stat()
        if fstatat(AT_FDCWD, fileURL.path, &value, 0) == 0 {
            guard (value.st_mode & S_IFMT) == S_IFREG else { throw TaskStoreError.invalidRecord }
            return TaskStoreFileIdentity(device: UInt64(value.st_dev), inode: UInt64(value.st_ino))
        }
        guard errno == ENOENT else { throw TaskStoreError.fileRemoved }
        for suffix in ["-wal", "-shm"] {
            var sibling = stat()
            if fstatat(AT_FDCWD, fileURL.path + suffix, &sibling, 0) == 0 || errno != ENOENT {
                throw TaskStoreError.authorityConflict
            }
        }
        return nil
    }

    /// Each authority operation uses an existing-only handle. It cannot recreate a DB
    /// removed after the probe. Read-only SQLite sees committed WAL (never immutable).
    private func existing<T>(identity: TaskStoreFileIdentity, writable: Bool,
                             body: (OpaquePointer) throws -> T) throws -> T {
        guard try fileIdentity() == identity else { throw TaskStoreError.authorityConflict }
        try boundary("beforeExistingOpen", db: nil)
        var handle: OpaquePointer?
        let flags = (writable ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY) | SQLITE_OPEN_FULLMUTEX
        let code = sqlite3_open_v2(fileURL.path, &handle, flags, nil)
        guard code == SQLITE_OK, let handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw TaskStoreError.sqlite(code)
        }
        defer { sqlite3_close_v2(handle) }
        sqlite3_busy_timeout(handle, 0)
        try boundary("existingOpened", db: handle)
        guard try fileIdentity() == identity else { throw TaskStoreError.authorityConflict }
        try Self.exec(handle, "PRAGMA foreign_keys=ON")
        guard try Self.integer(handle, "PRAGMA foreign_keys") == 1 else { throw TaskStoreError.foreignKeysOff }
        try Self.validateOpenedFile(handle)
        let result = try body(handle)
        try Self.validateOpenedFile(handle)
        guard try fileIdentity() == identity else { throw TaskStoreError.authorityConflict }
        return result
    }

    private static func validateOpenedFile(_ db: OpaquePointer) throws {
        var moved: Int32 = 0
        let code = sqlite3_file_control(db, "main", SQLITE_FCNTL_HAS_MOVED, &moved)
        guard code == SQLITE_OK, moved == 0 else { throw TaskStoreError.authorityConflict }
    }

    func probeAuthority(includeTasks: Bool = true) throws -> TaskStoreAuthorityProbe? {
        guard lock.try() else { throw TaskStoreError.sqlite(SQLITE_BUSY) }
        defer { lock.unlock() }
        guard let identity = try fileIdentity() else { return nil }
        return try existing(identity: identity, writable: false) { db in
            try Self.exec(db, "BEGIN")
            do {
                try TaskStoreSchema.validateKnown(on: db)
                guard try Self.stringColumn(db, "PRAGMA foreign_key_check").isEmpty else { throw TaskStoreError.invalidRecord }
                let marker = try Self.authority(in: db)
                try boundary("probeMarkerRead", db: db)
                let result = TaskStoreAuthorityProbe(identity: identity,
                    authority: marker, tasks: includeTasks ? try Self.readRows(from: db) : [])
                try Self.exec(db, "COMMIT")
                return result
            } catch { try? Self.exec(db, "ROLLBACK"); throw error }
        }
    }

    private static func authority(in db: OpaquePointer) throws -> TaskStoreAuthority? {
        if try integer(db, "PRAGMA user_version") == 1 { return nil }
        let statement = try prepare(db, "SELECT singleton,database_id,generation FROM task_authority")
        defer { sqlite3_finalize(statement) }
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return nil }
        guard code == SQLITE_ROW, sqlite3_column_type(statement, 0) == SQLITE_INTEGER,
              sqlite3_column_int64(statement, 0) == 1,
              let raw = try text(statement, 1), let id = UUID(uuidString: raw),
              sqlite3_column_type(statement, 2) == SQLITE_INTEGER,
              sqlite3_column_int64(statement, 2) > 0 else { throw TaskStoreError.invalidRecord }
        let result = TaskStoreAuthority(databaseID: id, generation: sqlite3_column_int64(statement, 2))
        guard sqlite3_step(statement) == SQLITE_DONE else { throw TaskStoreError.invalidRecord }
        return result
    }

    /// Creation is exclusive and follows JSON validation. A crash before preparation
    /// leaves an orphan/schema-zero file that normal loading refuses to reconstruct.
    func createForImport() throws -> TaskStoreAuthorityProbe {
        guard lock.try() else { throw TaskStoreError.sqlite(SQLITE_BUSY) }
        defer { lock.unlock() }
        guard try fileIdentity() == nil else { throw TaskStoreError.authorityConflict }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = Darwin.open(fileURL.path, O_RDWR | O_CREAT | O_EXCL, mode_t(0o600))
        guard fd >= 0 else { throw TaskStoreError.fileRemoved }
        Darwin.close(fd)
        guard let identity = try fileIdentity() else { throw TaskStoreError.fileRemoved }
        // Schema installation stays in the later reconcile transaction.
        return TaskStoreAuthorityProbe(identity: identity, authority: nil, tasks: [])
    }

    private static func importConflicts(_ tasks: [AgentTask], in db: OpaquePointer) throws {
        let incoming = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        let current = try readRows(from: db)
        guard current.allSatisfy({ task in
            guard let row = incoming[task.id] else { return false }
            return row.artifacts.starts(with: task.artifacts)
        }) else { throw TaskStoreError.authorityConflict }
        guard try stringColumn(db, "PRAGMA foreign_key_check").isEmpty else { throw TaskStoreError.invalidRecord }
    }

    func preflightImport(_ tasks: [AgentTask], probe: TaskStoreAuthorityProbe) throws {
        try Self.validate(tasks)
        guard probe.authority == nil else { throw TaskStoreError.authorityConflict }
        guard lock.try() else { throw TaskStoreError.sqlite(SQLITE_BUSY) }
        defer { lock.unlock() }
        try existing(identity: probe.identity, writable: false) { db in
            try TaskStoreSchema.validateKnown(on: db)
            guard try Self.authority(in: db) == nil else { throw TaskStoreError.authorityConflict }
            try Self.importConflicts(tasks, in: db)
        }
    }

    func reconcile(_ tasks: [AgentTask], probe: TaskStoreAuthorityProbe,
                   authority: TaskStoreAuthority, freshlyCreated: Bool = false) throws {
        try Self.validate(tasks)
        guard authority.generation == 1, probe.authority == nil else { throw TaskStoreError.authorityConflict }
        guard lock.try() else { throw TaskStoreError.sqlite(SQLITE_BUSY) }
        defer { lock.unlock() }
        try existing(identity: probe.identity, writable: true) { db in
            let version = try Self.integer(db, "PRAGMA user_version")
            if freshlyCreated {
                guard version == 0 else { throw TaskStoreError.authorityConflict }
            } else {
                try TaskStoreSchema.validateKnown(on: db)
                guard try Self.authority(in: db) == nil else { throw TaskStoreError.authorityConflict }
                try Self.importConflicts(tasks, in: db)
            }
            try Self.exec(db, "PRAGMA journal_mode=WAL")
            guard try Self.stringColumn(db, "PRAGMA journal_mode") == ["wal"] else { throw TaskStoreError.invalidRecord }
            try Self.exec(db, "PRAGMA synchronous=NORMAL")
            try Self.transaction(db) {
                try Self.validateOpenedFile(db)
                guard try fileIdentity() == probe.identity else { throw TaskStoreError.authorityConflict }
                if freshlyCreated {
                    try Self.exec(db, TaskStoreSchema.sql)
                    try Self.exec(db, TaskStoreSchema.authoritySQL)
                    try Self.exec(db, "PRAGMA user_version=\(TaskStoreSchema.version)")
                } else {
                    guard try Self.authority(in: db) == nil else { throw TaskStoreError.authorityConflict }
                    try Self.importConflicts(tasks, in: db)
                    try TaskStoreSchema.installAuthority(on: db)
                }
                try Self.writeRows(tasks, to: db, preservingChildren: true)
                try Self.run(db, "INSERT INTO task_authority(singleton,database_id,generation) VALUES(1,?,?)",
                    [.text(authority.databaseID.uuidString), .integer(authority.generation)])
                try boundary("beforeAuthorityCommit", db: db)
                try Self.validateOpenedFile(db)
                guard try fileIdentity() == probe.identity else { throw TaskStoreError.authorityConflict }
            }
        }
    }

    func commitAuthoritative(_ tasks: [AgentTask], probe: TaskStoreAuthorityProbe,
                             events: [TaskJournalEventDraft]) throws -> TaskStoreAuthority {
        try Self.validate(tasks)
        guard let before = probe.authority, before.generation < Int64.max,
              events.allSatisfy({ event in tasks.contains { $0.id == event.taskID } }) else {
            throw TaskStoreError.invalidRecord
        }
        guard lock.try() else { throw TaskStoreError.sqlite(SQLITE_BUSY) }
        defer { lock.unlock() }
        let after = TaskStoreAuthority(databaseID: before.databaseID, generation: before.generation + 1)
        try existing(identity: probe.identity, writable: true) { db in
            try TaskStoreSchema.validateKnown(on: db)
            try Self.exec(db, "PRAGMA synchronous=NORMAL")
            try Self.transaction(db) {
                try Self.validateOpenedFile(db)
                guard try fileIdentity() == probe.identity,
                      try Self.authority(in: db) == before else { throw TaskStoreError.authorityConflict }
                try TaskStoreSchema.installPendingInteractions(on: db)
                try Self.writeRows(tasks, to: db, preservingChildren: false)
                try TaskEventJournal.append(events, to: db)
                try TaskEventJournal.compact(in: db, now: Date())
                try Self.run(db, "UPDATE task_authority SET generation=? WHERE singleton=1", [.integer(after.generation)])
                try boundary("beforeAuthorityCommit", db: db)
                try Self.validateOpenedFile(db)
                guard try fileIdentity() == probe.identity else { throw TaskStoreError.authorityConflict }
            }
        }
        return after
    }

    /// One transaction replaces the canonical JSON snapshot's current rows. UPSERT updates
    /// retained identities without deleting their event/dependency rows. No second owner.
    func replaceSnapshot(_ tasks: [AgentTask], failFast: Bool = false,
                         events: [TaskJournalEventDraft] = [], now: Date = Date()) throws {
        try Self.validate(tasks)
        guard Set(tasks.map(\.id)).count == tasks.count,
              tasks.allSatisfy({ $0.createdAt.timeIntervalSince1970.isFinite }),
              events.allSatisfy({ event in tasks.contains { $0.id == event.taskID } }) else {
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
                try TaskStoreSchema.installPendingInteractions(on: db)
                try Self.writeRows(tasks, to: db, preservingChildren: false)
                try TaskEventJournal.append(events, to: db)
                try TaskEventJournal.compact(in: db, now: now)
            }
    }

    private static func writeRows(_ tasks: [AgentTask], to db: OpaquePointer,
                                  preservingChildren: Bool) throws {
        let oldIDs = try Self.stringColumn(db, "SELECT id FROM task")
        let incoming = Set(tasks.map(\.id))
        for id in oldIDs where !incoming.contains(id) && !preservingChildren {
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
                .optionalText(try task.durability.map(Self.json)),
                .optionalText(try task.pendingInteraction.map(Self.json))
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
            if !preservingChildren {
                try Self.run(db, "DELETE FROM task_artifact WHERE task_id=? AND ordinal>=?",
                    [.text(task.id), .integer(Int64(task.artifacts.count))])
            }
        }
    }

    func journal(taskID: String) throws -> [TaskJournalEvent] {
        try withConnection { try TaskEventJournal.load(from: $0, taskID: taskID) }
    }

    /// General diagnostic API. Conversational authority reads use the noncreating,
    /// fail-fast probe above; this broader API may create an unmarked fixture store.
    func load() throws -> [AgentTask] {
        try withConnection { try Self.readRows(from: $0) }
    }

    private static func readRows(from db: OpaquePointer) throws -> [AgentTask] {
            let pendingColumn = try TaskStore.integer(db, "PRAGMA user_version") >= 3
                ? "pending_interaction" : "NULL"
            let statement = try Self.prepare(db, "SELECT \(Self.columns),\(pendingColumn) FROM task ORDER BY sort_order,id")
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
                guard !id.isEmpty, sqlite3_column_type(statement, 15) == SQLITE_INTEGER,
                      sqlite3_column_int64(statement, 15) == Int64(tasks.count),
                      [SQLITE_FLOAT, SQLITE_INTEGER].contains(sqlite3_column_type(statement, 16)),
                      sqlite3_column_double(statement, 16).isFinite else { throw TaskStoreError.invalidRecord }
                let artifactsStatement = try Self.prepare(db,
                    "SELECT path,ordinal,added_at,kind,title FROM task_artifact WHERE task_id=? ORDER BY ordinal")
                defer { sqlite3_finalize(artifactsStatement) }
                try Self.bind(artifactsStatement, [.text(id)])
                var artifacts: [String] = []
                var artifactCode = sqlite3_step(artifactsStatement)
                while artifactCode == SQLITE_ROW {
                    guard let path = try Self.text(artifactsStatement, 0),
                          sqlite3_column_type(artifactsStatement, 1) == SQLITE_INTEGER,
                          sqlite3_column_int64(artifactsStatement, 1) == Int64(artifacts.count),
                          sqlite3_column_type(artifactsStatement, 2) == SQLITE_INTEGER,
                          try Self.text(artifactsStatement, 3) != nil else { throw TaskStoreError.invalidRecord }
                    _ = try Self.text(artifactsStatement, 4)
                    artifacts.append(path)
                    artifactCode = sqlite3_step(artifactsStatement)
                }
                guard artifactCode == SQLITE_DONE else { throw TaskStoreError.sqlite(artifactCode) }
                let task = AgentTask(id: id, objective: try required(4), source: try required(2),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 16)),
                    contextReferences: try Self.decode([String].self, required(6)), status: status,
                    progress: try required(5), result: try Self.text(statement, 17), artifacts: artifacts,
                    tool: try Self.text(statement, 7), arguments: try Self.decode([String: String].self, required(8)),
                    meetingID: try Self.uuid(Self.text(statement, 9)), backend: try required(3),
                    failure: try Self.text(statement, 18), acpCLI: try required(10),
                    compatibilityCommand: try Self.text(statement, 11), compatibilityCLI: try Self.text(statement, 12),
                    compatibilityDirectory: try Self.text(statement, 13), scheduleID: try Self.uuid(Self.text(statement, 14)),
                    durability: try Self.text(statement, 19).map { try Self.decode(TaskDurability.self, $0) },
                    pendingInteraction: try Self.text(statement, 20).map { try Self.decode(TaskPendingInteraction.self, $0) })
                tasks.append(task)
                code = sqlite3_step(statement)
            }
            guard code == SQLITE_DONE else { throw TaskStoreError.sqlite(code) }
            try validate(tasks)
            return tasks
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
        INSERT INTO task(\(columns),pending_interaction) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
          state=excluded.state,source=excluded.source,backend=excluded.backend,
          objective=excluded.objective,progress=excluded.progress,
          context_references=excluded.context_references,tool=excluded.tool,arguments=excluded.arguments,
          meeting_id=excluded.meeting_id,acp_cli=excluded.acp_cli,
          compatibility_command=excluded.compatibility_command,compatibility_cli=excluded.compatibility_cli,
          compatibility_directory=excluded.compatibility_directory,schedule_id=excluded.schedule_id,
          sort_order=excluded.sort_order,created_at=excluded.created_at,result=excluded.result,
          failure=excluded.failure,durability=excluded.durability,pending_interaction=excluded.pending_interaction
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
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT else { throw TaskStoreError.invalidRecord }
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

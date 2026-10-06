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
    // st_dev identifies the current mount, not a persistent APFS volume.
    var volumeUUID: String? = nil

    // Live file guards and prepared-import repair retain the original exact
    // mount identity. Stable volume metadata is checked only as a saved witness.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.device == rhs.device && lhs.inode == rhs.inode
    }

    /// Used only for an already-marked SQL history and its retained export.
    /// Legacy exports had no volume UUID; matching inode plus the separately
    /// checked database UUID/generation admits their first post-remount read.
    func matchesPersistedWitness(_ current: Self) -> Bool {
        guard inode == current.inode else { return false }
        if let volumeUUID { return volumeUUID == current.volumeUUID }
        return current.volumeUUID != nil || device == current.device
    }
}

struct TaskStoreAuthorityProbe: Sendable {
    let identity: TaskStoreFileIdentity
    let authority: TaskStoreAuthority?
    let tasks: [AgentTask]
    /// Optional read-only journal projection in this SAME existing snapshot transaction.
    var events: [String: [TaskJournalEvent]] = [:]
}

/// A predicate on an existing primary task row, checked inside the same commit.
/// It supplies no recovery, liveness or retry authority.
struct TaskWorkerWriteCondition: Equatable, Sendable {
    let taskID: String
    let attempt: Int
    let leaseOwner: String?
    let status: AgentTaskStatus
    // Optional SAME-row voice projection predicate. Ordinary worker conditions
    // keep their exact attempt/lease semantics; no presentation authority follows.
    var typedRevision: Int? = nil
    var typedPending: TaskPendingInteraction? = nil
    var voiceOrigin: TaskOrigin? = nil
    var voiceRevision: Int? = nil
    var voiceInputRequestID: String? = nil
    var voicePermission: TaskPendingInteraction? = nil
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
    // Captured on the first successful stat. In-process guards still compare
    // device+inode exactly, so a later mount/file replacement is rejected.
    private lazy var volumeUUID = try? fileURL.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
    var authorityBoundaryForTesting: ((String, OpaquePointer?) throws -> Void)?

    private func boundary(_ name: String, db: OpaquePointer?) throws {
        guard SelfTest.isRunning, let observer = authorityBoundaryForTesting else { return }
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path + "/"
        if fileURL.resolvingSymlinksInPath().path.hasPrefix(temporary) {
            try observer(name, db)
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
            guard !task.id.isEmpty, task.createdAt.timeIntervalSince1970.isFinite,
                  task.deliveryAttempts >= 0, task.revision >= 0,
                  [task.startedAt, task.finishedAt].compactMap({ $0 }).allSatisfy({ $0.timeIntervalSince1970.isFinite }),
                  task.userWords == nil || !(task.userWords?.isEmpty ?? true),
                  task.artifactRecords.allSatisfy({ !$0.kind.isEmpty && !$0.kind.utf8.contains(0) }) else { return false }
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
            return TaskStoreFileIdentity(device: UInt64(value.st_dev), inode: UInt64(value.st_ino), volumeUUID: volumeUUID)
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
        defer {
            sqlite3_close_v2(handle)
            // Numeric-only temporary diagnostic after the SAME existing close returns.
            // A notification cannot veto or replace the result after resource retirement.
            try? boundary("existingClosed", db: nil)
        }
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

    func probeAuthority(includeTasks: Bool = true, includeJournal: Bool = false) throws -> TaskStoreAuthorityProbe? {
        guard !includeJournal || includeTasks else { throw TaskStoreError.invalidRecord }
        guard lock.try() else { throw TaskStoreError.sqlite(SQLITE_BUSY) }
        defer { lock.unlock() }
        guard let identity = try fileIdentity() else { return nil }
        return try existing(identity: identity, writable: false) { db in
            try Self.exec(db, "BEGIN")
            do {
                let schemaVersion = try TaskStoreSchema.validateKnown(on: db)
                guard try Self.stringColumn(db, "PRAGMA foreign_key_check").isEmpty else { throw TaskStoreError.invalidRecord }
                let marker = try Self.authority(in: db, validatedVersion: schemaVersion)
                try boundary("probeMarkerRead", db: db)
                let tasks = includeTasks ? try Self.readRows(from: db) : []
                var events: [String: [TaskJournalEvent]] = [:]
                if includeJournal {
                    for task in tasks { events[task.id] = try TaskEventJournal.load(from: db, taskID: task.id) }
                }
                let result = TaskStoreAuthorityProbe(identity: identity,
                    authority: marker, tasks: tasks, events: events)
                try Self.exec(db, "COMMIT")
                return result
            } catch { try? Self.exec(db, "ROLLBACK"); throw error }
        }
    }

    private static func authority(in db: OpaquePointer, validatedVersion: Int64? = nil) throws -> TaskStoreAuthority? {
        let version = try validatedVersion ?? integer(db, "PRAGMA user_version")
        if version == 1 { return nil }
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
                && Array(row.artifactRecords.prefix(task.artifactRecords.count)) == task.artifactRecords
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

    /// A retained preparation may bind a genuinely empty file created before schema
    /// installation. Ordinary authority reads still reject schema zero. This probe
    /// never creates, upgrades or marks a ledger, including when repair is unavailable.
    func probePreparedImport(_ tasks: [AgentTask], identity: TaskStoreFileIdentity) throws -> TaskStoreAuthorityProbe {
        try Self.validate(tasks)
        guard lock.try() else { throw TaskStoreError.sqlite(SQLITE_BUSY) }
        defer { lock.unlock() }
        try boundary("preparedImportProbe", db: nil)
        return try existing(identity: identity, writable: false) { db in
            try Self.exec(db, "BEGIN")
            do {
                let current = try Self.validatePreparedImport(tasks, in: db)
                let probe = TaskStoreAuthorityProbe(identity: identity, authority: nil, tasks: current)
                try Self.exec(db, "COMMIT")
                return probe
            } catch { try? Self.exec(db, "ROLLBACK"); throw error }
        }
    }

    private static func validateEmptyPreparation(in db: OpaquePointer) throws {
        guard try integer(db, "PRAGMA user_version") == 0,
              try integer(db, "PRAGMA application_id") == 0,
              try integer(db, "SELECT count(*) FROM sqlite_master") == 0,
              try stringColumn(db, "PRAGMA integrity_check") == ["ok"] else {
            throw TaskStoreError.authorityConflict
        }
    }

    private static func validatePreparedImport(_ tasks: [AgentTask], in db: OpaquePointer) throws -> [AgentTask] {
        if try integer(db, "PRAGMA user_version") == 0 {
            try validateEmptyPreparation(in: db)
            return []
        }
        try TaskStoreSchema.validateKnown(on: db)
        guard try authority(in: db) == nil,
              try stringColumn(db, "PRAGMA integrity_check") == ["ok"],
              try stringColumn(db, "PRAGMA foreign_key_check").isEmpty,
              try integer(db, "SELECT count(*) FROM sqlite_master WHERE name NOT IN ('task','task_event','task_artifact','task_dependency','task_authority','sqlite_sequence','task_state','task_created','task_event_task','sqlite_autoindex_task_1','sqlite_autoindex_task_artifact_1','sqlite_autoindex_task_dependency_1')") == 0 else {
            throw TaskStoreError.authorityConflict
        }
        let current = try readRows(from: db)
        for task in current { _ = try TaskEventJournal.load(from: db, taskID: task.id) }
        let existingIDs = Set(current.map(\.id))
        guard current == tasks.filter({ existingIDs.contains($0.id) }) else {
            throw TaskStoreError.authorityConflict
        }
        return current
    }

    /// Explicit preparation repair, not automatic startup reconciliation. The bound
    /// file and every relevant predicate are checked again while holding its write
    /// transaction. Existing task children and receipts are never replaced or deleted.
    func repairPreparedImport(_ tasks: [AgentTask], identity: TaskStoreFileIdentity,
                              authority: TaskStoreAuthority, checkWitness: () throws -> Void) throws {
        try Self.validate(tasks)
        guard authority.generation == 1 else { throw TaskStoreError.authorityConflict }
        guard lock.try() else { throw TaskStoreError.sqlite(SQLITE_BUSY) }
        defer { lock.unlock() }
        try existing(identity: identity, writable: true) { db in
            _ = try Self.validatePreparedImport(tasks, in: db)
            try Self.exec(db, "PRAGMA synchronous=NORMAL")
            try Self.transaction(db) {
                try Self.validateOpenedFile(db)
                guard try fileIdentity() == identity else { throw TaskStoreError.authorityConflict }
                try checkWitness()
                try boundary("preparedRepairLocked", db: db)
                _ = try Self.validatePreparedImport(tasks, in: db)
                if try Self.integer(db, "PRAGMA user_version") == 0 {
                    try Self.exec(db, TaskStoreSchema.sql)
                    try Self.exec(db, TaskStoreSchema.authoritySQL)
                    try Self.exec(db, "PRAGMA user_version=\(TaskStoreSchema.version)")
                } else { try TaskStoreSchema.installAuthority(on: db) }
                try Self.writeRows(tasks, to: db, preservingChildren: true)
                try Self.run(db, "INSERT INTO task_authority(singleton,database_id,generation) VALUES(1,?,?)",
                    [.text(authority.databaseID.uuidString), .integer(authority.generation)])
                try boundary("beforeAuthorityCommit", db: db)
                try checkWitness()
                try Self.validateOpenedFile(db)
                guard try fileIdentity() == identity else { throw TaskStoreError.authorityConflict }
            }
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
                             events: [TaskJournalEventDraft], worker: TaskWorkerWriteCondition? = nil) throws -> TaskStoreAuthority {
        try Self.validate(tasks)
        guard let before = probe.authority, before.generation < Int64.max,
              events.allSatisfy({ event in tasks.contains { $0.id == event.taskID } }) else {
            throw TaskStoreError.invalidRecord
        }
        guard lock.try() else { throw TaskStoreError.sqlite(SQLITE_BUSY) }
        defer { lock.unlock() }
        let after = TaskStoreAuthority(databaseID: before.databaseID, generation: before.generation + 1)
        try existing(identity: probe.identity, writable: true) { db in
            try Self.exec(db, "PRAGMA synchronous=NORMAL")
            try Self.transaction(db) {
                // Validate this exact locked snapshot once, before any row mutation.
                let schemaVersion = try TaskStoreSchema.validateKnown(on: db)
                try Self.validateOpenedFile(db)
                guard try fileIdentity() == probe.identity,
                      try Self.authority(in: db, validatedVersion: schemaVersion) == before else { throw TaskStoreError.authorityConflict }
                if let worker {
                    guard try Self.workerPrimaryObservation(worker, in: db).outcome == .accepted,
                          let next = tasks.first(where: { $0.id == worker.taskID }) else {
                        throw TaskStoreError.authorityConflict
                    }
                    if let revision = worker.typedRevision {
                        guard worker.voiceOrigin == nil, worker.voiceRevision == nil,
                              worker.voiceInputRequestID == nil, worker.voicePermission == nil,
                              worker.attempt > 0, worker.leaseOwner != nil,
                              next.source == "text", next.origin == .typed,
                              next.revision >= revision else { throw TaskStoreError.authorityConflict }
                    }
                    if let origin = worker.voiceOrigin, let revision = worker.voiceRevision {
                        guard worker.attempt == 0, worker.leaseOwner == nil,
                              next.source == "voice", next.durability == nil,
                              next.origin == origin, case .voice = origin else { throw TaskStoreError.authorityConflict }
                        if worker.status == .running {
                            guard worker.voiceInputRequestID == nil, worker.voicePermission == nil else { throw TaskStoreError.authorityConflict }
                            if next.status == .running {
                                guard next.pendingInteraction == nil, next.revision >= revision,
                                      events.isEmpty || (next.revision > revision
                                        && events.count == next.revision - revision
                                        && events.allSatisfy({ $0.taskID == worker.taskID && $0.attempt == 0
                                            && $0.kind == .revisionRecorded
                                            && $0.detail?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }))
                                else { throw TaskStoreError.authorityConflict }
                            } else {
                                guard next.status == .waitingForPermission, next.revision == revision,
                                      case .permission(let request, _, let review?) = next.pendingInteraction,
                                      request.taskID == next.id, review.id == request.id, review.toolID == request.toolID,
                                      events.count == 1, events.first?.kind == .permissionRequested,
                                      events.allSatisfy({ $0.taskID == worker.taskID && $0.attempt == 0 }) else {
                                    throw TaskStoreError.authorityConflict
                                }
                            }
                        } else if worker.status == .waitingForInput {
                            guard worker.voicePermission == nil, next.status == .running,
                                  let request = worker.voiceInputRequestID, !request.isEmpty,
                                  next.pendingInteraction == nil, next.revision >= revision,
                                  let words = next.userWords, !words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                                  (events.count == 2 && Set(events.map(\.kind)) == [.inputProvided, .workerStarted])
                                    || (next.revision > revision && next.revision - revision == 1 && events.count == 3
                                        && Set(events.prefix(2).map(\.kind)) == [.inputProvided, .workerStarted]
                                        && events.last?.kind == .revisionRecorded && events.last?.detail == words),
                                  events.allSatisfy({ $0.taskID == worker.taskID && $0.attempt == 0 }) else {
                                throw TaskStoreError.authorityConflict
                            }
                        } else if worker.status == .waitingForPermission {
                            guard worker.voiceInputRequestID == nil,
                                  case .permission(let request, _, let review?) = worker.voicePermission,
                                  request.taskID == worker.taskID, review.id == request.id, review.toolID == request.toolID,
                                  next.pendingInteraction == nil,
                                  events.allSatisfy({ $0.taskID == worker.taskID && $0.attempt == 0 }) else {
                                throw TaskStoreError.authorityConflict
                            }
                            if next.status == .cancelled {
                                guard next.revision == revision, events.count == 1,
                                      events.first?.kind == .jobCancelled else { throw TaskStoreError.authorityConflict }
                            } else {
                                guard next.status == .running, next.revision >= revision else { throw TaskStoreError.authorityConflict }
                                if next.revision > revision {
                                    guard events.first?.kind == .workerStarted,
                                          events.count == 1 || (events.count - 1 == next.revision - revision
                                            && events.dropFirst().allSatisfy({ $0.kind == .revisionRecorded
                                                && $0.detail?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }))
                                    else { throw TaskStoreError.authorityConflict }
                                } else {
                                    guard events.count == 2,
                                          Set(events.map(\.kind)) == [.permissionApproved, .workerStarted]
                                            || Set(events.map(\.kind)) == [.permissionDenied, .workerStarted] else {
                                        throw TaskStoreError.authorityConflict
                                    }
                                }
                            }
                        } else { throw TaskStoreError.authorityConflict }
                    } else {
                        guard worker.voiceOrigin == nil, worker.voiceRevision == nil,
                              worker.voiceInputRequestID == nil, worker.voicePermission == nil else { throw TaskStoreError.authorityConflict }
                        let starting = worker.status == .queued && next.status == .running
                        guard worker.attempt >= 0, !starting || worker.attempt < Int.max,
                              next.durability?.attempt == worker.attempt + (starting ? 1 : 0),
                              starting || next.durability?.leaseOwner == worker.leaseOwner,
                              events.filter({ $0.taskID == worker.taskID }).allSatisfy({ $0.attempt == next.durability?.attempt }) else {
                            throw TaskStoreError.authorityConflict
                        }
                    }
                }
                // Current schema was fully checked above in this SAME transaction.
                // Older versions still execute the existing migration and post-validation.
                let artifactVersion = schemaVersion == TaskStoreSchema.version
                    ? schemaVersion : try TaskStoreSchema.installPendingInteractions(on: db)
                guard artifactVersion >= 4 || tasks.allSatisfy({ $0.artifactRecords.allSatisfy(\.isLegacy) }) else {
                    throw TaskStoreError.invalidRecord
                }
                guard artifactVersion >= 5 || tasks.allSatisfy({ !Self.hasTaskEncoding($0) }) else {
                    throw TaskStoreError.invalidRecord
                }
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

    /// Bound ACP progress changes one existing row and its journal atomically.
    /// The full snapshot API remains the owner for all other task mutations.
    func commitActivity(before: AgentTask, after: AgentTask, probe: TaskStoreAuthorityProbe,
                        event: TaskJournalEventDraft, worker: TaskWorkerWriteCondition) throws -> TaskStoreAuthority {
        try Self.validate([after])
        var allowed = before
        allowed.durability?.heartbeatAt = after.durability?.heartbeatAt
        allowed.durability?.lastProgressAt = after.durability?.lastProgressAt
        guard allowed == after, before.id == worker.taskID, after.status == .running,
              worker.status == .running, worker.attempt > 0,
              event.taskID == worker.taskID, event.kind == .heartbeat,
              (event.detail == "acp.activity" || (event.detail == "acp.periodic"
                && after.durability?.lastProgressAt == before.durability?.lastProgressAt)),
              event.attempt == worker.attempt,
              event.receiptID == nil, let prior = probe.authority, prior.generation < Int64.max else {
            throw TaskStoreError.invalidRecord
        }
        guard lock.try() else { throw TaskStoreError.sqlite(SQLITE_BUSY) }
        defer { lock.unlock() }
        let next = TaskStoreAuthority(databaseID: prior.databaseID, generation: prior.generation + 1)
        try existing(identity: probe.identity, writable: true) { db in
            try Self.exec(db, "PRAGMA synchronous=NORMAL")
            try Self.transaction(db) {
                let schemaVersion = try TaskStoreSchema.validateKnown(on: db)
                try Self.validateOpenedFile(db)
                guard try fileIdentity() == probe.identity,
                      try Self.authority(in: db, validatedVersion: schemaVersion) == prior else { throw TaskStoreError.authorityConflict }
                let current = try Self.workerPrimaryObservation(worker, in: db)
                guard current.outcome == .accepted, current.durability == before.durability,
                      after.durability?.attempt == worker.attempt,
                      after.durability?.leaseOwner == worker.leaseOwner else { throw TaskStoreError.authorityConflict }
                try Self.run(db, "UPDATE task SET durability=? WHERE id=?",
                    [.optionalText(try after.durability.map(Self.json)), .text(worker.taskID)])
                guard sqlite3_changes(db) == 1 else { throw TaskStoreError.authorityConflict }
                try TaskEventJournal.append([event], to: db)
                try TaskEventJournal.compact(in: db, now: Date())
                try Self.run(db, "UPDATE task_authority SET generation=? WHERE singleton=1", [.integer(next.generation)])
                try boundary("beforeAuthorityCommit", db: db)
                try Self.validateOpenedFile(db)
                guard try fileIdentity() == probe.identity else { throw TaskStoreError.authorityConflict }
            }
        }
        return next
    }

    /// The Bool execution contract consumes the same single authoritative row read.
    func matchesWorker(_ worker: TaskWorkerWriteCondition, probe: TaskStoreAuthorityProbe) throws -> Bool {
        try workerPrimaryObservation(worker, probe: probe).outcome == .accepted
    }

    /// Return metadata only after existing(...) finishes its native file-binding check.
    func workerPrimaryObservation(_ worker: TaskWorkerWriteCondition,
                                  probe: TaskStoreAuthorityProbe) throws -> TaskWorkerPrimaryObservation {
        guard let authority = probe.authority else {
            return TaskWorkerPrimaryObservation(expected: worker, outcome: .unavailable,
                observedAt: Date(), state: nil, durability: nil)
        }
        guard lock.try() else { throw TaskStoreError.sqlite(SQLITE_BUSY) }
        defer { lock.unlock() }
        return try existing(identity: probe.identity, writable: false) { db in
            try Self.exec(db, "BEGIN")
            defer { try? Self.exec(db, "ROLLBACK") }
            guard try Self.authority(in: db) == authority else {
                return TaskWorkerPrimaryObservation(expected: worker, outcome: .unavailable,
                    observedAt: Date(), state: nil, durability: nil)
            }
            return try Self.workerPrimaryObservation(worker, in: db)
        }
    }

    private static func workerPrimaryObservation(_ worker: TaskWorkerWriteCondition,
                                                 in db: OpaquePointer) throws -> TaskWorkerPrimaryObservation {
        let voice = worker.voiceOrigin != nil || worker.voiceRevision != nil || worker.voiceInputRequestID != nil || worker.voicePermission != nil
        let typed = worker.typedRevision != nil || worker.typedPending != nil
        let statement = try prepare(db, voice || typed
            ? "SELECT state,durability,source,origin,metadata_encoding_version,revision,pending_interaction FROM task WHERE id=?"
            : "SELECT state,durability FROM task WHERE id=?")
        defer { sqlite3_finalize(statement) }
        try bind(statement, [.text(worker.taskID)])
        let code = sqlite3_step(statement)
        guard code == SQLITE_ROW else {
            if code == SQLITE_DONE {
                return TaskWorkerPrimaryObservation(expected: worker, outcome: .mismatch,
                    observedAt: Date(), state: nil, durability: nil)
            }
            throw TaskStoreError.sqlite(code)
        }
        guard let state = try text(statement, 0), let status = AgentTaskStatus(rawValue: state) else {
            throw TaskStoreError.invalidRecord
        }
        let durability = try text(statement, 1).map { try decode(TaskDurability.self, $0) }
        guard (durability?.attempt ?? 0) >= 0 else { throw TaskStoreError.invalidRecord }
        var voiceMatches = true
        if voice {
            voiceMatches = false
            if let origin = worker.voiceOrigin, let revision = worker.voiceRevision, revision >= 0,
               [.running, .waitingForInput, .waitingForPermission].contains(worker.status), worker.attempt == 0, worker.leaseOwner == nil, durability == nil,
               try text(statement, 2) == "voice", sqlite3_column_type(statement, 4) == SQLITE_INTEGER {
                let encoding = sqlite3_column_int64(statement, 4)
                if [1, 2, 3].contains(encoding), let raw = try text(statement, 3),
                   case .voice = origin {
                    let currentOrigin = try decode(TaskOrigin.self, raw)
                    let currentRevision: Int?
                    if encoding == 3 {
                        currentRevision = sqlite3_column_type(statement, 5) == SQLITE_INTEGER
                            ? Int(exactly: sqlite3_column_int64(statement, 5)) : nil
                    } else { currentRevision = 0 } // Unowned historical revision bytes remain opaque.
                    let rawPending = try text(statement, 6)
                    let pending = try rawPending.map { try decode(TaskPendingInteraction.self, $0) }
                    let questionMatches: Bool
                    if worker.status == .waitingForInput {
                        if let requestID = worker.voiceInputRequestID,
                           case .input(let request)? = pending {
                            questionMatches = worker.voicePermission == nil && request.id == requestID && request.taskID == worker.taskID
                        } else { questionMatches = false }
                    } else if worker.status == .waitingForPermission {
                        if case .permission(let request, _, _)? = worker.voicePermission {
                            // Compare the exact canonical stored payload using this SAME
                            // store's sorted-key/date codec, not decoded Date equality.
                            let expectedPending = try worker.voicePermission.map { try json($0) }
                            questionMatches = worker.voiceInputRequestID == nil
                                && request.taskID == worker.taskID && rawPending == expectedPending
                        } else { questionMatches = false }
                    } else { questionMatches = worker.voiceInputRequestID == nil && worker.voicePermission == nil && pending == nil }
                    voiceMatches = currentOrigin == origin && currentRevision == revision && questionMatches
                }
            }
        }
        var typedMatches = !typed
        if let revision = worker.typedRevision {
            typedMatches = false
            if !voice, revision >= 0, worker.attempt > 0, worker.leaseOwner != nil,
               try text(statement, 2) == "text",
               let raw = try text(statement, 3), try decode(TaskOrigin.self, raw) == .typed,
               sqlite3_column_type(statement, 4) == SQLITE_INTEGER {
                let encoding = sqlite3_column_int64(statement, 4)
                let currentRevision = encoding == 3
                    ? (sqlite3_column_type(statement, 5) == SQLITE_INTEGER
                        ? Int(exactly: sqlite3_column_int64(statement, 5)) : nil)
                    : ([1, 2].contains(encoding) ? 0 : nil)
                let rawPending = try text(statement, 6)
                let expectedPending = try worker.typedPending.map { try json($0) }
                typedMatches = currentRevision == revision && rawPending == expectedPending
            }
        }
        let matches = status == worker.status && (durability?.attempt ?? 0) == worker.attempt
            && durability?.leaseOwner == worker.leaseOwner && voiceMatches && typedMatches
        return TaskWorkerPrimaryObservation(expected: worker, outcome: matches ? .accepted : .mismatch,
            observedAt: Date(), state: status, durability: durability)
    }

    /// One transaction replaces the canonical JSON snapshot's current rows. UPSERT updates
    /// retained identities without deleting their event/dependency rows. No second owner.
    func replaceSnapshot(_ tasks: [AgentTask], failFast: Bool = false,
                         events: [TaskJournalEventDraft] = [], now: Date = Date()) throws {
        try Self.validate(tasks)
        guard Set(tasks.map(\.id)).count == tasks.count,
              tasks.allSatisfy({ $0.createdAt.timeIntervalSince1970.isFinite && $0.revision >= 0 }),
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
                let artifactVersion = try TaskStoreSchema.installPendingInteractions(on: db)
                guard artifactVersion >= 4 || tasks.allSatisfy({ $0.artifactRecords.allSatisfy(\.isLegacy) }) else {
                    throw TaskStoreError.invalidRecord
                }
                guard artifactVersion >= 5 || tasks.allSatisfy({ !Self.hasTaskEncoding($0) }) else {
                    throw TaskStoreError.invalidRecord
                }
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
        guard !tasks.isEmpty else { return }
        // Every row uses the same SQL within this write. Keep its statement local
        // to this invocation; bindings and SQLite row-change checks remain per row.
        let upsertStatement = try Self.prepare(db, Self.upsert)
        defer { sqlite3_finalize(upsertStatement) }
        for (position, task) in tasks.enumerated() {
            let resetCode = sqlite3_reset(upsertStatement)
            guard resetCode == SQLITE_OK else { throw TaskStoreError.sqlite(resetCode) }
            let clearCode = sqlite3_clear_bindings(upsertStatement)
            guard clearCode == SQLITE_OK else { throw TaskStoreError.sqlite(clearCode) }
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
                .text(try task.origin.map(Self.json) ?? ""), .text(task.userWords ?? ""),
                task.startedAt.map { .real($0.timeIntervalSince1970) } ?? .optionalText(nil),
                task.finishedAt.map { .real($0.timeIntervalSince1970) } ?? .optionalText(nil),
                .optionalText(try task.pendingInteraction.map(Self.json)),
                .integer(task.revision > 0 ? 3 : (Self.hasTaskDelivery(task) ? 2 : (Self.hasTaskMetadata(task) ? 1 : 0))),
                .text(task.delivery?.rawValue ?? ""), .integer(Int64(task.deliveryAttempts)), .integer(Int64(task.revision))
            ]
            try Self.bind(upsertStatement, values)
            let stepCode = sqlite3_step(upsertStatement)
            guard stepCode == SQLITE_DONE else { throw TaskStoreError.sqlite(stepCode) }
            guard sqlite3_changes(db) == 1 else { throw TaskStoreError.invalidRecord }
            for (ordinal, path) in task.artifacts.enumerated() {
                let record = task.artifactRecords[ordinal]
                try Self.run(db, """
                    INSERT INTO task_artifact(task_id,path,ordinal,added_at,kind,title,encoding_version)
                    VALUES(?,?,?,CAST(? AS INTEGER),?,?,?)
                    ON CONFLICT(task_id,ordinal) DO UPDATE SET
                      kind=CASE WHEN excluded.kind='link' AND excluded.title IS NULL
                        AND path=excluded.path AND encoding_version=0 THEN kind ELSE excluded.kind END,
                      title=CASE WHEN excluded.kind='link' AND excluded.title IS NULL
                        AND path=excluded.path AND encoding_version=0 THEN title ELSE excluded.title END,
                      encoding_version=excluded.encoding_version, path=excluded.path
                    """, [.text(task.id), .text(path), .integer(Int64(ordinal)),
                        .real(task.createdAt.timeIntervalSince1970),
                        .text(record.isLegacy ? "link" : "artifact-v1:" + record.kind), .optionalText(record.title),
                        .integer(record.isLegacy ? 0 : 1)])
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
            let version = try Self.integer(db, "PRAGMA user_version")
            // A diagnostic v1 snapshot may already carry the recognized optional
            // column without an authority marker. Read it when present; a genuine
            // old schema still projects nil. Reading never upgrades or marks it.
            let pendingColumn: String
            if version >= 3 { pendingColumn = "pending_interaction" }
            else {
                pendingColumn = try Self.stringColumn(db, "PRAGMA table_info(task)", column: 1)
                    .contains("pending_interaction") ? "pending_interaction" : "NULL"
            }
            let statement = try Self.prepare(db, "SELECT \(Self.columns),\(pendingColumn),\(version >= 5 ? "metadata_encoding_version" : "0"),delivery,delivery_attempts,revision FROM task ORDER BY sort_order,id")
            defer { sqlite3_finalize(statement) }
            var tasks: [AgentTask] = []
            var code = sqlite3_step(statement)
            while code == SQLITE_ROW {
                func required(_ column: Int32) throws -> String {
                    guard let value = try Self.text(statement, column) else { throw TaskStoreError.invalidRecord }
                    return value
                }
                func optionalDate(_ column: Int32) throws -> Date? {
                    if sqlite3_column_type(statement, column) == SQLITE_NULL { return nil }
                    guard [SQLITE_FLOAT, SQLITE_INTEGER].contains(sqlite3_column_type(statement, column)),
                          sqlite3_column_double(statement, column).isFinite else { throw TaskStoreError.invalidRecord }
                    return Date(timeIntervalSince1970: sqlite3_column_double(statement, column))
                }
                guard let status = AgentTaskStatus(rawValue: try required(1)) else { throw TaskStoreError.invalidRecord }
                let id = try required(0)
                guard !id.isEmpty, sqlite3_column_type(statement, 15) == SQLITE_INTEGER,
                      sqlite3_column_int64(statement, 15) == Int64(tasks.count),
                      [SQLITE_FLOAT, SQLITE_INTEGER].contains(sqlite3_column_type(statement, 16)),
                      sqlite3_column_double(statement, 16).isFinite else { throw TaskStoreError.invalidRecord }
                let artifactsStatement = try Self.prepare(db,
                    "SELECT path,ordinal,added_at,kind,title,\(version >= 4 ? "encoding_version" : "0") FROM task_artifact WHERE task_id=? ORDER BY ordinal")
                defer { sqlite3_finalize(artifactsStatement) }
                try Self.bind(artifactsStatement, [.text(id)])
                var artifactRecords: [AgentArtifact] = []
                var artifactCode = sqlite3_step(artifactsStatement)
                while artifactCode == SQLITE_ROW {
                    guard let path = try Self.text(artifactsStatement, 0),
                          sqlite3_column_type(artifactsStatement, 1) == SQLITE_INTEGER,
                          sqlite3_column_int64(artifactsStatement, 1) == Int64(artifactRecords.count),
                          sqlite3_column_type(artifactsStatement, 2) == SQLITE_INTEGER,
                          sqlite3_column_type(artifactsStatement, 5) == SQLITE_INTEGER,
                          [0, 1].contains(sqlite3_column_int64(artifactsStatement, 5)),
                          let kind = try Self.text(artifactsStatement, 3) else { throw TaskStoreError.invalidRecord }
                    let title = try Self.text(artifactsStatement, 4)
                    let encoding = sqlite3_column_int64(artifactsStatement, 5)
                    if encoding == 0 {
                        // Every historical kind/title is neutral, including exact prefix collisions.
                        artifactRecords.append(AgentArtifact(path))
                    } else if kind.hasPrefix("artifact-v1:") {
                        let semantic = String(kind.dropFirst("artifact-v1:".count))
                        guard !semantic.isEmpty, !semantic.utf8.contains(0) else { throw TaskStoreError.invalidRecord }
                        artifactRecords.append(AgentArtifact(path, kind: semantic, title: title))
                    } else {
                        // Only the explicitly owned encoding domain can reject malformed/future data.
                        throw TaskStoreError.invalidRecord
                    }
                    artifactCode = sqlite3_step(artifactsStatement)
                }
                guard artifactCode == SQLITE_DONE else { throw TaskStoreError.sqlite(artifactCode) }
                guard sqlite3_column_type(statement, 25) == SQLITE_INTEGER,
                      [0, 1, 2, 3].contains(sqlite3_column_int64(statement, 25)) else { throw TaskStoreError.invalidRecord }
                let encoding = sqlite3_column_int64(statement, 25)
                let metadataOwned = encoding >= 1
                let origin: TaskOrigin?
                let userWords: String?
                let startedAt: Date?
                let finishedAt: Date?
                if metadataOwned {
                    guard sqlite3_column_type(statement, 20) == SQLITE_TEXT,
                          sqlite3_column_type(statement, 21) == SQLITE_TEXT else { throw TaskStoreError.invalidRecord }
                    let originText = try required(20)
                    let wordsText = try required(21)
                    origin = originText.isEmpty ? nil : try Self.decode(TaskOrigin.self, originText)
                    userWords = wordsText.isEmpty ? nil : wordsText
                    startedAt = try optionalDate(22)
                    finishedAt = try optionalDate(23)
                } else {
                    // All old reserved bytes, including typed-looking/prefix collisions,
                    // remain neutral and are never decoded as authored instructions.
                    origin = nil; userWords = nil; startedAt = nil; finishedAt = nil
                }
                let delivery: TaskDelivery?
                let deliveryAttempts: Int
                if encoding >= 2 {
                    guard sqlite3_column_type(statement, 26) == SQLITE_TEXT,
                          sqlite3_column_type(statement, 27) == SQLITE_INTEGER,
                          sqlite3_column_int64(statement, 27) >= 0,
                          let attempts = Int(exactly: sqlite3_column_int64(statement, 27)) else { throw TaskStoreError.invalidRecord }
                    let raw = try required(26)
                    guard raw.isEmpty || TaskDelivery(rawValue: raw) != nil else { throw TaskStoreError.invalidRecord }
                    delivery = raw.isEmpty ? nil : TaskDelivery(rawValue: raw)
                    deliveryAttempts = attempts
                } else {
                    // Even an exact old enum-word collision remains unowned.
                    delivery = nil; deliveryAttempts = 0
                }
                let revision: Int
                if encoding == 3 {
                    guard sqlite3_column_type(statement, 28) == SQLITE_INTEGER,
                          sqlite3_column_int64(statement, 28) >= 0,
                          let value = Int(exactly: sqlite3_column_int64(statement, 28)) else { throw TaskStoreError.invalidRecord }
                    revision = value
                } else {
                    // Raw revision bytes from every prior encoding remain wholly opaque.
                    revision = 0
                }
                var task = AgentTask(id: id, objective: try required(4), source: try required(2),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 16)),
                    contextReferences: try Self.decode([String].self, required(6)), status: status,
                    progress: try required(5), result: try Self.text(statement, 17), artifacts: artifactRecords.map(\.value),
                    tool: try Self.text(statement, 7), arguments: try Self.decode([String: String].self, required(8)),
                    meetingID: try Self.uuid(Self.text(statement, 9)), backend: try required(3),
                    failure: try Self.text(statement, 18), acpCLI: try required(10),
                    compatibilityCommand: try Self.text(statement, 11), compatibilityCLI: try Self.text(statement, 12),
                    compatibilityDirectory: try Self.text(statement, 13), scheduleID: try Self.uuid(Self.text(statement, 14)),
                    durability: try Self.text(statement, 19).map { try Self.decode(TaskDurability.self, $0) },
                    pendingInteraction: try Self.text(statement, 24).map { try Self.decode(TaskPendingInteraction.self, $0) },
                    origin: origin, userWords: userWords, revision: revision,
                    startedAt: startedAt, finishedAt: finishedAt,
                    delivery: delivery, deliveryAttempts: deliveryAttempts)
                task.artifactRecords = artifactRecords
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
        schedule_id,sort_order,created_at,result,failure,durability,origin,user_words,started_at,finished_at
        """
    private static let upsert = """
        INSERT INTO task(\(columns),pending_interaction,metadata_encoding_version,delivery,delivery_attempts,revision) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
          state=excluded.state,source=excluded.source,backend=excluded.backend,
          objective=excluded.objective,progress=excluded.progress,
          context_references=excluded.context_references,tool=excluded.tool,arguments=excluded.arguments,
          meeting_id=excluded.meeting_id,acp_cli=excluded.acp_cli,
          compatibility_command=excluded.compatibility_command,compatibility_cli=excluded.compatibility_cli,
          compatibility_directory=excluded.compatibility_directory,schedule_id=excluded.schedule_id,
          sort_order=excluded.sort_order,created_at=excluded.created_at,result=excluded.result,
          failure=excluded.failure,durability=excluded.durability,
          origin=CASE WHEN excluded.metadata_encoding_version=0 AND task.metadata_encoding_version=0 THEN task.origin ELSE excluded.origin END,
          user_words=CASE WHEN excluded.metadata_encoding_version=0 AND task.metadata_encoding_version=0 THEN task.user_words ELSE excluded.user_words END,
          started_at=CASE WHEN excluded.metadata_encoding_version=0 AND task.metadata_encoding_version=0 THEN task.started_at ELSE excluded.started_at END,
          finished_at=CASE WHEN excluded.metadata_encoding_version=0 AND task.metadata_encoding_version=0 THEN task.finished_at ELSE excluded.finished_at END,
          delivery=CASE WHEN task.metadata_encoding_version>=2 OR excluded.metadata_encoding_version>=2 THEN excluded.delivery ELSE task.delivery END,
          delivery_attempts=CASE WHEN task.metadata_encoding_version>=2 OR excluded.metadata_encoding_version>=2 THEN excluded.delivery_attempts ELSE task.delivery_attempts END,
          revision=CASE WHEN task.metadata_encoding_version=3 OR excluded.metadata_encoding_version=3 THEN excluded.revision ELSE task.revision END,
          pending_interaction=excluded.pending_interaction,metadata_encoding_version=max(task.metadata_encoding_version,excluded.metadata_encoding_version)
        WHERE typeof(task.metadata_encoding_version)='integer'
          AND task.metadata_encoding_version IN (0,1,2,3)
          AND (excluded.metadata_encoding_version=0 OR task.metadata_encoding_version IN (1,2,3)
            OR (typeof(task.origin)='text' AND task.origin=''
              AND typeof(task.user_words)='text' AND task.user_words=''
              AND task.started_at IS NULL AND task.finished_at IS NULL))
          AND (excluded.metadata_encoding_version<2 OR task.metadata_encoding_version>=2
            OR (task.metadata_encoding_version=1 AND typeof(task.delivery)='text' AND task.delivery=''
              AND typeof(task.delivery_attempts)='integer' AND task.delivery_attempts=0))
          AND (excluded.metadata_encoding_version<3 OR task.metadata_encoding_version=3
            OR (typeof(task.revision)='integer' AND task.revision=0))
          AND (task.metadata_encoding_version<>3 OR excluded.revision>=task.revision)
        """

    private static func hasTaskDelivery(_ task: AgentTask) -> Bool {
        task.delivery != nil || task.deliveryAttempts > 0
    }
    private static func hasTaskEncoding(_ task: AgentTask) -> Bool {
        hasTaskMetadata(task) || hasTaskDelivery(task) || task.revision > 0
    }

    private static func hasTaskMetadata(_ task: AgentTask) -> Bool {
        task.origin != nil || task.userWords != nil || task.startedAt != nil || task.finishedAt != nil
    }

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

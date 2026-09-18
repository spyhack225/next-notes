import Foundation
import SQLite3

/// What a chunk was cut from. The raw values are the `chunk.source_kind` column.
enum KnowledgeSourceKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case transcript
    case notes
    case conversation
    case routine
    case dictation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .transcript: "Transcripts"
        case .notes: "Meeting notes"
        case .conversation: "Agent conversations"
        case .routine: "Routine runs"
        case .dictation: "Dictation"
        }
    }
}

/// One retrievable passage, before it has a row id.
///
/// `occurredAt` is unix seconds: the meeting start plus `startTime` for a transcript, the
/// meeting start for notes, and the turn or run time for everything else.
struct KnowledgeChunk: Equatable, Sendable {
    var ordinal: Int
    var text: String
    var startTime: Double? = nil
    var endTime: Double? = nil
    var speaker: String? = nil
    var heading: String? = nil
    var occurredAt: Int64
}

/// What the index holds, for Settings and `--selftest-index`.
struct KnowledgeIndexStats: Equatable, Sendable {
    var chunks = 0
    var sources = 0
    var chunksByKind: [KnowledgeSourceKind: Int] = [:]
    /// Chunks with a vector, from any model.
    var embedded = 0
    /// The database file plus its write-ahead log.
    var bytes: Int64 = 0
}

enum KnowledgeStoreError: LocalizedError {
    case open(String)
    case sqlite(String)
    case foreignKeysOff

    var errorDescription: String? {
        switch self {
        case .open(let reason): "The knowledge index could not be opened: \(reason)"
        case .sqlite(let reason): "The knowledge index failed: \(reason)"
        case .foreignKeysOff: "The knowledge index connection refused PRAGMA foreign_keys = ON."
        }
    }
}

/// `knowledge.sqlite`: the chunk table, its FTS5 mirror, and the per-source generation.
///
/// **Derived and disposable.** The meeting folders, `agent-conversation.json`, `runs.jsonl`
/// and the routine run history stay the source of truth; deleting this file is a complete,
/// safe repair, and a file SQLite cannot read is deleted and rebuilt the same way. It lives
/// beside those files rather than inside a meeting folder so a corrupt index can never take
/// a transcript with it.
///
/// Two things the schema cannot do for itself, both done here on every connection:
///
/// - **`PRAGMA foreign_keys = ON`.** SQLite defaults it off, per connection, and without it
///   `embedding`'s `ON DELETE CASCADE` silently orphans vectors (Phase B).
/// - **The FTS5 mirror.** `chunk_fts` is an external-content table; triggers copy every
///   insert, update and delete on `chunk` into it inside the same statement's transaction,
///   so a row can never be searchable by SQL and invisible to search.
///
/// `generation` is the idempotency story. It is a fingerprint of the chunks a source
/// produces, so it changes exactly when the source is rewritten — Regenerate, diarization, a
/// speaker rename — and is identical when a rebuild reads the same files again. A replace
/// inserts the new generation and deletes every other one in one transaction: a search never
/// sees two generations of one source, and a crash mid-write leaves the old one whole.
///
/// One connection behind a lock. Every call is short — a search, or one source's
/// transaction — so callers on the main actor may call synchronously, and the indexer calls
/// from a background task.
final class KnowledgeStore: @unchecked Sendable {
    static let fileName = "knowledge.sqlite"
    /// Bumped when the schema changes. The index is derived, so a mismatch is a rebuild,
    /// never a migration.
    static let schemaVersion: Int32 = 1

    let fileURL: URL
    private let lock = NSLock()
    private var db: OpaquePointer?
    /// The inode the open connection's file had. The index is deletable at any time, even
    /// with the app running: a connection whose file is gone (or replaced) is closed and a
    /// new file is created, so deletes, backfill and search never use an unlinked file.
    private var openedInode: UInt64?
    /// Bumped by every write, under `lock`. The in-memory vector set compares it to know
    /// when to reload, so a deleted chunk's vector never outlives the chunk in search.
    private var mutations: UInt64 = 0

    /// How many writes this store has seen. Read it before loading anything derived.
    var mutationCount: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return mutations
    }

    init(directory: URL) {
        fileURL = directory.appendingPathComponent(Self.fileName)
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    /// Whether an index exists on disk. Deletion hooks use this so turning the feature off
    /// never creates a file just to delete nothing from it.
    var existsOnDisk: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    // MARK: - Connection

    /// Runs `body` with the open connection, opening (and creating) it on first use.
    func withConnection<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        let connection = try openLocked()
        return try body(connection)
    }

    /// `withConnection` for a body that writes.
    func withWritingConnection<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        lock.lock()
        defer {
            mutations &+= 1
            lock.unlock()
        }
        let connection = try openLocked()
        return try body(connection)
    }

    /// Closes the connection; the next call reopens it.
    func close() {
        lock.lock()
        defer { lock.unlock() }
        closeLocked()
    }

    /// Deletes the index and its journal files. The next call creates an empty one.
    func deleteFile() {
        lock.lock()
        defer { lock.unlock() }
        closeLocked()
        removeFilesLocked()
        mutations &+= 1
    }

    /// `PRAGMA foreign_keys` as the live connection reports it, for the self-test.
    func foreignKeysEnabled() throws -> Bool {
        try withConnection { db in try Self.int(db, "PRAGMA foreign_keys") == 1 }
    }

    /// `PRAGMA integrity_check` plus FTS5's own integrity check of the mirror.
    func integrityProblems() throws -> [String] {
        try withConnection { db in
            var problems: [String] = []
            let statement = try Self.prepare(db, "PRAGMA integrity_check")
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                let line = Self.text(statement, 0) ?? ""
                if line != "ok" { problems.append(line) }
            }
            do {
                try Self.exec(db, "INSERT INTO chunk_fts(chunk_fts, rank) VALUES('integrity-check', 1)")
            } catch {
                problems.append("chunk_fts: \(error.localizedDescription)")
            }
            return problems
        }
    }

    private func openLocked() throws -> OpaquePointer {
        if let db {
            if let inode = openedInode, Self.inode(atPath: fileURL.path) == inode { return db }
            Log.app.info("knowledge index file removed while open, reconnecting")
            closeLocked()
            mutations &+= 1
            // The journal files belonged to the removed database; a new one must not adopt them.
            for suffix in ["-wal", "-shm", "-journal"] {
                try? FileManager.default.removeItem(atPath: fileURL.path + suffix)
            }
        }
        do {
            return try connectLocked()
        } catch {
            // A file SQLite cannot read, or one from another schema, is not repaired in
            // place: the index is derived, so it is deleted and built again.
            Log.app.error("knowledge index unreadable, rebuilding: \(error.localizedDescription, privacy: .public)")
            closeLocked()
            removeFilesLocked()
            return try connectLocked()
        }
    }

    private func connectLocked() throws -> OpaquePointer {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(fileURL.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let reason = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "no handle"
            if let handle { sqlite3_close_v2(handle) }
            throw KnowledgeStoreError.open(reason)
        }
        do {
            sqlite3_busy_timeout(handle, 2_000)
            try Self.exec(handle, "PRAGMA foreign_keys = ON")
            guard try Self.int(handle, "PRAGMA foreign_keys") == 1 else { throw KnowledgeStoreError.foreignKeysOff }
            try Self.exec(handle, "PRAGMA journal_mode = WAL")
            try Self.exec(handle, "PRAGMA synchronous = NORMAL")
            let version = try Self.int(handle, "PRAGMA user_version")
            if version == 0 {
                try Self.exec(handle, "BEGIN IMMEDIATE")
                do {
                    try Self.exec(handle, Self.schema)
                    try Self.exec(handle, "PRAGMA user_version = \(Self.schemaVersion)")
                    try Self.exec(handle, "COMMIT")
                } catch {
                    try? Self.exec(handle, "ROLLBACK")
                    throw error
                }
            } else if version != Int(Self.schemaVersion) {
                throw KnowledgeStoreError.open("schema version \(version), expected \(Self.schemaVersion)")
            }
            // The graph tables (Phase C) are additive and created on every connection, so an
            // index built before extraction existed gains them without a rebuild — a rebuild
            // would lose conversation turns older than the history the Agent keeps.
            try Self.exec(handle, Self.graphSchema)
            // Entity resolution (Phase D), additive for the same reason.
            try Self.exec(handle, Self.resolutionSchema)
            // Touches every table, so a file that is not a database fails here rather than
            // on the first search.
            _ = try Self.int(handle, "SELECT count(*) FROM index_state")
        } catch {
            sqlite3_close_v2(handle)
            throw error
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        db = handle
        openedInode = Self.inode(atPath: fileURL.path)
        return handle
    }

    private func closeLocked() {
        if let db { sqlite3_close_v2(db) }
        db = nil
        openedInode = nil
    }

    private static func inode(atPath path: String) -> UInt64? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return UInt64(info.st_ino)
    }

    private func removeFilesLocked() {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(atPath: fileURL.path + suffix)
        }
    }

    /// The plan's schema, verbatim, plus the triggers that keep `chunk_fts` in step.
    static let schema = """
        CREATE TABLE chunk (
          id           INTEGER PRIMARY KEY,
          source_kind  TEXT NOT NULL,
          source_id    TEXT NOT NULL,
          generation   INTEGER NOT NULL,
          ordinal      INTEGER NOT NULL,
          text         TEXT NOT NULL,
          start_time   REAL,
          end_time     REAL,
          speaker      TEXT,
          heading      TEXT,
          occurred_at  INTEGER NOT NULL,
          UNIQUE (source_kind, source_id, generation, ordinal)
        );

        CREATE INDEX chunk_source ON chunk(source_kind, source_id, generation);
        CREATE INDEX chunk_time   ON chunk(occurred_at);

        CREATE VIRTUAL TABLE chunk_fts USING fts5(
          text,
          content='chunk',
          content_rowid='id',
          tokenize='porter unicode61'
        );

        CREATE TABLE embedding (
          chunk_id INTEGER PRIMARY KEY REFERENCES chunk(id) ON DELETE CASCADE,
          model    TEXT NOT NULL,
          dims     INTEGER NOT NULL,
          vector   BLOB NOT NULL
        );

        CREATE TABLE index_state (
          source_kind TEXT NOT NULL,
          source_id   TEXT NOT NULL,
          generation  INTEGER NOT NULL,
          indexed_at  INTEGER NOT NULL,
          embedded    INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (source_kind, source_id)
        );

        CREATE TRIGGER chunk_fts_insert AFTER INSERT ON chunk BEGIN
          INSERT INTO chunk_fts(rowid, text) VALUES (new.id, new.text);
        END;
        CREATE TRIGGER chunk_fts_delete AFTER DELETE ON chunk BEGIN
          INSERT INTO chunk_fts(chunk_fts, rowid, text) VALUES ('delete', old.id, old.text);
        END;
        CREATE TRIGGER chunk_fts_update AFTER UPDATE ON chunk BEGIN
          INSERT INTO chunk_fts(chunk_fts, rowid, text) VALUES ('delete', old.id, old.text);
          INSERT INTO chunk_fts(rowid, text) VALUES (new.id, new.text);
        END;
        """

    // MARK: - Writes

    enum ReplaceOutcome: Equatable, Sendable {
        /// The index already held this generation; nothing was written.
        case unchanged
        /// A new generation replaced whatever was there.
        case replaced(chunks: Int)
        /// The source produced no chunks; its rows and state are gone.
        case removed
    }

    /// Makes the index hold exactly `chunks` for one source, in one transaction.
    @discardableResult
    func replace(
        kind: KnowledgeSourceKind, sourceID: String, chunks: [KnowledgeChunk], now: Date = Date()
    ) throws -> ReplaceOutcome {
        guard !chunks.isEmpty else {
            let removed = try deleteSource(kind: kind, sourceID: sourceID)
            return removed > 0 ? .removed : .unchanged
        }
        let generation = Self.generation(of: chunks)
        return try withWritingConnection { db in
            try Self.exec(db, "BEGIN IMMEDIATE")
            do {
                let current = try Self.optionalInt(
                    db, "SELECT generation FROM index_state WHERE source_kind = ?1 AND source_id = ?2",
                    [.text(kind.rawValue), .text(sourceID)])
                if current == generation {
                    try Self.exec(db, "COMMIT")
                    return .unchanged
                }
                let insert = try Self.prepare(db, """
                    INSERT INTO chunk (source_kind, source_id, generation, ordinal, text, start_time,
                                       end_time, speaker, heading, occurred_at)
                    VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
                    """)
                defer { sqlite3_finalize(insert) }
                for chunk in chunks {
                    sqlite3_reset(insert)
                    sqlite3_clear_bindings(insert)
                    Self.bind(insert, [
                        .text(kind.rawValue), .text(sourceID), .int(generation), .int(Int64(chunk.ordinal)),
                        .text(chunk.text), .double(chunk.startTime), .double(chunk.endTime),
                        .optionalText(chunk.speaker), .optionalText(chunk.heading), .int(chunk.occurredAt),
                    ])
                    guard sqlite3_step(insert) == SQLITE_DONE else { throw Self.error(db) }
                }
                try Self.run(db, "DELETE FROM chunk WHERE source_kind = ?1 AND source_id = ?2 AND generation != ?3",
                             [.text(kind.rawValue), .text(sourceID), .int(generation)])
                try Self.run(db, """
                    INSERT INTO index_state (source_kind, source_id, generation, indexed_at, embedded)
                    VALUES (?1, ?2, ?3, ?4, 0)
                    ON CONFLICT (source_kind, source_id) DO UPDATE SET
                      generation = excluded.generation, indexed_at = excluded.indexed_at, embedded = 0
                    """, [.text(kind.rawValue), .text(sourceID), .int(generation), .int(Int64(now.timeIntervalSince1970))])
                try Self.exec(db, "COMMIT")
                return .replaced(chunks: chunks.count)
            } catch {
                try? Self.exec(db, "ROLLBACK")
                throw error
            }
        }
    }

    /// Deletes one source's chunks and state. Returns the number of chunks removed.
    @discardableResult
    func deleteSource(kind: KnowledgeSourceKind, sourceID: String) throws -> Int {
        try withWritingConnection { db in
            try Self.transaction(db) {
                try Self.run(db, "DELETE FROM chunk WHERE source_kind = ?1 AND source_id = ?2",
                             [.text(kind.rawValue), .text(sourceID)])
                let removed = Int(sqlite3_changes(db))
                try Self.run(db, "DELETE FROM index_state WHERE source_kind = ?1 AND source_id = ?2",
                             [.text(kind.rawValue), .text(sourceID)])
                return removed
            }
        }
    }

    /// Deletes every source of one kind — *Clear conversation*, *Forget everything*, or a
    /// kind the user has excluded. Returns the number of chunks removed.
    @discardableResult
    func deleteSources(kind: KnowledgeSourceKind) throws -> Int {
        try withWritingConnection { db in
            try Self.transaction(db) {
                try Self.run(db, "DELETE FROM chunk WHERE source_kind = ?1", [.text(kind.rawValue)])
                let removed = Int(sqlite3_changes(db))
                try Self.run(db, "DELETE FROM index_state WHERE source_kind = ?1", [.text(kind.rawValue)])
                return removed
            }
        }
    }

    // MARK: - Reads

    /// Source id → generation, for one kind.
    func indexedSources(kind: KnowledgeSourceKind) throws -> [String: Int64] {
        try withConnection { db in
            let statement = try Self.prepare(db, "SELECT source_id, generation FROM index_state WHERE source_kind = ?1")
            defer { sqlite3_finalize(statement) }
            Self.bind(statement, [.text(kind.rawValue)])
            var result: [String: Int64] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                if let id = Self.text(statement, 0) { result[id] = sqlite3_column_int64(statement, 1) }
            }
            return result
        }
    }

    /// Every distinct generation a source has rows for. More than one is a bug.
    func generations(kind: KnowledgeSourceKind, sourceID: String) throws -> [Int64] {
        try withConnection { db in
            let statement = try Self.prepare(
                db, "SELECT DISTINCT generation FROM chunk WHERE source_kind = ?1 AND source_id = ?2")
            defer { sqlite3_finalize(statement) }
            Self.bind(statement, [.text(kind.rawValue), .text(sourceID)])
            var result: [Int64] = []
            while sqlite3_step(statement) == SQLITE_ROW { result.append(sqlite3_column_int64(statement, 0)) }
            return result
        }
    }

    func chunkCount(kind: KnowledgeSourceKind? = nil, sourceID: String? = nil) throws -> Int {
        try withConnection { db in
            var sql = "SELECT count(*) FROM chunk WHERE 1"
            var values: [SQLValue] = []
            if let kind { values.append(.text(kind.rawValue)); sql += " AND source_kind = ?\(values.count)" }
            if let sourceID { values.append(.text(sourceID)); sql += " AND source_id = ?\(values.count)" }
            return Int(try Self.optionalInt(db, sql, values) ?? 0)
        }
    }

    /// Rows in the FTS5 mirror, counted through its own docsize shadow table.
    func mirroredCount() throws -> Int {
        try withConnection { db in Int(try Self.int(db, "SELECT count(*) FROM chunk_fts_docsize")) }
    }

    func stats() throws -> KnowledgeIndexStats {
        try withConnection { db in
            var stats = KnowledgeIndexStats()
            let statement = try Self.prepare(db, "SELECT source_kind, count(*) FROM chunk GROUP BY source_kind")
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let raw = Self.text(statement, 0), let kind = KnowledgeSourceKind(rawValue: raw) else { continue }
                let count = Int(sqlite3_column_int(statement, 1))
                stats.chunksByKind[kind] = count
                stats.chunks += count
            }
            stats.sources = Int(try Self.int(db, "SELECT count(*) FROM index_state"))
            stats.embedded = Int(try Self.int(db, "SELECT count(*) FROM embedding"))
            stats.bytes = ["", "-wal"].reduce(Int64(0)) { total, suffix in
                let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path + suffix)[.size]) as? NSNumber
                return total + (size?.int64Value ?? 0)
            }
            return stats
        }
    }

    // MARK: - Generation

    /// FNV-1a over every field a chunk carries, folded to a positive 63-bit integer. The same
    /// source read twice gives the same generation; any change to its text, timing, speaker
    /// or heading gives a different one.
    static func generation(of chunks: [KnowledgeChunk]) -> Int64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ string: String) {
            for byte in string.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
            hash ^= 0x1f
            hash = hash &* 0x0000_0100_0000_01b3
        }
        for chunk in chunks {
            mix(String(chunk.ordinal))
            mix(chunk.text)
            mix(chunk.startTime.map { String(format: "%.3f", $0) } ?? "-")
            mix(chunk.endTime.map { String(format: "%.3f", $0) } ?? "-")
            mix(chunk.speaker ?? "-")
            mix(chunk.heading ?? "-")
            mix(String(chunk.occurredAt))
        }
        let folded = Int64(bitPattern: hash & 0x7fff_ffff_ffff_ffff)
        return folded == 0 ? 1 : folded
    }

    // MARK: - SQLite helpers

    enum SQLValue {
        case int(Int64)
        case double(Double?)
        case text(String)
        case optionalText(String?)
        case blob(Data)
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw error(db)
        }
        return statement
    }

    static func bind(_ statement: OpaquePointer, _ values: [SQLValue]) {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .int(let number):
                sqlite3_bind_int64(statement, index, number)
            case .double(let number):
                if let number { sqlite3_bind_double(statement, index, number) } else { sqlite3_bind_null(statement, index) }
            case .text(let string):
                sqlite3_bind_text(statement, index, string, -1, transient)
            case .optionalText(let string):
                if let string { sqlite3_bind_text(statement, index, string, -1, transient) } else { sqlite3_bind_null(statement, index) }
            case .blob(let data):
                data.withUnsafeBytes { raw in
                    _ = sqlite3_bind_blob(statement, index, raw.baseAddress, Int32(raw.count), transient)
                }
            }
        }
    }

    static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            let reason = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(message)
            throw KnowledgeStoreError.sqlite(reason)
        }
    }

    static func run(_ db: OpaquePointer, _ sql: String, _ values: [SQLValue]) throws {
        let statement = try prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        bind(statement, values)
        let code = sqlite3_step(statement)
        guard code == SQLITE_DONE || code == SQLITE_ROW else { throw error(db) }
    }

    static func int(_ db: OpaquePointer, _ sql: String) throws -> Int64 {
        try optionalInt(db, sql, []) ?? 0
    }

    static func optionalInt(_ db: OpaquePointer, _ sql: String, _ values: [SQLValue]) throws -> Int64? {
        let statement = try prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        bind(statement, values)
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return sqlite3_column_type(statement, 0) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 0)
        case SQLITE_DONE:
            return nil
        default:
            throw error(db)
        }
    }

    static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let raw = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: raw)
    }

    static func optionalDouble(_ statement: OpaquePointer, _ column: Int32) -> Double? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : sqlite3_column_double(statement, column)
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

    static func error(_ db: OpaquePointer) -> KnowledgeStoreError {
        .sqlite(String(cString: sqlite3_errmsg(db)))
    }
}

import Foundation
import SQLite3

/// `imessage-outbound.sqlite`: what this app sent, and the nine facts about each send the store is
/// allowed to keep.
///
/// ## Why SQLite and not JSON
///
/// The task's own reason, and it stands: **a uniqueness constraint on a send, a mutable matched
/// identifier, and a settled-vs-pending state a crash can leave half-written.** That is
/// relational. `KnowledgeStore` is the template — a root URL, `0o600`, WAL, one connection
/// behind a lock — and this store copies it, adds a root and an `isolated()` seam.
///
/// ## Read the row type before this schema
///
/// `PendingOutboundMessage` is an **allowlist of nine fields** (`OutboundMessageLedger.swift`),
/// and this schema has exactly those columns and no more. `schema` is one `static let` rather than
/// a migration chain for the reason the decoder's parser is hand-written: **a file this cannot read
/// is deleted and built again, never repaired in place**, because the file is a matching table and
/// nothing else. A rebuild costs the pending set, and a pending row that was lost was a send whose
/// echo had not arrived — the breaker counts that one, and `IM-10`'s receipt reports it as
/// unverified rather than as a failure.
///
/// ## The three things this store refuses
///
/// 1. **A row it could never match.** An empty `textDigest`, or a digest that is not
///    `OutboundLedgerRules.digestByteCount` bytes, is refused at the boundary rather than stored:
///    such a row has no identity, so it would sit in the table for seven days and match nothing.
/// 2. **A second row for one send.** `UNIQUE (chat_guid, text_digest, dispatched_at)` is what
///    stops a retried dispatch from manufacturing the **ambiguity** case, which would silently
///    degrade a real echo into a command for the whole window.
/// 3. **A write to a Messages database.** It never opens one. `chat.db` is read by
///    `MessagesDatabase`, read-only, with `PRAGMA query_only`; nothing in this folder has a path
///    to it and no SQL here names `message`, `chat` or `handle`.
///
/// ## Privacy, enforced by the schema and not by a filter
///
/// The three `TEXT` columns are opaque ids and nothing else: `conversation_id` is IM-11's mapper's
/// output, `chat_guid` and `matched_message_guid` are Apple's. There is no column a body, a file
/// name, an address, a bundle id, an error sentence or a link could be written into, so there is
/// nothing for a sanitiser to miss. `--selftest-imessage-loop` proves that claim against the
/// **written file** with `strings(1)`, because a field-level assertion answers a different
/// question from the one the design asks.
final class IMessageOutboundStore: @unchecked Sendable {
    static let fileName = "imessage-outbound.sqlite"
    /// Bumped when the schema changes. The file is a matching table, so a mismatch is a rebuild.
    static let schemaVersion: Int32 = 1

    /// The owner's real file's directory, and **a per-process temporary directory under the
    /// self-test harness** — the same rule `UsageLog.shared` follows, and the reason no harness
    /// run can append to the owner's ledger. `SelfTestStoreGuard` watches the owner's three files
    /// (`--selftest-store-isolation`) so the claim is checked rather than asserted.
    static var defaultRoot: URL {
        SelfTest.isRunning
            ? FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "NextNotesSelfTest-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
            : AppIdentity.applicationSupportDirectory
    }

    /// A store on a fresh directory of its own. `--selftest-imessage-loop` seeds its sends here
    /// rather than through `shared`, so a case can create and destroy a ledger without a second
    /// process's temp directory in the way — the `MeetingStore.isolated()` pattern.
    static func isolated() -> IMessageOutboundStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "NextNotesOutboundTest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return IMessageOutboundStore(root: url)
    }

    let root: URL
    let fileURL: URL
    private let lock = NSLock()
    private var db: OpaquePointer?

    init(root: URL = IMessageOutboundStore.defaultRoot) {
        self.root = root
        self.fileURL = root.appendingPathComponent(Self.fileName)
    }

    deinit { if let db { sqlite3_close_v2(db) } }

    /// Every byte of the store, for a privacy assertion that reads what reached the disk: the
    /// database **and its two journal siblings**. A row written into the WAL has not been
    /// checkpointed into the main file, and a check that only read the main file would pass on a
    /// store that had just written somebody's sentence into a sibling.
    var filesToInspect: [URL] {
        [fileURL,
         URL(fileURLWithPath: fileURL.path + "-wal"),
         URL(fileURLWithPath: fileURL.path + "-shm")]
    }

    // MARK: - Writes

    /// Records one send. **The only way a row enters this store**, which is what makes "one
    /// `insert`" an enforcement rather than a habit.
    func record(_ send: PendingOutboundMessage) throws {
        let digest = try Self.validated(send.textDigest, named: "text digest")
        var attachmentBlob = Data()
        for candidate in send.attachmentDigests {
            attachmentBlob.append(try Self.validated(candidate, named: "attachment digest"))
        }
        guard !send.chatGUID.isEmpty else {
            throw IMessageOutboundStoreError.notAMatchableRow("the chat guid is empty")
        }
        try withWritingConnection { db in
            let statement = try Self.prepare(db, """
                INSERT INTO outbound (conversation_id, chat_guid, text_digest,
                                      attachment_digests, dispatched_at, matched_row_id,
                                      matched_message_guid, state)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """)
            defer { sqlite3_finalize(statement) }
            try Self.bind(statement, text: send.conversationID, to: 1)
            try Self.bind(statement, text: send.chatGUID, to: 2)
            try Self.bind(statement, blob: digest, to: 3)
            try Self.bind(statement, blob: attachmentBlob, to: 4)
            sqlite3_bind_int64(statement, 5, send.dispatchedAt)
            if let rowID = send.matchedRowID {
                sqlite3_bind_int64(statement, 6, rowID)
            } else {
                sqlite3_bind_null(statement, 6)
            }
            if let guid = send.matchedMessageGUID {
                try Self.bind(statement, text: guid, to: 7)
            } else {
                sqlite3_bind_null(statement, 7)
            }
            try Self.bind(statement, text: send.state.rawValue, to: 8)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw IMessageOutboundStoreError.write(Self.message(db))
            }
        }
    }

    /// Moves a send to `.landed` and writes the row that claimed it. **The one mutable
    /// transition**, and it is the receipt IM-10 reads.
    func markLanded(sendID: Int64, rowID: Int64, messageGUID: String) throws {
        try withWritingConnection { db in
            let statement = try Self.prepare(db, """
                UPDATE outbound SET state = ?, matched_row_id = ?, matched_message_guid = ?
                WHERE id = ?
                """)
            defer { sqlite3_finalize(statement) }
            try Self.bind(statement, text: OutboundState.landed.rawValue, to: 1)
            sqlite3_bind_int64(statement, 2, rowID)
            try Self.bind(statement, text: messageGUID, to: 3)
            sqlite3_bind_int64(statement, 4, sendID)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw IMessageOutboundStoreError.write(Self.message(db))
            }
        }
    }

    /// A local act gave up on a send: every still-pending send in that chat with that digest
    /// becomes `.abandoned`, which **can never match a later row**.
    @discardableResult
    func markAbandoned(chatGUID: String, textDigest: Data) throws -> Int {
        try withWritingConnection { db in
            let statement = try Self.prepare(db, """
                UPDATE outbound SET state = ? WHERE state = ? AND chat_guid = ? AND text_digest = ?
                """)
            defer { sqlite3_finalize(statement) }
            try Self.bind(statement, text: OutboundState.abandoned.rawValue, to: 1)
            try Self.bind(statement, text: OutboundState.pending.rawValue, to: 2)
            try Self.bind(statement, text: chatGUID, to: 3)
            try Self.bind(statement, blob: textDigest, to: 4)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw IMessageOutboundStoreError.write(Self.message(db))
            }
            return Int(sqlite3_changes(db))
        }
    }

    /// `pending` rows dispatched before `cutoff` become `.expired`. **The design's rule, and it is
    /// a rule about state rather than only about a comparison**: a settled row can never match a
    /// later row, so the window cannot be reopened by a late sweep.
    @discardableResult
    func expirePending(olderThan cutoff: Int64) throws -> Int {
        try withWritingConnection { db in
            let statement = try Self.prepare(db, """
                UPDATE outbound SET state = ? WHERE state = ? AND dispatched_at <= ?
                """)
            defer { sqlite3_finalize(statement) }
            try Self.bind(statement, text: OutboundState.expired.rawValue, to: 1)
            try Self.bind(statement, text: OutboundState.pending.rawValue, to: 2)
            sqlite3_bind_int64(statement, 3, cutoff)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw IMessageOutboundStoreError.write(Self.message(db))
            }
            return Int(sqlite3_changes(db))
        }
    }

    /// Deletes every settled row older than the retention window. **A `pending` row is never
    /// deleted here** — it is not settled, and deleting it would throw away the only record of a
    /// send whose echo has not arrived.
    @discardableResult
    func deleteSettled(olderThan cutoff: Int64) throws -> Int {
        try withWritingConnection { db in
            let statement = try Self.prepare(db, """
                DELETE FROM outbound WHERE state != ? AND dispatched_at <= ?
                """)
            defer { sqlite3_finalize(statement) }
            try Self.bind(statement, text: OutboundState.pending.rawValue, to: 1)
            sqlite3_bind_int64(statement, 2, cutoff)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw IMessageOutboundStoreError.write(Self.message(db))
            }
            return Int(sqlite3_changes(db))
        }
    }

    // MARK: - Reads

    /// Every row whose state may still identify an echo. **The whole table, deliberately**: it is
    /// bounded by the retention window to a handful of rows, and a query that filtered by date in
    /// SQL would move the window into the SQL where a case could not read it.
    func claimableRows() throws -> [PendingOutboundMessage] {
        try withConnection { db in
            var rows: [PendingOutboundMessage] = []
            let statement = try Self.prepare(db, """
                SELECT id, conversation_id, chat_guid, text_digest, attachment_digests,
                       dispatched_at, matched_row_id, matched_message_guid, state
                FROM outbound ORDER BY id
                """)
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(try Self.row(from: statement))
            }
            return rows.filter { $0.state.mayIdentifyAnEcho }
        }
    }

    /// Every row, in every state, for `--imessage-report` and the self-test.
    func allRows() throws -> [PendingOutboundMessage] {
        try withConnection { db in
            var rows: [PendingOutboundMessage] = []
            let statement = try Self.prepare(db, """
                SELECT id, conversation_id, chat_guid, text_digest, attachment_digests,
                       dispatched_at, matched_row_id, matched_message_guid, state
                FROM outbound ORDER BY id
                """)
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append(try Self.row(from: statement))
            }
            return rows
        }
    }

    /// Closes the connection, so the next call reopens the file. **The self-test's crash
    /// simulation is this and a fresh store instance**: nothing is kept in memory that a relaunch
    /// would not have, and that is the claim being tested.
    func close() {
        lock.lock()
        defer { lock.unlock() }
        if let db { sqlite3_close_v2(db) }
        db = nil
    }

    /// Checkpoints the WAL into the main file, so a `strings(1)` over the main file alone is not
    /// reading an empty database. `filesToInspect` covers the siblings too; this is belt and
    /// braces, and the self-test calls it before inspecting.
    func flush() {
        (try? withConnection { db in try Self.exec(db, "PRAGMA wal_checkpoint(TRUNCATE)") }) ?? ()
    }

    // MARK: - Connection

    private func withConnection<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(try openLocked())
    }

    private func withWritingConnection<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(try openLocked())
    }

    private func openLocked() throws -> OpaquePointer {
        if let db { return db }
        do {
            return try connectLocked()
        } catch {
            // The file is a matching table, so a database this cannot read is deleted and built
            // again rather than repaired in place. A rebuild costs at worst a rejected echo, and
            // every send in it was identified long ago.
            Log.app.error("imessage outbound store unreadable, rebuilding: \(error.localizedDescription, privacy: .public)")
            removeFilesLocked()
            return try connectLocked()
        }
    }

    private func connectLocked() throws -> OpaquePointer {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(fileURL.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let reason = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "no handle"
            if let handle { sqlite3_close_v2(handle) }
            throw IMessageOutboundStoreError.open(reason)
        }
        do {
            sqlite3_busy_timeout(handle, 2_000)
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
                throw IMessageOutboundStoreError.open("schema version \(version), expected \(Self.schemaVersion)")
            }
            // Touches the table, so a file that is not a database fails here rather than on the
            // first send.
            _ = try Self.int(handle, "SELECT count(*) FROM outbound")
        } catch {
            sqlite3_close_v2(handle)
            throw error
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        db = handle
        return handle
    }

    private func removeFilesLocked() {
        if let db { sqlite3_close_v2(db) }
        db = nil
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(atPath: fileURL.path + suffix)
        }
    }

    // MARK: - Schema

    /// **Nine columns, and they are the nine fields of `PendingOutboundMessage`.** There is no
    /// `status`, no `task`, no `note`, no `body` and no `label`, and adding one is a diff somebody
    /// has to justify. `pending_rows` is the only index and it exists for the sweep, not for a
    /// search: the store is a matching table, so the read is the whole table.
    static let schema = """
        CREATE TABLE outbound (
          id                   INTEGER PRIMARY KEY,
          conversation_id      TEXT NOT NULL,
          chat_guid            TEXT NOT NULL,
          text_digest          BLOB NOT NULL,
          attachment_digests   BLOB NOT NULL,
          dispatched_at        INTEGER NOT NULL,
          matched_row_id       INTEGER,
          matched_message_guid TEXT,
          state                TEXT NOT NULL,
          UNIQUE (chat_guid, text_digest, dispatched_at)
        );
        CREATE INDEX pending_rows ON outbound (state, dispatched_at);
        """

    // MARK: - Row reading and binding

    private static func row(from statement: OpaquePointer) throws -> PendingOutboundMessage {
        guard let state = text(statement, 8), let parsed = OutboundState(rawValue: state) else {
            throw IMessageOutboundStoreError.read("a row carried a state this build does not know")
        }
        let attachments = blob(statement, 4)
        var digests: [Data] = []
        if attachments.count % OutboundLedgerRules.digestByteCount == 0 {
            var index = attachments.startIndex
            while index < attachments.endIndex {
                let end = attachments.index(index, offsetBy: OutboundLedgerRules.digestByteCount)
                digests.append(attachments[index..<end])
                index = end
            }
        }
        return PendingOutboundMessage(
            id: sqlite3_column_int64(statement, 0),
            conversationID: text(statement, 1) ?? "",
            chatGUID: text(statement, 2) ?? "",
            textDigest: blob(statement, 3),
            attachmentDigests: digests,
            dispatchedAt: sqlite3_column_int64(statement, 5),
            matchedRowID: sqlite3_column_type(statement, 6) == SQLITE_NULL
                ? nil : sqlite3_column_int64(statement, 6),
            matchedMessageGUID: text(statement, 7),
            state: parsed)
    }

    /// A digest is 32 bytes or it is not a digest. **A row this could never match is refused at the
    /// boundary**, because storing it would put a row with no identity in a table whose only job
    /// is identity.
    private static func validated(_ digest: Data, named what: String) throws -> Data {
        guard digest.count == OutboundLedgerRules.digestByteCount else {
            throw IMessageOutboundStoreError.notAMatchableRow(
                "a \(what) of \(digest.count) bytes is not a digest")
        }
        return digest
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let text = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw IMessageOutboundStoreError.write(text)
        }
    }

    private static func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw IMessageOutboundStoreError.write(message(db))
        }
        return statement
    }

    private static func int(_ db: OpaquePointer, _ sql: String) throws -> Int {
        let statement = try prepare(db, sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw IMessageOutboundStoreError.write(message(db))
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    /// **Through `withCString`, and the reason is a real trap.** A Swift `String` passed
    /// directly where `UnsafePointer<CChar>` is expected is bridged, and an **empty** string
    /// bridges to a null pointer — so an empty `conversationID` arrived at the column as SQL
    /// `NULL` and the `NOT NULL` constraint rejected it. The three `TEXT` columns are optional in
    /// meaning (a conversation id is IM-11's, and may be empty until IM-11 exists) and never null
    /// in fact, so the binding has to say so itself.
    private static func bind(_ statement: OpaquePointer, text value: String, to index: Int32) throws {
        let status = value.withCString { pointer in
            sqlite3_bind_text(statement, index, pointer, -1, transient)
        }
        guard status == SQLITE_OK else {
            throw IMessageOutboundStoreError.write("binding the text at \(index) failed")
        }
    }

    private static func bind(_ statement: OpaquePointer, blob value: Data, to index: Int32) throws {
        let status = value.withUnsafeBytes { buffer in
            sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), transient)
        }
        guard status == SQLITE_OK else {
            throw IMessageOutboundStoreError.write("binding the blob at \(index) failed")
        }
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let raw = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: raw)
    }

    private static func blob(_ statement: OpaquePointer, _ column: Int32) -> Data {
        guard let raw = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: raw, count: Int(sqlite3_column_bytes(statement, column)))
    }

    private static func message(_ db: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(db))
    }
}

enum IMessageOutboundStoreError: Error, Equatable {
    case open(String)
    case write(String)
    case read(String)
    /// A row that could never be matched, refused rather than stored.
    case notAMatchableRow(String)

    var localizedDescription: String {
        switch self {
        case .open(let why), .write(let why), .read(let why): why
        case .notAMatchableRow(let why): "this send could never be recognised: \(why)"
        }
    }
}

import Foundation
import SQLite3

/// A read-only, capability-probing view of one Apple Messages `chat.db`.
///
/// **Next Notes never writes to this database.** It belongs to Messages, it is
/// TCC-protected, and iCloud syncs parts of it, so there are two separate defences and
/// both are here: `SQLITE_OPEN_READONLY` on the handle, and `PRAGMA query_only = ON` set
/// before any other statement. The pragma is the one that survives a refactor — an open
/// flag is visible in the type of the call, a pragma is a line somebody can delete — so
/// `--selftest-imessage-db` reads it back from a second connection rather than trusting
/// it.
///
/// **The database root is injected, and that is why this runs without a grant.**
/// Production points at `~/Library/Messages/chat.db`; the self-test points at a fixture
/// built in a temporary directory. Nothing here opens anything else, and nothing here
/// reads anything but rows.
///
/// An actor because a watcher will hold this open for the life of the app while the user
/// speaks, and SQLite handles are not safe to use from two places at once. It is one
/// actor rather than a connection pool because there is one database and one watcher.
actor MessagesDatabase {
    /// Why a database could not be read. Never a question about a grant: Full Disk Access
    /// has no read API, and the only honest answer is whether a row came back.
    enum OpenError: Error, Sendable, CustomStringConvertible {
        case unreadable(reason: String)

        var description: String {
            switch self {
            case .unreadable(let reason): "unreadable — \(reason)"
            }
        }
    }

    /// `~/Library/Messages/chat.db`, built from the home directory rather than written
    /// out: `~` is not a spelling anything should be compared against, and the file is
    /// replaced between macOS versions.
    static var defaultDatabase: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Messages/chat.db")
    }

    /// How long SQLite waits for a writer before answering `SQLITE_BUSY`.
    ///
    /// Short, and not a delay in the app's sense: this only elapses while Messages holds
    /// the write lock, and a reader that gave up immediately would report "no new
    /// messages" for a checkpoint that lasts a millisecond. `FULLMUTEX` covers this
    /// connection's own use of itself; this covers the other process.
    static let busyTimeoutMilliseconds: Int32 = 250

    /// The `chat.db` this view was opened on, as the caller spelled it.
    nonisolated let root: URL
    /// `root` through `realpath(3)` — the only spelling that agrees with
    /// `FileManager.enumerator` about `/private`.
    nonisolated let path: String
    /// The probed shape of this database, read once at open.
    nonisolated let schema: MessagesSchema
    /// What this database can answer.
    nonisolated var capabilities: MessagesCapabilities { schema.capabilities }

    private var connection: MessagesConnection?

    /// Opens `root` read-only and probes it.
    ///
    /// - Parameter root: the `chat.db` file. A directory is not accepted and is not
    ///   guessed at: the file is replaced between macOS releases, so a caller that wants
    ///   the current one has to ask for it.
    /// - Throws: `OpenError.unreadable` — the file is not there, this process may not
    ///   read it, or it is not a Messages database. Never a trap and never a crash: the
    ///   probe in IM-04a asks this same question to answer a permission row.
    init(root: URL = MessagesDatabase.defaultDatabase) throws {
        self.root = root
        let resolved = MessagesDatabase.canonicalPath(of: root)
        self.path = resolved
        let opened = try MessagesDatabase.openReadOnly(at: resolved)
        do {
            self.schema = try MessagesSchemaProbe.probe(opened)
        } catch {
            sqlite3_close(opened)
            throw error
        }
        self.connection = MessagesConnection(opened)
    }

    // MARK: - Opening

    /// The one place a connection is opened. Every connection in this file — the actor's
    /// and the self-test's second one — comes through here, which is what lets the
    /// `query_only` case fail the moment the pragma stops being set.
    static func openReadOnly(at path: String) throws -> OpaquePointer {
        var db: OpaquePointer?
        // FULLMUTEX, not NOMUTEX: one connection used from a watcher thread and an actor
        // is the shape that corrupts a SQLite handle. Read-only, and never URI — a `?` in
        // a path is a path here, not a query string.
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            let reason = db.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 failed"
            sqlite3_close(db)
            throw OpenError.unreadable(reason: "\(path): \(reason)")
        }
        sqlite3_busy_timeout(db, busyTimeoutMilliseconds)
        // The first statement, deliberately: the pragma is set before anything else has
        // run on this connection, so there is no window in which a read could be the
        // thing that opens the file a different way.
        if sqlite3_exec(db, "PRAGMA query_only = ON", nil, nil, nil) != SQLITE_OK {
            let reason = String(cString: sqlite3_errmsg(db))
            sqlite3_close(db)
            throw OpenError.unreadable(reason: "query_only was refused: \(reason)")
        }
        return db
    }

    /// `PRAGMA query_only` read **back** from an open connection.
    ///
    /// A getter rather than an echo of the value that was set: `--selftest-imessage-db`
    /// calls it on a second connection it opened itself, so dropping the pragma in
    /// `openReadOnly(at:)` makes that case red rather than making it agree with itself.
    static func queryOnlyFlag(on db: OpaquePointer) throws -> Int? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA query_only", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            let reason = MessagesSchemaProbe.reason(db, "PRAGMA query_only")
            sqlite3_finalize(statement)
            throw OpenError.unreadable(reason: reason)
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int(statement, 0))
    }

    /// The read-only flag on **this** connection, for a caller that wants to be sure
    /// rather than assume.
    func queryOnlyEnabled() throws -> Bool {
        guard let connection else { throw OpenError.unreadable(reason: "the database is closed") }
        return try MessagesDatabase.queryOnlyFlag(on: connection.handle) == 1
    }

    /// A path with every symlink and `..` resolved.
    ///
    /// `realpath(3)`, **not** `URL.resolvingSymlinksInPath()`: the URL version keeps
    /// `/var` where `FileManager.enumerator` reports `/private/var`, so a prefix test
    /// between the two spellings matches nothing and every lookup quietly returns empty —
    /// which reads as "the database is empty" rather than as a bug. The same reason
    /// `FileIndexStore.canonical` and `SkillScanner.canonicalPath` do it this way.
    ///
    /// A path that does not exist yet resolves as far as its deepest real ancestor and
    /// the rest is appended, so `~/Library/Messages/chat.db` still has a canonical form
    /// on a Mac where Messages has never run.
    static func canonicalPath(of url: URL) -> String {
        let expanded = (url.path as NSString).expandingTildeInPath
        var components = (expanded as NSString).pathComponents
        var trailing: [String] = []
        while !components.isEmpty {
            let candidate = NSString.path(withComponents: components)
            if let raw = realpath(candidate, nil) {
                var resolved = String(cString: raw)
                free(raw)
                for part in trailing {
                    resolved = (resolved as NSString).appendingPathComponent(part)
                }
                return resolved
            }
            trailing.insert(components.removeLast(), at: 0)
        }
        return expanded
    }

    /// Releases the connection. A watcher calls this when the feature is switched off;
    /// everything else can let the actor go.
    func close() {
        connection = nil
    }

    // MARK: - The five queries

    /// The highest `message.ROWID` in the database, or 0 when it holds no messages.
    func latestRowID() throws -> Int64 {
        let statement = try prepare(MessagesQueries.latestRowID())
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw stepError(statement, MessagesQueries.latestRowID())
        }
        return sqlite3_column_int64(statement, 0)
    }

    /// Messages with a `ROWID` above `rowID`, oldest first, optionally one chat's.
    ///
    /// - Parameters:
    ///   - rowID: the watermark. 0 is "everything", which is how a first pass reads.
    ///   - chatGUID: one chat, or nil for every chat. The filter is applied only when
    ///     this database has the join table; when it does not, asking for one chat's
    ///     messages would be answering a different question, so it is refused rather
    ///     than answered wrongly.
    func messages(after rowID: Int64 = 0, chatGUID: String? = nil, limit: Int = defaultPage) throws -> [MessageRow] {
        let joined = chatGUID != nil
        if joined, !MessagesQueries.canJoinMessagesToChats(schema) {
            throw OpenError.unreadable(reason: "chat_message_join is missing, so one chat's messages "
                                             + "cannot be told from every chat's")
        }
        let sql = MessagesQueries.messages(schema: schema,
                                            joinedToChat: MessagesQueries.canJoinMessagesToChats(schema),
                                            filteredToChat: joined)
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        var position: Int32 = 1
        sqlite3_bind_int64(statement, position, rowID)
        position += 1
        if let chatGUID {
            // Bound as SQLITE_STATIC, so `pointer` has to outlive the step. It does: the
            // NSString below lives to the end of this function.
            let pointer = (chatGUID as NSString).utf8String
            sqlite3_bind_text(statement, position, pointer, -1, nil)
            position += 1
        }
        sqlite3_bind_int64(statement, position, Int64(max(0, limit)))

        var rows: [MessageRow] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: rows.append(MessagesQueries.messageRow(statement))
            case SQLITE_DONE: return rows
            default: throw stepError(statement, sql)
            }
        }
    }

    /// One message by guid, or nil when this database has no such row.
    func message(guid: String) throws -> MessageRow? {
        let sql = MessagesQueries.message(schema: schema)
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        let pointer = (guid as NSString).utf8String
        sqlite3_bind_text(statement, 1, pointer, -1, nil)
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return MessagesQueries.messageRow(statement)
        case SQLITE_DONE: return nil
        default: throw stepError(statement, sql)
        }
    }

    /// One chat by guid, with its participants, or nil.
    func chat(guid: String) throws -> ChatRow? {
        let sql = MessagesQueries.chat(schema: schema)
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        let pointer = (guid as NSString).utf8String
        sqlite3_bind_text(statement, 1, pointer, -1, nil)
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return MessagesQueries.chatRow(statement)
        case SQLITE_DONE: return nil
        default: throw stepError(statement, sql)
        }
    }

    /// The most recently created chats, newest first.
    func chats(limit: Int = defaultChatPage) throws -> [ChatRow] {
        let sql = MessagesQueries.chats(schema: schema)
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, Int64(max(0, limit)))
        var rows: [ChatRow] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: rows.append(MessagesQueries.chatRow(statement))
            case SQLITE_DONE: return rows
            default: throw stepError(statement, sql)
            }
        }
    }

    /// How many messages one pass reads. Bounded so a first pass over a long history
    /// cannot hold the actor while it walks every row; IM-06 drains it on the next pass.
    static let defaultPage = 200
    /// How many chats the pairing screen asks for.
    static let defaultChatPage = 50

    // MARK: - Plumbing

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let connection else { throw OpenError.unreadable(reason: "the database is closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection.handle, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            let reason = MessagesSchemaProbe.reason(connection.handle, sql)
            sqlite3_finalize(statement)
            throw OpenError.unreadable(reason: reason)
        }
        return statement
    }

    /// A step that was neither a row nor the end. `SQLITE_BUSY` is in here because a
    /// watcher that reports "unreadable" when Messages was halfway through a checkpoint
    /// would turn a millisecond of contention into a stopped feature.
    private func stepError(_ statement: OpaquePointer, _ sql: String) -> OpenError {
        let detail = String(cString: sqlite3_errmsg(sqlite3_db_handle(statement)))
        return .unreadable(reason: "\(sql): \(detail) "
            + "(\(String(cString: sqlite3_errstr(sqlite3_errcode(sqlite3_db_handle(statement))))))")
    }
}


/// One open connection, closed when the last reference to it goes.
///
/// A box rather than a bare `OpaquePointer?` in the actor: an actor's `deinit` may not
/// touch non-`Sendable` stored state, and a watcher that is switched off should not need
/// a second shutdown path in order not to leak a handle. `close()` is that path; the box
/// is what makes forgetting it harmless.
private final class MessagesConnection: @unchecked Sendable {
    let handle: OpaquePointer

    init(_ handle: OpaquePointer) {
        self.handle = handle
    }

    deinit { sqlite3_close(handle) }
}

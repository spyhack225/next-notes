import Foundation
import SQLite3

/// What the watcher learned about a row's attachments, and how long it waited to learn it.
///
/// The cases are answers, not errors. A row with no attachments and a row whose join table
/// is missing are both ordinary: the first is every text command, the second is a database
/// on a macOS release whose schema this does not have, and neither is a reason to stop
/// reading messages.
enum AttachmentResolution: Equatable, Sendable {
    /// The row does not claim attachments, or this database cannot link any.
    case noneNeeded
    /// The join rows were there. `afterRetries` is 0 when the first look found them, which
    /// is the common case and worth knowing about separately from a wait.
    case resolved(afterRetries: Int, attachments: [MessagesAttachment])
    /// The per-message budget ran out with no join row yet. **The message is still
    /// delivered** — a photo that has not finished downloading is not a reason to drop the
    /// sentence somebody typed with it, and blocking here is the "Next stopped responding"
    /// failure this whole design exists to avoid.
    case unresolved(afterRetries: Int)
    /// `message_attachment_join` is not in this database, so there is nothing to wait for.
    /// Distinct from `noneNeeded` because a caller that cares about attachments has to be
    /// able to say "this Mac cannot tell me" rather than "there are none".
    case joinTableAbsent

    /// Whether the attachment list can be trusted as complete.
    var isComplete: Bool {
        switch self {
        case .noneNeeded, .resolved: true
        case .unresolved, .joinTableAbsent: false
        }
    }

    /// What a delivery carries. Empty for every case but `resolved`, so a caller cannot
    /// read a partial list as if it were the whole one — `isComplete` says which it is.
    var attachments: [MessagesAttachment] {
        if case .resolved(_, let found) = self { return found }
        return []
    }
}

/// Waits for a message's `message_attachment_join` rows, **per message**, and gives up on a
/// deadline of its own.
///
/// ## The race this exists for, and why the deadline is per message
///
/// A message row is written before its `message_attachment_join` rows are. A watcher that
/// reads the message, hands it on, and lets a later consumer look the attachments up finds
/// nothing — and "nothing" is indistinguishable from "this message had no attachments",
/// which is how a photo silently becomes a caption with no picture. So the row waits.
///
/// **A single global deadline is the wrong shape**, and this is the reason: with one budget
/// for the whole batch, one slow attachment holds a queue of text commands behind it. The
/// user typed four words and got nothing for two seconds, which is exactly the "Next
/// stopped responding" symptom the predecessor's sleep/wake section promises to avoid, and
/// it is worse than a photo that arrives late because it is *silent*. So the budget here
/// belongs to one message: it is spent on that row alone, and a text command later in the
/// same pass is not behind it at all — `MessagesWatcher` does not await the settle inline,
/// it detaches it, and the self-test asserts that a never-settling row does not delay a
/// later one by a measurable amount.
///
/// ## The numbers, and why they are the two the roadmap gives
///
/// `maxRetries: 8` and `maxElapsed: 2 s` are the same number counted twice: 8 × 250 ms is
/// 2 s exactly, so the retry count and the wall budget cannot drift apart. That is why the
/// interval is the **top** of the roadmap's 100–250 ms band rather than the middle. With a
/// shorter interval the two numbers stop agreeing and one of them has to become a lie;
/// with 250 ms they agree, and the cost is four extra queries on a message whose join rows
/// are genuinely slow, against a message that is otherwise delivered immediately. The
/// count is the harder number — a query on a busy machine costs more than a millisecond of
/// waiting — so it is the one held at the roadmap's value and the interval is what bends.
///
/// **The first look is not a retry.** `probe(row:)` asks once with no sleeping at all, and
/// that answer is what lets a row whose join rows are already there be delivered in row
/// order instead of a pass later.
final class AttachmentJoinResolver: @unchecked Sendable {
    /// The budget, as data rather than as literals at the call site, because a self-test
    /// states a policy and a reader should be able to see it.
    struct Policy: Equatable, Sendable {
        /// How long between refetches. 250 ms: the top of the roadmap's band, and the
        /// value that makes 8 retries and 2 s the same number.
        var retryInterval: Duration = .milliseconds(250)
        /// How many refetches before the message is delivered anyway.
        var maxRetries: Int = 8
        /// The wall-clock ceiling, checked alongside the count so a slow machine cannot
        /// spend eight full intervals if each one overran.
        var maxElapsed: Duration = .seconds(2)
    }

    /// The clock, injected. The one place this feature sleeps, so a test can make two
    /// seconds of settling cost no wall time and assert the *policy* rather than the
    /// machine's speed.
    let clock: MessagesWatcherClock
    let policy: Policy
    /// Whether this database can answer "which attachments is this message's" at all.
    ///
    /// **Asked of this connection, once, at init, and kept** rather than asked again: a missing
    /// join table is a capability the same way a missing `attributedBody` column is, and a query
    /// that named it anyway would be a crash on somebody's live history. The answer comes from
    /// `MessagesQueries.canReadAttachments` over a schema this file probed through
    /// `MessagesSchemaProbe` — the same probe the actor runs, on this connection, so the
    /// capability provably belongs to the connection that will run the query. Eight statements
    /// once, at the moment the watcher is armed, in exchange for not having a second opinion
    /// about the shape of somebody's database.
    let hasJoinTable: Bool

    /// Opened through `MessagesDatabase.openReadOnly`, so this connection carries the same
    /// two defences as the actor's: the read-only open flag and `PRAGMA query_only = ON`.
    /// A second connection is the price of not asking the actor to lend its handle across an
    /// actor boundary; it is not a second policy, and `queryOnlyEnabled()` lets a test say so.
    private let connection: OpaquePointer
    /// The probed shape of **this** connection. Kept so the statement is built from it rather
    /// than from a literal, which is the whole of what "one place a column name is written
    /// down" means in practice.
    private let schema: MessagesSchema
    /// One SQLite handle, and the retry loop's Task and the watcher's pass can both reach
    /// it. `FULLMUTEX` covers the connection's own reentrancy; this covers *which* caller
    /// steps it, so `close()` cannot shut it under a running query.
    private let lock = NSLock()
    private var queryCount = 0
    private var closed = false

    /// - Parameter databasePath: the canonical `chat.db` path — `MessagesDatabase.path`,
    ///   not a URL, because `realpath(3)` has already been applied there and this file
    ///   must not have a second opinion about it.
    /// - Throws: `MessagesDatabase.OpenError.unreadable` when this connection cannot read the
    ///   file, or when it is not a Messages database at all. Both are the same answers the actor
    ///   gives for the same file, and every caller reaches this only after that one succeeded —
    ///   so a throw here is not a new failure mode, it is the same one arriving twice.
    init(databasePath: String, clock: MessagesWatcherClock, policy: Policy = Policy()) throws {
        self.clock = clock
        self.policy = policy
        let opened = try MessagesDatabase.openReadOnly(at: databasePath)
        // Probed before anything is read, and the answer is kept rather than asked again.
        let probed = try MessagesSchemaProbe.probe(opened)
        self.connection = opened
        self.schema = probed
        self.hasJoinTable = MessagesQueries.canReadAttachments(probed)
    }

    deinit { close() }

    /// Releases the handle. The watcher's `stop()` and a feature being switched off both
    /// reach this; a resolver that is only let go is closed by `deinit` instead, so
    /// forgetting it leaks nothing.
    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        sqlite3_close(connection)
    }

    /// `PRAGMA query_only` read back from **this** connection. A probe rather than an
    /// assumption: this is a second connection to a database Next Notes does not own, and
    /// the self-test asserts the pragma here for the same reason IM-04 asserts it on the
    /// actor's.
    func queryOnlyEnabled() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return nil }
        return try? MessagesDatabase.queryOnlyFlag(on: connection)
    }

    /// How many queries have run. The watcher carries this into its statistics, and the
    /// self-test's idle case is a claim about this number not moving.
    var queries: Int {
        lock.lock()
        defer { lock.unlock() }
        return queryCount
    }

    /// One look, with no sleeping: is this row's attachment list complete right now?
    ///
    /// - Returns: `nil` for the one answer that means **come back later** — the row claims
    ///   attachments and none are joined yet. Every other case is final, which is what
    ///   makes the watcher's inline call safe to make without a budget: it either has an
    ///   answer now, or it hands the row to a task that has one.
    func probe(row: MessageRow) -> AttachmentResolution? {
        guard claimsAttachments(row) else { return .noneNeeded }
        guard hasJoinTable else { return .joinTableAbsent }
        let found = readAttachments(messageRowID: row.rowID)
        return found.isEmpty ? nil : .resolved(afterRetries: 0, attachments: found)
    }

    /// Waits for the join rows, up to `policy`, and never longer.
    ///
    /// The retry count in the answer is the number of **waits**, not the number of queries:
    /// the first look costs nothing and is the one `probe(row:)` already made.
    func settle(row: MessageRow) async -> AttachmentResolution {
        guard claimsAttachments(row) else { return .noneNeeded }
        guard hasJoinTable else { return .joinTableAbsent }

        var retries = 0
        var waited: Duration = .zero
        while true {
            let found = readAttachments(messageRowID: row.rowID)
            if !found.isEmpty { return .resolved(afterRetries: retries, attachments: found) }
            if retries >= policy.maxRetries || waited >= policy.maxElapsed {
                return .unresolved(afterRetries: retries)
            }
            await clock.sleep(policy.retryInterval)
            waited += policy.retryInterval
            retries += 1
        }
    }

    /// Whether this row is worth a join query.
    ///
    /// **`false` skips; `nil` looks anyway.** A `nil` here is not "no attachments" — it is
    /// "this database has no `cache_has_attachments` column", which `MessageRow`'s own
    /// header says, and a watcher that read it as `false` would report a photo as a caption
    /// with no picture on exactly the macOS release that dropped the column. One query on a
    /// database without the column is the cheapest possible way to be right.
    private func claimsAttachments(_ row: MessageRow) -> Bool {
        row.cacheHasAttachments != false
    }

    // MARK: - The two tables
    //
    // **Named in `MessagesQueries` and nowhere else, as of 2026-09-26.** This file used to
    // carry its own `PRAGMA table_info` probe, its own six column names, its own two column
    // readers and a comment recording that it was doing so — while `MessagesQueries`' header
    // claimed to be the only place a Messages column name was written down. The claim was
    // almost true, which is the worst kind of almost: a second place for a name fails
    // silently, so the only defence is that there is not one. The statement is now
    // `MessagesQueries.attachments(schema:)`, the reader is
    // `MessagesQueries.attachmentRow(_:)`, and the capability is
    // `MessagesQueries.canReadAttachments(_:)` over a schema probed by `MessagesSchemaProbe`
    // — the same three names the actor uses, and the same per-message deadline on top of them.

    /// The join and its attachments, ordered by the attachment's own `ROWID` so two
    /// refetches of a settled row answer in the same order.
    private func readAttachments(messageRowID: Int64) -> [MessagesAttachment] {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return [] }
        queryCount += 1
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            sqlite3_finalize(statement)
            return []
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, messageRowID)
        var found: [MessagesAttachment] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            found.append(MessagesQueries.attachmentRow(statement))
        }
        return found
    }

    /// Built once rather than per call, and from the probed schema rather than from a literal —
    /// which is the difference between a statement that follows the database and one that
    /// assumes it.
    private var sql: String { MessagesQueries.attachments(schema: schema) }
}

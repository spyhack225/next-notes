import Foundation
import SQLite3

/// What one `chat.db` actually has, resolved once at open.
///
/// `chat.db` is Apple's, is undocumented, and changes between macOS releases. A query
/// that names a column and gets "no such column" is a crash in a watcher on somebody's
/// live Messages history, so the columns are asked for once at open and the answer is
/// carried into every projection. A column that is not there is a **degradation**: the
/// field reads nil and the rest of the row is still a row.
struct MessagesCapabilities: Equatable, Sendable {
    /// `message.thread_originator_guid` — the row this one answers.
    var hasThreadOriginatorGUID = false
    /// `message.associated_message_guid` — a reaction, an edit, a retraction's target.
    var hasAssociatedMessageGUID = false
    /// `message.date_edited`.
    var hasEditMetadata = false
    /// `message.is_retracted`.
    var hasRetractionMetadata = false
    /// `message.is_delivered`.
    var hasDeliveryState = false
    /// `message.attributedBody` — the typedstream, which is the body of an iMessage.
    var hasAttributedBody = false
    /// `message.payload_data`.
    var hasPayloadData = false
    /// `message.balloon_bundle_id` — the extension a non-text balloon came from.
    var hasBalloonBundleID = false
    /// `message.is_sent`.
    var hasIsSent = false
    /// `message.is_audio_message` — a voice note. [IM-05d, 2026-09-26]
    ///
    /// **The tenth, and the only one whose absence changes what a row *is*.** The other nine
    /// answer "can this Mac read this row's …" and a missing column costs a field. This one
    /// answers "can this Mac tell a voice note from a body it failed to read", and a missing
    /// column costs a *classification*: with it, a voice note is a balloon with no words in it
    /// and says so; without it, the same row is a refusal, and the refusal is a thing a person
    /// is shown. That is why it is a capability and not one of the two columns
    /// `MessagesQueries.Column.Presence.column` carries — a reader that has to ask
    /// "is this row audio or is the column simply not there" cannot answer either question
    /// from a `Bool?`.
    var hasAudioMessage = false

    func flag(for capability: MessagesCapability) -> Bool {
        switch capability {
        case .threadOriginatorGUID: hasThreadOriginatorGUID
        case .associatedMessageGUID: hasAssociatedMessageGUID
        case .editMetadata: hasEditMetadata
        case .retractionMetadata: hasRetractionMetadata
        case .deliveryState: hasDeliveryState
        case .attributedBody: hasAttributedBody
        case .payloadData: hasPayloadData
        case .balloonBundleID: hasBalloonBundleID
        case .isSent: hasIsSent
        case .audioMessage: hasAudioMessage
        }
    }
}

/// One probed column, and the capability it stands for.
///
/// The raw name is written down here and in `MessagesQueries` and nowhere else: the probe
/// asks "does this database have this column", and a query asks "is the capability on"
/// before it projects it. A name therefore exists once, and a query cannot project a
/// column the capabilities say is not there.
enum MessagesCapability: String, CaseIterable, Sendable {
    case threadOriginatorGUID
    case associatedMessageGUID
    case editMetadata
    case retractionMetadata
    case deliveryState
    case attributedBody
    case payloadData
    case balloonBundleID
    case isSent
    case audioMessage

    /// The raw column name in `message`.
    var column: String {
        switch self {
        case .threadOriginatorGUID: "thread_originator_guid"
        case .associatedMessageGUID: "associated_message_guid"
        case .editMetadata: "date_edited"
        case .retractionMetadata: "is_retracted"
        case .deliveryState: "is_delivered"
        case .attributedBody: "attributedBody"
        case .payloadData: "payload_data"
        case .balloonBundleID: "balloon_bundle_id"
        case .isSent: "is_sent"
        case .audioMessage: "is_audio_message"
        }
    }

    var keyPath: WritableKeyPath<MessagesCapabilities, Bool> {
        switch self {
        case .threadOriginatorGUID: \.hasThreadOriginatorGUID
        case .associatedMessageGUID: \.hasAssociatedMessageGUID
        case .editMetadata: \.hasEditMetadata
        case .retractionMetadata: \.hasRetractionMetadata
        case .deliveryState: \.hasDeliveryState
        case .attributedBody: \.hasAttributedBody
        case .payloadData: \.hasPayloadData
        case .balloonBundleID: \.hasBalloonBundleID
        case .isSent: \.hasIsSent
        case .audioMessage: \.hasAudioMessage
        }
    }
}

/// The probed shape of one database: every table this task reads, and its columns.
///
/// `capabilities` is the published ten, derived from `message`'s columns, so the answer a
/// caller reads and the answer a query projects cannot drift apart.
struct MessagesSchema: Sendable {
    /// Table name → its column names, for the tables named in `probedTables` only.
    var columns: [String: Set<String>] = [:]

    func has(_ table: String) -> Bool { columns[table] != nil }

    func has(_ table: String, _ column: String) -> Bool { columns[table]?.contains(column) == true }

    /// The identity columns. Without these it is not a database this can read, and the
    /// open says so; everything else is allowed to be missing.
    ///
    /// A strict list on purpose: `display_name` and `text` have been in Apple's schema
    /// since the first release and will outlive us, but refusing to open somebody's
    /// database over a column that is only there to make a list prettier is the wrong
    /// trade, and the probe would rather say "absent" than throw.
    var missingIdentity: [String] {
        [("message", "ROWID"), ("message", "guid"), ("chat", "ROWID"), ("chat", "guid")]
            .filter { !has($0.0, $0.1) }
            .map { "\($0.0).\($0.1)" }
    }

    var capabilities: MessagesCapabilities {
        var result = MessagesCapabilities()
        for capability in MessagesCapability.allCases where has("message", capability.column) {
            result[keyPath: capability.keyPath] = true
        }
        return result
    }
}

/// Reads the shape out of an already-open connection.
enum MessagesSchemaProbe {
    /// The tables and columns this database has.
    ///
    /// - Throws: `.unreadable` when the connection cannot read a single row — a file that
    ///   is not there, or one this process has not been granted. `sqlite3_open_v2`
    ///   *succeeds* for a missing file, so the first real statement is where the truth
    ///   is, and it has to be a statement whose emptiness would be a different answer.
    /// - Throws: `.unreadable` naming the missing identity column when this is not a
    ///   Messages database.
    static func probe(_ db: OpaquePointer) throws -> MessagesSchema {
        // `PRAGMA table_info` on a file that is not there returns an empty list rather
        // than an error, so counting `sqlite_master` first is what separates "not a
        // database" from "a database with no columns".
        _ = try scalars(db, sql: "SELECT count(*) FROM sqlite_master", column: 0)
        var schema = MessagesSchema()
        for table in probedTables {
            schema.columns[table] = Set(try scalars(db, sql: "PRAGMA table_info(\(table))", column: 1))
        }
        if let missing = schema.missingIdentity.first {
            throw MessagesDatabase.OpenError.unreadable(
                reason: "this is not a Messages database: \(missing) is missing")
        }
        return schema
    }

    /// Every table a query in `MessagesQueries` can read. A table that is absent is not an
    /// error; the query that wanted it projects nothing and says so.
    ///
    /// **`message_attachment_join` and `attachment` joined this list on 2026-09-26**, which is
    /// what let `AttachmentJoinResolver` delete its own copy of those two tables' column names.
    /// The resolver had carried them with a comment saying so — `MessagesQueries` said *"this
    /// file is the only place a Messages column name is written down"* while the one exception
    /// was written down somewhere else, and an exception that is *documented* is still an
    /// exception. Five tables then seven, and the last two cost one `PRAGMA` each at open.
    static let probedTables = [
        "message", "chat", "handle",
        "chat_message_join", "chat_handle_join",
        "message_attachment_join", "attachment"
    ]

    /// `PRAGMA table_info` reports `(cid, name, type, notnull, default, pk)`, so the name
    /// is column **1** — reading column 0 answers a question nobody asked.
    private static func scalars(_ db: OpaquePointer, sql: String, column: Int32) throws -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            let reason = reason(db, sql)
            sqlite3_finalize(statement)
            throw MessagesDatabase.OpenError.unreadable(reason: reason)
        }
        defer { sqlite3_finalize(statement) }
        var values: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, column) else {
                values.append("")
                continue
            }
            values.append(String(cString: text))
        }
        return values
    }

    /// What SQLite said, not what this file hoped.
    static func reason(_ db: OpaquePointer, _ context: String) -> String {
        "\(context): \(String(cString: sqlite3_errmsg(db))) "
            + "(\(String(cString: sqlite3_errstr(sqlite3_errcode(db)))))"
    }
}

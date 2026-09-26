import Foundation
import SQLite3

/// One row of `message`, as far as this database lets us read it.
///
/// A `nil` in an optional field means "this database has no such column", not "this
/// message's value was absent" — the two read the same way on purpose, because the only
/// question a caller can act on is whether the *database* can answer at all, and that is
/// `MessagesCapabilities`.
struct MessageRow: Equatable, Sendable {
    /// `message.ROWID` — the watermark IM-06 advances, and an opaque handle here.
    var rowID: Int64 = 0
    /// `message.guid`.
    var guid: String = ""
    /// `message.text`. Routinely NULL for an iMessage; IM-05 decodes the body instead,
    /// which is why a `nil` here is a normal row and not a failure.
    var text: String?
    /// `message.is_from_me`. **A column, not a direction** — IM-08 turns it into one, and
    /// which way it runs is IM-01's answer, not this task's.
    var isFromMe: Bool = false
    /// `message.service`.
    var service: String?
    /// `message.handle_id`: a `handle.ROWID` and nothing more.
    var handleID: Int64?
    /// `message.date`, nanoseconds since 2001-01-01 — Apple's epoch, not Unix.
    var date: Int64?
    /// `message.attributedBody`, the typedstream.
    var attributedBody: Data?
    /// `message.payload_data`.
    var payloadData: Data?
    /// `message.balloon_bundle_id` — the extension a non-text balloon came from.
    var balloonBundleID: String?
    /// `message.is_sent`.
    var isSent: Bool?
    /// `message.is_retracted`.
    var isRetracted: Bool?
    /// `message.date_edited`.
    var dateEdited: Int64?
    /// `message.associated_message_guid` — a reaction's, an edit's or a retraction's target.
    var associatedMessageGUID: String?
    /// `message.thread_originator_guid` — the row this one answers.
    var threadOriginatorGUID: String?
    /// `message.thread_originator_part`.
    var threadOriginatorPart: String?
    /// `message.is_delivered`.
    var isDelivered: Bool?
    /// `message.cache_has_attachments`.
    var cacheHasAttachments: Bool?
}

/// One row of `chat`, with the participants the join tables can name.
struct ChatRow: Equatable, Sendable {
    var rowID: Int64 = 0
    /// `chat.guid`. The paired chat is identified by this and nothing else.
    var guid: String = ""
    /// `chat.chat_identifier`.
    var chatIdentifier: String?
    /// `chat.display_name`.
    var displayName: String?
    /// `chat.service_name`.
    var serviceName: String?
    /// `handle.uncanonicalized_id` for every handle joined to this chat, sorted.
    var participants: [String] = []
}

/// Every statement this task runs against a Messages database, and every raw column name
/// in it.
///
/// **This file is the only place a Messages column name is written down.** A statement is
/// built by asking the probed `MessagesSchema` what this database has, and a column that
/// is not there is projected as `NULL AS <name>` — so the value reads nil and the row is
/// still a row. Nothing outside this file can name a column, which is what keeps
/// "the capability struct drives every query" a fact rather than a habit.
///
/// Raw SQLite rows stop here. What reaches the agent layer is IM-05's `IMessageEnvelope`.
enum MessagesQueries {
    /// One projected column: which table it is in, what SQLite calls it, what the row
    /// field is called, and the rule for whether this database has it.
    struct Column: Sendable {
        enum Table: String, Sendable {
            case message = "m"
            case chat = "c"
            case handle = "h"

            /// The schema key this table is probed under.
            var name: String {
                switch self {
                case .message: "message"
                case .chat: "chat"
                case .handle: "handle"
                }
            }
        }

        /// Why this column is projected, which is also how a query asks whether it can be.
        enum Presence: Sendable {
            /// Without this one it is not a Messages database, and the open says so.
            case identity
            /// Present when the capability it stands for is on.
            case capability(MessagesCapability)
            /// Present when the table has the column. `cache_has_attachments` and
            /// `handle.uncanonicalized_id` are probed but are not one of the nine.
            case column
        }

        let table: Table
        let raw: String
        let alias: String
        let presence: Presence

        init(_ table: Table, _ raw: String, _ alias: String, _ presence: Presence) {
            self.table = table
            self.raw = raw
            self.alias = alias
            self.presence = presence
        }

        func isPresent(in schema: MessagesSchema) -> Bool {
            switch presence {
            case .identity: schema.has(table.name, raw)
            case .capability(let capability): schema.capabilities.flag(for: capability)
            case .column: schema.has(table.name, raw)
            }
        }
    }

    // MARK: - The columns

    /// `message`, in projection order. The nine optional ones are named through
    /// `MessagesCapability` so the name and the flag that governs it cannot disagree.
    static let messageColumns: [Column] = [
        Column(.message, "ROWID", "rowID", .identity),
        Column(.message, "guid", "guid", .identity),
        Column(.message, "text", "text", .column),
        Column(.message, "is_from_me", "isFromMe", .column),
        Column(.message, "service", "service", .column),
        Column(.message, "handle_id", "handleID", .column),
        Column(.message, "date", "date", .column),
        Column(.message, "cache_has_attachments", "cacheHasAttachments", .column),
        Column(.message, MessagesCapability.attributedBody.column, "attributedBody", .capability(.attributedBody)),
        Column(.message, MessagesCapability.payloadData.column, "payloadData", .capability(.payloadData)),
        Column(.message, MessagesCapability.balloonBundleID.column, "balloonBundleID", .capability(.balloonBundleID)),
        Column(.message, MessagesCapability.isSent.column, "isSent", .capability(.isSent)),
        Column(.message, MessagesCapability.retractionMetadata.column, "isRetracted", .capability(.retractionMetadata)),
        Column(.message, MessagesCapability.editMetadata.column, "dateEdited", .capability(.editMetadata)),
        Column(.message, MessagesCapability.deliveryState.column, "isDelivered", .capability(.deliveryState)),
        Column(.message, MessagesCapability.associatedMessageGUID.column, "associatedMessageGUID", .capability(.associatedMessageGUID)),
        Column(.message, MessagesCapability.threadOriginatorGUID.column, "threadOriginatorGUID", .capability(.threadOriginatorGUID)),
        Column(.message, "thread_originator_part", "threadOriginatorPart", .column)
    ]

    /// `chat`, in projection order. `participants` is a correlated subquery rather than a
    /// column, so it is appended by `chatProjection` and read at `participantsPosition`.
    static let chatColumns: [Column] = [
        Column(.chat, "ROWID", "rowID", .identity),
        Column(.chat, "guid", "guid", .identity),
        Column(.chat, "chat_identifier", "chatIdentifier", .column),
        Column(.chat, "display_name", "displayName", .column),
        Column(.chat, "service_name", "serviceName", .column)
    ]

    // MARK: - The statements

    /// The highest `message.ROWID` in the database, or 0 when it is empty.
    ///
    /// IM-06's watermark. `max(ROWID)` and not `max(date)`: a row can arrive out of date
    /// order, and a watermark that skips a late row is a message nobody ever answers.
    static func latestRowID() -> String {
        "SELECT coalesce(max(ROWID), 0) FROM message"
    }

    /// Messages after a watermark, optionally confined to one chat.
    ///
    /// The chat filter is a join rather than a column on `message`, because a row that
    /// belongs to two chats has to be findable in both. `ORDER BY ROWID ASC` is what
    /// makes a replay ordered: a GUID-keyed cache protects against the same row arriving
    /// twice, and the row id is what makes the *order* stable.
    static func messages(schema: MessagesSchema, joinedToChat: Bool, filteredToChat: Bool) -> String {
        guard joinedToChat else {
            return "SELECT \(projection(messageColumns, schema)) FROM message AS m "
                + "WHERE m.ROWID > ? ORDER BY m.ROWID ASC LIMIT ?"
        }
        var sql = "SELECT \(projection(messageColumns, schema)) FROM message AS m "
            + "JOIN chat_message_join AS j ON j.message_rowid = m.ROWID "
            + "JOIN chat AS c ON c.ROWID = j.chat_rowid WHERE m.ROWID > ?"
        if filteredToChat { sql += " AND c.guid = ?" }
        return sql + " ORDER BY m.ROWID ASC LIMIT ?"
    }

    /// Whether `chat_message_join` can answer "which chats is this message in".
    static func canJoinMessagesToChats(_ schema: MessagesSchema) -> Bool {
        schema.has("chat_message_join", "message_rowid") && schema.has("chat_message_join", "chat_rowid")
    }

    /// One message by guid.
    static func message(schema: MessagesSchema) -> String {
        "SELECT \(projection(messageColumns, schema)) FROM message AS m WHERE m.guid = ? LIMIT 1"
    }

    /// One chat by guid, with its participants.
    static func chat(schema: MessagesSchema) -> String {
        "SELECT \(chatProjection(schema)) FROM chat AS c WHERE c.guid = ? LIMIT 1"
    }

    /// The most recently created chats, newest first.
    static func chats(schema: MessagesSchema) -> String {
        "SELECT \(chatProjection(schema)) FROM chat AS c ORDER BY c.ROWID DESC LIMIT ?"
    }

    /// Where `participants` lands in a row: one past every projected chat column.
    ///
    /// Named rather than appended to `chatColumns`, because it is not a column of `chat`
    /// and putting it there would ask the projection for a `c.participants` that does not
    /// exist. The projection appends it and this is the other end of the same contract.
    static let participantsPosition = Int32(chatColumns.count)

    // MARK: - Projection

    /// `m.guid AS guid`, or `NULL AS guid` when this database has no such column.
    static func projection(_ columns: [Column], _ schema: MessagesSchema) -> String {
        columns.map { column in
            column.isPresent(in: schema)
                ? "\(column.table.rawValue).\(column.raw) AS \(column.alias)"
                : "NULL AS \(column.alias)"
        }
        .joined(separator: ", ")
    }

    /// `chat` plus `participants`, which is a join and not a column.
    static func chatProjection(_ schema: MessagesSchema) -> String {
        var parts = [projection(chatColumns, schema)]
        parts.append(participantsPresent(schema) ? participantsSQL : "NULL AS participants")
        return parts.joined(separator: ", ")
    }

    /// Every `handle.uncanonicalized_id` joined to this chat, newline separated.
    ///
    /// Sorted in `chatRow` rather than here: a `group_concat` over an ordered subquery is
    /// an order SQLite does not promise, and IM-09 has to be able to say it resolved the
    /// same addresses twice.
    private static var participantsSQL: String {
        """
        (SELECT group_concat(h.uncanonicalized_id, char(10)) FROM chat_handle_join AS hj \
        JOIN handle AS h ON h.ROWID = hj.handle_rowid WHERE hj.chat_rowid = c.ROWID) AS participants
        """
    }

    static func participantsPresent(_ schema: MessagesSchema) -> Bool {
        schema.has("chat_handle_join", "handle_rowid")
            && schema.has("chat_handle_join", "chat_rowid")
            && schema.has("handle", "ROWID")
            && schema.has("handle", "uncanonicalized_id")
    }

    // MARK: - Decoding

    /// One `message` row, from a statement built out of `messageColumns`.
    static func messageRow(_ statement: OpaquePointer) -> MessageRow {
        var row = MessageRow()
        row.rowID = integer(statement, messageColumns, "rowID") ?? 0
        row.guid = text(statement, messageColumns, "guid") ?? ""
        row.text = text(statement, messageColumns, "text")
        row.isFromMe = flag(statement, messageColumns, "isFromMe") ?? false
        row.service = text(statement, messageColumns, "service")
        row.handleID = integer(statement, messageColumns, "handleID")
        row.date = integer(statement, messageColumns, "date")
        row.attributedBody = data(statement, messageColumns, "attributedBody")
        row.payloadData = data(statement, messageColumns, "payloadData")
        row.balloonBundleID = text(statement, messageColumns, "balloonBundleID")
        row.isSent = flag(statement, messageColumns, "isSent")
        row.isRetracted = flag(statement, messageColumns, "isRetracted")
        row.dateEdited = integer(statement, messageColumns, "dateEdited")
        row.associatedMessageGUID = text(statement, messageColumns, "associatedMessageGUID")
        row.threadOriginatorGUID = text(statement, messageColumns, "threadOriginatorGUID")
        row.threadOriginatorPart = text(statement, messageColumns, "threadOriginatorPart")
        row.isDelivered = flag(statement, messageColumns, "isDelivered")
        row.cacheHasAttachments = flag(statement, messageColumns, "cacheHasAttachments")
        return row
    }

    /// One `chat` row, from a statement built out of `chatColumns` plus `participants`.
    static func chatRow(_ statement: OpaquePointer) -> ChatRow {
        var row = ChatRow()
        row.rowID = integer(statement, chatColumns, "rowID") ?? 0
        row.guid = text(statement, chatColumns, "guid") ?? ""
        row.chatIdentifier = text(statement, chatColumns, "chatIdentifier")
        row.displayName = text(statement, chatColumns, "displayName")
        row.serviceName = text(statement, chatColumns, "serviceName")
        let joined = joinedText(statement) ?? ""
        row.participants = joined
            .split(separator: "\n")
            .map { String($0) }
            .filter { !$0.isEmpty }
            .sorted()
        return row
    }

    // MARK: - Column readers
    //
    // A column that was projected as `NULL` and a column the row itself holds as NULL
    // read the same way. That is deliberate: a watcher can act on "the database cannot
    // answer this", which is `MessagesCapabilities`, and must not also have to reason
    // about "this particular message has no value here".

    private static func index(of alias: String, in columns: [Column]) -> Int32? {
        guard let position = columns.firstIndex(where: { $0.alias == alias }) else { return nil }
        return Int32(position)
    }

    static func text(_ statement: OpaquePointer, _ columns: [Column], _ alias: String) -> String? {
        guard let column = index(of: alias, in: columns),
              let value = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: value)
    }

    static func integer(_ statement: OpaquePointer, _ columns: [Column], _ alias: String) -> Int64? {
        guard let column = index(of: alias, in: columns) else { return nil }
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(statement, column)
    }

    /// A SQLite integer as a flag. Anything non-zero is true, which is what the `DEFAULT
    /// 0` columns and Apple's own `is_*` columns mean.
    static func flag(_ statement: OpaquePointer, _ columns: [Column], _ alias: String) -> Bool? {
        integer(statement, columns, alias).map { $0 != 0 }
    }

    /// The `participants` subquery's value, newline separated by `group_concat`.
    static func joinedText(_ statement: OpaquePointer) -> String? {
        guard let value = sqlite3_column_text(statement, participantsPosition) else { return nil }
        return String(cString: value)
    }

    static func data(_ statement: OpaquePointer, _ columns: [Column], _ alias: String) -> Data? {
        guard let column = index(of: alias, in: columns) else { return nil }
        let length = Int(sqlite3_column_bytes(statement, column))
        guard length > 0, let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: bytes, count: length)
    }
}

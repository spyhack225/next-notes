import Foundation
import SQLite3

/// IM-14 — attachment rows for one message, and nothing else.
///
/// The statement already existed (`MessagesQueries.attachments`); this is the
/// accessor that runs it. A database that cannot answer (the join tables absent)
/// throws rather than answering empty: an empty answer would read as "no
/// attachments" and the copier would report success having copied nothing.
enum MessagesAttachmentReader {
    /// Every attachment joined to one `message.ROWID`, ordered by the
    /// attachment's own `ROWID`.
    static func attachments(for messageRowID: Int64, in database: MessagesDatabase) async throws -> [MessagesAttachment] {
        try await database.attachmentRows(messageRowID: messageRowID)
    }
}

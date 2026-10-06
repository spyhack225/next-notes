import Foundation
import SQLite3

/// A read-only view of Apple Mail's own index, for the Google account the Mac already holds.
///
/// **Next Notes never writes to this database.** It belongs to Mail. It is opened through
/// `MessagesDatabase.openReadOnly` — the one place a connection to somebody else's SQLite file
/// is opened, with `SQLITE_OPEN_READONLY` and `PRAGMA query_only` set first — so the second
/// defence is the same one the iMessage reader has and `--selftest-mac-accounts` reads it back
/// from a second connection. Full Disk Access is the grant that opens it; it is the same one
/// the Messages reader needs, so one grant covers both.
///
/// **Only Google's mailboxes are ever asked.** The person said "my Google account"; a search
/// over their iCloud or work mail would answer a different question and put somebody else's
/// mail in a prompt. A Google account is recognised by its `[Gmail]` folders (or the host in an
/// older-style mailbox address); the INBOX, Sent and Drafts of those accounts are the only
/// mailboxes a query names.
///
/// **What is measured and what is not.** The column names below are Mail's own on the macOS
/// versions this was written against, and they are probed at open rather than assumed: a
/// missing optional column degrades the answer (no preview, no unread flag) and a missing
/// required one refuses with a plain sentence. `--selftest-mac-accounts` builds its fixture
/// with these names, so it proves the reader's logic, not that Mail still spells them so;
/// `--selftest-mac-accounts-live` is the check against a real index and has not been run.
actor MailDatabase {
    /// Whether this process can read Mail's index at all.
    enum Access: Equatable, Sendable {
        case readable
        /// The index is there and this process was refused it: Full Disk Access is off.
        case needsFullDiskAccess
        /// There is no Mail data on this Mac.
        case noMailData
        case unreadable(String)
    }

    /// Where Mail's data lives: `~/Library/Mail`, built from the home directory.
    static var defaultMailRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mail")
    }

    /// The highest `V<n>/MailData/Envelope Index` under `mailRoot`, or why there is none.
    static func locateIndex(mailRoot: URL) -> (versionRoot: URL?, access: Access) {
        let fileManager = FileManager.default
        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(atPath: mailRoot.path)
        } catch {
            return (nil, classify(error))
        }
        let versions = names.compactMap { name -> (Int, String)? in
            guard name.hasPrefix("V"), let number = Int(name.dropFirst()) else { return nil }
            return (number, name)
        }.sorted { $0.0 > $1.0 }
        for (_, name) in versions {
            let root = mailRoot.appendingPathComponent(name, isDirectory: true)
            let index = root.appendingPathComponent("MailData/Envelope Index")
            let descriptor = open(index.path, O_RDONLY)
            if descriptor >= 0 {
                close(descriptor)
                return (root, .readable)
            }
            if errno == EPERM || errno == EACCES { return (nil, .needsFullDiskAccess) }
        }
        return (nil, .noMailData)
    }

    /// Cheap and read-only: finds the index and opens it once. For the Settings row and the
    /// account check, never for a tool call.
    static func probe(mailRoot: URL = defaultMailRoot) -> Access {
        let found = locateIndex(mailRoot: mailRoot)
        guard let root = found.versionRoot else { return found.access }
        do {
            let handle = try MessagesDatabase.openReadOnly(at: indexPath(in: root))
            sqlite3_close(handle)
            return .readable
        } catch {
            return .unreadable(String(describing: error))
        }
    }

    private static func classify(_ error: Error) -> Access {
        let ns = error as NSError
        let posix = (ns.userInfo[NSUnderlyingErrorKey] as? NSError)?.code
        if ns.code == NSFileReadNoPermissionError || posix == Int(EPERM) || posix == Int(EACCES) {
            return .needsFullDiskAccess
        }
        if ns.code == NSFileReadNoSuchFileError || ns.code == NSFileNoSuchFileError || posix == Int(ENOENT) {
            return .noMailData
        }
        return .unreadable(ns.localizedDescription)
    }

    private static func indexPath(in versionRoot: URL) -> String {
        MessagesDatabase.canonicalPath(of: versionRoot.appendingPathComponent("MailData/Envelope Index"))
    }

    // MARK: - Shape

    /// A mailbox row, with the account it belongs to read out of its address.
    struct Mailbox: Sendable, Equatable {
        enum Kind: Sendable, Equatable { case inbox, sent, drafts, other }
        let rowID: Int64
        /// What stands where the account is in the mailbox address: a UUID, or `user@imap.gmail.com`.
        let account: String
        /// The folder, percent-decoded: `INBOX`, `[Gmail]/Sent Mail`.
        let path: String
        let isGoogleAccount: Bool
        var kind: Kind { Self.kind(ofPath: path) }

        static func kind(ofPath path: String) -> Kind {
            let lower = path.lowercased()
            if lower == "inbox" { return .inbox }
            let leaf = lower.split(separator: "/").last.map(String.init) ?? lower
            if lower.hasPrefix("[gmail]/") || lower.hasPrefix("[google mail]/") {
                if ["sent mail", "gesendet", "envoy\u{e9}s", "enviados", "inviata", "verzonden"].contains(leaf) { return .sent }
                if ["drafts", "entw\u{fc}rfe", "brouillons", "borradores", "bozze", "concepten"].contains(leaf) { return .drafts }
            }
            return .other
        }
    }

    /// What the probed index can answer.
    struct Layout: Sendable, Equatable {
        var hasRead = false
        var hasDeleted = false
        var hasSummary = false
        var hasComment = false
    }

    nonisolated let versionRoot: URL
    nonisolated let layout: Layout
    private let connection: MailConnection

    /// Opens the index read-only and probes it.
    init(mailRoot: URL = MailDatabase.defaultMailRoot) throws {
        let found = Self.locateIndex(mailRoot: mailRoot)
        guard let root = found.versionRoot else {
            switch found.access {
            case .needsFullDiskAccess: throw MacWorkspaceError.needsFullDiskAccess
            case .noMailData: throw MacWorkspaceError.noMailAccount
            case .readable: throw MacWorkspaceError.noMailAccount
            case .unreadable(let reason): throw MacWorkspaceError.cannotRead(reason)
            }
        }
        let handle: OpaquePointer
        do {
            handle = try MessagesDatabase.openReadOnly(at: Self.indexPath(in: root))
        } catch {
            throw MacWorkspaceError.cannotRead("Mail\u{2019}s index wouldn\u{2019}t open.")
        }
        do {
            layout = try Self.probeLayout(handle)
        } catch {
            sqlite3_close(handle)
            throw error
        }
        versionRoot = root
        connection = MailConnection(handle)
    }

    /// The columns every answer needs, and the ones it can do without.
    private static func probeLayout(_ db: OpaquePointer) throws -> Layout {
        func columns(_ table: String) -> Set<String> {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(statement) }
            var names: Set<String> = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let text = sqlite3_column_text(statement, 1) { names.insert(String(cString: text)) }
            }
            return names
        }
        let messages = columns("messages"), mailboxes = columns("mailboxes")
        let addresses = columns("addresses"), subjects = columns("subjects"), summaries = columns("summaries")
        let required: [(Set<String>, [String])] = [
            (messages, ["ROWID", "mailbox", "sender", "subject", "date_received"]),
            (mailboxes, ["ROWID", "url"]), (addresses, ["ROWID", "address"]), (subjects, ["ROWID", "subject"]),
        ]
        for (present, wanted) in required where !Set(wanted).isSubset(of: present) {
            throw MacWorkspaceError.cannotRead("Mail\u{2019}s data has a shape Next Notes doesn\u{2019}t know yet.")
        }
        return Layout(
            hasRead: messages.contains("read"),
            hasDeleted: messages.contains("deleted"),
            hasSummary: messages.contains("summary") && summaries.isSuperset(of: ["ROWID", "summary"]),
            hasComment: addresses.contains("comment"))
    }

    // MARK: - Mailboxes

    /// Every mailbox, with Google accounts marked. A handful of rows, read on each call so a
    /// newly added account is seen without a restart.
    func mailboxes() throws -> [Mailbox] {
        let statement = try prepare("SELECT ROWID, url FROM mailboxes")
        defer { sqlite3_finalize(statement) }
        var parsed: [(Int64, String, String)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let url = sqlite3_column_text(statement, 1) else { continue }
            let (account, path) = Self.split(url: String(cString: url))
            parsed.append((sqlite3_column_int64(statement, 0), account, path))
        }
        let googleAccounts = Set(parsed.filter { Self.looksGoogle(account: $0.1, path: $0.2) }.map(\.1))
        return parsed.map { Mailbox(rowID: $0.0, account: $0.1, path: $0.2, isGoogleAccount: googleAccounts.contains($0.1)) }
    }

    /// `imap://UUID/%5BGmail%5D/Sent%20Mail` into (`UUID`, `[Gmail]/Sent Mail`).
    static func split(url: String) -> (account: String, path: String) {
        var rest = Substring(url)
        if let scheme = rest.range(of: "://") { rest = rest[scheme.upperBound...] }
        guard let slash = rest.firstIndex(of: "/") else { return (String(rest), "") }
        let account = String(rest[..<slash])
        let path = String(rest[rest.index(after: slash)...])
        return (account, path.removingPercentEncoding ?? path)
    }

    static func looksGoogle(account: String, path: String) -> Bool {
        let lowerAccount = account.lowercased(), lowerPath = path.lowercased()
        return lowerPath.hasPrefix("[gmail]") || lowerPath.hasPrefix("[google mail]")
            || lowerAccount.contains("imap.gmail.com") || lowerAccount.contains("googlemail.com")
    }

    /// Whether Mail holds a Google account at all.
    func hasGoogleAccount() throws -> Bool {
        try mailboxes().contains { $0.isGoogleAccount }
    }

    // MARK: - Search

    func search(_ query: MacMailQuery) throws -> [MacMailSummary] {
        let all = try mailboxes().filter(\.isGoogleAccount)
        guard !all.isEmpty else { throw MacWorkspaceError.noMailAccount }
        let wanted: Mailbox.Kind = switch query.folder {
        case .inbox: .inbox
        case .sent: .sent
        case .drafts: .drafts
        }
        let ids = all.filter { $0.kind == wanted }.map(\.rowID)
        guard !ids.isEmpty else { return [] }
        if query.unreadOnly, !layout.hasRead { throw MacWorkspaceError.unsupportedSearch("\u{201c}is:unread\u{201d}") }

        var binds: [Bind] = []
        // The ids come from this database as integers, never from the caller, so they are
        // written into the statement rather than bound.
        var sql = """
            SELECT m.ROWID, a.address, \(layout.hasComment ? "a.comment" : "NULL"), s.subject, m.date_received, \
            \(layout.hasRead ? "m.read" : "NULL"), \(layout.hasSummary ? "sm.summary" : "NULL")
            FROM messages m
            LEFT JOIN addresses a ON a.ROWID = m.sender
            LEFT JOIN subjects s ON s.ROWID = m.subject
            \(layout.hasSummary ? "LEFT JOIN summaries sm ON sm.ROWID = m.summary" : "")
            WHERE m.mailbox IN (\(ids.map(String.init).joined(separator: ",")))
            """
        if layout.hasDeleted { sql += " AND m.deleted = 0" }
        if query.unreadOnly { sql += " AND m.read = 0" }
        for term in query.from {
            let pattern = Self.pattern(term)
            sql += layout.hasComment
                ? " AND (LOWER(a.address) LIKE ? ESCAPE '\\' OR LOWER(a.comment) LIKE ? ESCAPE '\\')"
                : " AND LOWER(a.address) LIKE ? ESCAPE '\\'"
            binds.append(.text(pattern)); if layout.hasComment { binds.append(.text(pattern)) }
        }
        for term in query.subject {
            sql += " AND LOWER(s.subject) LIKE ? ESCAPE '\\'"
            binds.append(.text(Self.pattern(term)))
        }
        for term in query.text {
            let pattern = Self.pattern(term)
            var clauses = ["LOWER(a.address) LIKE ? ESCAPE '\\'", "LOWER(s.subject) LIKE ? ESCAPE '\\'"]
            binds.append(.text(pattern)); binds.append(.text(pattern))
            if layout.hasComment { clauses.append("LOWER(a.comment) LIKE ? ESCAPE '\\'"); binds.append(.text(pattern)) }
            if layout.hasSummary { clauses.append("LOWER(sm.summary) LIKE ? ESCAPE '\\'"); binds.append(.text(pattern)) }
            sql += " AND (" + clauses.joined(separator: " OR ") + ")"
        }
        if let after = query.after { sql += " AND m.date_received >= ?"; binds.append(.real(after.timeIntervalSince1970)) }
        if let before = query.before { sql += " AND m.date_received < ?"; binds.append(.real(before.timeIntervalSince1970)) }
        sql += " ORDER BY m.date_received DESC LIMIT ?"
        binds.append(.int(Int64(max(1, min(query.limit, 100)))))

        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(binds, to: statement)
        var rows: [MacMailSummary] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            guard status == SQLITE_ROW else { throw MacWorkspaceError.cannotRead("Mail was busy. Try again in a moment.") }
            let received = sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil
                : Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
            rows.append(MacMailSummary(
                ref: "mac-\(sqlite3_column_int64(statement, 0))",
                from: Self.sender(address: text(statement, 1), name: text(statement, 2)),
                subject: text(statement, 3) ?? "(no subject)",
                date: received,
                snippet: text(statement, 6) ?? "",
                isUnread: layout.hasRead ? sqlite3_column_int(statement, 5) == 0 : false))
        }
        return rows
    }

    /// One message in full: its headers from the index and its text from the `.emlx` Mail
    /// stored. Bounded; a message whose body Mail has not downloaded says so.
    func read(ref: String) throws -> MacMailMessage {
        guard ref.hasPrefix("mac-"), let rowID = Int64(ref.dropFirst(4)) else { throw MacWorkspaceError.messageNotFound }
        let statement = try prepare("""
            SELECT a.address, \(layout.hasComment ? "a.comment" : "NULL"), s.subject, m.date_received, mb.url
            FROM messages m
            JOIN mailboxes mb ON mb.ROWID = m.mailbox
            LEFT JOIN addresses a ON a.ROWID = m.sender
            LEFT JOIN subjects s ON s.ROWID = m.subject
            WHERE m.ROWID = ?
            """)
        defer { sqlite3_finalize(statement) }
        try bind([.int(rowID)], to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW, let url = text(statement, 4) else { throw MacWorkspaceError.messageNotFound }
        let (account, path) = Self.split(url: url)
        // A message in somebody else's mailbox is not this person's Google mail, whatever its number.
        let isGoogle = try mailboxes().contains { $0.account == account && $0.isGoogleAccount }
        guard isGoogle || Self.looksGoogle(account: account, path: path) else { throw MacWorkspaceError.messageNotFound }
        let received = sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil
            : Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
        let body: String? = Self.emlxURL(versionRoot: versionRoot, account: account, path: path, rowID: rowID)
            .flatMap { EmlxParser.bodyText(of: $0) }
        return MacMailMessage(
            from: Self.sender(address: text(statement, 0), name: text(statement, 1)),
            date: received,
            subject: text(statement, 2) ?? "(no subject)",
            body: body ?? "",
            bodyIsAvailable: !(body ?? "").isEmpty)
    }

    /// The mailbox name and number a reply needs, as Mail's scripting names them.
    func replyTarget(ref: String) throws -> (mailbox: String, id: Int64) {
        guard ref.hasPrefix("mac-"), let rowID = Int64(ref.dropFirst(4)) else { throw MacWorkspaceError.messageNotFound }
        let statement = try prepare("SELECT mb.url FROM messages m JOIN mailboxes mb ON mb.ROWID = m.mailbox WHERE m.ROWID = ?")
        defer { sqlite3_finalize(statement) }
        try bind([.int(rowID)], to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW, let url = text(statement, 0) else { throw MacWorkspaceError.messageNotFound }
        let (account, path) = Self.split(url: url)
        guard try mailboxes().contains(where: { $0.account == account && $0.isGoogleAccount }) else { throw MacWorkspaceError.messageNotFound }
        return (path, rowID)
    }

    /// "Is it there?": a message in this folder whose subject is exactly this, received since
    /// `since` (with a minute's slack for the clocks); an empty subject means any message. Loose by design — the caller says "looks
    /// like it went out", never "it did".
    func containsMessage(subject: String, folder: MacMailQuery.Folder, since: Date) throws -> Bool {
        var query = MacMailQuery()
        query.folder = folder
        let wanted = subject.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !wanted.isEmpty { query.subject = [wanted] }
        query.after = since.addingTimeInterval(-60)
        query.limit = 25
        let found = try search(query)
        // An empty subject (a reply, whose subject Mail writes) matches any message since then.
        return wanted.isEmpty ? !found.isEmpty : found.contains {
            $0.subject.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == wanted
        }
    }

    // MARK: - Files

    /// Where Mail keeps one message's text. Its layout is
    /// `<account>/<folder>.mbox/<store>/Data/<digits>/Messages/<rowid>.emlx`, with the digits
    /// of the thousands of the number, reversed, one folder each. The computed place is tried
    /// first; a bounded search of the mailbox answers when the layout is not what this expects.
    static func emlxURL(versionRoot: URL, account: String, path: String, rowID: Int64) -> URL? {
        let fileManager = FileManager.default
        var box = versionRoot.appendingPathComponent(account, isDirectory: true)
        for part in path.split(separator: "/") { box.appendPathComponent(String(part) + ".mbox", isDirectory: true) }
        guard let stores = try? fileManager.contentsOfDirectory(atPath: box.path) else { return nil }
        let digits: [String] = rowID >= 1_000 ? String(rowID / 1_000).reversed().map { String($0) } : []
        let names = ["\(rowID).emlx", "\(rowID).partial.emlx"]
        for store in stores where !store.hasSuffix(".mbox") && !store.hasPrefix(".") {
            var directory = box.appendingPathComponent(store, isDirectory: true).appendingPathComponent("Data", isDirectory: true)
            for digit in digits { directory.appendPathComponent(digit, isDirectory: true) }
            directory.appendPathComponent("Messages", isDirectory: true)
            for name in names {
                let candidate = directory.appendingPathComponent(name)
                if fileManager.fileExists(atPath: candidate.path) { return candidate }
            }
        }
        // The layout is not the one above. Look for the file, a bounded number of entries deep.
        guard let walker = fileManager.enumerator(at: box, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
        var visited = 0
        for case let url as URL in walker {
            visited += 1
            if visited > 20_000 { break }
            if names.contains(url.lastPathComponent) { return url }
        }
        return nil
    }

    // MARK: - SQLite

    private enum Bind { case int(Int64), real(Double), text(String) }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection.handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            sqlite3_finalize(statement)
            throw MacWorkspaceError.cannotRead("Mail\u{2019}s data has a shape Next Notes doesn\u{2019}t know yet.")
        }
        return statement
    }

    private func bind(_ values: [Bind], to statement: OpaquePointer) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32 = switch value {
            case .int(let number): sqlite3_bind_int64(statement, index, number)
            case .real(let number): sqlite3_bind_double(statement, index, number)
            case .text(let string): sqlite3_bind_text(statement, index, string, -1, transient)
            }
            guard status == SQLITE_OK else { throw MacWorkspaceError.cannotRead("Mail\u{2019}s data couldn\u{2019}t be searched.") }
        }
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL, let raw = sqlite3_column_text(statement, column) else { return nil }
        let value = String(cString: raw)
        return value.isEmpty ? nil : value
    }

    /// `%term%` lower-cased, with LIKE's own characters escaped so a search for `50%` means 50%.
    private static func pattern(_ term: String) -> String {
        let escaped = term.lowercased()
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return "%" + escaped + "%"
    }

    private static func sender(address: String?, name: String?) -> String {
        switch (name, address) {
        case let (name?, address?) where name.lowercased() != address.lowercased(): "\(name) <\(address)>"
        case let (_, address?): address
        case let (name?, nil): name
        default: "unknown sender"
        }
    }
}

/// Closes the handle when the actor goes, so a switched-off feature cannot leak it.
private final class MailConnection: @unchecked Sendable {
    let handle: OpaquePointer
    init(_ handle: OpaquePointer) { self.handle = handle }
    deinit { sqlite3_close(handle) }
}

// MARK: - The message file

/// Reads the text out of one `.emlx`: a byte count, the message, then a property list.
///
/// Bounded in every direction — the file is read up to four megabytes, a multipart message is
/// walked to a depth of five, and the text returned is cut at twenty thousand characters —
/// because a hostile or enormous message must cost a read, not the app. Only text is returned:
/// attachments are skipped, and an HTML-only message is reduced to its words.
enum EmlxParser {
    static let maxFileBytes = 4 * 1_024 * 1_024
    static let maxCharacters = 20_000

    static func bodyText(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxFileBytes), !data.isEmpty else { return nil }
        return bodyText(fromEmlx: data)
    }

    static func bodyText(fromEmlx data: Data) -> String? {
        var message = data
        // The first line is the length of the message that follows it.
        if let newline = data.firstIndex(of: 0x0A),
           let count = Int(String(decoding: data[data.startIndex..<newline], as: UTF8.self).trimmingCharacters(in: .whitespaces)),
           count > 0 {
            let start = data.index(after: newline)
            let end = data.index(start, offsetBy: min(count, data.distance(from: start, to: data.endIndex)))
            message = data[start..<end]
        }
        let text = text(of: Data(message), depth: 0)
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxCharacters))
    }

    private struct Part {
        var headers: [String: String]
        var body: Data
    }

    private static func parse(_ data: Data) -> Part {
        let separators: [[UInt8]] = [[0x0D, 0x0A, 0x0D, 0x0A], [0x0A, 0x0A]]
        var split: (Range<Int>)?
        let bytes = [UInt8](data)
        for separator in separators {
            if let at = find(separator, in: bytes) { split = at..<(at + separator.count); break }
        }
        let headerBytes = split.map { Array(bytes[0..<$0.lowerBound]) } ?? bytes
        let body = split.map { Data(bytes[$0.upperBound...]) } ?? Data()
        var headers: [String: String] = [:]
        var current: String?
        for rawLine in String(decoding: headerBytes, as: UTF8.self).components(separatedBy: .newlines) {
            if rawLine.first == " " || rawLine.first == "\t" {
                if let current { headers[current, default: ""] += " " + rawLine.trimmingCharacters(in: .whitespaces) }
            } else if let colon = rawLine.firstIndex(of: ":") {
                let name = rawLine[..<colon].lowercased()
                if headers[name] == nil {
                    current = name
                    headers[name] = rawLine[rawLine.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                } else { current = nil }
            }
        }
        return Part(headers: headers, body: body)
    }

    private static func find(_ needle: [UInt8], in bytes: [UInt8]) -> Int? {
        guard !needle.isEmpty, bytes.count >= needle.count else { return nil }
        for index in 0...(bytes.count - needle.count) where bytes[index] == needle[0] {
            if Array(bytes[index..<(index + needle.count)]) == needle { return index }
        }
        return nil
    }

    private static func text(of data: Data, depth: Int) -> String? {
        let part = parse(data)
        let type = (part.headers["content-type"] ?? "text/plain").lowercased()
        if (part.headers["content-disposition"] ?? "").lowercased().hasPrefix("attachment") { return nil }
        if type.hasPrefix("multipart/"), depth < 5, let boundary = parameter("boundary", in: part.headers["content-type"] ?? "") {
            let pieces = String(decoding: part.body, as: UTF8.self).components(separatedBy: "--" + boundary)
            var plain: String?, html: String?
            for piece in pieces.dropFirst() {
                let trimmed = piece.hasPrefix("--") ? "" : piece
                guard !trimmed.isEmpty else { continue }
                let inner = Data(trimmed.drop(while: { $0 == "\r" || $0 == "\n" }).utf8)
                let childType = (parse(inner).headers["content-type"] ?? "text/plain").lowercased()
                guard let found = text(of: inner, depth: depth + 1), !found.isEmpty else { continue }
                if childType.hasPrefix("text/html") { html = html ?? found }
                else if plain == nil { plain = found }
            }
            return plain ?? html
        }
        guard type.hasPrefix("text/") else { return nil }
        let decoded = decode(part.body, encoding: (part.headers["content-transfer-encoding"] ?? "").lowercased())
        let string = string(from: decoded, charset: parameter("charset", in: part.headers["content-type"] ?? ""))
        return type.hasPrefix("text/html") ? stripHTML(string) : string
    }

    private static func parameter(_ name: String, in header: String) -> String? {
        for piece in header.split(separator: ";").dropFirst() {
            let pair = piece.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2, pair[0].lowercased() == name {
                return pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return nil
    }

    private static func decode(_ body: Data, encoding: String) -> Data {
        switch encoding {
        case "base64":
            let text = String(decoding: body, as: UTF8.self).components(separatedBy: .whitespacesAndNewlines).joined()
            return Data(base64Encoded: text, options: [.ignoreUnknownCharacters]) ?? body
        case "quoted-printable":
            var out = Data()
            let bytes = [UInt8](body)
            var index = 0
            while index < bytes.count {
                if bytes[index] == 0x3D {
                    if index + 1 < bytes.count, bytes[index + 1] == 0x0A { index += 2; continue }
                    if index + 2 < bytes.count, bytes[index + 1] == 0x0D, bytes[index + 2] == 0x0A { index += 3; continue }
                    if index + 2 < bytes.count,
                       let value = UInt8(String(decoding: bytes[(index + 1)...(index + 2)], as: UTF8.self), radix: 16) {
                        out.append(value); index += 3; continue
                    }
                }
                out.append(bytes[index]); index += 1
            }
            return out
        default:
            return body
        }
    }

    private static func string(from data: Data, charset: String?) -> String {
        if let charset {
            let cf = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            if cf != kCFStringEncodingInvalidId {
                let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
                if let decoded = String(data: data, encoding: encoding) { return decoded }
            }
        }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    static func stripHTML(_ html: String) -> String {
        var text = html
        for pattern in ["<script[\\s\\S]*?</script>", "<style[\\s\\S]*?</style>"] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(of: "<(br|/p|/div|/li|/tr)[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (entity, value) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'")] {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        let lines = text.components(separatedBy: "\n").map {
            $0.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        }
        return lines.filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

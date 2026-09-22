import Foundation
import SQLite3
import UniformTypeIdentifiers

/// One row of the file tree: names and metadata only, never contents.
struct FileRecord: Equatable, Sendable {
    var path: String
    /// The containing directory's path. Nil only for an indexed root.
    var parent: String?
    var name: String
    var isDirectory: Bool
    /// The UTType identifier, e.g. `com.adobe.pdf`. Nil when macOS has no answer.
    var kind: String?
    /// A handful of plain-language buckets a person (or a small model) can filter by.
    var category: FileCategory
    var size: Int64?
    var createdAt: Int64?
    var modifiedAt: Int64?
    /// Last access date — the closest thing macOS exposes to "last opened" without Spotlight.
    var accessedAt: Int64?
    /// 0 for the indexed folder itself, 1 for its children, and so on.
    var depth: Int
}

/// What a file is, in words the rest of the app (and the agent) can use.
enum FileCategory: String, CaseIterable, Sendable {
    case folder, document, spreadsheet, presentation, pdf, image, video, audio, archive, code, other

    var title: String {
        switch self {
        case .folder: "Folders"
        case .document: "Documents"
        case .spreadsheet: "Spreadsheets"
        case .presentation: "Presentations"
        case .pdf: "PDFs"
        case .image: "Images"
        case .video: "Videos"
        case .audio: "Audio"
        case .archive: "Archives"
        case .code: "Code"
        case .other: "Other files"
        }
    }

    /// The SF Symbol a row shows. One per bucket, so a list of files reads at a glance
    /// rather than as eleven identical pages.
    var symbol: String {
        switch self {
        case .folder: "folder"
        case .document: "doc.text"
        case .spreadsheet: "tablecells"
        case .presentation: "rectangle.on.rectangle"
        case .pdf: "doc.richtext"
        case .image: "photo"
        case .video: "film"
        case .audio: "waveform"
        case .archive: "shippingbox"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .other: "doc"
        }
    }

    /// What a model or a person is likely to type, mapped to a bucket. Nil when the word
    /// names no bucket, which the tool reports rather than silently ignoring.
    static func named(_ raw: String) -> FileCategory? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "folder", "folders", "directory", "directories": .folder
        case "document", "documents", "doc", "docs", "text", "word": .document
        case "spreadsheet", "spreadsheets", "excel", "numbers", "csv": .spreadsheet
        case "presentation", "presentations", "slides", "keynote", "powerpoint": .presentation
        case "pdf", "pdfs": .pdf
        case "image", "images", "photo", "photos", "picture", "pictures", "screenshot", "screenshots": .image
        case "video", "videos", "movie", "movies", "film": .video
        case "audio", "music", "sound", "sounds", "recording", "recordings": .audio
        case "archive", "archives", "zip", "zips": .archive
        case "code", "source", "script", "scripts": .code
        case "other", "file", "files": .other
        default: nil
        }
    }

    /// The bucket a UTType falls into. Conformance, not extensions, so `.md`, `.rtf` and
    /// `.pages` all land under documents without a list of suffixes to keep up to date.
    static func of(type: UTType?, isDirectory: Bool) -> FileCategory {
        if isDirectory { return .folder }
        guard let type else { return .other }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .spreadsheet) || type.conforms(to: .commaSeparatedText) { return .spreadsheet }
        if type.conforms(to: .presentation) { return .presentation }
        if type.conforms(to: .archive) || type.conforms(to: .diskImage) { return .archive }
        if type.conforms(to: .sourceCode) || type.conforms(to: .script) || type.conforms(to: .shellScript) {
            return .code
        }
        if type.conforms(to: .text) || type.conforms(to: .rtf) || type.conforms(to: .compositeContent) {
            return .document
        }
        return .other
    }
}

/// One search hit, for the tools and for the graph.
struct FileHit: Identifiable, Equatable, Sendable {
    var path: String
    var name: String
    var isDirectory: Bool
    var category: FileCategory
    var size: Int64?
    var modifiedAt: Date?
    var accessedAt: Date?
    var root: String
    var depth: Int

    var id: String { path }
}

/// What one indexed folder holds, for Settings.
struct FileIndexRootState: Equatable, Sendable, Identifiable {
    var root: String
    var files: Int
    var folders: Int
    var scannedAt: Date?
    /// True when the crawl stopped at a cap; `note` says why in words.
    var wasCapped: Bool
    var note: String?

    var id: String { root }
}

struct FileIndexStats: Equatable, Sendable {
    var files = 0
    var folders = 0
    var roots = 0
    var bytes: Int64 = 0
    var scannedAt: Date?
}

/// `file-index.sqlite`: the tree of the folders the user listed, and an FTS5 mirror of the
/// names and paths.
///
/// **Its own file, deliberately.** The knowledge index (`knowledge.sqlite`) holds passages of
/// the user's meetings and conversations and is the expensive one to rebuild; a file crawl is
/// cheap, changes constantly, and would otherwise be writing into the same WAL as the
/// indexer all day. Keeping them apart means a corrupt or oversized file index can be deleted
/// without touching a single transcript, and the crawler never blocks a search.
///
/// Derived and disposable, like the knowledge index: delete it and the next scan rebuilds it.
/// Only names, paths, sizes and dates are stored — nothing here ever opens a file.
final class FileIndexStore: @unchecked Sendable {
    static let fileName = "file-index.sqlite"
    static let schemaVersion: Int32 = 1

    let fileURL: URL
    private let lock = NSLock()
    private var db: OpaquePointer?
    private var openedInode: UInt64?

    init(directory: URL) {
        fileURL = directory.appendingPathComponent(Self.fileName)
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    var existsOnDisk: Bool { FileManager.default.fileExists(atPath: fileURL.path) }

    // MARK: - One spelling per path

    /// Every path that goes into or out of this store passes through here.
    ///
    /// `/var/folders/…` and `/private/var/folders/…` are the same directory: FSEvents and
    /// `FileManager.contentsOfDirectory` hand back the second, `FileManager.temporaryDirectory`
    /// and `NSOpenPanel` can hand back the first, and `~` is a third spelling again. Store two
    /// of them and the rows are all there but nothing finds them — every `LIKE '<parent>/%'`,
    /// every `parent =` lookup and every purge quietly matches nothing, which reads as "the
    /// index is empty" rather than as a bug.
    ///
    /// `realpath(3)`, not `URL.resolvingSymlinksInPath()`: the URL version deliberately keeps
    /// `/var` (it strips `/private` rather than adding it), so it is not a canonical form at
    /// all — that is exactly the bug this comment exists because of. A path that does not
    /// exist yet, or one that has just been deleted, is resolved as far as its deepest real
    /// ancestor and the rest is appended, so a purge still matches the rows it has to remove.
    static func canonical(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
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

    static func canonical(_ url: URL) -> URL {
        URL(fileURLWithPath: canonical(url.path))
    }

    // MARK: - Connection

    func withConnection<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(try openLocked())
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        closeLocked()
    }

    func deleteFile() {
        lock.lock()
        defer { lock.unlock() }
        closeLocked()
        for suffix in ["", "-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(atPath: fileURL.path + suffix)
        }
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

    private func openLocked() throws -> OpaquePointer {
        if let db {
            if let inode = openedInode, Self.inode(atPath: fileURL.path) == inode { return db }
            closeLocked()
            for suffix in ["-wal", "-shm", "-journal"] {
                try? FileManager.default.removeItem(atPath: fileURL.path + suffix)
            }
        }
        do {
            return try connectLocked()
        } catch {
            // Derived: an unreadable or stale-schema file is deleted and built again, never
            // migrated. Nothing in it is the user's only copy of anything.
            Log.app.error("file index unreadable, rebuilding: \(error.localizedDescription, privacy: .public)")
            closeLocked()
            for suffix in ["", "-wal", "-shm", "-journal"] {
                try? FileManager.default.removeItem(atPath: fileURL.path + suffix)
            }
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
            try KnowledgeStore.exec(handle, "PRAGMA journal_mode = WAL")
            try KnowledgeStore.exec(handle, "PRAGMA synchronous = NORMAL")
            let version = try KnowledgeStore.int(handle, "PRAGMA user_version")
            if version == 0 {
                try KnowledgeStore.exec(handle, "BEGIN IMMEDIATE")
                do {
                    try KnowledgeStore.exec(handle, Self.schema)
                    try KnowledgeStore.exec(handle, "PRAGMA user_version = \(Self.schemaVersion)")
                    try KnowledgeStore.exec(handle, "COMMIT")
                } catch {
                    try? KnowledgeStore.exec(handle, "ROLLBACK")
                    throw error
                }
            } else if version != Int(Self.schemaVersion) {
                throw KnowledgeStoreError.open("schema version \(version), expected \(Self.schemaVersion)")
            }
            _ = try KnowledgeStore.int(handle, "SELECT count(*) FROM file_root")
        } catch {
            sqlite3_close_v2(handle)
            throw error
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        db = handle
        openedInode = Self.inode(atPath: fileURL.path)
        return handle
    }

    static let schema = """
        CREATE TABLE file (
          id          INTEGER PRIMARY KEY,
          root        TEXT NOT NULL,
          path        TEXT NOT NULL UNIQUE,
          parent      TEXT,
          name        TEXT NOT NULL,
          is_dir      INTEGER NOT NULL,
          kind        TEXT,
          category    TEXT NOT NULL,
          size        INTEGER,
          created_at  INTEGER,
          modified_at INTEGER,
          accessed_at INTEGER,
          depth       INTEGER NOT NULL
        );
        CREATE INDEX file_root_index ON file(root);
        CREATE INDEX file_parent_index ON file(parent);
        CREATE INDEX file_modified_index ON file(modified_at);
        CREATE INDEX file_category_index ON file(category);

        CREATE VIRTUAL TABLE file_fts USING fts5(
          name, path, content='file', content_rowid='id', tokenize='unicode61'
        );
        CREATE TRIGGER file_fts_insert AFTER INSERT ON file BEGIN
          INSERT INTO file_fts(rowid, name, path) VALUES (new.id, new.name, new.path);
        END;
        CREATE TRIGGER file_fts_delete AFTER DELETE ON file BEGIN
          INSERT INTO file_fts(file_fts, rowid, name, path) VALUES ('delete', old.id, old.name, old.path);
        END;
        CREATE TRIGGER file_fts_update AFTER UPDATE ON file BEGIN
          INSERT INTO file_fts(file_fts, rowid, name, path) VALUES ('delete', old.id, old.name, old.path);
          INSERT INTO file_fts(rowid, name, path) VALUES (new.id, new.name, new.path);
        END;

        CREATE TABLE file_root (
          root        TEXT PRIMARY KEY,
          scanned_at  INTEGER NOT NULL,
          capped      INTEGER NOT NULL DEFAULT 0,
          note        TEXT
        );
        """

    // MARK: - Writes

    /// Makes the index hold exactly `records` for one indexed folder, in one transaction.
    ///
    /// A whole-root replace: the crawl produced the truth, so anything the crawl did not see
    /// is gone. `capped`/`note` are recorded rather than dropped — a folder that was cut short
    /// says so in Settings instead of quietly answering half of every search.
    func replaceRoot(_ rawRoot: String, records: [FileRecord], capped: Bool, note: String?,
                     now: Date = Date()) throws {
        let root = Self.canonical(rawRoot)
        try withConnection { db in
            try KnowledgeStore.transaction(db) {
                try KnowledgeStore.run(db, "DELETE FROM file WHERE root = ?1", [.text(root)])
                try Self.insert(db, records: records, root: root)
                try KnowledgeStore.run(db, """
                    INSERT INTO file_root (root, scanned_at, capped, note) VALUES (?1, ?2, ?3, ?4)
                    ON CONFLICT (root) DO UPDATE SET scanned_at = excluded.scanned_at,
                      capped = excluded.capped, note = excluded.note
                    """, [.text(root), .int(Int64(now.timeIntervalSince1970)), .int(capped ? 1 : 0),
                          .optionalText(note)])
            }
        }
    }

    /// Replaces one subtree — what an FSEvents notification asks for. Rows under `subtree`
    /// (and the subtree row itself) are removed and the given records take their place.
    func replaceSubtree(root rawRoot: String, subtree rawSubtree: String, records: [FileRecord],
                        now: Date = Date()) throws {
        let root = Self.canonical(rawRoot)
        let subtree = Self.canonical(rawSubtree)
        try withConnection { db in
            try KnowledgeStore.transaction(db) {
                try KnowledgeStore.run(db, "DELETE FROM file WHERE path = ?1 OR path LIKE ?2 ESCAPE '\\'",
                                       [.text(subtree), .text(Self.prefixPattern(subtree))])
                try Self.insert(db, records: records, root: root)
                try KnowledgeStore.run(db, "UPDATE file_root SET scanned_at = ?2 WHERE root = ?1",
                                       [.text(root), .int(Int64(now.timeIntervalSince1970))])
            }
        }
    }

    /// One directory's listing, replaced in place — what an FSEvents notification asks for.
    ///
    /// Only the directory's own row and its direct children are touched, so a save inside
    /// `~/Documents/Work` never costs a re-crawl of Documents. Children that have gone take
    /// their subtrees with them. Returns the paths of sub-directories that are new here, so
    /// the caller can crawl them properly rather than leaving an empty folder in the tree.
    @discardableResult
    func refreshDirectory(root rawRoot: String, directory rawDirectory: String, records: [FileRecord],
                          now: Date = Date()) throws -> [String] {
        let root = Self.canonical(rawRoot)
        let directory = Self.canonical(rawDirectory)
        return try withConnection { db in
            try KnowledgeStore.transaction(db) {
                var existing: Set<String> = []
                var existingDirectories: Set<String> = []
                let children = try KnowledgeStore.prepare(
                    db, "SELECT path, is_dir FROM file WHERE parent = ?1")
                KnowledgeStore.bind(children, [.text(directory)])
                while sqlite3_step(children) == SQLITE_ROW {
                    guard let path = KnowledgeStore.text(children, 0) else { continue }
                    existing.insert(path)
                    if sqlite3_column_int(children, 1) == 1 { existingDirectories.insert(path) }
                }
                sqlite3_finalize(children)

                let kept = Set(records.map(\.path))
                for gone in existing.subtracting(kept) {
                    try KnowledgeStore.run(db, "DELETE FROM file WHERE path = ?1 OR path LIKE ?2 ESCAPE '\\'",
                                           [.text(gone), .text(Self.prefixPattern(gone))])
                }
                try Self.insert(db, records: records, root: root)
                try KnowledgeStore.run(db, "UPDATE file_root SET scanned_at = ?2 WHERE root = ?1",
                                       [.text(root), .int(Int64(now.timeIntervalSince1970))])
                return records
                    .filter { $0.isDirectory && $0.path != directory && !existingDirectories.contains($0.path) }
                    .map(\.path)
            }
        }
    }

    /// Removes one path and everything under it — a folder that has been deleted or moved away.
    func purgeSubtree(_ rawPath: String) throws {
        guard existsOnDisk else { return }
        let path = Self.canonical(rawPath)
        try withConnection { db in
            try KnowledgeStore.run(db, "DELETE FROM file WHERE path = ?1 OR path LIKE ?2 ESCAPE '\\'",
                                   [.text(path), .text(Self.prefixPattern(path))])
        }
    }

    /// Whether the index already knows this path.
    func knows(_ rawPath: String) throws -> Bool {
        guard existsOnDisk else { return false }
        let path = Self.canonical(rawPath)
        return try withConnection { db in
            try KnowledgeStore.optionalInt(db, "SELECT 1 FROM file WHERE path = ?1", [.text(path)]) != nil
        }
    }

    /// Every row of one indexed folder, and its state. Called the moment a folder is removed
    /// from the list, so a removed folder can never answer a search.
    func purgeRoot(_ rawRoot: String) throws {
        guard existsOnDisk else { return }
        let root = Self.canonical(rawRoot)
        try withConnection { db in
            try KnowledgeStore.transaction(db) {
                try KnowledgeStore.run(db, "DELETE FROM file WHERE root = ?1", [.text(root)])
                try KnowledgeStore.run(db, "DELETE FROM file_root WHERE root = ?1", [.text(root)])
            }
        }
    }

    /// Roots the index still holds that are no longer on the user's list.
    func staleRoots(keeping rawWanted: Set<String>) throws -> [String] {
        guard existsOnDisk else { return [] }
        let wanted = Set(rawWanted.map(Self.canonical))
        return try withConnection { db in
            let statement = try KnowledgeStore.prepare(db, "SELECT root FROM file_root")
            defer { sqlite3_finalize(statement) }
            var result: [String] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let root = KnowledgeStore.text(statement, 0), !wanted.contains(root) { result.append(root) }
            }
            return result
        }
    }

    private static func insert(_ db: OpaquePointer, records: [FileRecord], root: String) throws {
        guard !records.isEmpty else { return }
        let statement = try KnowledgeStore.prepare(db, """
            INSERT OR REPLACE INTO file
              (root, path, parent, name, is_dir, kind, category, size, created_at, modified_at, accessed_at, depth)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
            """)
        defer { sqlite3_finalize(statement) }
        for record in records {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            KnowledgeStore.bind(statement, [
                .text(root), .text(record.path), .optionalText(record.parent), .text(record.name),
                .int(record.isDirectory ? 1 : 0), .optionalText(record.kind), .text(record.category.rawValue),
                record.size.map { .int($0) } ?? .optionalText(nil),
                record.createdAt.map { .int($0) } ?? .optionalText(nil),
                record.modifiedAt.map { .int($0) } ?? .optionalText(nil),
                record.accessedAt.map { .int($0) } ?? .optionalText(nil),
                .int(Int64(record.depth)),
            ])
            guard sqlite3_step(statement) == SQLITE_DONE else { throw KnowledgeStore.error(db) }
        }
    }

    // MARK: - Reads

    private static let columns = "f.path, f.name, f.is_dir, f.category, f.size, f.modified_at, f.accessed_at, f.root, f.depth"

    /// Name and path search, newest first among equally good matches.
    ///
    /// FTS5 when there are words to match; a plain listing under the filters when there are
    /// none, so "everything I changed this week" is a legal question.
    func find(query: String, category: FileCategory? = nil, folder rawFolder: String? = nil,
              modifiedAfter: Date? = nil, includeFolders: Bool = true, limit: Int = 20) throws -> [FileHit] {
        guard existsOnDisk else { return [] }
        let folder = rawFolder.map(Self.canonical)
        let tokens = Self.tokens(query)
        var values: [KnowledgeStore.SQLValue] = []
        var sql: String
        if tokens.isEmpty {
            sql = "SELECT \(Self.columns) FROM file f WHERE 1"
        } else {
            values.append(.text(Self.expression(tokens)))
            sql = """
                SELECT \(Self.columns) FROM file_fts JOIN file f ON f.id = file_fts.rowid
                WHERE file_fts MATCH ?1
                """
        }
        if let category {
            values.append(.text(category.rawValue))
            sql += " AND f.category = ?\(values.count)"
        }
        if !includeFolders { sql += " AND f.is_dir = 0" }
        if let folder {
            values.append(.text(folder))
            values.append(.text(Self.prefixPattern(folder)))
            sql += " AND (f.path = ?\(values.count - 1) OR f.path LIKE ?\(values.count) ESCAPE '\\')"
        }
        if let modifiedAfter {
            values.append(.int(Int64(modifiedAfter.timeIntervalSince1970)))
            sql += " AND f.modified_at >= ?\(values.count)"
        }
        // Recency is the tie-break people expect from a file search; BM25 alone puts a
        // ten-year-old draft above the one they saved this morning.
        sql += tokens.isEmpty
            ? " ORDER BY f.modified_at DESC, f.path"
            : " ORDER BY bm25(file_fts), f.modified_at DESC, f.path"
        values.append(.int(Int64(max(1, min(limit, 200)))))
        sql += " LIMIT ?\(values.count)"
        return try hits(sql, values: values)
    }

    /// How many rows match the words, for the facet count beside "Files and folders".
    ///
    /// Counted in SQL rather than by measuring what `find` returned: `find` stops at its
    /// limit, so counting its rows would show "20 files" to someone with two thousand.
    func count(query: String) throws -> Int {
        guard existsOnDisk else { return 0 }
        let tokens = Self.tokens(query)
        return try withConnection { db in
            guard !tokens.isEmpty else {
                return Int(try KnowledgeStore.optionalInt(db, "SELECT count(*) FROM file", []) ?? 0)
            }
            return Int(try KnowledgeStore.optionalInt(
                db, "SELECT count(*) FROM file_fts WHERE file_fts MATCH ?1",
                [.text(Self.expression(tokens))]) ?? 0)
        }
    }

    /// The tree under one path, `depth` levels down. Depth 1 is that folder's own children.
    func tree(path rawPath: String, depth: Int, limit: Int = 300) throws -> [FileHit] {
        guard existsOnDisk else { return [] }
        let path = Self.canonical(rawPath)
        let base = try self.depth(of: path)
        guard let base else { return [] }
        let values: [KnowledgeStore.SQLValue] = [
            .text(path), .text(Self.prefixPattern(path)),
            .int(Int64(base + max(1, min(depth, 6)))), .int(Int64(max(1, min(limit, 1_000)))),
        ]
        let sql = """
            SELECT \(Self.columns) FROM file f
            WHERE (f.path = ?1 OR f.path LIKE ?2 ESCAPE '\\') AND f.depth <= ?3
            ORDER BY f.depth, f.is_dir DESC, f.name COLLATE NOCASE
            LIMIT ?4
            """
        return try hits(sql, values: values)
    }

    /// How many rows the tree under `path` has, so `tree` can say what it left out.
    func subtreeCount(path rawPath: String) throws -> Int {
        guard existsOnDisk else { return 0 }
        let path = Self.canonical(rawPath)
        return try withConnection { db in
            Int(try KnowledgeStore.optionalInt(db, """
                SELECT count(*) FROM file WHERE path = ?1 OR path LIKE ?2 ESCAPE '\\'
                """, [.text(path), .text(Self.prefixPattern(path))]) ?? 0)
        }
    }

    private func depth(of path: String) throws -> Int? {
        try withConnection { db in
            try KnowledgeStore.optionalInt(db, "SELECT depth FROM file WHERE path = ?1", [.text(path)]).map(Int.init)
        }
    }

    /// The indexed folders' own rows — the top of the tree, for the graph and for Settings.
    func roots() throws -> [FileHit] {
        guard existsOnDisk else { return [] }
        return try hits("SELECT \(Self.columns) FROM file f WHERE f.depth = 0 ORDER BY f.name COLLATE NOCASE",
                        values: [])
    }

    /// Sub-folders one level under `path`, biggest first — what the graph draws on expand.
    func subfolders(of rawPath: String, limit: Int = 24) throws -> [FileHit] {
        guard existsOnDisk else { return [] }
        let path = Self.canonical(rawPath)
        return try hits("""
            SELECT \(Self.columns) FROM file f
            WHERE f.parent = ?1 AND f.is_dir = 1
            ORDER BY f.modified_at DESC, f.name COLLATE NOCASE LIMIT ?2
            """, values: [.text(path), .int(Int64(max(1, limit)))])
    }

    /// Files worth drawing as their own node: recently used, folders excluded.
    ///
    /// "Recently used" is the later of the modification and access dates. Without the cap and
    /// the cutoff this is where a graph turns into a hairball — twelve thousand dots and no map.
    func recentlyUsed(since: Date, limit: Int = 40) throws -> [FileHit] {
        guard existsOnDisk else { return [] }
        return try hits("""
            SELECT \(Self.columns) FROM file f
            WHERE f.is_dir = 0 AND MAX(COALESCE(f.modified_at, 0), COALESCE(f.accessed_at, 0)) >= ?1
            ORDER BY MAX(COALESCE(f.modified_at, 0), COALESCE(f.accessed_at, 0)) DESC, f.path
            LIMIT ?2
            """, values: [.int(Int64(since.timeIntervalSince1970)), .int(Int64(max(1, limit)))])
    }

    /// Files whose name appears in `names` — how a file mentioned in a meeting or a memory
    /// finds its node. Matched on the file name, case-insensitively.
    func matching(names: [String], limit: Int = 40) throws -> [FileHit] {
        guard existsOnDisk, !names.isEmpty else { return [] }
        var values: [KnowledgeStore.SQLValue] = []
        var placeholders: [String] = []
        for name in names.prefix(60) {
            values.append(.text(name))
            placeholders.append("?\(values.count)")
        }
        values.append(.int(Int64(max(1, limit))))
        let sql = """
            SELECT \(Self.columns) FROM file f
            WHERE f.is_dir = 0 AND f.name COLLATE NOCASE IN (\(placeholders.joined(separator: ", ")))
            ORDER BY f.modified_at DESC, f.path LIMIT ?\(values.count)
            """
        return try hits(sql, values: values)
    }

    func stats() throws -> FileIndexStats {
        guard existsOnDisk else { return FileIndexStats() }
        return try withConnection { db in
            var stats = FileIndexStats()
            stats.files = Int(try KnowledgeStore.int(db, "SELECT count(*) FROM file WHERE is_dir = 0"))
            stats.folders = Int(try KnowledgeStore.int(db, "SELECT count(*) FROM file WHERE is_dir = 1"))
            stats.roots = Int(try KnowledgeStore.int(db, "SELECT count(*) FROM file_root"))
            if let latest = try KnowledgeStore.optionalInt(db, "SELECT MAX(scanned_at) FROM file_root", []) {
                stats.scannedAt = Date(timeIntervalSince1970: TimeInterval(latest))
            }
            stats.bytes = ["", "-wal"].reduce(Int64(0)) { total, suffix in
                let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path + suffix)[.size]) as? NSNumber
                return total + (size?.int64Value ?? 0)
            }
            return stats
        }
    }

    func rootStates() throws -> [FileIndexRootState] {
        guard existsOnDisk else { return [] }
        return try withConnection { db in
            let statement = try KnowledgeStore.prepare(db, """
                SELECT r.root, r.scanned_at, r.capped, r.note,
                       (SELECT count(*) FROM file WHERE root = r.root AND is_dir = 0),
                       (SELECT count(*) FROM file WHERE root = r.root AND is_dir = 1)
                FROM file_root r ORDER BY r.root
                """)
            defer { sqlite3_finalize(statement) }
            var result: [FileIndexRootState] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let root = KnowledgeStore.text(statement, 0) else { continue }
                result.append(FileIndexRootState(
                    root: root,
                    files: Int(sqlite3_column_int(statement, 4)),
                    folders: Int(sqlite3_column_int(statement, 5)),
                    scannedAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 1))),
                    wasCapped: sqlite3_column_int(statement, 2) == 1,
                    note: KnowledgeStore.text(statement, 3)))
            }
            return result
        }
    }

    private func hits(_ sql: String, values: [KnowledgeStore.SQLValue]) throws -> [FileHit] {
        try withConnection { db in
            let statement = try KnowledgeStore.prepare(db, sql)
            defer { sqlite3_finalize(statement) }
            KnowledgeStore.bind(statement, values)
            var result: [FileHit] = []
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { break }
                guard code == SQLITE_ROW else { throw KnowledgeStore.error(db) }
                guard let path = KnowledgeStore.text(statement, 0) else { continue }
                func date(_ column: Int32) -> Date? {
                    sqlite3_column_type(statement, column) == SQLITE_NULL
                        ? nil : Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, column)))
                }
                result.append(FileHit(
                    path: path,
                    name: KnowledgeStore.text(statement, 1) ?? "",
                    isDirectory: sqlite3_column_int(statement, 2) == 1,
                    category: FileCategory(rawValue: KnowledgeStore.text(statement, 3) ?? "") ?? .other,
                    size: sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 4),
                    modifiedAt: date(5),
                    accessedAt: date(6),
                    root: KnowledgeStore.text(statement, 7) ?? "",
                    depth: Int(sqlite3_column_int(statement, 8))))
            }
            return result
        }
    }

    // MARK: - Query text

    /// Words, lowercased, in order, at most eight. Punctuation splits: `report-2024.pdf`
    /// becomes `report`, `2024`, `pdf`, so any of those finds it.
    static func tokens(_ text: String) -> [String] {
        var seen: Set<String> = []
        return text.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .map(String.init)
            .filter { seen.insert($0).inserted }
            .prefix(8)
            .map { $0 }
    }

    /// Every word, quoted so nothing is an operator, as a prefix match — someone typing
    /// "invo" means the invoice.
    static func expression(_ tokens: [String]) -> String {
        tokens.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"*" }.joined(separator: " AND ")
    }

    /// `LIKE` pattern for "inside this directory", with the wildcards in a path escaped so a
    /// folder called `100%_done` cannot match half the disk.
    static func prefixPattern(_ path: String) -> String {
        let prefix = path.hasSuffix("/") ? path : path + "/"
        let escaped = prefix
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return escaped + "%"
    }
}

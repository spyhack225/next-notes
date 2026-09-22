import Foundation
import UniformTypeIdentifiers

/// Walks a folder and turns it into rows. Names, sizes and dates only — nothing here opens a
/// file, and adding that later is a separate decision with its own switch.
///
/// Breadth-first on purpose. When a folder is bigger than the cap, the rows that survive are
/// the shallow ones: `~/Documents/Taxes/2024/receipts.pdf` is worth more to someone asking
/// "where are my tax papers" than the ten-thousandth file inside a checked-out repository.
/// Hitting the cap is recorded and logged, never silent — a search that quietly covers a
/// third of a folder is worse than one that says it was cut short.
struct FileCrawler: Sendable {
    /// Rows per indexed folder. ~50k names and dates is a few megabytes of SQLite.
    static let maxEntries = 50_000
    /// Levels below the indexed folder. Deeper than this is a build tree, not a document.
    static let maxDepth = 12

    /// Folders whose insides are never anybody's documents. `Library` is here because macOS
    /// puts a hundred thousand support files in it and none of them are what the user means
    /// by "my files".
    static let skippedFolders: Set<String> = [
        "node_modules", ".git", ".svn", ".hg", "build", ".build", "DerivedData", "Library",
        ".Trash", "__pycache__", ".venv", "venv", "Pods", ".next", "dist", "out", ".cache",
        ".gradle", ".tox", "target", ".terraform", "vendor", ".npm", ".yarn",
    ]

    struct Result: Sendable {
        var records: [FileRecord] = []
        /// True when the crawl stopped at `maxEntries` or `maxDepth`.
        var capped = false
        /// What to show the user about the cap, in their words.
        var note: String?
        /// Why the folder could not be read at all — a TCC refusal, usually.
        var problem: String?
        var truncatedAt = 0
    }

    /// Crawls `root`, whose own depth in the indexed folder is `startDepth`.
    ///
    /// Call this off the main actor: on a real Downloads folder it is tens of thousands of
    /// `stat` calls.
    static func crawl(
        _ root: URL,
        startDepth: Int = 0,
        maxEntries: Int = FileCrawler.maxEntries,
        maxDepth: Int = FileCrawler.maxDepth,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> Result {
        var result = Result()
        let manager = FileManager.default
        // One spelling for every path in the index — see FileIndexStore.canonical.
        let root = FileIndexStore.canonical(root)

        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            result.problem = "This folder isn’t there any more."
            return result
        }
        // The root's own row, so the tree has a top and `tree(path:)` can start from it.
        result.records.append(record(for: root, depth: startDepth, isDirectoryHint: true))

        var frontier: [(url: URL, depth: Int)] = [(root, startDepth)]
        var deepestReached = startDepth
        /// Two different ends, and only one of them stops the walk. Running out of rows is a
        /// hard stop; refusing to go deeper is not — treating them as one flag meant the first
        /// deep folder ended the crawl and every sibling after it was silently missing.
        var entriesExhausted = false
        var depthLimited = false

        while !frontier.isEmpty, !isCancelled(), !entriesExhausted {
            var next: [(url: URL, depth: Int)] = []
            for (directory, depth) in frontier {
                if isCancelled() { break }
                guard result.records.count < maxEntries else {
                    entriesExhausted = true
                    break
                }
                let children: [URL]
                do {
                    children = try manager.contentsOfDirectory(
                        at: directory,
                        includingPropertiesForKeys: Array(resourceKeys),
                        options: [.skipsHiddenFiles, .skipsPackageDescendants]
                    )
                } catch {
                    // The root failing is worth telling the user about; a single unreadable
                    // sub-folder deep in a tree is not.
                    if directory.path == root.path {
                        let code = (error as NSError).code
                        result.problem = code == NSFileReadNoPermissionError
                            ? "macOS hasn’t allowed Next Notes to read this folder yet."
                            : error.localizedDescription
                    }
                    continue
                }
                for child in children {
                    if result.records.count >= maxEntries {
                        entriesExhausted = true
                        break
                    }
                    let name = child.lastPathComponent
                    if name.hasPrefix(".") { continue }
                    let values = try? child.resourceValues(forKeys: resourceKeys)
                    let isDirectory = values?.isDirectory ?? false
                    let isPackage = values?.isPackage ?? false
                    let isSymlink = values?.isSymbolicLink ?? false
                    if isDirectory, skippedFolders.contains(name) { continue }
                    result.records.append(record(for: child, depth: depth + 1, values: values,
                                                 isDirectoryHint: isDirectory && !isPackage))
                    deepestReached = max(deepestReached, depth + 1)
                    // A package (`.app`, `.rtfd`, a Photos library) is one thing to a person,
                    // so it is one row. A symlink is not followed: that is how a crawl of a
                    // home folder turns into an infinite loop.
                    guard isDirectory, !isPackage, !isSymlink else { continue }
                    if depth + 1 >= maxDepth {
                        depthLimited = true
                        continue
                    }
                    next.append((child, depth + 1))
                }
                if entriesExhausted { break }
            }
            frontier = next
        }

        result.capped = entriesExhausted || depthLimited
        if result.capped {
            result.truncatedAt = result.records.count
            result.note = entriesExhausted
                ? "This folder is very large, so the first \(maxEntries.formatted()) items were listed."
                : "This folder goes deeper than \(maxDepth) levels; anything below that was left out."
            Log.app.info("""
                file index · \(root.lastPathComponent, privacy: .public) capped at \
                \(result.records.count, privacy: .public) rows (depth \(deepestReached, privacy: .public))
                """)
        }
        return result
    }

    private static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .fileSizeKey, .creationDateKey,
        .contentModificationDateKey, .contentAccessDateKey, .contentTypeKey,
    ]

    private static func record(
        for url: URL, depth: Int, values: URLResourceValues? = nil, isDirectoryHint: Bool
    ) -> FileRecord {
        let values = values ?? (try? url.resourceValues(forKeys: resourceKeys))
        let type = values?.contentType
        let isDirectory = isDirectoryHint
        return FileRecord(
            path: url.path,
            parent: depth == 0 ? nil : url.deletingLastPathComponent().path,
            name: url.lastPathComponent,
            isDirectory: isDirectory,
            kind: type?.identifier,
            category: FileCategory.of(type: type, isDirectory: isDirectory),
            size: isDirectory ? nil : values?.fileSize.map(Int64.init),
            createdAt: values?.creationDate.map { Int64($0.timeIntervalSince1970) },
            modifiedAt: values?.contentModificationDate.map { Int64($0.timeIntervalSince1970) },
            accessedAt: values?.contentAccessDate.map { Int64($0.timeIntervalSince1970) },
            depth: depth
        )
    }
}

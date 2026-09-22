import Foundation
import Observation

/// Keeps `file-index.sqlite` in step with the folders the user listed.
///
/// Everything expensive happens off the main actor: a crawl is tens of thousands of `stat`
/// calls and the window must stay live through it. The main actor holds only the queue, the
/// counts the UI shows, and the FSEvents callback's hand-off.
@MainActor
@Observable
final class FileIndexer {
    /// The production indexer. Under a self-test it gets a database in a temporary directory
    /// and watches nothing — a self-test must never touch the user's own index.
    static let shared: FileIndexer = {
        if SelfTest.isRunning {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("NextNotesSelfTest-files-\(ProcessInfo.processInfo.processIdentifier)",
                                        isDirectory: true)
            return FileIndexer(store: FileIndexStore(directory: directory), watches: false)
        }
        return FileIndexer(store: FileIndexStore(directory: AppIdentity.applicationSupportDirectory))
    }()

    let store: FileIndexStore

    private(set) var isScanning = false
    /// The folder being crawled right now, for the progress line in Settings.
    private(set) var scanningFolder: String?
    private(set) var stats = FileIndexStats()
    private(set) var rootStates: [FileIndexRootState] = []
    private(set) var lastError: String?
    /// Bumped after every write, so views re-read.
    private(set) var revision = 0

    private let watches: Bool
    @ObservationIgnored private var watcher: FileIndexWatcher?
    @ObservationIgnored private var queue: [URL] = []
    @ObservationIgnored private var worker: Task<Void, Never>?
    /// Directories FSEvents reported, coalesced until the debounce fires.
    @ObservationIgnored private var changed: Set<String> = []
    @ObservationIgnored private var changeDebounce: Task<Void, Never>?
    @ObservationIgnored private var watchedPaths: [String] = []

    /// How long changes pile up before a shallow re-scan. FSEvents already coalesces for two
    /// seconds; this is the second net, for a copy that writes for a minute.
    static let changeDelay: Duration = .seconds(3)

    init(store: FileIndexStore, watches: Bool = true) {
        self.store = store
        self.watches = watches
    }

    // MARK: - Lifecycle

    /// Begins watching the listed folders. Safe to call repeatedly; it re-arms the watcher
    /// when the list has changed and does nothing when it has not.
    func start() {
        refreshStats()
        guard watches, IndexedFoldersStore.shared.isEnabled else { return }
        let folders = IndexedFoldersStore.shared.folders
        let paths = folders.map(\.path)
        guard paths != watchedPaths else { return }
        watchedPaths = paths
        if watcher == nil {
            watcher = FileIndexWatcher { paths in
                Task { @MainActor in FileIndexer.shared.noteChanges(paths) }
            }
        }
        watcher?.watch(folders)
    }

    /// Stops watching. The rows stay: turning the switch off hides the folders from the
    /// assistant, and turning it back on must not cost a full crawl of three folders.
    func stop() {
        watcher?.stop()
        watchedPaths = []
        changeDebounce?.cancel()
        changeDebounce = nil
        worker?.cancel()
        worker = nil
        queue = []
        isScanning = false
        scanningFolder = nil
    }

    // MARK: - Scanning

    /// Crawls every listed folder, and drops any the user has since removed.
    func scanAll() {
        let folders = IndexedFoldersStore.shared.folders
        let wanted = Set(folders.map(\.path))
        if let stale = try? store.staleRoots(keeping: wanted) {
            for root in stale { try? store.purgeRoot(root) }
        }
        for folder in folders { enqueue(folder) }
        start()
    }

    /// Crawls one folder from scratch.
    func scan(_ folder: URL) {
        enqueue(FileIndexStore.canonical(folder))
    }

    /// Forgets one folder now. Called the moment it leaves the user's list.
    func purge(_ folder: URL) {
        let path = FileIndexStore.canonical(folder).path
        queue.removeAll { $0.path == path }
        do {
            try store.purgeRoot(path)
        } catch {
            lastError = error.localizedDescription
        }
        revision &+= 1
        refreshStats()
        watchedPaths = []
        start()
    }

    /// Deletes the whole index and crawls again — Settings' repair button.
    func rebuild() {
        stop()
        store.deleteFile()
        revision &+= 1
        scanAll()
    }

    private func enqueue(_ folder: URL) {
        guard !queue.contains(where: { $0.path == folder.path }) else { return }
        queue.append(folder)
        drain()
    }

    private func drain() {
        guard worker == nil, !queue.isEmpty else { return }
        isScanning = true
        worker = Task { @MainActor [weak self] in
            while let self, !self.queue.isEmpty, !Task.isCancelled {
                let folder = self.queue.removeFirst()
                self.scanningFolder = folder.lastPathComponent
                await self.crawl(folder)
            }
            self?.isScanning = false
            self?.scanningFolder = nil
            self?.worker = nil
            self?.refreshStats()
            // A crawl is the moment a TCC refusal or an unmounted disk becomes visible, so it
            // is the moment to re-ask — off the main actor, which is the whole point of the
            // cached verdict.
            IndexedFoldersStore.shared.refreshAccessProblems()
        }
    }

    private func crawl(_ folder: URL) async {
        let store = self.store
        let began = Date()
        let result = await Task.detached(priority: .utility) { () -> FileCrawler.Result in
            FileCrawler.crawl(folder)
        }.value
        guard !Task.isCancelled else { return }
        if let problem = result.problem {
            lastError = problem
            // A folder that could not be read this minute has not become empty. macOS asks
            // for Desktop / Documents / Downloads the first time and refuses until someone
            // answers; an external disk is not mounted yet. Writing the empty crawl over a
            // good index would make every search go quiet and look like a bug in search.
            let known = ((try? store.rootStates()) ?? [])
                .first { $0.root == FileIndexStore.canonical(folder.path) }
            if (known?.files ?? 0) + (known?.folders ?? 0) > 1 {
                Log.app.info("file index · kept \(folder.lastPathComponent, privacy: .public): \(problem, privacy: .public)")
                refreshStats()
                return
            }
        }
        do {
            try store.replaceRoot(folder.path, records: result.records, capped: result.capped,
                                  note: result.note ?? result.problem)
            if result.problem == nil { lastError = nil }
        } catch {
            lastError = error.localizedDescription
        }
        revision &+= 1
        refreshStats()
        Log.app.info("""
            file index · \(folder.lastPathComponent, privacy: .public) · \
            \(result.records.count, privacy: .public) items in \
            \(Date().timeIntervalSince(began), format: .fixed(precision: 2))s\
            \(result.capped ? " (capped)" : "", privacy: .public)
            """)
    }

    // MARK: - Incremental updates

    /// FSEvents told us something happened in these directories.
    func noteChanges(_ paths: [String]) {
        guard IndexedFoldersStore.shared.isEnabled else { return }
        for path in paths { changed.insert(path) }
        changeDebounce?.cancel()
        changeDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.changeDelay)
            guard !Task.isCancelled else { return }
            await self?.applyChanges()
        }
    }

    /// One shallow listing per changed directory, plus a proper crawl of anything new.
    func applyChanges() async {
        let directories = changed
        changed = []
        guard !directories.isEmpty else { return }
        let folders = IndexedFoldersStore.shared.folders
        let store = self.store
        for directory in directories.sorted() {
            guard let root = folders.first(where: {
                $0.path == directory || IndexedFoldersStore.contains(parent: $0, child: URL(fileURLWithPath: directory))
            }) else { continue }
            if FileCrawler.skippedFolders.contains((directory as NSString).lastPathComponent) { continue }
            let url = FileIndexStore.canonical(URL(fileURLWithPath: directory))
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                try? store.purgeSubtree(url.path)
                revision &+= 1
                continue
            }
            let depth = url.pathComponents.count - root.pathComponents.count
            guard depth <= FileCrawler.maxDepth else { continue }
            // One level: the directory's own row and its children. Anything new below that is
            // crawled separately, so a folder full of a thousand files is one listing, not a
            // re-walk of the tree above it.
            let listing = await Task.detached(priority: .utility) { () -> FileCrawler.Result in
                FileCrawler.crawl(url, startDepth: depth, maxDepth: depth + 1)
            }.value
            guard listing.problem == nil else { continue }
            do {
                let newDirectories = try store.refreshDirectory(
                    root: root.path, directory: url.path, records: listing.records)
                for path in newDirectories {
                    let child = URL(fileURLWithPath: path)
                    let childDepth = child.pathComponents.count - root.pathComponents.count
                    guard childDepth < FileCrawler.maxDepth else { continue }
                    let subtree = await Task.detached(priority: .utility) { () -> FileCrawler.Result in
                        FileCrawler.crawl(child, startDepth: childDepth)
                    }.value
                    try store.replaceSubtree(root: root.path, subtree: child.path, records: subtree.records)
                }
            } catch {
                lastError = error.localizedDescription
            }
            revision &+= 1
        }
        refreshStats()
    }

    // MARK: - What the rest of the app reads

    func refreshStats() {
        stats = (try? store.stats()) ?? FileIndexStats()
        rootStates = (try? store.rootStates()) ?? []
    }

    /// Whether the file tools may answer right now.
    var isAvailable: Bool {
        IndexedFoldersStore.shared.isEnabled && !IndexedFoldersStore.shared.folders.isEmpty && store.existsOnDisk
    }

    /// The single line the agent's prompt carries. Not the file list — that is the whole
    /// point: twelve thousand paths would eat the context window and teach the model nothing
    /// it cannot ask for. One sentence, so it knows the tools are worth calling.
    ///
    /// Nil when a cloud model is the reader and the user has not consented to that: the folder
    /// names alone say who the user works for and what they are working on, so the sentence is
    /// withheld from the same reader the tools would decline. `FileIndexSelfTest` checks that
    /// every tool name in here is one the planner is actually allowed to call — the sentence
    /// used to name `files.find`, which the realtime loop's allow-list rejects, and a rejected
    /// name does not lose one call: it abandons the whole tool plan.
    var promptSummary: String? {
        guard isAvailable, stats.files + stats.folders > 0,
              FileIndexScope.mayRead(cloudConsent: IndexedFoldersStore.shared.cloudConsent)
        else { return nil }
        let names = IndexedFoldersStore.shared.folders.map(\.lastPathComponent)
        return Self.summarySentence(folders: names, files: stats.files)
    }

    /// The sentence itself, given the two facts it states. Separate so the self-test can check
    /// the real string — the names it advertises against the planner's allow-list — instead of
    /// a copy of it that would drift out of step with the thing it is guarding.
    nonisolated static func summarySentence(folders names: [String], files: Int) -> String {
        let list = ListFormatter.localizedString(byJoining: names)
        return "I can look through \(list) — \(files.formatted()) files. "
            + "Use \(FileToolCatalogue.findID) to search them by name and "
            + "\(FileToolCatalogue.treeID) to see what is in a folder."
    }

    /// Every tool name the sentence tells the model to call. Anything with a dot in it that is
    /// not the end of the sentence is an id, which is exactly the shape a tool name has.
    nonisolated static func advertisedToolNames(in sentence: String) -> [String] {
        sentence
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".;:")) }
            .filter { $0.contains(".") }
    }
}

import Foundation
import Observation

/// Which folders the assistant may look through, and whether it may look at all.
///
/// The list is the user's, held as plain paths in `indexed-folders.json` under Application
/// Support. **No security-scoped bookmarks**: Next Notes is deliberately not sandboxed
/// (`Resources/NextNotes.entitlements` says so in as many words, because a CGEventTap and
/// system-wide AX both need to be outside the sandbox), so a path is all that is needed and
/// a bookmark would only add a second thing that can go stale. macOS still gates Desktop,
/// Documents and Downloads behind TCC for an unsandboxed app, which is a *read* that fails,
/// not a path that stops existing — `accessProblem(for:)` names that case so the UI can say
/// "macOS hasn't allowed this yet" instead of showing an empty folder.
///
/// Adding a folder kicks off a crawl into `FileIndex`; removing one purges its rows in the
/// same breath, so a folder the user took away can never come back as a search hit.
@MainActor
@Observable
final class IndexedFoldersStore {
    static let shared = IndexedFoldersStore()

    static let fileName = "indexed-folders.json"
    /// UserDefaults key for the master switch, so Settings and the crawler agree on it.
    nonisolated static let enabledKey = "fileIndexEnabled"

    /// The folders, in the order they were added, deduplicated by standardised path.
    private(set) var folders: [URL] = []

    /// Desktop, Documents and Downloads — the three the onboarding sheet and Settings offer
    /// with one click. Only folders that actually exist are offered.
    static var suggested: [URL] {
        let manager = FileManager.default
        return [FileManager.SearchPathDirectory.desktopDirectory, .documentDirectory, .downloadsDirectory]
            .compactMap { manager.urls(for: $0, in: .userDomainMask).first }
            .filter { manager.fileExists(atPath: $0.path) }
            .map { FileIndexStore.canonical($0) }
    }

    /// The master switch. Off by default: nothing on the Mac is looked at until someone asks.
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled {
                FileIndexer.shared.start()
                FileIndexer.shared.scanAll()
                refreshAccessProblems()
            } else {
                FileIndexer.shared.stop()
            }
            revision &+= 1
        }
    }

    /// Bumped whenever the list or the switch changes, so views re-read counts.
    private(set) var revision = 0

    /// Whether a cloud model may be told these folder names and be handed these paths.
    ///
    /// Off by default, and separate from the master switch, exactly as the life map's consent
    /// is: a file tree carries the user's account name, their clients, their projects and what
    /// they are working on this week. `FileIndexScope` is what reads this; when it says no, the
    /// prompt carries no folder sentence and the two tools decline.
    var cloudConsent: Bool {
        didSet {
            guard cloudConsent != oldValue else { return }
            UserDefaults.standard.set(cloudConsent, forKey: Self.cloudConsentKey)
            revision &+= 1
        }
    }

    /// UserDefaults key for the cloud consent, so Settings and `FileIndexScope` agree on it.
    nonisolated static let cloudConsentKey = "fileIndexCloudConsent"

    /// Why each folder cannot be read, keyed by canonical path — the *cached* verdict.
    ///
    /// Classifying a folder means a `contentsOfDirectory` on it, and that is a syscall against
    /// whatever volume the folder lives on: a network home directory, an unmounted external
    /// disk, or a TCC prompt still waiting for an answer can all take seconds. It used to be
    /// computed inside a SwiftUI body, twice per row, on every evaluation — which meant the
    /// window froze on exactly the folders whose problem the row existed to describe. It is
    /// now probed off the main actor and only read from here.
    private(set) var accessProblems: [String: String] = [:]

    @ObservationIgnored private var probeTask: Task<Void, Never>?

    private let fileURL: URL

    init(directory: URL? = nil) {
        let root: URL
        if let directory {
            root = directory
        } else if SelfTest.isRunning {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "NextNotesSelfTest-folders-\(ProcessInfo.processInfo.processIdentifier)",
                    isDirectory: true
                )
        } else {
            root = AppIdentity.applicationSupportDirectory
        }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fileURL = root.appendingPathComponent(Self.fileName)
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? false
        cloudConsent = UserDefaults.standard.object(forKey: Self.cloudConsentKey) as? Bool ?? false
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode(Snapshot.self, from: data) {
            folders = Self.deduplicated(saved.paths.map { FileIndexStore.canonical(URL(fileURLWithPath: $0)) })
        }
        refreshAccessProblems()
    }

    // MARK: - The list

    /// Adds a folder and starts indexing it. A file, a duplicate, or a folder already covered
    /// by one in the list is ignored — indexing `~/Documents` twice because `~/Documents/Work`
    /// was added as well would double every count.
    func add(_ url: URL) {
        let folder = FileIndexStore.canonical(url)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }
        guard !folders.contains(where: { $0.path == folder.path || Self.contains(parent: $0, child: folder) })
        else { return }
        // A new folder that *contains* ones already listed replaces them.
        let shadowed = folders.filter { Self.contains(parent: folder, child: $0) }
        for old in shadowed { purge(old) }
        folders.removeAll { url in shadowed.contains { $0.path == url.path } }
        folders.append(folder)
        persist()
        revision &+= 1
        refreshAccessProblems()
        guard isEnabled else { return }
        FileIndexer.shared.start()
        FileIndexer.shared.scan(folder)
    }

    /// Removes a folder and purges its rows immediately. The purge is not deferred to the
    /// next crawl: a folder the user has just taken away must stop answering searches now.
    func remove(_ url: URL) {
        let folder = FileIndexStore.canonical(url)
        guard let index = folders.firstIndex(where: { $0.path == folder.path }) else { return }
        folders.remove(at: index)
        persist()
        purge(folder)
        accessProblems[folder.path] = nil
        revision &+= 1
    }

    /// Whether a path is inside a folder the user listed. Everything the file tools read is
    /// checked against this, so `files.tree /etc` answers nothing rather than the system.
    func isIndexed(_ url: URL) -> Bool {
        let path = FileIndexStore.canonical(url)
        return folders.contains { $0.path == path.path || Self.contains(parent: $0, child: path) }
    }

    // MARK: - Can this folder be read?

    /// Why a folder cannot be read, in the user's words, or nil when it can.
    ///
    /// A cache read, and deliberately so: this is called from SwiftUI bodies and from the
    /// graph's reload, neither of which may block on a disk. `refreshAccessProblems()` is what
    /// actually asks the file system, off the main actor. A folder nobody has probed yet reads
    /// as "no problem" rather than inventing one — the row shows its counts, and the verdict
    /// lands a moment later without the window ever having waited for it.
    func accessProblem(for url: URL) -> String? {
        accessProblems[FileIndexStore.canonical(url).path]
    }

    /// Re-probes every listed folder off the main actor and publishes the verdicts.
    ///
    /// Called when the list or the switch changes, after a crawl, and when a pane that shows
    /// the verdicts appears. Cheap when nothing is wrong; when something is, the wait happens
    /// on a utility thread instead of in front of the user.
    func refreshAccessProblems() {
        // Nothing is looked at while the switch is off, and that includes this: asking macOS to
        // list the user's Desktop is what *raises* the TCC prompt, so a probe on a feature
        // nobody has turned on would put a permission sheet in front of someone who never asked
        // for one.
        let paths = isEnabled ? folders.map(\.path) : []
        probeTask?.cancel()
        guard !paths.isEmpty else {
            if !accessProblems.isEmpty { accessProblems = [:] }
            return
        }
        probeTask = Task { [weak self] in
            let probed = await Task.detached(priority: .utility) { () -> [String: String] in
                var found: [String: String] = [:]
                for path in paths {
                    if Task.isCancelled { return found }
                    if let problem = Self.probe(path) { found[path] = problem }
                }
                return found
            }.value
            guard !Task.isCancelled, let self else { return }
            if self.accessProblems != probed { self.accessProblems = probed }
        }
    }

    /// The syscall itself. `nonisolated` because it must run off the main actor.
    ///
    /// Desktop, Documents and Downloads are TCC-gated even for an unsandboxed app: the first
    /// read prompts, and a refusal makes `contentsOfDirectory` fail with a permission error
    /// forever after. That is a different thing from an empty folder and is said differently.
    nonisolated static func probe(_ path: String) -> String? {
        guard FileManager.default.fileExists(atPath: path) else {
            return "This folder isn’t there any more."
        }
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: path)
            return nil
        } catch {
            let code = (error as NSError).code
            if code == NSFileReadNoPermissionError || code == Int(EPERM) || code == Int(EACCES) {
                return "macOS hasn’t allowed this yet. Open System Settings › Privacy & Security › "
                    + "Files and Folders and switch Next Notes on for this folder."
            }
            return "This folder couldn’t be read: \(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    private func purge(_ folder: URL) {
        FileIndexer.shared.purge(folder)
    }

    /// True when `child` is inside `parent`. Compared component by component so
    /// `/Users/x/Documents2` is not treated as living inside `/Users/x/Documents`.
    nonisolated static func contains(parent: URL, child: URL) -> Bool {
        let parentParts = FileIndexStore.canonical(parent).pathComponents
        let childParts = FileIndexStore.canonical(child).pathComponents
        guard childParts.count > parentParts.count else { return false }
        return Array(childParts.prefix(parentParts.count)) == parentParts
    }

    private static func deduplicated(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        return urls.filter { seen.insert($0.path).inserted }
    }

    // MARK: - Persistence

    private struct Snapshot: Codable {
        var paths: [String]
    }

    private func persist() {
        let snapshot = Snapshot(paths: folders.map(\.path))
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

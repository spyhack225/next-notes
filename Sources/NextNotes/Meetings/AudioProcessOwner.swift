import Foundation

/// Resolves the audio process Core Audio reports to the app that owns it, before any
/// `CallPolicy` rule runs.
///
/// Core Audio's `kAudioProcessPropertyBundleID` names the process that holds the audio.
/// For Chromium browsers, Electron apps and Firefox that is a *helper* inside the app
/// bundle (`com.google.Chrome.helper`), so every policy check ran on the helper id and
/// the browser consent gate never fired. The owner is the outermost `.app` bundle on
/// the process's executable path; a process not inside any `.app`
/// (`/usr/libexec/avconferenced`) keeps its reported id. An id is never returned
/// without a path — or, for the migration, an installed app — proving it.
enum AudioProcessOwner {
    /// The outermost path component ending in ".app", scanning from the root.
    ///
    /// "/Applications/Google Chrome.app/Contents/Frameworks/…/Google Chrome Helper.app/…"
    ///   → "/Applications/Google Chrome.app".
    /// "/usr/libexec/avconferenced" → nil (no `.app` on the path).
    static func outermostAppPath(executablePath: String) -> String? {
        let parts = executablePath
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard let index = parts.firstIndex(where: { $0.hasSuffix(".app") && $0.count > 4 }) else {
            return nil
        }
        let joined = parts[0...index].joined(separator: "/")
        return joined.isEmpty ? nil : joined
    }

    /// The owning app's bundle id for a reported id and executable path.
    ///
    /// Pure: `bundleIDAt` is `{ Bundle(path: $0)?.bundleIdentifier }` in production.
    /// If the executable path yields an outer `.app` whose bundle id is known, that id
    /// wins; otherwise the reported id is kept. Never returns a *different* id without
    /// a path proving it.
    static func owner(
        reportedBundleID: String?,
        executablePath: String?,
        bundleIDAt: (String) -> String?
    ) -> String? {
        guard let executablePath,
              let appPath = outermostAppPath(executablePath: executablePath),
              let ownerID = bundleIDAt(appPath),
              !ownerID.isEmpty
        else {
            return reportedBundleID
        }
        return ownerID
    }

    /// The live lookup: `proc_pidpath` plus `Bundle(path:)`.
    ///
    /// Cached per (pid, reportedBundleID) in a `@MainActor` dictionary; entries for pids
    /// no longer in the process list are dropped by `pruneCache(livePIDs:)`, which
    /// `CallDetector.audioProcesses()` calls after every pass. A pid that has exited
    /// makes `proc_pidpath` return 0, and the reported id is kept.
    @MainActor static func resolve(
        pid: pid_t,
        reportedBundleID: String?
    ) -> (bundleID: String?, appPath: String?) {
        let key = "\(pid)#\(reportedBundleID ?? "")"
        if let cached = cache[key] {
            return cached
        }
        let result = resolveUncached(pid: pid, reportedBundleID: reportedBundleID)
        cache[key] = result
        return result
    }

    /// One uncached lookup. A path with no `.app` on it, or an outer `.app` with no
    /// bundle id to read, keeps the reported id — a guessed id is an answer stored
    /// against nothing.
    @MainActor private static func resolveUncached(
        pid: pid_t,
        reportedBundleID: String?
    ) -> (bundleID: String?, appPath: String?) {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let count = buffer.count
        let length: Int32 = buffer.withUnsafeMutableBytes { raw in
            proc_pidpath(pid, raw.baseAddress, UInt32(count))
        }
        guard length > 0 else {
            return (reportedBundleID, nil)
        }
        // `proc_pidpath` fills the buffer with the path; terminate it by hand rather
        // than trusting a trailing nul that the length does not promise.
        buffer[min(Int(length), buffer.count - 1)] = 0
        let executablePath = String(cString: buffer)
        let appPath = outermostAppPath(executablePath: executablePath)
        let owned = owner(
            reportedBundleID: reportedBundleID,
            executablePath: executablePath,
            bundleIDAt: { Bundle(path: $0)?.bundleIdentifier }
        )
        return (owned, appPath)
    }

    /// Drops cached entries for pids that are no longer holding audio.
    @MainActor static func pruneCache(livePIDs: Set<pid_t>) {
        for key in cache.keys {
            let pidPart = key.split(separator: "#", maxSplits: 1).first.flatMap { pid_t($0) }
            if let pid = pidPart, !livePIDs.contains(pid) {
                cache.removeValue(forKey: key)
            }
        }
    }

    @MainActor private static var cache: [String: (bundleID: String?, appPath: String?)] = [:]

    /// Moves helper-keyed rows in `callAppAnswers` / `callAppsSeen` to their owning app.
    ///
    /// Pure: `installedApp` is
    /// `{ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }` in
    /// production. For each key ending in `.helper` or containing `.helper.` (e.g.
    /// `com.google.Chrome.helper.renderer`), the candidate owner is the key up to
    /// `.helper`; the row moves only when `installedApp(candidate)` is true, otherwise
    /// it is left alone — never invent an id. A collision keeps the more cautious of
    /// the two answers (`never` > `ask` > `always`); any owner in
    /// `CallPolicy.askOnlyBundleIDs` holding `always` becomes `ask`; every row for an
    /// id in `CallPolicy.deniedBundleIDs` is dropped. A moved `seen` name loses its
    /// trailing " Helper" and any " (Renderer)" / " (GPU)" suffix. Idempotent.
    static func migrate(
        answers: [String: String],
        seen: [String: String],
        installedApp: (String) -> Bool
    ) -> (answers: [String: String], seen: [String: String]) {
        var answers = answers
        var seen = seen
        for key in Array(answers.keys) where isHelperKey(key) {
            guard let candidate = ownerCandidate(forHelperKey: key),
                  installedApp(candidate)
            else {
                continue
            }
            let moved = answers.removeValue(forKey: key) ?? CallPolicy.AppAnswer.ask.rawValue
            answers[candidate] = moreCautious(answers[candidate], moved)
        }
        // A stored `always` survives from an app being added to `askOnlyBundleIDs`
        // after the fact; reporting it back would be a lie about what
        // `recordsWithoutAsking` is going to do.
        for (key, value) in answers
        where CallPolicy.askOnlyBundleIDs.contains(key)
            && value == CallPolicy.AppAnswer.always.rawValue
        {
            answers[key] = CallPolicy.AppAnswer.ask.rawValue
        }
        for key in Array(answers.keys) where CallPolicy.deniedBundleIDs.contains(key) {
            answers.removeValue(forKey: key)
        }
        for key in Array(seen.keys) where isHelperKey(key) {
            guard let candidate = ownerCandidate(forHelperKey: key),
                  installedApp(candidate)
            else {
                continue
            }
            let oldName = seen.removeValue(forKey: key) ?? candidate
            if seen[candidate] == nil {
                seen[candidate] = cleanedAppName(oldName)
            }
        }
        for key in Array(seen.keys) where CallPolicy.deniedBundleIDs.contains(key) {
            seen.removeValue(forKey: key)
        }
        return (answers, seen)
    }

    /// A row that names a helper rather than an app: `com.foo.helper`, or a deeper
    /// service such as `com.google.Chrome.helper.renderer`.
    private static func isHelperKey(_ key: String) -> Bool {
        key.hasSuffix(".helper") || key.contains(".helper.")
    }

    /// The candidate owner of a helper key: everything up to `.helper`.
    private static func ownerCandidate(forHelperKey key: String) -> String? {
        if key.hasSuffix(".helper") {
            return String(key.dropLast(".helper".count))
        }
        if let range = key.range(of: ".helper.") {
            return String(key[..<range.lowerBound])
        }
        return nil
    }

    /// The more cautious of two stored answers: `never` over `ask` over `always`.
    /// An unknown raw value counts as `always` — the least cautious reading.
    private static func moreCautious(_ existing: String?, _ moved: String) -> String {
        func rank(_ raw: String?) -> Int {
            switch raw {
            case CallPolicy.AppAnswer.never.rawValue: 2
            case CallPolicy.AppAnswer.ask.rawValue: 1
            default: 0
            }
        }
        guard let existing else { return moved }
        return rank(existing) >= rank(moved) ? existing : moved
    }

    /// "Google Chrome Helper (Renderer)" → "Google Chrome".
    private static func cleanedAppName(_ name: String) -> String {
        var cleaned = name
        for suffix in [" (Renderer)", " (GPU)"] where cleaned.hasSuffix(suffix) {
            cleaned = String(cleaned.dropLast(suffix.count))
        }
        if cleaned.hasSuffix(" Helper") {
            cleaned = String(cleaned.dropLast(" Helper".count))
        }
        return cleaned
    }
}

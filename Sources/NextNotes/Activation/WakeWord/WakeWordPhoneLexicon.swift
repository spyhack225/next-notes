import Foundation

/// The wake model's bundled English phone lexicon (`en.phone`).
///
/// Same CMU-style dictionary sherpa's `text2token --tokens-type phone+ppinyin --lexicon`
/// uses. Loaded once from Application Support after the keyword model is downloaded —
/// ~126k words, a few megabytes — so a user can type almost any English wake phrase
/// without us shipping a hand-maintained table or inventing ARPAbet letter by letter.
enum WakeWordPhoneLexicon {
    /// First pronunciation for each word, uppercased key (`HEY` → `["HH", "EY1"]`).
    private static let lock = NSLock()
    /// Guarded by `lock`. Marked unsafe for Swift 6: the lock is the synchronisation.
    nonisolated(unsafe) private static var table: [String: [String]]?
    nonisolated(unsafe) private static var loadedPath: String?

    static var url: URL {
        WakeWordModelManager.modelDirectory
            .appendingPathComponent(WakeWordModels.phoneLexiconFile)
    }

    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// ARPAbet phones for `word`, or nil when the lexicon is missing or the word is absent.
    static func phones(for word: String) -> [String]? {
        let key = normalizeKey(word)
        guard !key.isEmpty else { return nil }
        loadIfNeeded()
        lock.lock()
        defer { lock.unlock() }
        return table?[key]
    }

    /// Drop cached rows. Used by self-tests that want a clean load, and after a model
    /// reinstall so a new `en.phone` is picked up.
    static func reset() {
        lock.lock()
        table = nil
        loadedPath = nil
        lock.unlock()
    }

    private static func normalizeKey(_ word: String) -> String {
        word
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .punctuationCharacters)
            .uppercased()
    }

    private static func loadIfNeeded() {
        let path = url.path
        lock.lock()
        if table != nil, loadedPath == path {
            lock.unlock()
            return
        }
        lock.unlock()

        guard let data = try? String(contentsOf: url, encoding: .utf8) else {
            lock.lock()
            table = [:]
            loadedPath = path
            lock.unlock()
            return
        }

        var built: [String: [String]] = [:]
        built.reserveCapacity(130_000)
        data.enumerateLines { line, _ in
            let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard parts.count >= 2 else { return }
            // CMU variants are `READ(1)` — keep the first pronunciation of the base word.
            let base = parts[0].split(separator: "(", maxSplits: 1, omittingEmptySubsequences: true)
                .first
                .map(String.init) ?? parts[0]
            let key = base.uppercased()
            guard built[key] == nil else { return }
            built[key] = Array(parts.dropFirst())
        }

        lock.lock()
        table = built
        loadedPath = path
        lock.unlock()
    }
}

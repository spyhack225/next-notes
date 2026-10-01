import Foundation

/// Files that failed a full-weight open on this Mac, remembered so no resolution path
/// hands one back to the runtime.
///
/// P0-13's probe decides whether llama.cpp can open a file *before* a role is assigned.
/// This store is the other half: a file the probe passed — or a row written before the
/// probe existed — that then failed a real load. Without it the role re-asserts the same
/// file on every turn, the load fails every time, and the app repeats the same notice
/// while a person keeps typing.
///
/// The key carries the file's byte size and the llama.cpp build tag, so a re-downloaded
/// file, or the same file on a newer build, is tried again instead of being refused for
/// ever. Persisted under `modelLibrary.openFailures`; a self-test gets its own suite.
@MainActor
final class ModelOpenFailureStore {
    /// What makes one failure entry distinct. A different size or a different llama.cpp
    /// build is a different question, and clears the old answer.
    struct Key: Hashable, Codable {
        let path: String
        let bytes: Int64
        let buildTag: String
    }

    /// The process-wide store. Under the harness it is a per-run suite, so a self-test can
    /// never write the owner's `modelLibrary.*` keys.
    static let shared = ModelOpenFailureStore(
        defaults: SelfTest.isRunning
            ? UserDefaults(suiteName: "NextNotesSelfTest-\(ProcessInfo.processInfo.processIdentifier)")
                ?? .standard
            : .standard
    )

    private static let defaultsKey = "modelLibrary.openFailures"

    private let defaults: UserDefaults
    private var failures: [Key: String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.failures = Self.load(from: defaults)
    }

    /// The file failed a real full-weight open. Nothing else writes this.
    func record(_ model: InstalledLocalModel, reason: String) {
        record(path: model.fileURL.path, bytes: model.bytes, reason: reason)
    }

    /// The runtime's own record: it holds a `ModelSpec`, not a library row, and the two
    /// name the same file by path and size.
    func record(path: String, bytes: Int64, reason: String) {
        failures[Key(path: path, bytes: bytes, buildTag: LlamaArchitectures.buildTag)] = reason
        persist()
    }

    /// Whether this exact file, on this build, has already failed to open.
    func hasFailed(_ model: InstalledLocalModel) -> Bool {
        failures[Key(path: model.fileURL.path, bytes: model.bytes,
                     buildTag: LlamaArchitectures.buildTag)] != nil
    }

    /// Forgets one file's failure, so it is tried again.
    func clear(_ model: InstalledLocalModel) {
        failures.removeValue(forKey: Key(
            path: model.fileURL.path, bytes: model.bytes, buildTag: LlamaArchitectures.buildTag))
        persist()
    }

    private func persist() {
        var table: [String: String] = [:]
        for (key, reason) in failures { table[Self.token(key)] = reason }
        defaults.set(table, forKey: Self.defaultsKey)
    }

    private static func load(from defaults: UserDefaults) -> [Key: String] {
        guard let table = defaults.dictionary(forKey: defaultsKey) as? [String: String] else {
            return [:]
        }
        var restored: [Key: String] = [:]
        for (token, reason) in table {
            guard let key = Key(token: token) else { continue }
            restored[key] = reason
        }
        return restored
    }

    private static func token(_ key: Key) -> String {
        "\(key.path)|\(key.bytes)|\(key.buildTag)"
    }
}

private extension ModelOpenFailureStore.Key {
    /// `path|bytes|buildTag`. Paths may contain `|`, so only the last two separators are
    /// taken and everything before them is the path.
    init?(token: String) {
        guard let last = token.lastIndex(of: "|"),
              let secondLast = token[..<last].lastIndex(of: "|"),
              let bytes = Int64(token[token.index(after: secondLast)..<last])
        else { return nil }
        self.init(
            path: String(token[..<secondLast]),
            bytes: bytes,
            buildTag: String(token[token.index(after: last)...])
        )
    }
}

extension SelfTest {
    /// The three flags allowed to read the owner's saved model choice while the harness is
    /// running. P0-14b's exit harness, the Metal probe and P1-05's constrained-tool-calling
    /// test each answer a question about the model this Mac actually has selected — the last
    /// one because a grammar that has never been run against the real sampler is a comment —
    /// and every other self-test keeps the isolated, empty selection. Read-only: nothing here
    /// writes `modelLibrary.*`.
    static var allowsSavedModelSelection: Bool {
        requested == "--selftest-agent-answers" || requested == "--selftest-llm-metal"
            || requested == "--selftest-native-tools"
            || requested == "--selftest-meeting-resources-live"
    }
}

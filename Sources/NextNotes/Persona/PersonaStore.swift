import Foundation

/// The user-owned persona: one free-text file every Agent prompt starts with.
///
/// `persona.md` is seeded once from `Resources/agent-persona-base.md` and never overwritten
/// after that — *Reset to base* in Settings is the only thing that puts the preset back.
/// Truncation is prompt-only: the caps below decide what a model hears, and the file on
/// disk keeps whatever the user wrote.
///
/// Thread-safe rather than `@MainActor`, because the prompt paths that read it run on the
/// Foundation Models frontend actor and in nonisolated prompt builders. A read is a cached
/// string plus one `stat`, so it is cheap enough for every voice turn.
final class PersonaStore: @unchecked Sendable {
    /// Every path except the Apple-model voice answer hears at most this much.
    static let fullLimit = 2_000
    /// The Apple-model voice path has 4,096 tokens for everything; it hears only the first
    /// paragraph, capped here.
    static let shortCardLimit = 400
    static let fileName = "persona.md"
    /// Shared with `Settings.agentPersonaEnabled`; read here directly because `Settings` is
    /// main-actor isolated and the voice frontend is not.
    static let enabledDefaultsKey = "agentPersonaEnabled"

    /// The production store. A self-test never touches the user's `persona.md`: it gets a
    /// per-process temporary directory seeded from the same base preset.
    static let shared: PersonaStore = {
        if SelfTest.isRunning {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("NextNotesSelfTest-persona-\(ProcessInfo.processInfo.processIdentifier)",
                                        isDirectory: true)
            return PersonaStore(directory: directory, isEnabled: { true })
        }
        return PersonaStore(directory: AppIdentity.applicationSupportDirectory, isEnabled: {
            UserDefaults.standard.object(forKey: PersonaStore.enabledDefaultsKey) as? Bool ?? true
        })
    }()

    let fileURL: URL
    private let enabledProvider: @Sendable () -> Bool
    private let lock = NSLock()
    private var cachedText: String?
    private var cachedModified: Date?

    init(directory: URL, isEnabled: @escaping @Sendable () -> Bool = { true }) {
        fileURL = directory.appendingPathComponent(Self.fileName)
        enabledProvider = isEnabled
    }

    var isEnabled: Bool { enabledProvider() }

    // MARK: - The base preset

    /// The preset as shipped in the bundle, or the compiled-in copy when running outside
    /// one (`make build` produces a bare binary). `--selftest-persona` fails if the two drift.
    static var baseText: String {
        bundledBaseText ?? builtInBaseText
    }

    static var bundledBaseText: String? {
        guard let url = Bundle.main.url(forResource: "agent-persona-base", withExtension: "md") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    static let builtInBaseText = """
        You are Next Notes, a voice assistant on this Mac. Talk like a sharp, friendly colleague:
        short sentences, plain words, answer first, no filler or flattery. If you are not sure, say
        so in one sentence instead of guessing. Give an opinion when asked for one.

        Keep spoken replies to one or two sentences unless asked for more. Never read out more than
        three items; offer to put the rest on screen. When you finish a task, say what actually
        happened, not what you intended.

        Add below: the name you want the Agent to use, what it should call you, and anything else
        about how it should sound.

        """

    // MARK: - The file

    /// The file's current text, seeding it from the base preset the first time. A seed that
    /// cannot be written (full disk, read-only volume) still returns the preset, so the
    /// Agent keeps its voice; the next read tries again.
    func text() -> String {
        lock.lock()
        defer { lock.unlock() }
        let manager = FileManager.default
        if !manager.fileExists(atPath: fileURL.path) {
            let base = Self.baseText
            do {
                try writeLocked(base)
            } catch {
                cachedText = nil
                cachedModified = nil
                return base
            }
        }
        let modified = (try? manager.attributesOfItem(atPath: fileURL.path)[.modificationDate]) as? Date
        if let cachedText, modified == cachedModified { return cachedText }
        let read = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        cachedText = read
        cachedModified = modified
        return read
    }

    /// Replace the persona. Atomic: a failed write leaves the previous file intact.
    func save(_ text: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try writeLocked(text)
    }

    /// The explicit *Reset to base* action; nothing else overwrites a seeded file.
    @discardableResult
    func resetToBase() throws -> String {
        let base = Self.baseText
        try save(base)
        return base
    }

    private func writeLocked(_ text: String) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: fileURL, options: .atomic)
        cachedText = text
        cachedModified = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate]) as? Date
    }

    // MARK: - What a prompt hears

    /// The whole persona as prompts receive it, or empty when the persona is turned off.
    func fullPersona() -> String {
        guard isEnabled else { return "" }
        return Self.fullCard(of: text()).kept
    }

    /// The first paragraph only, for the Apple-model voice answer.
    func shortCard() -> String {
        guard isEnabled else { return "" }
        return Self.shortCard(of: text()).kept
    }

    /// What a cap keeps and what it cuts. The editor shows `cut` so the user can see which
    /// part of their text a path will not hear.
    struct Cut: Equatable, Sendable {
        let kept: String
        let cut: String
        /// Characters of source text the card is drawn from, before the cap.
        let sourceCount: Int
        let limit: Int
        var isTruncated: Bool { !cut.isEmpty }
    }

    static func fullCard(of text: String) -> Cut {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return cap(trimmed, limit: fullLimit)
    }

    /// The first paragraph: everything up to the first blank line, after leading blank lines.
    static func shortCard(of text: String) -> Cut {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.components(separatedBy: "\n")
        var paragraph: [String] = []
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { break }
            paragraph.append(line)
        }
        let first = paragraph.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return cap(first, limit: shortCardLimit)
    }

    /// Hard character cap that backs off to a word boundary when one is close, so a prompt
    /// never ends mid-word. Always within `limit`.
    static func cap(_ text: String, limit: Int) -> Cut {
        guard text.count > limit else {
            return Cut(kept: text, cut: "", sourceCount: text.count, limit: limit)
        }
        var end = text.index(text.startIndex, offsetBy: limit)
        let window = text.index(end, offsetBy: -min(40, limit))
        if let space = text[window..<end].lastIndex(where: { $0.isWhitespace }) {
            end = space
        }
        let kept = String(text[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        let cut = String(text[end...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return Cut(kept: kept, cut: cut, sourceCount: text.count, limit: limit)
    }
}

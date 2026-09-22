import Foundation

/// The person, in their own words (G3).
///
/// A free-text file beside `persona.md`: what the Agent should call them, how to say
/// their name, and anything else about them worth knowing. Seeded once, never
/// overwritten, edited in Settings → Agent → About (one tap beside the avatar).
///
/// Guards: the same injection scan as memory (`MemoryGuard.scan`), plus provenance — a
/// write from a conversation must name the person in the person's own words, and a write
/// from anywhere else is refused. Persona-before-rules ordering holds: this text is
/// facts for section 1 of `AgentPromptContext`, never rules, and the override line still
/// closes the fixed rules after it.
final class AgentIdentityProse: @unchecked Sendable {
    static let fileName = "user-identity.md"
    static let maxLength = 1_000

    static let shared: AgentIdentityProse = {
        if SelfTest.isRunning {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("NextNotesSelfTest-identity-prose-\(ProcessInfo.processInfo.processIdentifier)",
                                        isDirectory: true)
            return AgentIdentityProse(directory: directory)
        }
        return AgentIdentityProse(directory: AppIdentity.applicationSupportDirectory)
    }()

    let fileURL: URL
    private let lock = NSLock()
    private var cachedText: String?
    private var cachedModified: Date?

    init(directory: URL) {
        fileURL = directory.appendingPathComponent(Self.fileName)
    }

    /// Seed text for the first voice session's naming line. Written to memory, not just
    /// here, so the name survives even if this file is cleared.
    static var seedPrompt: String { "What should I call you?" }

    func text() -> String {
        lock.lock()
        defer { lock.unlock() }
        let manager = FileManager.default
        if !manager.fileExists(atPath: fileURL.path) { return "" }
        let modified = (try? manager.attributesOfItem(atPath: fileURL.path)[.modificationDate]) as? Date
        if let cachedText, modified == cachedModified { return cachedText }
        let read = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        cachedText = read
        cachedModified = modified
        return read
    }

    /// The display name line: the first non-empty line, capped at 40 characters.
    var displayName: String {
        let first = text().split(whereSeparator: \.isNewline).map(String.init)
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let trimmed = (first ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(40))
    }

    /// Save the person's own edit. Injection-scanned; refused text throws with the reason.
    func save(_ raw: String) throws {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let clipped = String(trimmed.prefix(Self.maxLength))
        if let finding = MemoryGuard.scan(clipped) {
            throw MemoryWriteError.blocked(finding.reason)
        }
        guard MemoryGuard.isDeclarative(clipped) || clipped.isEmpty else {
            throw MemoryWriteError.notDeclarative
        }
        lock.lock()
        defer { lock.unlock() }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(clipped.utf8).write(to: fileURL, options: .atomic)
        cachedText = clipped
        cachedModified = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.modificationDate]) as? Date
    }

    /// The first-voice-session naming answer, from the person's own words.
    ///
    /// Provenance: `userText` must contain the name; tool output never counts. The name is
    /// written to core memory (`The user wants to be called X.`) and to this file, and the
    /// caller shows it beside the avatar with a one-tap change via the About path.
    @MainActor
    static func saveNamingAnswer(_ name: String, userText: [String], memory: NextMemory,
                                 prose: AgentIdentityProse = .shared) throws -> String {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw MemoryWriteError.empty }
        let provenance = MemoryProvenance(origin: .userConversation, sessionID: nil,
                                          userText: userText, untrustedText: [])
        let sentence = "The user wants to be called \(cleaned)."
        if let problem = MemoryGuard.provenanceProblem(sentence, provenance: provenance) {
            throw MemoryWriteError.provenance(problem.reason)
        }
        _ = try memory.remember(kind: .profile, text: sentence, source: .userSaid)
        let existing = prose.text()
        let line = "Call me \(cleaned)."
        if !existing.contains(cleaned) {
            try prose.save(existing.isEmpty ? line : existing + "\n" + line)
        }
        return cleaned
    }

    /// Facts for section 1 of the prompt, after the persona and before the fixed rules.
    /// Empty when nothing is known; never instructions.
    func groundingLine() -> String {
        let name = displayName
        guard !name.isEmpty else { return "" }
        return "The person using this Mac wants to be called \(name)."
    }
}

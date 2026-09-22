import Foundation

/// Everything the assistant is, in one file the person owns.
///
/// Written beside a readable Markdown rendering by `MemoryExporter`, read back by
/// `MemoryImportReader`. The JSON is the record; the Markdown is for the person.
///
/// **Versioning.** `format` identifies the shape and `version` its revision. A reader
/// refuses an unknown `format` outright — a file that only looks like ours would otherwise
/// be restored as if it were — and accepts any `version` up to `currentVersion`, decoding
/// everything it does not recognise as absent. Every optional field here is `decodeIfPresent`
/// by construction (Swift synthesises that for `Optional`), which is the same rule
/// `MeetingModels` learned the hard way: a new field must never orphan an older file.
///
/// Nothing in here leaves the Mac. The exporter writes where the person pointed the save
/// panel and nothing else.
struct MemoryPackage: Codable, Equatable, Sendable {
    static let formatIdentifier = "next-notes.assistant-memory"
    static let currentVersion = 1

    /// The whole assistant at one moment.
    struct Assistant: Codable, Equatable, Sendable {
        /// The name the person gave it.
        var name: String
        /// The avatar as `AgentIdentityStore` stores it, so a restore looks the same.
        var avatar: NotionAvatarConfig?
        /// `persona.md` — the SOUL — exactly as written.
        var soul: String?
    }

    /// One remembered fact.
    struct Memory: Codable, Equatable, Sendable, Identifiable {
        var id: UUID
        /// `profile` or `note`, matching `MemoryEntry.Kind`.
        var kind: String
        var text: String
        /// `MemoryEntry.Source` — how it was first saved.
        var source: String
        /// "Grok", "ChatGPT" … when this fact was itself imported.
        var importedFrom: String?
        var createdAt: Date
        var updatedAt: Date

        init(_ entry: MemoryEntry) {
            id = entry.id
            kind = entry.kind.rawValue
            text = entry.text
            source = entry.source.rawValue
            importedFrom = entry.importedFrom
            createdAt = entry.createdAt
            updatedAt = entry.updatedAt
        }

        init(id: UUID, kind: String, text: String, source: String,
             importedFrom: String? = nil, createdAt: Date, updatedAt: Date) {
            self.id = id
            self.kind = kind
            self.text = text
            self.source = source
            self.importedFrom = importedFrom
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }

        /// The entry this row restores to, or nil when the kind or source is from a newer
        /// build. A row that cannot be placed is reported, never guessed at.
        var entry: MemoryEntry? {
            guard let kind = MemoryEntry.Kind(rawValue: kind) else { return nil }
            let source = MemoryEntry.Source(rawValue: source) ?? .manual
            return MemoryEntry(id: id, kind: kind, text: text, source: source,
                               createdAt: createdAt, updatedAt: updatedAt,
                               importedFrom: importedFrom)
        }
    }

    /// One name or label the app already knew — a meeting title, a person, a spoken term.
    /// Carried so a restore starts with the same grounding, not only the same facts.
    struct ActivityLabel: Codable, Equatable, Sendable {
        var kind: String
        var key: String
        var value: String
        var source: String
        var updatedAt: Date
        var useCount: Int

        init(_ item: NextMemoryItem) {
            kind = item.kind.rawValue
            key = item.key
            value = item.value
            source = item.source
            updatedAt = item.updatedAt
            useCount = item.useCount
        }

        init(kind: String, key: String, value: String, source: String, updatedAt: Date, useCount: Int) {
            self.kind = kind
            self.key = key
            self.value = value
            self.source = source
            self.updatedAt = updatedAt
            self.useCount = useCount
        }

        var item: NextMemoryItem? {
            guard let kind = NextMemoryKind(rawValue: kind) else { return nil }
            return NextMemoryItem(kind: kind, key: key, value: value, source: source,
                                  updatedAt: updatedAt, useCount: useCount)
        }
    }

    /// A routine, only when the person asked for routines to be included.
    struct Routine: Codable, Equatable, Sendable {
        var title: String
        var prompt: String
        var schedule: String
        var isEnabled: Bool
    }

    var format: String
    var version: Int
    var exportedAt: Date
    /// The app that wrote it, for a person reading the file a year from now.
    var writtenBy: String
    var assistant: Assistant
    var memories: [Memory]
    var activity: [ActivityLabel]
    var routines: [Routine]?

    init(
        exportedAt: Date, writtenBy: String = MemoryPackage.defaultWriter,
        assistant: Assistant, memories: [Memory], activity: [ActivityLabel],
        routines: [Routine]? = nil
    ) {
        format = Self.formatIdentifier
        version = Self.currentVersion
        self.exportedAt = exportedAt
        self.writtenBy = writtenBy
        self.assistant = assistant
        self.memories = memories
        self.activity = activity
        self.routines = routines
    }

    static var defaultWriter: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return version.map { "Next Notes \($0)" } ?? "Next Notes"
    }

    // MARK: - Files

    /// The JSON file inside the exported folder. A fixed name, because the importer looks
    /// for it when the person hands back the folder rather than the file.
    static let jsonFileName = "memory.json"
    static let markdownFileName = "Memory.md"

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func jsonData() throws -> Data {
        try Self.encoder().encode(self)
    }

    /// Decodes one of ours, or nil when the data is some other JSON. Never throws on a
    /// foreign file: the caller falls through to the tolerant text path.
    static func decode(_ data: Data) -> MemoryPackage? {
        guard let package = try? decoder().decode(MemoryPackage.self, from: data),
              package.format == formatIdentifier,
              package.version <= currentVersion else { return nil }
        return package
    }

    // MARK: - The readable half

    /// The same contents as prose, so the person can read the export without a JSON viewer
    /// and paste it into any other assistant.
    func markdown() -> String {
        let day = DateFormatter()
        day.dateStyle = .long
        day.timeStyle = .short

        var lines: [String] = []
        lines.append("# \(assistant.name) — memory")
        lines.append("")
        lines.append("Exported from \(writtenBy) on \(day.string(from: exportedAt)).")
        lines.append("")
        lines.append("This is everything your assistant knows about you. It never left this Mac.")
        lines.append("`\(Self.jsonFileName)` beside this file is the same thing in a form Next Notes "
                     + "can read back.")
        lines.append("")

        lines.append("## Soul")
        lines.append("")
        let soul = (assistant.soul ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append(soul.isEmpty ? "_Nothing written yet._" : soul)
        lines.append("")

        for kind in MemoryEntry.Kind.allCases {
            let rows = memories.filter { $0.kind == kind.rawValue }
                .sorted { $0.createdAt > $1.createdAt }
            lines.append("## \(kind.displayName)")
            lines.append("")
            if rows.isEmpty {
                lines.append("_None._")
            } else {
                for row in rows {
                    let source = MemoryEntry.Source(rawValue: row.source)?.displayName ?? row.source
                    let origin = row.importedFrom.map { "imported from \($0)" } ?? source
                    lines.append("- \(row.text) — \(origin), \(day.string(from: row.createdAt))")
                }
            }
            lines.append("")
        }

        lines.append("## Names and labels")
        lines.append("")
        if activity.isEmpty {
            lines.append("_None._")
        } else {
            for label in activity.sorted(by: { $0.updatedAt > $1.updatedAt }) {
                lines.append("- \(label.value) (\(label.kind))")
            }
        }
        lines.append("")

        if let routines, !routines.isEmpty {
            lines.append("## Routines")
            lines.append("")
            for routine in routines {
                let state = routine.isEnabled ? "on" : "off"
                lines.append("- **\(routine.title)** — \(routine.schedule), \(state)")
                lines.append("  > \(routine.prompt.replacingOccurrences(of: "\n", with: " "))")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }
}

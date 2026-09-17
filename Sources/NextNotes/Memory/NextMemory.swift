import Foundation
import Observation

/// The small, local memory the Agent keeps about the person using it.
///
/// Two tiers live in one replaceable JSON file, `next-memory.json`:
///
/// - **Core memory** — `MemoryEntry` rows of kind `profile` (facts about the user) and
///   `note` (what the Agent has learned about working here). Small, character-budgeted,
///   declarative, and injected into prompts as a snapshot frozen per session.
/// - **Activity items** — names and labels Next Notes already knows (meeting attendees and
///   titles, dictionary vocabulary, project roots, tool preferences), matched per request.
///   Never transcript bodies or mail contents. They are derived and rebuild themselves.
///
/// A corrupted file can be discarded without affecting meetings or dictation history.
enum NextMemoryKind: String, Codable, CaseIterable, Sendable {
    case person
    case project
    case vocabulary
    case meeting
    case commitment
    case file
    case toolPreference
    case recurringAction
}

struct NextMemoryItem: Codable, Identifiable, Equatable, Sendable {
    var id: String { "\(kind.rawValue):\(key)" }
    let kind: NextMemoryKind
    let key: String
    var value: String
    var source: String
    var updatedAt: Date
    var useCount: Int
}

/// One core-memory fact. Activity items keep their own `NextMemoryItem` record: they are
/// keyed labels that rebuild from app state, not sentences someone said.
struct MemoryEntry: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        /// Facts about the user. "The user prefers answers under two sentences."
        case profile
        /// What the Agent has learned about working here.
        case note

        var displayName: String {
            switch self {
            case .profile: "About you"
            case .note: "Notes"
            }
        }

        /// Characters, not tokens, so a budget does not change with the model.
        var budget: Int {
            switch self {
            case .profile: 1_200
            case .note: 2_000
            }
        }
    }

    enum Source: String, Codable, CaseIterable, Sendable {
        /// Saved during a conversation from something the user said.
        case userSaid
        /// Saved by the background memory review reading what the user said.
        case review
        /// Promoted from app activity.
        case activity
        /// Typed in Settings.
        case manual

        var displayName: String {
            switch self {
            case .userSaid: "You said"
            case .review: "Learned"
            case .activity: "From activity"
            case .manual: "Added by you"
            }
        }
    }

    let id: UUID
    var kind: Kind
    /// One declarative sentence.
    var text: String
    var source: Source
    /// The conversation it came from.
    var sessionID: UUID?
    var createdAt: Date
    var updatedAt: Date
    /// The entry this replaced, kept in `NextMemory.superseded` for undo and Forget.
    var supersedes: UUID?

    init(
        id: UUID = UUID(), kind: Kind, text: String, source: Source, sessionID: UUID? = nil,
        createdAt: Date, updatedAt: Date? = nil, supersedes: UUID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.source = source
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.supersedes = supersedes
    }
}

/// Why a core-memory write did not happen. The message is what the model and Settings see.
/// Overflow and match errors carry the current entries, so the model can merge or replace
/// in the same turn instead of the store silently dropping the oldest fact.
enum MemoryWriteError: Error, LocalizedError, Equatable {
    case disabled
    case empty
    case tooLong(limit: Int)
    case notDeclarative
    case invalidKind
    case blocked(String)
    case provenance(String)
    /// Mostly the model's wording rather than the user's; it may retry in their words.
    case notUserWords(String)
    case overBudget(kind: MemoryEntry.Kind, used: Int, adding: Int, current: [MemoryEntry])
    case noMatch(match: String, current: [MemoryEntry])
    case ambiguous(match: String, candidates: [MemoryEntry])
    case storage(String)

    /// The model can fix these itself on the next step of the same turn.
    var isRecoverable: Bool {
        switch self {
        case .overBudget, .noMatch, .ambiguous, .notDeclarative, .tooLong, .empty, .invalidKind, .notUserWords: true
        case .disabled, .blocked, .provenance, .storage: false
        }
    }

    var errorDescription: String? {
        switch self {
        case .disabled:
            return "Memory is turned off in Settings."
        case .empty:
            return "There was nothing to remember."
        case .tooLong(let limit):
            return "A memory is one sentence of at most \(limit) characters."
        case .notDeclarative:
            return "Write the memory as a fact, not a command — for example "
                + "\"The user prefers short answers.\""
        case .invalidKind:
            return "kind must be profile or note."
        case .blocked(let reason):
            return "Not saved: \(reason)"
        case .provenance(let reason), .notUserWords(let reason):
            return "Not saved: \(reason)"
        case .overBudget(let kind, let used, let adding, let current):
            return "Not saved: \(kind.rawValue) memory is full (\(used) of \(kind.budget) characters "
                + "used; this adds \(adding)). Merge or replace an entry with memory.update, or "
                + "remove one with memory.forget. Current \(kind.rawValue) entries (data): "
                + Self.render(current)
        case .noMatch(let match, let current):
            return "No remembered fact contains \"\(match)\". Current entries (data): "
                + Self.render(current)
        case .ambiguous(let match, let candidates):
            return "\"\(match)\" matches more than one remembered fact; use a longer part of one. "
                + "Matches (data): " + Self.render(candidates)
        case .storage(let reason):
            return "Memory could not be saved: \(reason)"
        }
    }

    /// JSON, so remembered text stays data inside an error the model reads.
    static func render(_ entries: [MemoryEntry]) -> String {
        let rows = entries.map { ["kind": $0.kind.rawValue, "text": $0.text] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(rows),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }
}

@MainActor
@Observable
final class NextMemory {
    /// The production store. A self-test never touches the user's `next-memory.json`: it
    /// gets a per-process temporary directory.
    static let shared: NextMemory = {
        if SelfTest.isRunning {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("NextNotesSelfTest-memory-\(ProcessInfo.processInfo.processIdentifier)",
                                        isDirectory: true)
            return NextMemory(directory: directory, snapshotCache: .shared)
        }
        return NextMemory(directory: AppIdentity.applicationSupportDirectory, snapshotCache: .shared,
                          isEnabled: { MemorySnapshotCache.defaultsEnabled })
    }()

    static let fileName = "next-memory.json"
    static let maxEntryLength = 300

    private(set) var items: [NextMemoryItem] = []
    /// Active profile and note entries, oldest first.
    private(set) var entries: [MemoryEntry] = []
    /// Entries replaced by `update`, kept so a change can be undone and fully forgotten.
    private(set) var superseded: [MemoryEntry] = []
    /// Entries that failed the injection scan on load. Listed, never injected.
    private(set) var flagged: [UUID: String] = [:]
    /// When the Memories list was last closed; review saves after this carry a *New* badge.
    private(set) var listViewedAt: Date?

    let fileURL: URL?
    private let snapshotCache: MemorySnapshotCache
    private let enabledProvider: () -> Bool
    private let now: () -> Date
    private static let maxItems = 240
    private static let maxValueLength = 240

    /// - Parameters:
    ///   - directory: where `next-memory.json` lives; `nil` keeps everything in memory.
    ///   - snapshotCache: where the frozen prompt snapshot is published.
    init(
        directory: URL?,
        snapshotCache: MemorySnapshotCache = MemorySnapshotCache(isEnabled: { true }),
        isEnabled: @escaping () -> Bool = { true },
        now: @escaping () -> Date = Date.init
    ) {
        fileURL = directory?.appendingPathComponent(Self.fileName)
        self.snapshotCache = snapshotCache
        enabledProvider = isEnabled
        self.now = now
        load()
        beginSession()
    }

    var isEnabled: Bool { enabledProvider() }

    // MARK: - Activity items

    /// Rebuilds only from local activity that already has a stable typed representation.
    /// It is cheap enough to call before an agent turn and does not read raw transcripts.
    func refreshFromActivity() {
        var changed = false

        for entry in DictionaryStore.shared.entries where entry.isEnabled {
            switch entry.kind {
            case .term:
                changed = upsert(
                    kind: .vocabulary,
                    key: entry.write,
                    value: entry.write,
                    source: "dictionary"
                ) || changed
            case .correction:
                changed = upsert(
                    kind: .vocabulary,
                    key: entry.hear,
                    value: entry.write,
                    source: "dictionary"
                ) || changed
            }
        }

        for meeting in MeetingStore.shared.meetings {
            changed = upsert(
                kind: .meeting,
                key: meeting.title,
                value: meeting.title,
                source: "meeting:\(meeting.id.uuidString)"
            ) || changed
            for attendee in meeting.attendees {
                changed = upsert(
                    kind: .person,
                    key: attendee,
                    value: attendee,
                    source: "meeting:\(meeting.id.uuidString)"
                ) || changed
            }
        }

        for task in AgentTaskManager.shared.tasks {
            for reference in task.contextReferences where reference.hasPrefix("project://") {
                let path = String(reference.dropFirst("project://".count))
                changed = upsert(
                    kind: .project,
                    key: path,
                    value: path,
                    source: "task:\(task.id)"
                ) || changed
            }
            if !task.acpCLI.isEmpty {
                changed = upsert(
                    kind: .toolPreference,
                    key: task.acpCLI,
                    value: task.acpCLI,
                    source: "task:\(task.id)"
                ) || changed
            }
        }

        if changed { try? persist() }
    }

    /// Adds a single activity label, replacing the old value for that key and kind.
    @discardableResult
    func remember(
        _ kind: NextMemoryKind,
        key: String,
        value: String,
        source: String
    ) -> Bool {
        let changed = upsert(kind: kind, key: key, value: value, source: source)
        if changed { try? persist() }
        return changed
    }

    /// Returns the best bounded matches for a spoken phrase. Exact values win, then
    /// contains matches, then token overlap. A query never causes a new memory entry.
    func matches(_ query: String, limit: Int = 8) -> [NextMemoryItem] {
        let needle = Self.normalize(query)
        guard !needle.isEmpty, limit > 0 else { return [] }
        let queryTokens = Set(needle.split(separator: " ").map(String.init))
        return items
            .map { item in
                let key = Self.normalize(item.key)
                let value = Self.normalize(item.value)
                let score: Int
                if key == needle || value == needle {
                    score = 1000
                } else if key.contains(needle) || value.contains(needle) {
                    score = 700 + item.useCount
                } else {
                    let tokens = Set((key + " " + value).split(separator: " ").map(String.init))
                    let overlap = tokens.intersection(queryTokens).count
                    score = overlap > 0 ? overlap * 100 + item.useCount : 0
                }
                return (item, score)
            }
            .filter { $0.1 > 0 }
            .sorted {
                if $0.1 != $1.1 { return $0.1 > $1.1 }
                return $0.0.updatedAt > $1.0.updatedAt
            }
            .prefix(limit)
            .map(\.0)
    }

    /// JSON keeps activity-sourced labels on one data line. Meeting titles and attendee
    /// names can be supplied by other people, so they must never become prompt syntax.
    func grounding(for query: String, limit: Int = 8) -> String {
        let facts = matches(query, limit: limit).map {
            ["kind": $0.kind.rawValue, "value": $0.value]
        }
        guard !facts.isEmpty,
              let data = try? JSONEncoder().encode(facts),
              let json = String(data: data, encoding: .utf8) else { return "" }
        return json
    }

    func clearForTesting() {
        items = []
        entries = []
        superseded = []
        flagged = [:]
    }

    // MARK: - Core memory: reads

    func used(_ kind: MemoryEntry.Kind) -> Int {
        entries.filter { $0.kind == kind }.reduce(0) { $0 + $1.text.count }
    }

    /// Newest first, as the Memories list shows them.
    func entries(of kind: MemoryEntry.Kind) -> [MemoryEntry] {
        entries.filter { $0.kind == kind }.sorted { $0.createdAt > $1.createdAt }
    }

    func entry(id: UUID) -> MemoryEntry? { entries.first { $0.id == id } }

    /// A review save the user has not seen in the Memories list yet.
    func isNew(_ entry: MemoryEntry) -> Bool {
        entry.source == .review && entry.createdAt > (listViewedAt ?? .distantPast)
    }

    var newCount: Int { entries.filter(isNew).count }

    /// `memory.recall`: core entries whose words overlap the query, then activity matches.
    /// The Part 4 index replaces the second half later.
    func recall(_ query: String, limit: Int = 8) -> (entries: [MemoryEntry], activity: [NextMemoryItem]) {
        let queryTokens = Set(MemoryGuard.tokens(query))
        var scored: [(entry: MemoryEntry, score: Int)] = []
        for entry in entries where flagged[entry.id] == nil {
            let score = Set(MemoryGuard.tokens(entry.text)).intersection(queryTokens).count
            if queryTokens.isEmpty || score > 0 { scored.append((entry, score)) }
        }
        scored.sort { lhs, rhs in
            lhs.score != rhs.score ? lhs.score > rhs.score : lhs.entry.createdAt > rhs.entry.createdAt
        }
        let found: [MemoryEntry] = scored.prefix(limit).map { $0.entry }
        return (found, queryTokens.isEmpty ? [] : matches(query, limit: limit))
    }

    // MARK: - Core memory: writes

    /// Result of a write the store accepted.
    struct WriteOutcome: Sendable {
        let entry: MemoryEntry
        /// The entry it replaced, for `update`.
        let replaced: MemoryEntry?
        /// The same fact was already remembered; nothing changed.
        let wasDuplicate: Bool
    }

    /// Adds one fact. Rejects a write that would exceed the kind's budget rather than trim.
    @discardableResult
    func remember(
        kind: MemoryEntry.Kind, text raw: String, source: MemoryEntry.Source, sessionID: UUID? = nil
    ) throws -> WriteOutcome {
        if source != .manual, !isEnabled { throw MemoryWriteError.disabled }
        let text = try Self.validated(raw)
        let key = Self.normalize(text)
        if let existing = entries.first(where: { $0.kind == kind && Self.normalize($0.text) == key }) {
            return WriteOutcome(entry: existing, replaced: nil, wasDuplicate: true)
        }
        let used = used(kind)
        guard used + text.count <= kind.budget else {
            throw MemoryWriteError.overBudget(kind: kind, used: used, adding: text.count,
                                              current: unflaggedEntries(of: kind))
        }
        let date = now()
        let entry = MemoryEntry(kind: kind, text: text, source: source, sessionID: sessionID, createdAt: date)
        try commit { $0.entries.append(entry) }
        return WriteOutcome(entry: entry, replaced: nil, wasDuplicate: false)
    }

    /// Replaces the one fact containing `match`. The old entry is kept under `supersedes`
    /// rather than left beside the new one: a stale preference next to its replacement
    /// keeps getting followed.
    @discardableResult
    func update(
        match: String, text raw: String, source: MemoryEntry.Source, sessionID: UUID? = nil
    ) throws -> WriteOutcome {
        if source != .manual, !isEnabled { throw MemoryWriteError.disabled }
        let old = try uniqueEntry(matching: match)
        let text = try Self.validated(raw)
        if Self.normalize(text) == Self.normalize(old.text) {
            return WriteOutcome(entry: old, replaced: nil, wasDuplicate: true)
        }
        let used = used(old.kind) - old.text.count
        guard used + text.count <= old.kind.budget else {
            throw MemoryWriteError.overBudget(kind: old.kind, used: used + old.text.count,
                                              adding: text.count - old.text.count,
                                              current: unflaggedEntries(of: old.kind))
        }
        let date = now()
        let replacement = MemoryEntry(kind: old.kind, text: text, source: source, sessionID: sessionID,
                                      createdAt: date, supersedes: old.id)
        try commit { state in
            state.entries.removeAll { $0.id == old.id }
            state.entries.append(replacement)
            state.superseded.append(old)
        }
        return WriteOutcome(entry: replacement, replaced: old, wasDuplicate: false)
    }

    /// The one fact containing `match`, for a tool to check before it changes it.
    func entry(matching match: String) throws -> MemoryEntry {
        try uniqueEntry(matching: match)
    }

    /// Texts a write's provenance may lean on: the user said each of them when it was saved.
    var rememberedTexts: [String] {
        entries.filter { flagged[$0.id] == nil }.map(\.text)
    }

    /// `memory.forget`: the one fact containing `match`, with every earlier version of it.
    /// The frozen snapshot only loses that fact, so this session's other saves stay out of
    /// the prompt until the next session.
    @discardableResult
    func forget(match: String) throws -> MemoryEntry {
        let entry = try uniqueEntry(matching: match)
        try forget(id: entry.id, refreezeSnapshot: false)
        return entry
    }

    /// Settings' Forget button. Removes the entry and the chain of entries it superseded,
    /// so a forgotten fact cannot come back through undo.
    func forget(id: UUID) throws {
        try forget(id: id, refreezeSnapshot: true)
    }

    private func forget(id: UUID, refreezeSnapshot: Bool) throws {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        var chain: Set<UUID> = [entry.id]
        var cursor = entry.supersedes
        while let previous = cursor, let found = superseded.first(where: { $0.id == previous }) {
            chain.insert(found.id)
            cursor = found.supersedes
        }
        let texts = (entries + superseded).filter { chain.contains($0.id) }.map(\.text)
        try commit { state in
            state.entries.removeAll { chain.contains($0.id) }
            state.superseded.removeAll { chain.contains($0.id) }
        }
        flagged[id] = nil
        if refreezeSnapshot {
            freezeSnapshot()
        } else {
            snapshotCache.drop(texts)
        }
    }

    /// Called after *Forget everything*. `KnowledgeIndexer.connect` sets it on the shared
    /// store, so the indexed conversations go with the memories.
    @ObservationIgnored var onForgetEverything: (() -> Void)?

    /// Settings' *Forget everything*: every core entry, its history, and the activity index
    /// (which rebuilds itself from app state) — and every indexed Agent conversation.
    func forgetEverything() throws {
        try commit { state in
            state.entries = []
            state.superseded = []
            state.items = []
        }
        flagged = [:]
        freezeSnapshot()
        onForgetEverything?()
    }

    /// Edit in place from Settings. The same guards as any other write apply, and the entry
    /// becomes the user's own: "You said" no longer describes words they rewrote.
    func edit(id: UUID, text raw: String) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let old = entries[index]
        let text = try Self.validated(raw)
        guard text != old.text else { return }
        let key = Self.normalize(text)
        if entries.contains(where: { $0.id != id && $0.kind == old.kind && Self.normalize($0.text) == key }) {
            throw MemoryWriteError.blocked("that fact is already remembered.")
        }
        let used = used(old.kind) - old.text.count
        guard used + text.count <= old.kind.budget else {
            throw MemoryWriteError.overBudget(kind: old.kind, used: used + old.text.count,
                                              adding: text.count - old.text.count,
                                              current: unflaggedEntries(of: old.kind))
        }
        let date = now()
        try commit { state in
            guard let position = state.entries.firstIndex(where: { $0.id == id }) else { return }
            state.entries[position].text = text
            state.entries[position].source = .manual
            state.entries[position].updatedAt = date
        }
        flagged[id] = nil
        freezeSnapshot()
    }

    /// Puts back the entry an update replaced, and drops the replacement.
    func undoSupersede(id: UUID) throws {
        guard let entry = entries.first(where: { $0.id == id }),
              let previousID = entry.supersedes,
              let previous = superseded.first(where: { $0.id == previousID }) else { return }
        let used = used(entry.kind) - entry.text.count
        guard used + previous.text.count <= entry.kind.budget else {
            throw MemoryWriteError.overBudget(kind: entry.kind, used: used + entry.text.count,
                                              adding: previous.text.count - entry.text.count,
                                              current: unflaggedEntries(of: entry.kind))
        }
        try commit { state in
            state.entries.removeAll { $0.id == id }
            state.superseded.removeAll { $0.id == previousID }
            state.entries.append(previous)
        }
        freezeSnapshot()
    }

    func markListViewed() {
        let date = now()
        let previous = listViewedAt
        listViewedAt = date
        do { try persist() } catch { listViewedAt = previous }
    }

    // MARK: - The frozen snapshot

    /// Core memory is read once per session and not rebuilt mid-session, so the cached
    /// prompt prefix survives. A save made during the session is already in the
    /// conversation. Called on launch, on *Clear conversation*, and after a user's own
    /// Forget or edit in Settings — a forgotten fact must leave the prompt immediately.
    func beginSession() {
        freezeSnapshot()
    }

    private func freezeSnapshot() {
        let usable = entries.filter { flagged[$0.id] == nil }
            .sorted { $0.createdAt > $1.createdAt }
        snapshotCache.freeze(
            profile: usable.filter { $0.kind == .profile }.map(\.text),
            notes: usable.filter { $0.kind == .note }.map(\.text)
        )
    }

    // MARK: - Export

    func markdownExport() -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        var lines = ["# Next Notes memories", "", "Exported \(formatter.string(from: now())).", ""]
        for kind in MemoryEntry.Kind.allCases {
            lines.append("## \(kind.displayName) (\(used(kind)) / \(kind.budget) characters)")
            lines.append("")
            let rows = entries(of: kind)
            if rows.isEmpty { lines.append("_None._") }
            for entry in rows {
                lines.append("- \(entry.text) — \(entry.source.displayName), \(formatter.string(from: entry.createdAt))")
            }
            lines.append("")
        }
        lines.append("## Activity (\(items.count))")
        lines.append("")
        for item in items.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            lines.append("- \(item.kind.rawValue): \(item.value)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Private

    /// What an error may show the model: a flagged entry is listed in Settings, never injected.
    private func unflaggedEntries(of kind: MemoryEntry.Kind? = nil) -> [MemoryEntry] {
        (kind.map(entries(of:)) ?? entries).filter { flagged[$0.id] == nil }
    }

    private func uniqueEntry(matching raw: String) throws -> MemoryEntry {
        let match = Self.normalize(raw)
        guard !match.isEmpty else { throw MemoryWriteError.noMatch(match: raw, current: unflaggedEntries()) }
        let found = entries.filter { Self.normalize($0.text).contains(match) }
        if found.count == 1 { return found[0] }
        if found.isEmpty { throw MemoryWriteError.noMatch(match: raw, current: unflaggedEntries()) }
        if let exact = found.first(where: { Self.normalize($0.text) == match }) { return exact }
        throw MemoryWriteError.ambiguous(match: raw, candidates: found.filter { flagged[$0.id] == nil })
    }

    /// Newlines and runs of spaces collapse to single spaces, so nothing hides on a second
    /// line and a stray newline is not mistaken for an invisible character.
    static func collapsedWhitespace(_ raw: String) -> String {
        raw.split(whereSeparator: { $0.isNewline || $0 == "\t" })
            .joined(separator: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One sentence, guarded. Newlines collapse to spaces before the scan so nothing hides
    /// on a second line; everything else invisible is refused, not stripped.
    static func validated(_ raw: String) throws -> String {
        let collapsed = collapsedWhitespace(raw)
        guard !collapsed.isEmpty else { throw MemoryWriteError.empty }
        if let finding = MemoryGuard.scan(collapsed) {
            throw MemoryWriteError.blocked(finding.reason)
        }
        guard collapsed.count <= maxEntryLength else { throw MemoryWriteError.tooLong(limit: maxEntryLength) }
        guard MemoryGuard.isDeclarative(collapsed) else { throw MemoryWriteError.notDeclarative }
        guard let last = collapsed.last, ".!?".contains(last) else { return collapsed + "." }
        return collapsed
    }

    private struct State {
        var entries: [MemoryEntry]
        var superseded: [MemoryEntry]
        var items: [NextMemoryItem]
    }

    /// Applies a change and writes it. A failed write (full disk, read-only volume) restores
    /// the previous state and throws, so memory in the app never disagrees with the file.
    private func commit(_ change: (inout State) -> Void) throws {
        let previous = State(entries: entries, superseded: superseded, items: items)
        var next = previous
        change(&next)
        entries = next.entries
        superseded = next.superseded
        items = next.items
        do {
            try persist()
        } catch {
            entries = previous.entries
            superseded = previous.superseded
            items = previous.items
            throw MemoryWriteError.storage(error.localizedDescription)
        }
    }

    private func upsert(kind: NextMemoryKind, key: String, value: String, source: String) -> Bool {
        let cleanKey = String(key
            .split(whereSeparator: { $0.isNewline })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(Self.maxValueLength)
        )
        let cleanValue = String(value
            .split(whereSeparator: { $0.isNewline })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(Self.maxValueLength)
        )
        guard !cleanKey.isEmpty, !cleanValue.isEmpty else { return false }
        let normalizedKey = Self.normalize(cleanKey)
        guard !normalizedKey.isEmpty else { return false }
        if let index = items.firstIndex(where: { $0.kind == kind && Self.normalize($0.key) == normalizedKey }) {
            let old = items[index]
            guard old.value != cleanValue || old.source != source else { return false }
            items[index].value = cleanValue
            items[index].source = source
            items[index].updatedAt = now()
            items[index].useCount = old.useCount + 1
            return old.value != cleanValue || old.source != source
        }
        items.append(NextMemoryItem(
            kind: kind,
            key: cleanKey,
            value: cleanValue,
            source: source,
            updatedAt: now(),
            useCount: 1
        ))
        if items.count > Self.maxItems {
            items.sort { $0.updatedAt > $1.updatedAt }
            items = Array(items.prefix(Self.maxItems))
        }
        return true
    }

    /// Version 2 of `next-memory.json`. Version 1 was a bare array of activity items.
    private struct StoredFile: Codable {
        var version: Int
        var entries: [MemoryEntry]
        var superseded: [MemoryEntry]
        var activity: [NextMemoryItem]
        var listViewedAt: Date?
    }

    private func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let stored = try? decoder.decode(StoredFile.self, from: data) {
            entries = stored.entries
            superseded = stored.superseded
            items = Array(stored.activity.prefix(Self.maxItems))
            listViewedAt = stored.listViewedAt
        } else if let legacy = try? decoder.decode([NextMemoryItem].self, from: data) {
            // Migration: keep every existing activity item, start core memory empty.
            items = Array(legacy.prefix(Self.maxItems))
            do {
                try persist()
                Log.agent.info("next-memory.json migrated to version 2 with \(legacy.count) activity items")
            } catch {
                Log.agent.error("next-memory.json migration not written: \(error.localizedDescription, privacy: .public)")
            }
        } else {
            // Unreadable: set it aside rather than overwrite it on the next write.
            let aside = fileURL.deletingPathExtension()
                .appendingPathExtension("unreadable-\(Int(now().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            Log.agent.error("next-memory.json could not be read; moved aside")
        }
        // The scan runs on load as well as on write: a file edited outside the app, or an
        // entry written before a pattern existed, is listed but never injected.
        flagged = [:]
        for entry in entries {
            if let finding = MemoryGuard.scan(entry.text) { flagged[entry.id] = finding.reason }
        }
    }

    private func persist() throws {
        guard let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let stored = StoredFile(version: 2, entries: entries, superseded: superseded, activity: items,
                                listViewedAt: listViewedAt)
        let data = try encoder.encode(stored)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    static func normalize(_ raw: String) -> String {
        raw.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}

/// The core-memory snapshot as prompts hear it, frozen per session.
///
/// Thread-safe rather than `@MainActor`, for the same reason as `PersonaStore`: the prompt
/// builders that read it run on the Foundation Models frontend actor and in nonisolated
/// code. `NextMemory` publishes into it; nothing else writes.
final class MemorySnapshotCache: @unchecked Sendable {
    /// Shared with `Settings.agentMemoryEnabled`.
    static let enabledDefaultsKey = "agentMemoryEnabled"

    static var defaultsEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledDefaultsKey) as? Bool ?? true
    }

    static let shared = MemorySnapshotCache(isEnabled: {
        SelfTest.isRunning ? true : MemorySnapshotCache.defaultsEnabled
    })

    private let lock = NSLock()
    private var profile: [String] = []
    private var notes: [String] = []
    private let enabledProvider: @Sendable () -> Bool

    init(isEnabled: @escaping @Sendable () -> Bool) {
        enabledProvider = isEnabled
    }

    var isEnabled: Bool { enabledProvider() }

    /// Newest first.
    func freeze(profile: [String], notes: [String]) {
        lock.lock()
        defer { lock.unlock() }
        self.profile = profile
        self.notes = notes
    }

    /// Removes forgotten facts without re-reading the store, so the rest of the frozen
    /// snapshot (and the cached prompt prefix) stays as the session began.
    func drop(_ texts: [String]) {
        lock.lock()
        defer { lock.unlock() }
        profile.removeAll { texts.contains($0) }
        notes.removeAll { texts.contains($0) }
    }

    /// The memory section value for a path, within its budget, or empty.
    func text(for path: AgentPromptPath) -> String {
        guard isEnabled else { return "" }
        let limit = path.budget.memoryLimit
        guard limit > 0 else { return "" }
        lock.lock()
        let profile = self.profile
        let notes = self.notes
        lock.unlock()
        let includeNotes = switch path {
        case .toolLoop, .localModel, .scheduledRun: true
        case .voiceAnswer, .voiceRoute, .meetingAssistant, .knowledgeAsk, .acpAgent: false
        }
        return Self.render(profile: profile, notes: includeNotes ? notes : [], limit: limit)
    }

    /// One JSON array per kind, so stored text cannot act as prompt syntax. Whole entries
    /// only, newest first: a sentence cut in half can change its meaning.
    static func render(profile: [String], notes: [String], limit: Int) -> String {
        var remaining = limit
        func fit(_ label: String, _ texts: [String]) -> String? {
            var kept: [String] = []
            var line = ""
            for text in texts {
                let candidate = label + ": " + json(kept + [text])
                if candidate.count <= remaining {
                    kept.append(text)
                    line = candidate
                }
            }
            guard !kept.isEmpty else { return nil }
            remaining -= line.count + 1
            return line
        }
        return [fit("profile", profile), fit("notes", notes)]
            .compactMap { $0 }
            .joined(separator: "\n")
    }

    private static func json(_ texts: [String]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(texts), let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return string
    }
}

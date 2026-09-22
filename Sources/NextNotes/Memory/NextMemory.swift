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
        ///
        /// This is the size of the *store*, not of the prompt. What actually reaches a model
        /// is bounded again, per path, by `AgentPromptPath.budget.memoryLimit` through
        /// `MemorySnapshotCache.render`, which fits whole entries newest-first. Raised from
        /// 1,200 / 2,000 once memory started learning from dictations and meetings as well
        /// as conversations: at the old size a real profile filled up in a week and every
        /// later fact was refused.
        var budget: Int {
            switch self {
            case .profile: 2_400
            case .note: 4_000
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
        /// Brought in from a file or from another assistant, after the person reviewed it.
        /// `MemoryEntry.importedFrom` names which one.
        case imported

        var displayName: String {
            switch self {
            case .userSaid: "You said"
            case .review: "Learned"
            case .activity: "From activity"
            case .manual: "Added by you"
            case .imported: "Imported"
            }
        }

        /// Whether the person made this write themselves rather than the Agent making it.
        /// Those two are the writes that still happen while *Remember what I tell the
        /// Agent* is off: the switch is a promise about what the Agent saves on its own,
        /// not a lock on the person's own list.
        var isPersonsOwnWrite: Bool {
            switch self {
            case .manual, .imported: true
            case .userSaid, .review, .activity: false
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
    /// Where an imported fact came from — "Grok", "a file", "ChatGPT". Shown beside it in
    /// the list so nobody has to wonder later where a sentence came from.
    ///
    /// Optional, so Swift's synthesized `init(from:)` decodes it with `decodeIfPresent` and
    /// a `next-memory.json` written before this field existed still loads.
    var importedFrom: String?
    /// The one import this entry arrived in, so the whole batch can be undone together.
    var importBatchID: UUID?
    /// Which of the user's own channels the words came from. Optional so a `next-memory.json`
    /// written before memory learned from anything but conversations still decodes.
    var origin: MemoryProvenance.TrustedSource?
    /// "your dictation on 19 Sep", "your call with Mathieu" — the rest of the plain-words
    /// phrase the Memories list shows beside the fact.
    var sourceLabel: String?
    /// 0…1. How sure the Agent is, by channel: what you told it outranks what the life map
    /// inferred. Shown as words, never as a number.
    var confidence: Double?

    init(
        id: UUID = UUID(), kind: Kind, text: String, source: Source, sessionID: UUID? = nil,
        createdAt: Date, updatedAt: Date? = nil, supersedes: UUID? = nil,
        importedFrom: String? = nil, importBatchID: UUID? = nil,
        origin: MemoryProvenance.TrustedSource? = nil, sourceLabel: String? = nil,
        confidence: Double? = nil
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.source = source
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.supersedes = supersedes
        self.importedFrom = importedFrom
        self.importBatchID = importBatchID
        self.origin = origin
        self.sourceLabel = sourceLabel
        self.confidence = confidence
    }

    /// Where this fact came from, in the words a non-technical person would use:
    /// "You told me, 20 Sep", "From your dictation on 19 Sep", "From your call with Mathieu".
    var whereFrom: String {
        if let label = importLabel { return label }
        let day = createdAt.formatted(.dateTime.day().month(.abbreviated))
        guard let origin else {
            // Written before origins existed, or typed in Settings.
            return source == .manual ? "Added by you, \(day)" : "\(source.displayName), \(day)"
        }
        if let sourceLabel, !sourceLabel.isEmpty {
            return "\(origin.displayName) \(sourceLabel)"
        }
        return "\(origin.displayName), \(day)"
    }

    /// "Imported from Grok, 19 Sep 2026", or nil when it was not imported.
    var importLabel: String? {
        guard let importedFrom else { return nil }
        return "Imported from \(importedFrom), "
            + createdAt.formatted(.dateTime.day().month(.abbreviated).year())
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
                          isEnabled: { MemorySnapshotCache.defaultsEnabled },
                          resolvedPeople: { PersonResolutionService.shared.memoryPeople() },
                          graphCloudConsent: { KnowledgeIndexer.shared.settings.graphCloudConsent })
    }()

    static let fileName = "next-memory.json"
    /// `nonisolated`, with the four pure helpers below, because the import pipeline screens
    /// and normalises text off the main actor before any of it reaches the store. None of
    /// them touches instance state — they are string functions that happen to live here.
    nonisolated static let maxEntryLength = 300

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
    /// Resolved people from the knowledge graph (Part 4, Phase D).
    private let resolvedPeopleProvider: () -> MemoryPeople
    /// Whether the user let a cloud model read the graph (`knowledgeGraphCloudConsent`).
    private let graphCloudConsentProvider: () -> Bool
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
        resolvedPeople: @escaping () -> MemoryPeople = { .graphOff },
        graphCloudConsent: @escaping () -> Bool = { false },
        now: @escaping () -> Date = Date.init
    ) {
        fileURL = directory?.appendingPathComponent(Self.fileName)
        self.snapshotCache = snapshotCache
        enabledProvider = isEnabled
        resolvedPeopleProvider = resolvedPeople
        graphCloudConsentProvider = graphCloudConsent
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

        // Resolved people replace keyword-matched attendee names: one person, one item.
        let people = applyMemoryPeople(resolvedPeopleProvider())
        changed = people.changed || changed
        let resolvedNames = people.names
        for meeting in MeetingStore.shared.meetings {
            changed = upsert(
                kind: .meeting,
                key: meeting.title,
                value: meeting.title,
                source: "meeting:\(meeting.id.uuidString)"
            ) || changed
            // A meeting not in the graph yet still contributes its attendees.
            for attendee in meeting.attendees where !resolvedNames.contains(Self.normalize(attendee)) {
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

    /// Makes the person items exactly one per resolved person: the name that heads the
    /// person as the key, every other name they were mentioned as in the value — so "S.K."
    /// finds Serge — and the person's node id (`person:…`) as the source. Attendee items naming a resolved person
    /// go; attendees the graph has not seen, and person items saved any other way, stay. Does not persist; the caller does.
    /// - Returns: whether anything changed.
    @discardableResult
    func applyResolvedPeople(_ people: [ResolvedPerson]) -> Bool {
        let before = items
        let covered = Set(people.flatMap { [$0.name] + $0.aliases }.map(Self.normalize))
        items.removeAll { item in
            item.kind == .person && (item.source.hasPrefix("person:")
                || (item.source.hasPrefix("meeting:") && covered.contains(Self.normalize(item.key))))
        }
        for person in people.sorted(by: { $0.id < $1.id }) {
            let aliases = person.aliases.filter { Self.normalize($0) != Self.normalize(person.name) }
            let value = aliases.isEmpty ? person.name : "\(person.name) (also \(aliases.joined(separator: ", ")))"
            // Carry a previous item's use count across the rewrite.
            let previous = before.first { $0.kind == .person && $0.source == person.id }
            // A person item saved another way already has this name: it stays as it is.
            guard !items.contains(where: { $0.kind == .person && Self.normalize($0.key) == Self.normalize(person.name) })
            else { continue }
            let clipped = String(value.prefix(Self.maxValueLength))
            items.append(NextMemoryItem(kind: .person, key: person.name, value: clipped, source: person.id,
                                        updatedAt: previous.map { $0.value == clipped ? $0.updatedAt : now() } ?? now(),
                                        useCount: previous?.useCount ?? 1))
        }
        if items.count > Self.maxItems {
            items.sort { $0.updatedAt > $1.updatedAt }
            items = Array(items.prefix(Self.maxItems))
        }
        return items != before
    }

    /// What resolution says about people, applied: resolved people become the person items,
    /// the graph switched off removes the ones it made, not loaded yet keeps what is there.
    /// Does not persist; the caller does.
    /// - Returns: whether anything changed, and the normalised names now covered by a person item.
    func applyMemoryPeople(_ state: MemoryPeople) -> (changed: Bool, names: Set<String>) {
        switch state {
        case .resolved(let resolved):
            let changed = applyResolvedPeople(resolved)
            return (changed, Set(resolved.flatMap { [$0.name] + $0.aliases }.map(Self.normalize)))
        case .graphOff:
            // Nothing the graph derived outlives the graph; attendees come back from meetings.
            return (removeResolvedPeople(), [])
        case .notLoaded:
            return (false, [])
        }
    }

    /// Removes every person item the knowledge graph made (`person:…` sources).
    /// - Returns: whether anything changed.
    @discardableResult
    func removeResolvedPeople() -> Bool {
        let count = items.count
        items.removeAll { Self.isGraphPerson($0) }
        return items.count != count
    }

    static func isGraphPerson(_ item: NextMemoryItem) -> Bool {
        item.kind == .person && item.source.hasPrefix("person:")
    }

    /// Whether `reader` may see graph-derived person items. They carry names the graph
    /// extracted (action item owners, renamed speakers, addresses), so like `expand_node`
    /// they reach a cloud model, or an unknown reader, only with `knowledgeGraphCloudConsent`.
    func mayShareGraphPeople(with reader: LLMProviderID?) -> Bool {
        KnowledgeGraphScope.mayRead(reader: reader, cloudConsent: graphCloudConsentProvider())
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
    /// - Parameter includeGraphPeople: false leaves out person items the knowledge graph made.
    func matches(_ query: String, limit: Int = 8, includeGraphPeople: Bool = true) -> [NextMemoryItem] {
        let needle = Self.normalize(query)
        guard !needle.isEmpty, limit > 0 else { return [] }
        let queryTokens = Set(needle.split(separator: " ").map(String.init))
        return items
            .filter { includeGraphPeople || !Self.isGraphPerson($0) }
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
    /// - Parameter reader: the model the grounding goes to; graph-derived people reach a cloud
    ///   one only with the graph's cloud consent. Defaults to the turn's `KnowledgeGraphScope`.
    func grounding(for query: String, limit: Int = 8, reader: LLMProviderID? = KnowledgeGraphScope.reader) -> String {
        let facts = matches(query, limit: limit, includeGraphPeople: mayShareGraphPeople(with: reader)).map {
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
    func recall(_ query: String, limit: Int = 8,
                reader: LLMProviderID? = KnowledgeGraphScope.reader) -> (entries: [MemoryEntry], activity: [NextMemoryItem]) {
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
        return (found, queryTokens.isEmpty ? []
                : matches(query, limit: limit, includeGraphPeople: mayShareGraphPeople(with: reader)))
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
        kind: MemoryEntry.Kind, text raw: String, source: MemoryEntry.Source, sessionID: UUID? = nil,
        importedFrom: String? = nil, importBatchID: UUID? = nil,
        origin: MemoryProvenance.TrustedSource? = nil, sourceLabel: String? = nil
    ) throws -> WriteOutcome {
        if !source.isPersonsOwnWrite, !isEnabled { throw MemoryWriteError.disabled }
        let text = try Self.validated(raw)
        let key = Self.normalize(text)
        if let existing = entries.first(where: { $0.kind == kind && Self.normalize($0.text) == key }) {
            return WriteOutcome(entry: existing, replaced: nil, wasDuplicate: true)
        }
        // The same fact said twice in different words is one fact. The channel the Agent
        // trusts more keeps its wording; the other write reports it as already known.
        if let near = nearDuplicate(kind: kind, text: text) {
            return WriteOutcome(entry: near, replaced: nil, wasDuplicate: true)
        }
        let used = used(kind)
        guard used + text.count <= kind.budget else {
            throw MemoryWriteError.overBudget(kind: kind, used: used, adding: text.count,
                                              current: unflaggedEntries(of: kind))
        }
        let date = now()
        let entry = MemoryEntry(kind: kind, text: text, source: source, sessionID: sessionID,
                                createdAt: date, importedFrom: importedFrom, importBatchID: importBatchID,
                                origin: origin, sourceLabel: sourceLabel, confidence: origin?.confidence)
        try commit { $0.entries.append(entry) }
        return WriteOutcome(entry: entry, replaced: nil, wasDuplicate: false)
    }

    /// An active entry of the same kind that says the same thing in different words, or nil.
    /// Three quarters of the content words shared is the same bar the review's own skip rule
    /// uses, so a fact rejected there and a fact merged here are judged alike.
    func nearDuplicate(kind: MemoryEntry.Kind, text: String) -> MemoryEntry? {
        let tokens = Set(MemoryGuard.contentTokens(text))
        guard !tokens.isEmpty else { return nil }
        return entries.first { entry in
            guard entry.kind == kind, flagged[entry.id] == nil else { return false }
            let other = Set(MemoryGuard.contentTokens(entry.text))
            guard !other.isEmpty else { return false }
            return Double(tokens.intersection(other).count) / Double(tokens.union(other).count) >= 0.75
        }
    }

    /// Replaces the one fact containing `match`. The old entry is kept under `supersedes`
    /// rather than left beside the new one: a stale preference next to its replacement
    /// keeps getting followed.
    @discardableResult
    func update(
        match: String, text raw: String, source: MemoryEntry.Source, sessionID: UUID? = nil,
        origin: MemoryProvenance.TrustedSource? = nil, sourceLabel: String? = nil
    ) throws -> WriteOutcome {
        if !source.isPersonsOwnWrite, !isEnabled { throw MemoryWriteError.disabled }
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
                                      createdAt: date, supersedes: old.id,
                                      origin: origin, sourceLabel: sourceLabel,
                                      confidence: origin?.confidence)
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
                lines.append("- \(entry.text) — \(entry.whereFrom)")
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

    // MARK: - Portability

    /// Every active fact, for the portable package. Flagged entries go too: they are the
    /// person's own data, and the importer re-runs the scan on the way back in.
    var packageMemories: [MemoryPackage.Memory] {
        entries.sorted { $0.createdAt < $1.createdAt }.map(MemoryPackage.Memory.init)
    }

    var packageActivity: [MemoryPackage.ActivityLabel] {
        items.sorted { $0.updatedAt < $1.updatedAt }.map(MemoryPackage.ActivityLabel.init)
    }

    /// What one import did, so the list can say it in a sentence and offer it back.
    struct ImportReceipt: Sendable {
        let batchID: UUID
        var saved: [MemoryEntry] = []
        /// Facts that did not fit, with why — a full budget, usually.
        var notSaved: [(text: String, reason: String)] = []
        /// Already remembered word for word; nothing was written for these.
        var alreadyKnown: [String] = []

        var isEmpty: Bool { saved.isEmpty }
    }

    /// Writes the facts the person ticked in the review step, under one batch id.
    ///
    /// Every write goes through `remember`, so the injection scan, the declarative rule, the
    /// length cap and the budget all still apply — imported text is untrusted no matter how
    /// carefully the review sheet screened it first. A fact that cannot be written does not
    /// stop the rest: the receipt names it instead.
    @discardableResult
    func applyImport(
        _ facts: [(kind: MemoryEntry.Kind, text: String)], from origin: String,
        batchID: UUID = UUID()
    ) -> ImportReceipt {
        var receipt = ImportReceipt(batchID: batchID)
        for fact in facts {
            do {
                let outcome = try remember(kind: fact.kind, text: fact.text, source: .imported,
                                           importedFrom: origin, importBatchID: batchID)
                if outcome.wasDuplicate {
                    receipt.alreadyKnown.append(outcome.entry.text)
                } else {
                    receipt.saved.append(outcome.entry)
                }
            } catch {
                receipt.notSaved.append((fact.text, error.localizedDescription))
            }
        }
        if !receipt.saved.isEmpty { freezeSnapshot() }
        return receipt
    }

    /// Takes back one whole import. The batch is the unit because that is what the person
    /// did: they imported a file, not twenty separate facts.
    /// - Returns: how many entries were removed.
    @discardableResult
    func undoImport(batchID: UUID) -> Int {
        let ids = entries.filter { $0.importBatchID == batchID }.map(\.id)
        for id in ids { try? forget(id: id, refreezeSnapshot: false) }
        freezeSnapshot()
        return ids.count
    }

    /// Whether an import batch is still there to be undone.
    func importBatchCount(_ batchID: UUID) -> Int {
        entries.filter { $0.importBatchID == batchID }.count
    }

    enum RestoreMode: String, CaseIterable, Sendable {
        /// Everything currently remembered is replaced by the file's contents.
        case replace
        /// The file's facts are added beside what is already there.
        case merge
    }

    /// Restores the memory half of one of our own packages.
    ///
    /// `replace` keeps the file's ids and dates, so the same package restored on two Macs
    /// gives the same list — that is what makes the round trip lossless rather than merely
    /// equivalent. `merge` leaves what is here and adds the rest through `applyImport`, so
    /// the added facts carry the ordinary guards and one undoable batch id.
    @discardableResult
    func restore(_ package: MemoryPackage, mode: RestoreMode, batchID: UUID = UUID()) throws -> ImportReceipt {
        switch mode {
        case .merge:
            let facts: [(kind: MemoryEntry.Kind, text: String)] = package.memories.compactMap { row in
                guard let kind = MemoryEntry.Kind(rawValue: row.kind) else { return nil }
                return (kind, row.text)
            }
            var receipt = applyImport(facts, from: package.assistant.name, batchID: batchID)
            // Labels are derived data, so a merge tops them up rather than replacing them.
            var changed = false
            for label in package.activity {
                guard let item = label.item else { continue }
                changed = upsert(kind: item.kind, key: item.key, value: item.value,
                                 source: item.source) || changed
            }
            if changed { try? persist() }
            if receipt.saved.isEmpty, receipt.notSaved.isEmpty, receipt.alreadyKnown.isEmpty {
                receipt.notSaved.append(("", "There were no memories in that file."))
            }
            return receipt
        case .replace:
            let screened = Self.screenedForRestore(package.memories)
            let labels = package.activity.compactMap(\.item)
            let restored = screened.entries
            try commit { state in
                state.entries = restored
                state.superseded = []
                state.items = Array(labels.suffix(Self.maxItems))
            }
            flagged = screened.flagged
            freezeSnapshot()
            var receipt = ImportReceipt(batchID: batchID, saved: restored)
            receipt.notSaved = screened.refused
            if screened.unplaceable > 0 {
                receipt.notSaved.append(("", "\(screened.unplaceable) memories were written by a "
                                         + "newer version of Next Notes and were left out."))
            }
            return receipt
        }
    }

    /// What a replace is allowed to put back, and what it must leave out.
    struct RestoreScreening {
        var entries: [MemoryEntry] = []
        /// Ids the injection scan caught, with its sentence. Listed in Settings, never injected.
        var flagged: [UUID: String] = [:]
        /// Rows that broke a rule the store enforces on every write, with why.
        var refused: [(text: String, reason: String)] = []
        /// Rows from a newer build whose kind this version does not have.
        var unplaceable = 0
    }

    /// Screens the rows of a package the way `validated` screens a written sentence.
    ///
    /// A replace writes rows straight into `entries`, which is where `freezeSnapshot` reads
    /// the prompt prefix from — so without this a `memory.json` carrying our format string
    /// would be a way to put text of any length, in any voice, into the Agent's system
    /// prompt. Every rule `validated` enforces applies here too.
    ///
    /// The one difference is what happens to a row the injection scan catches. A written
    /// sentence is refused; a restored one is *kept and flagged*, because a package is the
    /// person's own data and `packageMemories` deliberately carries their flagged memories
    /// out so a round trip does not quietly lose them. A flagged row is listed in Settings
    /// and never reaches the prompt, so keeping it costs nothing — and the declarative rule,
    /// which exists to keep instructions out of the prompt, is therefore asked only of the
    /// rows that will actually get there.
    static func screenedForRestore(_ rows: [MemoryPackage.Memory]) -> RestoreScreening {
        var screening = RestoreScreening()
        var used: [MemoryEntry.Kind: Int] = [:]
        for row in rows {
            guard var entry = row.entry else {
                screening.unplaceable += 1
                continue
            }
            let text = collapsedWhitespace(entry.text)
            let finding = MemoryGuard.scan(text)
            func refuse(_ reason: String) {
                screening.refused.append((MemoryImportPlanner.preview(row.text), reason))
            }
            guard !text.isEmpty else {
                refuse("There was nothing in it.")
                continue
            }
            guard text.count <= maxEntryLength else {
                refuse("It's longer than one memory can be.")
                continue
            }
            if finding == nil, !MemoryGuard.isDeclarative(text) {
                refuse("It tells the assistant what to do instead of saying something about you.")
                continue
            }
            let running = used[entry.kind, default: 0]
            guard running + text.count <= entry.kind.budget else {
                refuse("“\(entry.kind.displayName)” was already full.")
                continue
            }
            used[entry.kind] = running + text.count
            entry.text = text
            screening.entries.append(entry)
            if let finding { screening.flagged[entry.id] = finding.reason }
        }
        return screening
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
    nonisolated static func collapsedWhitespace(_ raw: String) -> String {
        raw.split(whereSeparator: { $0.isNewline || $0 == "\t" })
            .joined(separator: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One sentence, guarded. Newlines collapse to spaces before the scan so nothing hides
    /// on a second line; everything else invisible is refused, not stripped.
    nonisolated static func validated(_ raw: String) throws -> String {
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

    nonisolated static func normalize(_ raw: String) -> String {
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

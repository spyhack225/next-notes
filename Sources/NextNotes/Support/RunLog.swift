import NextNotesDictionary
import Foundation

/// One completed dictation.
struct DictationRun: Codable, Sendable, Identifiable {
    /// Stable identity, so a single run can be deleted without matching on its text.
    ///
    /// Decoded leniently: runs written before this existed have no `id` field, and failing
    /// their whole line would throw away the user's history to add a delete button. Those
    /// get a fresh id on load, which is then persisted the next time the file is rewritten.
    var id: UUID = UUID()

    let date: Date
    let engine: String
    /// How long the key was held.
    let audioSeconds: Double
    /// Release → final text ready. This is the latency you actually feel.
    let processSeconds: Double
    let text: String
    /// Shared by every engine that processed the same recording, so the dashboard can
    /// present them as one side-by-side comparison instead of unrelated rows.
    var group: String?

    /// Dictionary corrections that fired on this transcript. Recorded so history can show
    /// whether the dictionary is actually doing anything, rather than leaving it to faith.
    ///
    /// Optional for backwards compatibility: runs recorded before the dictionary existed
    /// decode with this nil rather than failing the whole line.
    var corrections: [AppliedCorrection]?

    /// What the user changed this transcript to, if they have.
    ///
    /// Kept beside `text` rather than replacing it, because the pair *is* the training
    /// signal: the diff between what was written and what it was corrected to is what
    /// `CorrectionLearner` reads. Overwrite `text` and the evidence is gone.
    ///
    /// Optional for backwards compatibility, like `corrections` above: runs written before
    /// editing existed decode with this nil rather than failing the whole line.
    var editedText: String?

    /// What the cleanup pass did to this utterance, if anything.
    ///
    /// Added because the file could not answer the only question anyone ever asked of it.
    /// `text` is what was typed, and one string cannot say whether grammar was switched on,
    /// which model ran, whether its answer was thrown away by `CleanupGuard`, whether it
    /// timed out, or whether a spoken list was turned into a list — and those are five
    /// different faults with one symptom.
    ///
    /// Optional, and `CleanupRecord` decodes every key with `decodeIfPresent`, so the 175
    /// runs already in this user's `runs.jsonl` still load. Nothing here is required reading
    /// for the Dictation list; it is the diagnostic half of the row.
    var cleanup: CleanupRecord?

    /// What to show, and what to copy: the correction if there is one.
    var displayText: String { editedText ?? text }

    var wasEdited: Bool { editedText != nil }

    var realtimeFactor: Double { audioSeconds / max(processSeconds, 0.0001) }
    var characters: Int { text.count }

    init(
        id: UUID = UUID(),
        date: Date,
        engine: String,
        audioSeconds: Double,
        processSeconds: Double,
        text: String,
        group: String? = nil,
        corrections: [AppliedCorrection]? = nil,
        editedText: String? = nil,
        cleanup: CleanupRecord? = nil
    ) {
        self.editedText = editedText
        self.id = id
        self.date = date
        self.engine = engine
        self.audioSeconds = audioSeconds
        self.processSeconds = processSeconds
        self.text = text
        self.group = group
        self.corrections = corrections
        self.cleanup = cleanup
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try container.decode(Date.self, forKey: .date)
        engine = try container.decode(String.self, forKey: .engine)
        audioSeconds = try container.decode(Double.self, forKey: .audioSeconds)
        processSeconds = try container.decode(Double.self, forKey: .processSeconds)
        text = try container.decode(String.self, forKey: .text)
        group = try container.decodeIfPresent(String.self, forKey: .group)
        corrections = try container.decodeIfPresent([AppliedCorrection].self, forKey: .corrections)
        editedText = try container.decodeIfPresent(String.self, forKey: .editedText)
        // Written by hand for the same reason `id` is: every row already in the file
        // predates this key, and a synthesized decoder would throw `keyNotFound` on all 175
        // of them rather than lose one optional field.
        cleanup = try container.decodeIfPresent(CleanupRecord.self, forKey: .cleanup)
    }
}

/// Appends every dictation to a JSONL file in Application Support.
///
/// Append-only on the hot path so recording a run is one write; deletes rewrite the file.
@MainActor
enum RunLog {
    /// Where the file lives, pointed somewhere else by a self-test.
    ///
    /// A `@TaskLocal` rather than a parameter so every call site keeps its shape, and so no
    /// production code has to ask whether a test is running: `--selftest-dictation-hygiene`
    /// installs the value for the length of a case and the store follows it. `AGENTS.md`'s
    /// "A self-test must never call `RunLog.record`" is the older, narrower rule; this is
    /// what makes the history *store* testable with the owner's file nowhere in sight.
    @TaskLocal static var directoryOverride: URL?

    static var directory: URL {
        directoryOverride ?? AppIdentity.applicationSupportDirectory
    }

    private static var runsURL: URL { directory.appendingPathComponent("runs.jsonl") }

    /// A recorded hold, in the list and on disk.
    ///
    /// The store is appended to rather than reloaded, so the Dictation list sees the new row
    /// in the same turn with no read of the file behind it. `append` to the file is still the
    /// durable half and still happens first: if the process died between the two, the next
    /// launch's `reload` would have the row anyway.
    static func record(_ run: DictationRun) {
        append(run)
        RunStore.shared.append(run)
    }

    static func record(_ runs: [DictationRun]) {
        runs.forEach(append)
        RunStore.shared.append(contentsOf: runs)
    }

    private static func append(_ run: DictationRun) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(run) else { return }
        line.append(0x0A) // newline

        if let handle = try? FileHandle(forWritingTo: runsURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: runsURL)
        }
    }

    static func load() -> [DictationRun] {
        guard let data = try? Data(contentsOf: runsURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).compactMap { line in
            try? decoder.decode(DictationRun.self, from: Data(line))
        }
    }

    /// Deletes one run.
    static func delete(_ run: DictationRun) {
        delete(ids: [run.id])
    }

    /// Deletes every run in a comparison group — the engines all transcribed one utterance,
    /// so removing that utterance means removing all of its rows.
    static func deleteGroup(_ group: String) {
        let runs = load()
        rewrite(runs.filter { $0.group != group })
        KnowledgeIndexer.shared.removeDictations(runs.filter { $0.group == group }.map(\.id))
    }

    static func delete(ids: Set<UUID>) {
        rewrite(load().filter { !ids.contains($0.id) })
        KnowledgeIndexer.shared.removeDictations(Array(ids))
    }

    /// Persists an edit to one run.
    ///
    /// A rewrite rather than an append, for the same reason deleting is: the file is one
    /// line per run and a correction changes a line in place.
    static func update(_ run: DictationRun) {
        rewrite(load().map { $0.id == run.id ? run : $0 })
    }

    static func clear() {
        try? FileManager.default.removeItem(at: runsURL)
        KnowledgeIndexer.shared.removeAllDictations()
        RunStore.shared.reload()
    }

    // MARK: - Retention

    /// The runs a policy would remove, chosen from `runs` and nothing else.
    ///
    /// Pure, and the reason `prune` below is testable at all: a self-test can hand it
    /// 5,002 runs and a date without writing a file. Sorted by date rather than by
    /// position, because the file's order is append order and a run whose `date` was
    /// written by a machine with a wrong clock is still the older one.
    static func toPrune(
        _ runs: [DictationRun],
        policy: DictationHistoryRetention,
        now: Date
    ) -> Set<UUID> {
        switch policy {
        case .forever:
            return []
        case .days90:
            guard let days = policy.maxAgeDays else { return [] }
            let cutoff = now.addingTimeInterval(-days * 86_400)
            return Set(runs.filter { $0.date < cutoff }.map(\.id))
        case .rows5000:
            guard let keep = policy.maxRuns else { return [] }
            // Oldest first, by date rather than by position: `runs.jsonl` is append order,
            // and a run written by a machine whose clock was wrong is still the older one.
            guard runs.count > keep else { return [] }
            let oldest = runs.sorted { $0.date < $1.date }.prefix(runs.count - keep)
            return Set(oldest.map(\.id))
        }
    }

    /// Rewrites the file without the runs `toPrune` selects, and tells the knowledge index
    /// about the same ids so a pruned run cannot still be found by search.
    ///
    /// A no-op unless the policy actually selects something, so the common case costs a
    /// parse and no write.
    @discardableResult
    static func prune(
        policy: DictationHistoryRetention,
        now: Date = Date()
    ) -> Int {
        let runs = load()
        let doomed = toPrune(runs, policy: policy, now: now)
        guard !doomed.isEmpty else { return 0 }
        rewrite(runs.filter { !doomed.contains($0.id) })
        KnowledgeIndexer.shared.removeDictations(Array(doomed))
        return doomed.count
    }

    /// Prunes at most once a day, and never at all under `.forever`.
    ///
    /// Called from launch, so the day gate is what keeps a machine that is opened five
    /// times a morning from rewriting a file it just rewrote. The marker is a date string
    /// rather than a timer, because "yesterday's sweep happened" is the only question
    /// being asked and a process that quits overnight would otherwise never answer it.
    @discardableResult
    static func pruneIfDue(
        policy: DictationHistoryRetention,
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) -> Int {
        guard policy != .forever else { return 0 }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        let today = formatter.string(from: now)
        guard defaults.string(forKey: lastPruneKey) != today else { return 0 }
        let removed = prune(policy: policy, now: now)
        defaults.set(today, forKey: lastPruneKey)
        return removed
    }

    /// The last day `pruneIfDue` swept. Public so a self-test can point it elsewhere and
    /// so the name is not spelled twice.
    static let lastPruneKey = "dictationHistoryPrunedOn"

    /// Replaces the whole file. Deleting can't be an append, and rewriting also persists the
    /// ids that older runs were assigned on load.
    private static func rewrite(_ runs: [DictationRun]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let body = runs.compactMap { run -> String? in
            guard let data = try? encoder.encode(run) else { return nil }
            return String(data: data, encoding: .utf8)
        }.joined(separator: "\n")

        // Atomic: a partial write here would lose history that the user didn't ask to delete.
        try? (body.isEmpty ? "" : body + "\n")
            .write(to: runsURL, atomically: true, encoding: .utf8)

        RunStore.shared.reload()
    }
}

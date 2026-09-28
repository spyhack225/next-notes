import Foundation
import Observation

/// A routine the review noticed the user might want: the same request, on several days.
///
/// Recorded by the review, offered once by the Agent in a later session, and never created.
/// A yes goes through `schedule.create` and its confirmation like any other request.
struct RoutineSuggestion: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    /// `RoutineSuggestionDetector.key`, so the same request is suggested once — and, since
    /// P1-30, the **only** record of what was asked. This row used to keep the request as the
    /// user last said it, in the same file as the request log, which made removing the log's
    /// `text` half a fix: the sentence was here too. `offer()` builds its words from the key.
    let key: String
    var occurrences: [Date]
    /// The session whose review found it; the offer waits for a later one.
    let detectedInSession: UUID?
    let createdAt: Date
    var offeredAt: Date?
    var offeredInSession: UUID?
    /// *Set it up* or *Dismiss* in the Routines view: it leaves the list and is never offered.
    var resolvedAt: Date?

    /// P1-30: built from `key`, not from the request as it was said.
    ///
    /// The log no longer keeps the words — side talk from a meeting reaches this store and
    /// would be quoted back to somebody as though the owner had said it — so the offer names
    /// the **content words** instead. That is a deliberate loss of fluency: "calendar tomorrow
    /// schedule" is not a sentence. The alternative was to keep a quote, and a quote in curly
    /// marks is a claim that those words were said together, in that order, by this person.
    ///
    /// So the words are presented as words. The test's `offer?.contains("what")` still holds,
    /// because "what" is a content word of "what's on my calendar".
    func offer(zone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let days = Set(occurrences.map { calendar.startOfDay(for: $0) }).count
        let hours = occurrences.map { calendar.component(.hour, from: $0) }.sorted()
        var when = ""
        if let low = hours.first, let high = hours.last, high - low <= 2 {
            when = ", usually around \(hours[hours.count / 2]):00"
        }
        return "You’ve asked about \(RoutineSuggestionDetector.phrase(for: key)) "
            + "on \(days) different days\(when). "
            + "Want me to make that a routine? Say so and I’ll set it up for you to confirm."
    }
}

struct RoutineRequestOccurrence: Codable, Equatable, Sendable {
    let key: String
    let at: Date
    let sessionID: UUID?

    init(key: String, at: Date, sessionID: UUID?) {
        self.key = key
        self.at = at
        self.sessionID = sessionID
    }

    /// P1-30: this row used to keep the request's full `text`.
    ///
    /// The microphone does not distinguish speakers and `AgentUtteranceSource` has only voice,
    /// text and meeting, so **other people's side talk was being saved as if the owner had said
    /// it** — 74 rows on this Mac, from 16 sessions. The key is enough to recognise the same
    /// request said differently, which is all this log is for.
    ///
    /// Decoded leniently on purpose: a file written by an older build still has `text` on every
    /// row, and reading it is harmless — the value is dropped here and gone from the file the
    /// next time it is written. `decodeIfPresent` for nothing would throw on the one key a
    /// synthesized decoder insists on, so the hand-written `init(from:)` is the whole reason
    /// this type has one.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(String.self, forKey: .key)
        at = try container.decode(Date.self, forKey: .at)
        sessionID = try container.decodeIfPresent(UUID.self, forKey: .sessionID)
    }
}

/// Recognises the same request said differently, and decides when it has recurred enough.
enum RoutineSuggestionDetector {
    /// "What's on my calendar" three mornings running.
    static let requiredDays = 3
    static let logLimit = 400

    /// The request's content words, sorted, or nil when it is not a request worth a routine:
    /// too short, a memory or reminder command already, or conversational filler.
    static func key(for request: String) -> String? {
        let lowered = request.lowercased().replacingOccurrences(of: "’", with: "'")
        let words = lowered.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map { String($0).replacingOccurrences(of: "'s", with: "") }
        guard words.count >= 2, words.count <= 16 else { return nil }
        if words.contains(where: { commandWords.contains($0) }) { return nil }
        let content = Set(words.filter { $0.count >= 3 && !filler.contains($0) })
        guard !content.isEmpty else { return nil }
        return content.sorted().joined(separator: " ")
    }

    /// The user's own words for a key, as a readable phrase.
    ///
    /// P1-30, and the only thing in this file that turns a key back into something a person
    /// reads. The key is a sorted set of content words, so this is a list and not a sentence —
    /// and it is quoted as a list on purpose, because a key sorted alphabetically is not an
    /// order anyone spoke in.
    static func phrase(for key: String) -> String {
        let words = key.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else { return "something" }
        switch words.count {
        case 1: return "“\(words[0])”"
        case 2: return "“\(words[0])” and “\(words[1])”"
        default:
            let leading = words.dropLast().joined(separator: ", ")
            return "“\(leading)” and “\(words[words.count - 1])”"
        }
    }

    /// New suggestions for keys seen on `requiredDays` different days that have no
    /// suggestion yet.
    static func detect(
        log: [RoutineRequestOccurrence], existing: [RoutineSuggestion], sessionID: UUID?,
        now: Date, zone: TimeZone = .current
    ) -> [RoutineSuggestion] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let known = Set(existing.map(\.key))
        var result: [RoutineSuggestion] = []
        let grouped = Dictionary(grouping: log, by: \.key)
        for key in grouped.keys.sorted() where !known.contains(key) {
            let rows = grouped[key, default: []].sorted { $0.at < $1.at }
            let days = Set(rows.map { calendar.startOfDay(for: $0.at) })
            guard days.count >= requiredDays, let latest = rows.last else { continue }
            _ = latest
            result.append(RoutineSuggestion(
                id: UUID(), key: key,
                occurrences: rows.map(\.at), detectedInSession: sessionID, createdAt: now))
        }
        return result
    }

    private static let commandWords: Set<String> = [
        "remind", "reminder", "reminders", "remember", "forget", "routine", "routines", "every",
        "schedule", "stop", "cancel", "yes", "no",
    ]

    private static let filler: Set<String> = [
        "hey", "please", "can", "could", "would", "you", "tell", "what", "what's", "whats", "the",
        "and", "for", "are", "is", "show", "give", "next", "notes", "agent", "today", "now",
        "this", "morning", "afternoon", "evening", "tonight", "again", "just", "some", "any",
        "thanks", "thank", "okay", "about", "with", "have", "there", "that", "how", "does",
        "did", "was", "were", "let", "know", "get", "need", "want", "like", "right",
    ]
}

/// `agent-memory-review.json`: the review's watermark, the request log routine suggestions
/// are found in, and the suggestions themselves. Written atomically; a failed write keeps
/// the previous file whole.
@MainActor
@Observable
final class MemoryReviewStateStore {
    /// A self-test never touches the user's file: it gets a per-process temporary directory.
    static let shared: MemoryReviewStateStore = {
        if SelfTest.isRunning {
            return MemoryReviewStateStore(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("NextNotesSelfTest-review-\(ProcessInfo.processInfo.processIdentifier)",
                                        isDirectory: true))
        }
        return MemoryReviewStateStore(directory: AppIdentity.applicationSupportDirectory)
    }()

    static let fileName = "agent-memory-review.json"

    private(set) var reviewedThrough: Date?
    /// *Remember what I tell the Agent* was off when last seen. Persisted, so a relaunch
    /// with it back on still moves the watermark past what was said while it was off.
    private(set) var memoryOff = false
    private(set) var requests: [RoutineRequestOccurrence] = []
    private(set) var suggestions: [RoutineSuggestion] = []
    /// What every pass of the review decided, newest last. The Memories sheet reads the last
    /// row, so an empty list is never again indistinguishable from a review that never ran.
    private(set) var runs: [MemoryReviewRun] = []
    /// `sourceKey` values the review has already read — `dictation:<uuid>`, `meeting:<uuid>`.
    /// This is what makes the backfill resumable and idempotent.
    private(set) var harvested: Set<String> = []
    private(set) var backfill = MemoryBackfillState()

    static let runLimit = 200
    /// P1-30: 1 stored every request's text and every refused/skipped fact's text. 2 stores
    /// keys, ids, reasons and counts. A file at 1 is rewritten once, on the next load.
    static let currentVersion = 2

    let directory: URL
    var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    init(directory: URL) {
        self.directory = directory
        load()
    }

    func markReviewed(through date: Date, memoryOff: Bool? = nil) {
        let through = max(reviewedThrough ?? .distantPast, date)
        let off = memoryOff ?? self.memoryOff
        guard through != reviewedThrough || off != self.memoryOff else { return }
        reviewedThrough = through
        self.memoryOff = off
        persist()
    }

    /// After a review finishes: moves the watermark, logs the job's requests, and records a
    /// suggestion for any request that has now recurred on enough days.
    @discardableResult
    func recordReview(_ job: MemoryReviewJob, now: Date, zone: TimeZone = .current) -> [RoutineSuggestion] {
        reviewedThrough = max(reviewedThrough ?? .distantPast, job.endAt)
        for turn in job.userRequests {
            guard let key = RoutineSuggestionDetector.key(for: turn.text) else { continue }
            // No `text`: the key is what the log is for, and the words are the owner's
            // neighbours' as often as theirs. See `RoutineRequestOccurrence`.
            requests.append(RoutineRequestOccurrence(key: key, at: turn.at, sessionID: job.sessionID))
        }
        if requests.count > RoutineSuggestionDetector.logLimit {
            requests.removeFirst(requests.count - RoutineSuggestionDetector.logLimit)
        }
        let found = RoutineSuggestionDetector.detect(log: requests, existing: suggestions,
                                                     sessionID: job.sessionID, now: now, zone: zone)
        suggestions += found
        persist()
        return found
    }

    /// The one offer a session gets: the oldest suggestion not yet offered, found in a
    /// different session. Marked offered before it is returned, so it is never repeated.
    func takeOffer(for sessionID: UUID, now: Date) -> String? {
        guard let index = suggestions.firstIndex(where: { $0.offeredAt == nil && $0.detectedInSession != sessionID })
        else { return nil }
        suggestions[index].offeredAt = now
        suggestions[index].offeredInSession = sessionID
        persist()
        return suggestions[index].offer()
    }

    // MARK: - The review ledger

    /// Records what one pass decided, and ticks off the source it read.
    func record(run: MemoryReviewRun, sourceKey: String?) {
        runs.append(run)
        if runs.count > Self.runLimit { runs.removeFirst(runs.count - Self.runLimit) }
        // A conversation is re-read as it grows, so only the other channels are ticked off.
        if let sourceKey, !sourceKey.hasPrefix("conversation:") { harvested.insert(sourceKey) }
        persist()
    }

    var lastRun: MemoryReviewRun? { runs.last }

    /// "Last looked: today 17:40 — saved 2.", or the sentence for a review that never ran.
    func lastLookedLine(now: Date = Date()) -> String {
        guard let lastRun else {
            return memoryOff
                ? "Not looking: remembering is turned off."
                : "Last looked: not yet — the Agent looks when a conversation ends and after each note."
        }
        return lastRun.line(now: now)
    }

    // MARK: - Backfill

    func updateBackfill(_ change: (inout MemoryBackfillState) -> Void) {
        var next = backfill
        change(&next)
        guard next != backfill else { return }
        backfill = next
        persist()
    }

    /// Ticks a source off without a run row — used when a source turns out to hold nothing
    /// the user said, so the backfill does not keep coming back to it.
    func markHarvested(_ sourceKey: String) {
        guard harvested.insert(sourceKey).inserted else { return }
        persist()
    }

    /// Un-ticks every source, so the next pass reads the whole history again. Only
    /// *Look again at your past activity* calls this — see `MemoryBackfill.startAgain` —
    /// and it is safe because the review's duplicate rules drop anything already known.
    func resetHarvest() {
        guard !harvested.isEmpty else { return }
        harvested = []
        persist()
    }

    /// Suggestions still shown at the top of the Routines view.
    var openSuggestions: [RoutineSuggestion] {
        suggestions.filter { $0.resolvedAt == nil }
    }

    /// *Set it up* or *Dismiss*: either way it is done, and the Agent will not offer it again.
    func resolveSuggestion(id: UUID, now: Date = Date()) {
        guard let index = suggestions.firstIndex(where: { $0.id == id }) else { return }
        suggestions[index].resolvedAt = now
        if suggestions[index].offeredAt == nil { suggestions[index].offeredAt = now }
        persist()
    }

    /// Seeds a suggestion directly, for `--selftest-memory-review`.
    func recordReviewForTesting(_ suggestion: RoutineSuggestion) {
        suggestions.append(suggestion)
        persist()
    }

    private struct Stored: Codable {
        /// Optional so a file written before it existed still reads as version 1 and gets
        /// migrated, rather than failing to decode and starting the log over.
        var version: Int?
        var reviewedThrough: Date?
        /// Optional so a file written before it existed still decodes.
        var memoryOff: Bool?
        var requests: [RoutineRequestOccurrence]
        var suggestions: [RoutineSuggestion]
        /// Optional for the same reason: a file from before the ledger existed still reads.
        var runs: [MemoryReviewRun]?
        var harvested: [String]?
        var backfill: MemoryBackfillState?
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom(Self.decodeDate)
        guard let stored = try? decoder.decode(Stored.self, from: data) else {
            Log.agent.error("agent-memory-review.json is unreadable; starting fresh")
            return
        }
        reviewedThrough = stored.reviewedThrough
        memoryOff = stored.memoryOff ?? false
        requests = stored.requests
        suggestions = stored.suggestions
        runs = stored.runs ?? []
        harvested = Set(stored.harvested ?? [])
        backfill = stored.backfill ?? MemoryBackfillState()
        // P1-30, targets 4 and 5. Both are "the file is smaller than it was", so both are
        // written here rather than by a caller: a launch is the only moment guaranteed to
        // happen, and a rule that needs remembering is a rule that will not be applied.
        //
        // The version check is the one-time migration. A file at version 1 has a `text` on
        // every request row and on every refused/skipped decision; the lenient decoders have
        // already dropped those values in memory, so the single write below is what takes them
        // off the disk. `version` is then 2 and this does not run again.
        var changed = false
        if (stored.version ?? 1) < Self.currentVersion {
            changed = true
        }
        if prune(now: Date()) { changed = true }
        if changed { persist() }
    }

    /// Drops request rows that can no longer produce a suggestion.
    ///
    /// Two rules, both about rows that are finished with rather than about size:
    /// - **30 days.** The only retention limit this log had was a count of 400, and nothing
    ///   aged out, so a request asked in March could still be sitting there in September.
    /// - **a resolved key.** Once a suggestion has been set up or dismissed, the occurrences
    ///   behind it have done their job. They stay while the suggestion is merely *offered* —
    ///   an offered-but-unanswered suggestion is still live — and go when it is resolved.
    ///
    /// Returns whether anything was dropped, so `load` knows to write.
    @discardableResult
    func prune(now: Date) -> Bool {
        let cutoff = now.addingTimeInterval(-Double(Self.requestRetentionDays) * 86_400)
        let resolved = Set(suggestions.filter { $0.resolvedAt != nil }.map(\.key))
        let kept = requests.filter { $0.at >= cutoff && !resolved.contains($0.key) }
        guard kept.count != requests.count else { return false }
        requests = kept
        return true
    }

    /// How long a request row may live. 30 days is four times `requiredDays`, so a request
    /// asked on three separate mornings is still recognisable as a routine at 29 days.
    static let requestRetentionDays = 30

    /// Dates are stored as the exact number `Date` holds (seconds since 2001), as
    /// `agent-conversation.json` stores them. A watermark rounded to the second — or to the
    /// millisecond — would make its own row look unreviewed after a relaunch. ISO 8601
    /// strings from an older file still read.
    private nonisolated static func encodeDate(_ date: Date, _ encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(date.timeIntervalSinceReferenceDate)
    }

    private nonisolated static func decodeDate(_ decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        if let seconds = try? container.decode(Double.self) {
            return Date(timeIntervalSinceReferenceDate: seconds)
        }
        let text = try container.decode(String.self)
        if let date = try? Date(text, strategy: .iso8601) { return date }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a date: \(text)")
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom(Self.encodeDate)
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(Stored(version: Self.currentVersion, reviewedThrough: reviewedThrough, memoryOff: memoryOff,
                                                 requests: requests, suggestions: suggestions, runs: runs,
                                                 harvested: harvested.sorted(), backfill: backfill))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            Log.agent.error("agent-memory-review.json not written: \(error.localizedDescription, privacy: .public)")
        }
    }
}

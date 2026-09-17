import Foundation
import Observation

/// A routine the review noticed the user might want: the same request, on several days.
///
/// Recorded by the review, offered once by the Agent in a later session, and never created.
/// A yes goes through `schedule.create` and its confirmation like any other request.
struct RoutineSuggestion: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    /// The request as the user last said it.
    var request: String
    /// `RoutineSuggestionDetector.key`, so the same request is suggested once.
    let key: String
    var occurrences: [Date]
    /// The session whose review found it; the offer waits for a later one.
    let detectedInSession: UUID?
    let createdAt: Date
    var offeredAt: Date?
    var offeredInSession: UUID?

    /// "You've asked “what's on my calendar” on 3 different days, usually around 9:00. …"
    func offer(zone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let days = Set(occurrences.map { calendar.startOfDay(for: $0) }).count
        let hours = occurrences.map { calendar.component(.hour, from: $0) }.sorted()
        var when = ""
        if let low = hours.first, let high = hours.last, high - low <= 2 {
            when = ", usually around \(hours[hours.count / 2]):00"
        }
        return "You’ve asked “\(request)” on \(days) different days\(when). "
            + "Want me to make that a routine? Say so and I’ll set it up for you to confirm."
    }
}

struct RoutineRequestOccurrence: Codable, Equatable, Sendable {
    let key: String
    let text: String
    let at: Date
    let sessionID: UUID?
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
            result.append(RoutineSuggestion(
                id: UUID(), request: latest.text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)),
                key: key, occurrences: rows.map(\.at), detectedInSession: sessionID, createdAt: now))
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
            requests.append(RoutineRequestOccurrence(key: key, text: turn.text, at: turn.at, sessionID: job.sessionID))
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

    /// Seeds a suggestion directly, for `--selftest-memory-review`.
    func recordReviewForTesting(_ suggestion: RoutineSuggestion) {
        suggestions.append(suggestion)
        persist()
    }

    private struct Stored: Codable {
        var version: Int
        var reviewedThrough: Date?
        /// Optional so a file written before it existed still decodes.
        var memoryOff: Bool?
        var requests: [RoutineRequestOccurrence]
        var suggestions: [RoutineSuggestion]
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
    }

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
            let data = try encoder.encode(Stored(version: 1, reviewedThrough: reviewedThrough, memoryOff: memoryOff,
                                                 requests: requests, suggestions: suggestions))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            Log.agent.error("agent-memory-review.json not written: \(error.localizedDescription, privacy: .public)")
        }
    }
}

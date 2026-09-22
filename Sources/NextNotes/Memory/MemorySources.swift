import Foundation

/// Everywhere the user's own words live, turned into review jobs.
///
/// The Agent conversation was the only channel memory ever learned from. That is why a person
/// with six recorded meetings, 180 dictations and an 8,796-file index still had an empty
/// Memories list: everything they had ever said *about themselves* was in the other channels.
///
/// What is allowed here, and why each one is the user's own words:
///
/// | Channel | What is read | What is not |
/// |---|---|---|
/// | `.userSaidToAgent` | their turns in a conversation | the Agent's replies, tool output |
/// | `.userDictated` | the whole dictation — their microphone, their words | nothing else is there |
/// | `.userSpokeInMeeting` | only the `You` speaker's lines, and note lines naming them | every other speaker |
/// | `.derivedFromUsersGraph` | life-map facts about the user | anything not corroborated |
///
/// File and folder names are deliberately absent. They are already reachable through the file
/// index and the grounding block; a path is not a fact about a person.
///
/// The source of truth is the knowledge index (`KnowledgeStore`), which already chunks
/// dictations, transcripts and notes with a speaker on each row, so nothing here re-reads a
/// recording or a transcript file. With the index switched off there is nothing to harvest
/// and the conversation channel carries on alone.
@MainActor
enum MemoryHarvest {
    /// The speaker label the diarizer gives the person holding the Mac.
    static let userSpeaker = "You"
    /// Sentences shorter than this are filler ("okay", "yeah, sure") and carry no fact.
    static let minimumSentence = 24
    /// At most this much of one source reaches the model, newest-first within the source.
    static let charactersPerJob = 6_000

    /// Every source the review could read, newest first, with the ones already reviewed left
    /// out. `reviewed` holds `sourceKey` values — `dictation:<uuid>`, `meeting:<uuid>`.
    static func documents(
        store: KnowledgeStore, reviewed: Set<String> = [], since: Date? = nil, limit: Int = 200
    ) -> [MemoryReviewJob] {
        var jobs: [MemoryReviewJob] = []
        jobs += dictationJobs(store: store, reviewed: reviewed, since: since)
        jobs += meetingJobs(store: store, reviewed: reviewed, since: since)
        return Array(jobs.sorted { $0.endAt > $1.endAt }.prefix(limit))
    }

    // MARK: - Dictations

    /// One job per dictation. A dictation is the user talking to themselves: all of it is
    /// theirs, and there is no untrusted half.
    static func dictationJobs(
        store: KnowledgeStore, reviewed: Set<String> = [], since: Date? = nil
    ) -> [MemoryReviewJob] {
        guard let sources = try? store.indexedSources(kind: .dictation) else { return [] }
        var jobs: [MemoryReviewJob] = []
        for sourceID in sources.keys.sorted() {
            let key = "dictation:\(sourceID)"
            guard !reviewed.contains(key), let rows = try? store.chunkRows(kind: .dictation, sourceID: sourceID),
                  let first = rows.first else { continue }
            let occurredAt = Date(timeIntervalSince1970: TimeInterval(first.occurredAt))
            if let since, occurredAt <= since { continue }
            let text = sentences(rows.map(\.text))
            guard !text.isEmpty else { continue }
            jobs.append(MemoryReviewJob(
                source: .userDictated, trigger: .dictationSaved, sourceKey: key,
                label: "on " + occurredAt.formatted(.dateTime.day().month(.abbreviated)),
                sessionID: UUID(uuidString: sourceID) ?? UUID(),
                userText: clipped(text), untrustedText: [], occurredAt: occurredAt))
        }
        return jobs
    }

    // MARK: - Meetings

    /// One job per recorded meeting, carrying only what the user said.
    ///
    /// Everything the other people on the call said goes into `untrustedText`, so a fact whose
    /// wording only exists there is refused by `MemoryGuard.provenanceProblem` — "Mathieu is
    /// ordering the safety-light kits" is not a memory about the user unless the user said it.
    /// The notes are read the same way: only lines that name the user carry over.
    static func meetingJobs(
        store: KnowledgeStore, reviewed: Set<String> = [], since: Date? = nil
    ) -> [MemoryReviewJob] {
        guard let sources = try? store.indexedSources(kind: .transcript) else { return [] }
        var jobs: [MemoryReviewJob] = []
        for sourceID in sources.keys.sorted() {
            let key = "meeting:\(sourceID)"
            guard !reviewed.contains(key), let rows = try? store.chunkRows(kind: .transcript, sourceID: sourceID),
                  let first = rows.first else { continue }
            let occurredAt = Date(timeIntervalSince1970: TimeInterval(first.occurredAt))
            if let since, occurredAt <= since { continue }
            let mine = rows.filter { $0.speaker == userSpeaker }.map(\.text)
            let theirs = rows.filter { $0.speaker != userSpeaker }
            let notes = (try? store.chunkRows(kind: .notes, sourceID: sourceID)) ?? []
            let (aboutMe, aboutOthers) = splitNotes(notes)
            let userText = sentences(mine + aboutMe)
            guard !userText.isEmpty else { continue }
            let others = Set(theirs.compactMap(\.speaker)).sorted()
            jobs.append(MemoryReviewJob(
                source: .userSpokeInMeeting, trigger: .meetingNotesReady, sourceKey: key,
                label: meetingLabel(others: others, at: occurredAt),
                sessionID: UUID(uuidString: sourceID) ?? UUID(),
                userText: clipped(userText),
                untrustedText: theirs.map(\.text) + aboutOthers,
                occurredAt: occurredAt))
        }
        return jobs
    }

    /// "with Mathieu, 19 Sep", or "on 19 Sep" when the call has no named attendee.
    static func meetingLabel(others: [String], at: Date) -> String {
        let day = at.formatted(.dateTime.day().month(.abbreviated))
        let named = others.filter { $0 != "Others" && !$0.hasPrefix("Speaker ") }
        guard let first = named.first else { return "on \(day)" }
        let rest = named.count > 1 ? " and \(named.count - 1) more" : ""
        return "with \(first)\(rest), \(day)"
    }

    /// Note lines split into the ones that are about the user and the ones that are not.
    ///
    /// Meeting notes are written by a model from everyone's words, so they are not the user's
    /// sentences. A line under an action-item or decision heading that names the user is
    /// treated as the user's — it is their own commitment, written down — and everything else
    /// stays untrusted.
    static func splitNotes(_ rows: [KnowledgeChunkRow]) -> (mine: [String], theirs: [String]) {
        var mine: [String] = []
        var theirs: [String] = []
        for row in rows {
            let heading = (row.heading ?? "").lowercased()
            let isOwnable = ownableHeading.contains { heading.contains($0) }
            for line in row.text.split(whereSeparator: \.isNewline).map(String.init) {
                if isOwnable, namesTheUser(line) { mine.append(line) } else { theirs.append(line) }
            }
        }
        return (mine, theirs)
    }

    private static let ownableHeading = ["action", "decision", "next step", "follow-up", "follow up", "commitment"]

    /// A note line that names the user as its owner: "You will…", "Serge to…" is not enough
    /// on its own, because the diarizer's label for the person at the Mac is "You".
    static func namesTheUser(_ line: String) -> Bool {
        let folded = line.lowercased().replacingOccurrences(of: "’", with: "'")
        return folded.range(of: #"(^|[^a-z])(you|your|i|i'm|i'll|my|me)([^a-z]|$)"#,
                            options: .regularExpression) != nil
    }

    // MARK: - The life map

    /// The user's own life map as one job: the people they talk to and how they are related,
    /// the projects, organisations, activities and preferences attached to them.
    ///
    /// This is the app's reading of the user's notes rather than a sentence they said, so the
    /// job carries `.derivedFromUsersGraph` and every fact it proposes has to be corroborated
    /// word for word by `corroboration` — the user's own sentences, passed in by the caller.
    /// Without that the job is not built at all.
    static func lifeMapJob(
        facts: [String], corroboration: [String], now: Date
    ) -> MemoryReviewJob? {
        let usable = facts.filter { !MemoryGuard.contentTokens($0).isEmpty }
        guard !usable.isEmpty, !corroboration.isEmpty else { return nil }
        return MemoryReviewJob(
            source: .derivedFromUsersGraph, trigger: .lifeMap, sourceKey: "lifemap",
            label: "on " + now.formatted(.dateTime.day().month(.abbreviated)),
            sessionID: UUID(),
            // The graph rows are what the model reads; the user's own sentences are what the
            // guard measures every saved word against.
            userText: clipped(usable + corroboration), untrustedText: [], occurredAt: now)
    }

    // MARK: - Shared

    /// Sentences worth reading: trimmed, de-duplicated, filler dropped.
    static func sentences(_ rows: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for row in rows {
            let text = NextMemory.collapsedWhitespace(row)
            guard text.count >= minimumSentence else { continue }
            let key = NextMemory.normalize(text)
            guard seen.insert(key).inserted else { continue }
            result.append(text)
        }
        return result
    }

    /// The newest end of a source, within the per-job character budget.
    static func clipped(_ rows: [String]) -> [String] {
        var total = 0
        var kept: [String] = []
        for row in rows.reversed() {
            total += row.count
            if total > charactersPerJob, !kept.isEmpty { break }
            kept.append(row)
        }
        return kept.reversed()
    }
}

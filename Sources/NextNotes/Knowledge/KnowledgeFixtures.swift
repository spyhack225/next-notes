import Foundation

/// A small library on disk for `--selftest-index` and `--selftest-search`: meeting folders in
/// the format `MeetingStore` writes, a conversation, dictations and a routine run — all under
/// a temporary directory. Nothing here reads the user's Application Support folder.
@MainActor
enum KnowledgeFixtures {
    /// 2026-03-02 14:00 UTC.
    static let pricingStart = Date(timeIntervalSince1970: 1_772_460_000)
    /// A week later.
    static let hiringStart = Date(timeIntervalSince1970: 1_773_064_800)

    static let pricingID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    static let hiringID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    /// Still recording: the indexer must leave it alone.
    static let liveID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    static let sessionID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    static let dictationID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
    static let routineRunID = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!

    /// The segment the search self-test expects to land on.
    static let decisionStart: TimeInterval = 312
    static let decisionEnd: TimeInterval = 318.5

    static let pricingNotes = """
        ## Summary

        The team reviewed the new pricing page and agreed a launch date.

        ## Key points

        - The annual plan discount moves from 15% to 20%.
        - Enterprise pricing stays on the contact form.

        ## Decisions

        - Ship the pricing page on Friday.
        - The budget owner for launch ads is Sam, with a budget of 4,000.

        ## Action items

        - **Ana** — publish the pricing page
          and announce it in the newsletter.

        ## Open questions

        _None._
        """

    static let hiringNotes = """
        ## Summary

        Hiring sync for the platform team.

        ## Decisions

        - Open a second backend role before the budget review.

        ## Action items

        _None._
        """

    /// Words that are not about anything, so padding never matches a query.
    static func filler(_ count: Int, seed: Int = 0) -> String {
        let words = ["lorem", "ipsum", "dolor", "sit", "amet", "consectetur", "adipiscing", "elit", "sed", "tempor"]
        return (0..<count).map { words[($0 + seed) % words.count] }.joined(separator: " ")
    }

    static func pricingSegments() -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        var time: TimeInterval = 0
        // Speaker 1 talks for ~220 words in 20-word segments with a pause after segment 8,
        // so the ~150-word cut lands on that pause and overlaps the next chunk by one segment.
        for index in 0..<11 {
            let gap: TimeInterval = index == 8 ? 2.0 : 0.2
            segments.append(TranscriptSegment(start: time, end: time + 8, text: filler(20, seed: index),
                                              source: .system, speaker: "Speaker 1"))
            time += 8 + gap
        }
        segments.append(TranscriptSegment(start: 300, end: 306, text: "What about the pricing page timing?",
                                          source: .mic))
        segments.append(TranscriptSegment(start: 306.5, end: 311, text: "Next Notes, add a reminder for Friday.",
                                          source: .mic, kind: .agentCommand))
        segments.append(TranscriptSegment(start: decisionStart, end: decisionEnd,
                                          text: "We decided to ship the pricing page on Friday.",
                                          source: .system, speaker: "Speaker 1"))
        segments.append(TranscriptSegment(start: 319, end: 325,
                                          text: "Sam owns the launch ads budget.", source: .system, speaker: "Speaker 2"))
        // One monologue segment longer than the hard cut.
        segments.append(TranscriptSegment(start: 400, end: 520, text: filler(320, seed: 3), source: .mic))
        return segments
    }

    static func hiringSegments() -> [TranscriptSegment] {
        [
            TranscriptSegment(start: 5, end: 12, text: "The budget review is next month, so the role opens first.",
                              source: .mic),
            TranscriptSegment(start: 13, end: 20, text: "Pricing is not on the agenda today.", source: .system,
                              speaker: "Speaker 1"),
        ]
    }

    static func writeMeeting(
        root: URL, id: UUID, title: String, start: Date, status: MeetingStatus = .done,
        segments: [TranscriptSegment], notes: String?, speakerNames: [String: String] = [:]
    ) throws {
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let meeting = Meeting(id: id, title: title, start: start, end: start.addingTimeInterval(1_800),
                              status: status, speakerNames: speakerNames)
        try encoder.encode(meeting).write(to: directory.appendingPathComponent(MeetingStore.recordFile), options: .atomic)
        try encoder.encode(segments).write(to: directory.appendingPathComponent(MeetingStore.transcriptFile), options: .atomic)
        if let notes {
            try notes.write(to: directory.appendingPathComponent(MeetingStore.notesFile), atomically: true, encoding: .utf8)
        }
    }

    static func writeNotes(root: URL, id: UUID, notes: String) throws {
        try notes.write(to: root.appendingPathComponent(id.uuidString, isDirectory: true)
            .appendingPathComponent(MeetingStore.notesFile), atomically: true, encoding: .utf8)
    }

    /// Two finished meetings and one still recording.
    static func writeLibrary(meetingsRoot root: URL) throws {
        try writeMeeting(root: root, id: pricingID, title: "Pricing review", start: pricingStart,
                         segments: pricingSegments(), notes: pricingNotes, speakerNames: ["Speaker 1": "Ana"])
        try writeMeeting(root: root, id: hiringID, title: "Hiring sync", start: hiringStart,
                         segments: hiringSegments(), notes: hiringNotes)
        try writeMeeting(root: root, id: liveID, title: "Live call", start: hiringStart.addingTimeInterval(86_400),
                         status: .recording,
                         segments: [TranscriptSegment(start: 1, end: 3, text: "Pricing live secret", source: .mic)],
                         notes: nil)
    }

    static func conversation() -> KnowledgeConversationSession {
        let at = pricingStart.addingTimeInterval(7_200)
        return KnowledgeConversationSession(id: sessionID, rows: [
            KnowledgeConversationRow(role: "user", text: "When does the pricing page ship?", source: "text", at: at),
            KnowledgeConversationRow(role: "assistant", text: "Calendar: Launch sync, Friday 10:00 (tool data)",
                                     contextKind: "calendar", at: at.addingTimeInterval(2)),
            KnowledgeConversationRow(role: "assistant", text: "On Friday, as decided in the pricing review.",
                                     at: at.addingTimeInterval(3)),
            KnowledgeConversationRow(role: "user", text: "Meeting line about quarterly goals", source: "meeting",
                                     at: at.addingTimeInterval(10)),
            KnowledgeConversationRow(role: "assistant", text: "Should I remind you every morning?",
                                     contextKind: AgentSession.routineSuggestionContextKind, at: at.addingTimeInterval(11)),
        ])
    }
}

/// Sources that read from the fixture folder and in-memory lists.
@MainActor
final class FixtureKnowledgeSources: KnowledgeSourceProviding {
    let meetingsRoot: URL
    var sessions: [KnowledgeConversationSession] = []
    var dictationRuns: [KnowledgeDictation] = []
    var routines: [KnowledgeRoutineRun] = []

    init(meetingsRoot: URL) {
        self.meetingsRoot = meetingsRoot
    }

    func endedConversationSessions() -> [KnowledgeConversationSession] { sessions }
    func dictations() -> [KnowledgeDictation] { dictationRuns }
    func routineRuns() -> [KnowledgeRoutineRun] { routines }

    func title(for hit: KnowledgeHit) -> String? {
        switch hit.sourceID {
        case KnowledgeFixtures.pricingID.uuidString: "Pricing review"
        case KnowledgeFixtures.hiringID.uuidString: "Hiring sync"
        default: nil
        }
    }

    func meetingIDs(matching name: String) -> [String] {
        if let id = UUID(uuidString: name) { return [id.uuidString] }
        return [(KnowledgeFixtures.pricingID, "Pricing review"), (KnowledgeFixtures.hiringID, "Hiring sync")]
            .filter { $0.1.localizedCaseInsensitiveContains(name) }.map(\.0.uuidString)
    }
}

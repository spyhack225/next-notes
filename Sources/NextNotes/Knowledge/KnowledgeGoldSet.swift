import Foundation

/// The retrieval gold set: `Tests/Fixtures/knowledge-gold.json`.
///
/// Without one there is no telling whether a change helped, and every change feels like it
/// helped. Each question names the one passage that answers it by its source and a phrase
/// the passage contains — not by chunk id, which a rebuild changes. The file carries its own
/// small library, so `--selftest-search` builds the index from it in a temporary directory.
///
/// A scaffold: the questions are written against a hand-made library, and the metrics a
/// fake embedder produces measure the pipeline, not a model. The same format, pointed at
/// real meetings with real questions, is what decides between potion and EmbeddingGemma —
/// pending until the library holds meetings worth asking about.
struct KnowledgeGoldSet: Decodable {
    struct Meeting: Decodable {
        let key: String
        let title: String
        let start: Date
        let notes: String
    }

    struct Conversation: Decodable {
        struct Turn: Decodable {
            let role: String
            let text: String
        }

        let key: String
        let at: Date
        let turns: [Turn]
    }

    struct Question: Decodable {
        let kind: String
        let question: String
        let source: String
        let contains: String
    }

    let meetings: [Meeting]
    let conversations: [Conversation]
    let questions: [Question]

    /// `--gold <path>`, else the repository's copy beside this source file, else the working
    /// directory's.
    static func fileURL() -> URL? {
        if let path = SelfTest.value(after: "--gold") { return URL(fileURLWithPath: path) }
        let relative = "Tests/Fixtures/knowledge-gold.json"
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        for base in [repository, URL(fileURLWithPath: FileManager.default.currentDirectoryPath)] {
            let url = base.appendingPathComponent(relative)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    static func load() throws -> KnowledgeGoldSet {
        guard let url = fileURL() else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "knowledge-gold.json not found (pass --gold <path>)"])
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(KnowledgeGoldSet.self, from: Data(contentsOf: url))
    }

    /// A stable id per source key, so a hit maps back to the key it came from.
    static func sourceID(_ index: Int, conversation: Bool) -> UUID {
        UUID(uuidString: String(format: "%@-0000-4000-8000-%012d", conversation ? "C0C0C0C0" : "A0A0A0A0", index))!
    }

    /// Source key → the id its chunks carry in the index.
    var sourceIDs: [String: String] {
        var ids: [String: String] = [:]
        for (index, meeting) in meetings.enumerated() { ids[meeting.key] = Self.sourceID(index, conversation: false).uuidString }
        for (index, session) in conversations.enumerated() {
            ids[session.key] = Self.sourceID(index, conversation: true).uuidString
        }
        return ids
    }

    /// Writes the meetings as folders and returns the sessions, for `FixtureKnowledgeSources`.
    @MainActor
    func writeLibrary(meetingsRoot: URL) throws -> [KnowledgeConversationSession] {
        for (index, meeting) in meetings.enumerated() {
            try KnowledgeFixtures.writeMeeting(root: meetingsRoot, id: Self.sourceID(index, conversation: false),
                                               title: meeting.title, start: meeting.start, segments: [],
                                               notes: meeting.notes)
        }
        return conversations.enumerated().map { index, session in
            KnowledgeConversationSession(
                id: Self.sourceID(index, conversation: true),
                rows: session.turns.enumerated().map { offset, turn in
                    KnowledgeConversationRow(role: turn.role, text: turn.text, source: turn.role == "user" ? "text" : nil,
                                             at: session.at.addingTimeInterval(Double(offset)))
                })
        }
    }

    // MARK: - Metrics

    struct Score: Equatable {
        var questions = 0
        var found = 0
        var reciprocalRanks: Double = 0

        var recallAt10: Double { questions == 0 ? 0 : Double(found) / Double(questions) }
        var mrr: Double { questions == 0 ? 0 : reciprocalRanks / Double(questions) }

        mutating func add(rank: Int?) {
            questions += 1
            guard let rank, rank <= 10 else { return }
            found += 1
            reciprocalRanks += 1 / Double(rank)
        }

        var line: String { String(format: "recall@10=%.3f MRR=%.3f (%d/%d)", recallAt10, mrr, found, questions) }
    }

    struct Report {
        var bm25 = Score()
        var cosine = Score()
        var fused = Score()
        var byKind: [String: (bm25: Score, cosine: Score, fused: Score)] = [:]
        /// Questions no ranking found in its top ten.
        var missed: [String] = []
    }

    /// 1-based rank of the first passage that answers `question`, or nil.
    func rank(of question: Question, in hits: [KnowledgeHit]) -> Int? {
        guard let id = sourceIDs[question.source] else { return nil }
        return hits.firstIndex { $0.sourceID == id && $0.text.localizedCaseInsensitiveContains(question.contains) }
            .map { $0 + 1 }
    }

    func evaluate(_ search: HybridKnowledgeSearch) throws -> Report {
        var report = Report()
        for question in questions {
            let rankings = try search.rankings(KnowledgeQuery(text: question.question, limit: 10))
            let bm25 = rank(of: question, in: Array(rankings.bm25.prefix(10)))
            let cosine = rank(of: question, in: Array(rankings.cosine.prefix(10).map(\.hit)))
            let fused = rank(of: question, in: rankings.fused)
            report.bm25.add(rank: bm25)
            report.cosine.add(rank: cosine)
            report.fused.add(rank: fused)
            var kind = report.byKind[question.kind] ?? (Score(), Score(), Score())
            kind.bm25.add(rank: bm25)
            kind.cosine.add(rank: cosine)
            kind.fused.add(rank: fused)
            report.byKind[question.kind] = kind
            if fused == nil { report.missed.append(question.question) }
        }
        return report
    }
}

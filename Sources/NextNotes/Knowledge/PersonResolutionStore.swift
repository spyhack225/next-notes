import Foundation
import SQLite3

// Part 4, Phase D: where resolution lands, and what it reads.

extension KnowledgeStore {
    /// Additive, created on every connection like the graph tables.
    ///
    /// `person_entity` has one row per Person node and per voice-printed unnamed speaker.
    /// A merge sets `merged_into`; nothing is ever deleted by a merge, so un-merging is one
    /// `UPDATE` of one row. Rows are not foreign keys to `graph_node`: a meeting re-extracted
    /// drops and re-adds its shared nodes, and a decision must not go with them.
    static let resolutionSchema = """
        CREATE TABLE IF NOT EXISTS person_entity (
          id          TEXT PRIMARY KEY,     -- 'person:ana' or 'speaker:<meeting>:<label>'
          kind        TEXT NOT NULL,        -- 'person' | 'speaker'
          label       TEXT NOT NULL,
          merged_into TEXT,                 -- NULL = its own person
          method      TEXT,                 -- 'user' | 'email' | 'voice' | 'name' | 'model' | 'split'
          score       REAL,
          reasons     TEXT,
          meetings    INTEGER NOT NULL DEFAULT 0,
          decided_at  INTEGER
        );
        CREATE INDEX IF NOT EXISTS person_entity_merged ON person_entity(merged_into);

        CREATE TABLE IF NOT EXISTS person_candidate (
          a        TEXT NOT NULL,
          b        TEXT NOT NULL,
          score    REAL NOT NULL,
          reasons  TEXT NOT NULL,
          verdict  INTEGER,                 -- the model's answer: 1 same, 0 different, NULL not asked or unsure
          PRIMARY KEY (a, b)
        );
        """
}

/// One member of a resolved person, as the review sheet lists it.
struct ResolvedPersonMember: Identifiable, Equatable, Sendable {
    var id: String
    var label: String
    var kind: PersonMention.Kind
    var method: ResolutionMethod
    var score: Double?
    var reasons: String?
    var decidedAt: Date?
}

/// One person after resolution: the node that names them, and everything merged into it.
struct ResolvedPerson: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var kind: PersonMention.Kind
    var members: [ResolvedPersonMember]
    var meetings: Int

    var aliases: [String] { members.filter { $0.kind == .person }.map(\.label) }
}

/// `person_entity` and `person_candidate`.
struct PersonResolutionStore: Sendable {
    let store: KnowledgeStore

    /// Writes a plan in one transaction: every mention gets a row, rows for mentions that no
    /// longer exist go (their node is gone — that is not a merge), candidates are replaced.
    func apply(_ plan: ResolutionPlan, mentions: [PersonMention], now: Date = Date()) throws {
        try store.withWritingConnection { db in
            try KnowledgeStore.transaction(db) {
                try KnowledgeStore.exec(db, "CREATE TEMP TABLE IF NOT EXISTS person_seen (id TEXT PRIMARY KEY); DELETE FROM person_seen;")
                let upsert = try KnowledgeStore.prepare(db, """
                    INSERT INTO person_entity (id, kind, label, merged_into, method, score, reasons, meetings, decided_at)
                    VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)
                    ON CONFLICT (id) DO UPDATE SET
                      kind = excluded.kind, label = excluded.label, meetings = excluded.meetings,
                      merged_into = excluded.merged_into,
                      -- A split the user made stays marked until something merges it again.
                      method = CASE WHEN excluded.merged_into IS NULL AND person_entity.method = 'split'
                                    THEN 'split' ELSE excluded.method END,
                      score = excluded.score, reasons = excluded.reasons,
                      decided_at = CASE WHEN person_entity.merged_into IS excluded.merged_into
                                        THEN person_entity.decided_at ELSE excluded.decided_at END
                    """)
                defer { sqlite3_finalize(upsert) }
                let seen = try KnowledgeStore.prepare(db, "INSERT OR IGNORE INTO person_seen (id) VALUES (?1)")
                defer { sqlite3_finalize(seen) }
                for mention in mentions {
                    let assignment = plan.assignments[mention.id] ?? PersonAssignment()
                    sqlite3_reset(upsert)
                    sqlite3_clear_bindings(upsert)
                    KnowledgeStore.bind(upsert, [
                        .text(mention.id), .text(mention.kind.rawValue), .text(mention.label),
                        .optionalText(assignment.mergedInto), .optionalText(assignment.method?.rawValue),
                        .double(assignment.score), .optionalText(assignment.reasons),
                        .int(Int64(mention.meetings.count)), .int(Int64(now.timeIntervalSince1970)),
                    ])
                    guard sqlite3_step(upsert) == SQLITE_DONE else { throw KnowledgeStore.error(db) }
                    sqlite3_reset(seen)
                    KnowledgeStore.bind(seen, [.text(mention.id)])
                    guard sqlite3_step(seen) == SQLITE_DONE else { throw KnowledgeStore.error(db) }
                }
                try KnowledgeStore.exec(db, "DELETE FROM person_entity WHERE id NOT IN (SELECT id FROM person_seen)")

                try KnowledgeStore.exec(db, "DELETE FROM person_candidate")
                let candidate = try KnowledgeStore.prepare(db, """
                    INSERT OR REPLACE INTO person_candidate (a, b, score, reasons, verdict) VALUES (?1, ?2, ?3, ?4, ?5)
                    """)
                defer { sqlite3_finalize(candidate) }
                for entry in plan.candidates {
                    sqlite3_reset(candidate)
                    sqlite3_clear_bindings(candidate)
                    KnowledgeStore.bind(candidate, [
                        .text(entry.pair.a), .text(entry.pair.b), .double(entry.score), .text(entry.reasons),
                        entry.verdict.map { .int($0 ? 1 : 0) } ?? .optionalText(nil),
                    ])
                    guard sqlite3_step(candidate) == SQLITE_DONE else { throw KnowledgeStore.error(db) }
                }
            }
        }
    }

    /// The user's merge: one row. A chain (`a` into `b`, `b` later into `c`) is followed on read.
    /// - Returns: rows changed — 1, or 0 when either id is unknown.
    @discardableResult
    func merge(_ id: String, into target: String, now: Date = Date()) throws -> Int {
        guard id != target else { return 0 }
        return try store.withWritingConnection { db in
            try KnowledgeStore.run(db, """
                UPDATE person_entity SET merged_into = ?2, method = 'user', score = 1, reasons = 'merged by you',
                  decided_at = ?3
                WHERE id = ?1 AND EXISTS (SELECT 1 FROM person_entity WHERE id = ?2)
                """, [.text(id), .text(target), .int(Int64(now.timeIntervalSince1970))])
            return Int(sqlite3_changes(db))
        }
    }

    /// Un-merge: one `UPDATE` of one row. The row was never deleted, so nothing is restored
    /// but the pointer.
    /// - Returns: the person it had been merged into, or nil when it was not merged.
    @discardableResult
    func split(_ id: String, now: Date = Date()) throws -> (previous: String, changedRows: Int)? {
        try store.withWritingConnection { db in
            let statement = try KnowledgeStore.prepare(db, "SELECT merged_into FROM person_entity WHERE id = ?1")
            KnowledgeStore.bind(statement, [.text(id)])
            let previous = sqlite3_step(statement) == SQLITE_ROW ? KnowledgeStore.text(statement, 0) : nil
            sqlite3_finalize(statement)
            guard let previous else { return nil }
            try KnowledgeStore.run(db, """
                UPDATE person_entity SET merged_into = NULL, method = 'split', score = NULL, reasons = NULL, decided_at = ?2
                WHERE id = ?1
                """, [.text(id), .int(Int64(now.timeIntervalSince1970))])
            return (previous, Int(sqlite3_changes(db)))
        }
    }

    func deleteAll() throws {
        guard store.existsOnDisk else { return }
        try store.withWritingConnection { db in
            try KnowledgeStore.exec(db, "DELETE FROM person_entity; DELETE FROM person_candidate;")
        }
    }

    // MARK: Reads

    struct Row: Equatable, Sendable {
        var id: String
        var kind: PersonMention.Kind
        var label: String
        var mergedInto: String?
        var method: String?
        var score: Double?
        var reasons: String?
        var meetings: Int
        var decidedAt: Date?
    }

    func rows() throws -> [Row] {
        guard store.existsOnDisk else { return [] }
        return try store.withConnection { db in try Self.rows(db) }
    }

    static func rows(_ db: OpaquePointer) throws -> [Row] {
        let statement = try KnowledgeStore.prepare(db, """
            SELECT id, kind, label, merged_into, method, score, reasons, meetings, decided_at FROM person_entity ORDER BY id
            """)
        defer { sqlite3_finalize(statement) }
        var result: [Row] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = KnowledgeStore.text(statement, 0) else { continue }
            result.append(Row(
                id: id, kind: PersonMention.Kind(rawValue: KnowledgeStore.text(statement, 1) ?? "") ?? .person,
                label: KnowledgeStore.text(statement, 2) ?? id, mergedInto: KnowledgeStore.text(statement, 3),
                method: KnowledgeStore.text(statement, 4), score: KnowledgeStore.optionalDouble(statement, 5),
                reasons: KnowledgeStore.text(statement, 6), meetings: Int(sqlite3_column_int(statement, 7)),
                decidedAt: sqlite3_column_type(statement, 8) == SQLITE_NULL
                    ? nil : Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 8)))))
        }
        return result
    }

    /// Follows `merged_into` to the end, stopping at a cycle.
    static func canonical(_ id: String, parents: [String: String]) -> String {
        var current = id
        var seen: Set<String> = [id]
        while let next = parents[current], seen.insert(next).inserted {
            current = next
        }
        return current
    }

    func canonical(_ id: String) throws -> String {
        let parents = Dictionary(try rows().compactMap { row in row.mergedInto.map { (row.id, $0) } },
                                 uniquingKeysWith: { first, _ in first })
        return Self.canonical(id, parents: parents)
    }

    /// Every id that resolves to the same person as `id`, itself included.
    static func memberIDs(_ db: OpaquePointer, of id: String) throws -> [String] {
        let all = try rows(db)
        let parents = Dictionary(all.compactMap { row in row.mergedInto.map { (row.id, $0) } }, uniquingKeysWith: { first, _ in first })
        let root = canonical(id, parents: parents)
        var members = all.map(\.id).filter { canonical($0, parents: parents) == root }
        if !members.contains(id) { members.append(id) }
        if !members.contains(root) { members.append(root) }
        return members.sorted()
    }

    /// Every resolved person, most merged first.
    func people() throws -> [ResolvedPerson] {
        let all = try rows()
        let parents = Dictionary(all.compactMap { row in row.mergedInto.map { (row.id, $0) } }, uniquingKeysWith: { first, _ in first })
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var groups: [String: [Row]] = [:]
        for row in all { groups[Self.canonical(row.id, parents: parents), default: []].append(row) }
        return groups.compactMap { root, rows -> ResolvedPerson? in
            guard let head = byID[root] else { return nil }
            let members = rows.filter { $0.id != root }.map { row in
                ResolvedPersonMember(id: row.id, label: row.label, kind: row.kind,
                                     method: row.method.flatMap(ResolutionMethod.init(rawValue:)) ?? .name,
                                     score: row.score, reasons: row.reasons, decidedAt: row.decidedAt)
            }.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
            return ResolvedPerson(id: root, name: head.label, kind: head.kind, members: members,
                                  meetings: rows.map(\.meetings).max() ?? head.meetings)
        }
        .sorted { lhs, rhs in
            lhs.members.count != rhs.members.count ? lhs.members.count > rhs.members.count
                : lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    func candidates() throws -> [PersonCandidate] {
        guard store.existsOnDisk else { return [] }
        return try store.withConnection { db in
            let statement = try KnowledgeStore.prepare(db, "SELECT a, b, score, reasons, verdict FROM person_candidate ORDER BY score DESC, a, b")
            defer { sqlite3_finalize(statement) }
            var result: [PersonCandidate] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let a = KnowledgeStore.text(statement, 0), let b = KnowledgeStore.text(statement, 1) else { continue }
                result.append(PersonCandidate(
                    pair: PersonPair(a, b), score: sqlite3_column_double(statement, 2),
                    reasons: KnowledgeStore.text(statement, 3) ?? "",
                    verdict: sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil : sqlite3_column_int(statement, 4) == 1))
            }
            return result
        }
    }

    /// The model's cached answers, so a pair is asked once per scoring.
    func verdicts() throws -> [PersonPair: Bool] {
        var result: [PersonPair: Bool] = [:]
        for candidate in try candidates() {
            if let verdict = candidate.verdict { result[candidate.pair] = verdict }
        }
        return result
    }
}

// MARK: - The user's decisions

/// `knowledge-person-decisions.json`: the merges and splits the user made in the review
/// sheet. Outside `knowledge.sqlite` on purpose — the index is disposable, the user's word is
/// not — so a rebuilt index resolves people the way the user left them. Written atomically.
final class PersonDecisionLog: @unchecked Sendable {
    static let fileName = "knowledge-person-decisions.json"

    let directory: URL
    var fileURL: URL { directory.appendingPathComponent(Self.fileName) }
    private let lock = NSLock()
    private var stored: PersonDecisions

    init(directory: URL) {
        self.directory = directory
        if let data = try? Data(contentsOf: directory.appendingPathComponent(Self.fileName)),
           let decoded = try? JSONDecoder().decode(PersonDecisions.self, from: data) {
            stored = decoded
        } else {
            stored = PersonDecisions()
        }
    }

    var decisions: PersonDecisions {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    /// `id` is the same person as `target`: recorded, and any "apart" between them withdrawn.
    func recordMerge(_ id: String, into target: String) throws {
        try change { decisions in
            decisions.merges[id] = target
            decisions.apart.remove(PersonPair(id, target))
        }
    }

    /// `id` is not `other`: the merge withdrawn, and the pair kept apart from now on.
    func recordApart(_ id: String, from other: String) throws {
        try change { decisions in
            if decisions.merges[id] == other { decisions.merges[id] = nil }
            if decisions.merges[other] == id { decisions.merges[other] = nil }
            decisions.apart.insert(PersonPair(id, other))
        }
    }

    func withdrawApart(_ id: String, from other: String) throws {
        try change { $0.apart.remove(PersonPair(id, other)) }
    }

    func withdrawMerge(_ id: String) throws {
        try change { $0.merges[id] = nil }
    }

    func clear() throws {
        try change { $0 = PersonDecisions() }
    }

    private func change(_ body: (inout PersonDecisions) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        var next = stored
        body(&next)
        guard next != stored else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(next).write(to: fileURL, options: .atomic)
        stored = next
    }
}

// MARK: - Evidence

/// Reads the mentions resolution scores from the graph, the chunk table, the vectors and the
/// meeting folders' `speakers.json`. Read-only.
struct PersonEvidenceLoader: Sendable {
    let store: KnowledgeStore
    let meetingsRoot: URL

    static func speakerID(meetingID: String, label: String) -> String {
        "speaker:\(meetingID):\(GraphIDs.slug(label))"
    }

    func load() throws -> [PersonMention] {
        guard store.existsOnDisk else { return [] }
        struct Raw {
            var people: [String: PersonMention] = [:]
            var meetingTitles: [String: String] = [:]
            /// Meeting → speaker label → chunk ids, for unnamed speakers.
            var unnamedChunks: [String: [String: [Int64]]] = [:]
            var chunksByMention: [String: [Int64]] = [:]
        }
        var raw = try store.withConnection { db -> Raw in
            var raw = Raw()
            let nodes = try KnowledgeStore.prepare(db, "SELECT id, type, label, meeting_id FROM graph_node WHERE type IN ('Person', 'Meeting')")
            while sqlite3_step(nodes) == SQLITE_ROW {
                guard let id = KnowledgeStore.text(nodes, 0), let type = KnowledgeStore.text(nodes, 1) else { continue }
                let label = KnowledgeStore.text(nodes, 2) ?? id
                if type == "Person" {
                    raw.people[id] = PersonMention(id: id, label: label, emails: PersonName.parse(label).emails)
                } else if let meeting = KnowledgeStore.text(nodes, 3) {
                    raw.meetingTitles[meeting] = label
                }
            }
            sqlite3_finalize(nodes)

            // attended edges cite the speaker's first passage (a transcript chunk) or the notes
            // anchor (an invitation); owns edges cite the action item's passage.
            let edges = try KnowledgeStore.prepare(db, """
                SELECT e.type, e.from_node, e.meeting_id, e.source_chunk, c.source_kind
                FROM graph_edge e LEFT JOIN chunk c ON c.id = e.source_chunk
                WHERE e.type IN ('attended', 'owns')
                """)
            while sqlite3_step(edges) == SQLITE_ROW {
                guard let type = KnowledgeStore.text(edges, 0), let person = KnowledgeStore.text(edges, 1),
                      let meeting = KnowledgeStore.text(edges, 2), raw.people[person] != nil else { continue }
                raw.people[person]?.meetings.insert(meeting)
                if type == "attended", KnowledgeStore.text(edges, 4) == KnowledgeSourceKind.notes.rawValue {
                    raw.people[person]?.listedIn.insert(meeting)
                }
                if type == "owns" { raw.chunksByMention[person, default: []].append(sqlite3_column_int64(edges, 3)) }
            }
            sqlite3_finalize(edges)

            let spoken = try KnowledgeStore.prepare(db, """
                SELECT source_id, speaker, id FROM chunk WHERE source_kind = 'transcript' AND speaker IS NOT NULL
                """)
            while sqlite3_step(spoken) == SQLITE_ROW {
                guard let meeting = KnowledgeStore.text(spoken, 0), let speaker = KnowledgeStore.text(spoken, 1),
                      raw.meetingTitles[meeting] != nil else { continue }
                let chunk = sqlite3_column_int64(spoken, 2)
                if GraphBuilder.isPerson(speaker) {
                    let id = GraphIDs.person(speaker)
                    guard raw.people[id] != nil else { continue }
                    raw.people[id]?.spokeIn.insert(meeting)
                    raw.people[id]?.meetings.insert(meeting)
                    raw.chunksByMention[id, default: []].append(chunk)
                } else if speaker.firstMatch(of: /^Speaker \d+$/) != nil {
                    raw.unnamedChunks[meeting, default: [:]][speaker, default: []].append(chunk)
                }
            }
            sqlite3_finalize(spoken)
            return raw
        }

        // Voices: a named speaker's print joins its Person; an unnamed one becomes a mention.
        for meeting in raw.meetingTitles.keys.sorted() {
            let directory = meetingsRoot.appendingPathComponent(meeting, isDirectory: true)
            guard let prints = MeetingVoicePrints.read(directory: directory) else { continue }
            let names = Self.speakerNames(directory: directory)
            for print in prints.prints(meetingID: meeting) {
                if let name = names[print.label], GraphBuilder.isPerson(name) {
                    let id = GraphIDs.person(name)
                    raw.people[id]?.voices.append(print)
                    raw.people[id]?.spokeIn.insert(meeting)
                } else {
                    let id = Self.speakerID(meetingID: meeting, label: print.label)
                    raw.people[id] = PersonMention(
                        id: id, kind: .speaker, label: "\(print.label) in \(raw.meetingTitles[meeting] ?? "a meeting")",
                        meetings: [meeting], spokeIn: [meeting], voices: [print])
                    raw.chunksByMention[id] = raw.unnamedChunks[meeting]?[print.label] ?? []
                }
            }
        }

        // Who was around whom. Someone in most meetings — the user, "You" on the mic track — is
        // around everyone, and says nothing about who anyone is.
        var byMeeting: [String: Set<String>] = [:]
        for mention in raw.people.values {
            for meeting in mention.meetings { byMeeting[meeting, default: []].insert(mention.id) }
        }
        let everywhere = Double(max(3, Int((Double(byMeeting.count) * 0.5).rounded(.up))))
        let ubiquitous = Set(raw.people.values.filter { Double($0.meetings.count) >= everywhere }.map(\.id))
        for id in raw.people.keys {
            guard let mention = raw.people[id] else { continue }
            var others: Set<String> = []
            for meeting in mention.meetings { others.formUnion(byMeeting[meeting] ?? []) }
            others.remove(id)
            others.subtract(ubiquitous)
            raw.people[id]?.coAttendees = others
            raw.people[id]?.meetingTitles = mention.meetings.compactMap { raw.meetingTitles[$0] }.sorted()
        }

        // Context: the mean of the vectors of what they said and owned, from the model most
        // of those passages have vectors for.
        let wanted = Set(raw.chunksByMention.values.flatMap { $0 })
        let vectors = try contextVectors(for: wanted)
        for (id, chunks) in raw.chunksByMention {
            let rows = chunks.compactMap { vectors[$0] }
            guard let dims = rows.first?.count, rows.allSatisfy({ $0.count == dims }) else { continue }
            var mean = [Float](repeating: 0, count: dims)
            for row in rows { for index in mean.indices { mean[index] += row[index] } }
            let norm = mean.reduce(0) { $0 + $1 * $1 }.squareRoot()
            if norm > 0 { raw.people[id]?.context = mean.map { $0 / norm } }
        }
        return raw.people.values.sorted { $0.id < $1.id }
    }

    private func contextVectors(for chunks: Set<Int64>) throws -> [Int64: [Float]] {
        guard !chunks.isEmpty else { return [:] }
        return try store.withConnection { db in
            let statement = try KnowledgeStore.prepare(db, "SELECT chunk_id, model, dims, vector FROM embedding")
            defer { sqlite3_finalize(statement) }
            var byModel: [String: [Int64: [Float]]] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                let chunk = sqlite3_column_int64(statement, 0)
                guard chunks.contains(chunk), let model = KnowledgeStore.text(statement, 1),
                      let blob = sqlite3_column_blob(statement, 3) else { continue }
                let dims = Int(sqlite3_column_int(statement, 2))
                let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 3)))
                if let vector = EmbeddingMath.vector(from: data, dimensions: dims) { byModel[model, default: [:]][chunk] = vector }
            }
            return byModel.max { $0.value.count != $1.value.count ? $0.value.count < $1.value.count : $0.key > $1.key }?.value ?? [:]
        }
    }

    private static func speakerNames(directory: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(MeetingStore.recordFile)) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(Meeting.self, from: data))?.speakerNames ?? [:]
    }
}

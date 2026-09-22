import Foundation
import SQLite3

/// Filters, applied as SQL in the query rather than after it: a filter applied post-hoc to
/// the top fifty would quietly return nothing for a speaker who is not in them.
struct KnowledgeFilter: Equatable, Sendable {
    /// Empty means every kind; likewise for the sets below.
    var kinds: Set<KnowledgeSourceKind> = []
    var sourceIDs: Set<String> = []
    var speakers: Set<String> = []
    var headings: Set<String> = []
    var from: Date?
    var to: Date?

    var isEmpty: Bool { self == KnowledgeFilter() }
}

struct KnowledgeQuery: Equatable, Sendable {
    var text: String
    var filter = KnowledgeFilter()
    var limit = 50
    /// The query's embedding, when a caller that can wait computed it (`prepare`). Nil
    /// leaves hybrid search to an embedder that answers inline, or to BM25 alone.
    var vector: [Float]? = nil
    /// The vector set `prepare` loaded beside `vector`, so the synchronous search that follows
    /// — on the main actor, for `memory.recall` — never rebuilds it from SQLite because a
    /// write landed in between. Passages written since are missed for this one search;
    /// passages deleted since are dropped when the hits are re-joined to `chunk`.
    var preparedVectors: KnowledgePreparedVectors? = nil
}

/// A loaded vector set, compared by identity: two queries are equal when they carry the
/// same load, and nothing compares 38 MB of floats.
final class KnowledgePreparedVectors: Equatable, Sendable {
    let set: KnowledgeVectorSet

    init(_ set: KnowledgeVectorSet) {
        self.set = set
    }

    static func == (lhs: KnowledgePreparedVectors, rhs: KnowledgePreparedVectors) -> Bool { lhs === rhs }
}

/// One ranked passage.
struct KnowledgeHit: Identifiable, Equatable, Sendable {
    let chunkID: Int64
    let kind: KnowledgeSourceKind
    let sourceID: String
    let ordinal: Int
    let text: String
    /// The matching words wrapped in `snippetOpen` / `snippetClose`.
    let snippet: String
    let startTime: Double?
    let endTime: Double?
    let speaker: String?
    let heading: String?
    let occurredAt: Date
    /// Lower is better, as BM25 reports it. Zero for a browse with no query text.
    let score: Double

    var id: Int64 { chunkID }

    static let snippetOpen = "\u{2}"
    static let snippetClose = "\u{3}"

    /// The snippet without its markers, for anything that is not the search screen.
    var plainSnippet: String {
        snippet.replacingOccurrences(of: Self.snippetOpen, with: "")
            .replacingOccurrences(of: Self.snippetClose, with: "")
    }
}

/// Counts down the facet rail. Computed for the query text alone, so the rail shows what is
/// there to narrow to rather than collapsing onto the current selection.
struct KnowledgeFacets: Equatable, Sendable {
    var kinds: [KnowledgeSourceKind: Int] = [:]
    var speakers: [String: Int] = [:]
    var headings: [String: Int] = [:]
    var sources: [String: Int] = [:]
}

/// Search behind a protocol, so Phase B's hybrid BM25 + cosine + RRF drops in without the
/// view, `memory.recall` or the self-tests changing.
protocol KnowledgeSearching: Sendable {
    func search(_ query: KnowledgeQuery) throws -> [KnowledgeHit]
    func facets(_ query: KnowledgeQuery) throws -> KnowledgeFacets
    /// Does whatever needs to wait before `search` — embedding the query text through a
    /// model actor. Keyword search needs nothing.
    func prepare(_ query: KnowledgeQuery) async -> KnowledgeQuery
}

extension KnowledgeSearching {
    func prepare(_ query: KnowledgeQuery) async -> KnowledgeQuery { query }
}

/// Phase A: FTS5 BM25 alone, ranked, stemmed, with snippets.
struct KeywordKnowledgeSearch: KnowledgeSearching {
    let store: KnowledgeStore

    func search(_ query: KnowledgeQuery) throws -> [KnowledgeHit] {
        let tokens = KnowledgeFTSQuery.tokens(query.text)
        guard !tokens.isEmpty else { return try browse(query) }
        // Every word first; any word when that finds nothing, so a long question still
        // returns the passage that has most of it.
        let all = try ranked(KnowledgeFTSQuery.expression(tokens, joiner: " AND "), query: query)
        guard all.isEmpty, tokens.count > 1 else { return all }
        return try ranked(KnowledgeFTSQuery.expression(tokens, joiner: " OR "), query: query)
    }

    func facets(_ query: KnowledgeQuery) throws -> KnowledgeFacets {
        let tokens = KnowledgeFTSQuery.tokens(query.text)
        var match: String?
        if !tokens.isEmpty {
            let all = KnowledgeFTSQuery.expression(tokens, joiner: " AND ")
            match = try count(all) == 0 && tokens.count > 1
                ? KnowledgeFTSQuery.expression(tokens, joiner: " OR ") : all
        }
        var facets = KnowledgeFacets()
        for (key, value) in try group("source_kind", match: match) {
            if let kind = KnowledgeSourceKind(rawValue: key) { facets.kinds[kind] = value }
        }
        facets.speakers = try group("speaker", match: match)
        facets.headings = try group("heading", match: match)
        facets.sources = try group("source_id", match: match)
        return facets
    }

    // MARK: - SQL

    private static let columns = """
        c.id, c.source_kind, c.source_id, c.ordinal, c.text, c.start_time, c.end_time, c.speaker,
        c.heading, c.occurred_at
        """

    private func ranked(_ match: String, query: KnowledgeQuery) throws -> [KnowledgeHit] {
        var values: [KnowledgeStore.SQLValue] = [.text(match)]
        let filters = Self.whereClause(query.filter, values: &values)
        values.append(.int(Int64(max(1, query.limit))))
        let sql = """
            SELECT \(Self.columns),
                   snippet(chunk_fts, 0, char(2), char(3), '…', 24),
                   bm25(chunk_fts) AS score
            FROM chunk_fts JOIN chunk c ON c.id = chunk_fts.rowid
            WHERE chunk_fts MATCH ?1\(filters)
            ORDER BY score, c.occurred_at DESC
            LIMIT ?\(values.count)
            """
        return try hits(sql, values: values, snippetColumn: 10, scoreColumn: 11)
    }

    /// No words: the newest passages under the filters, so the facet rail alone is a way in.
    private func browse(_ query: KnowledgeQuery) throws -> [KnowledgeHit] {
        guard !query.filter.isEmpty else { return [] }
        var values: [KnowledgeStore.SQLValue] = []
        let filters = Self.whereClause(query.filter, values: &values)
        values.append(.int(Int64(max(1, query.limit))))
        let sql = """
            SELECT \(Self.columns)
            FROM chunk c
            WHERE 1\(filters)
            ORDER BY c.occurred_at DESC, c.ordinal
            LIMIT ?\(values.count)
            """
        return try hits(sql, values: values, snippetColumn: nil, scoreColumn: nil)
    }

    /// Rows by id, under the same filters, for passages the vector leg found and BM25 did
    /// not. No snippet markers: nothing matched a word.
    func hits(ids: [Int64], filter: KnowledgeFilter) throws -> [KnowledgeHit] {
        guard !ids.isEmpty else { return [] }
        var values: [KnowledgeStore.SQLValue] = []
        var placeholders: [String] = []
        for id in ids {
            values.append(.int(id))
            placeholders.append("?\(values.count)")
        }
        let filters = Self.whereClause(filter, values: &values)
        let sql = """
            SELECT \(Self.columns)
            FROM chunk c
            WHERE c.id IN (\(placeholders.joined(separator: ", ")))\(filters)
            """
        return try hits(sql, values: values, snippetColumn: nil, scoreColumn: nil)
    }

    private func hits(_ sql: String, values: [KnowledgeStore.SQLValue], snippetColumn: Int32?,
                      scoreColumn: Int32?) throws -> [KnowledgeHit] {
        try store.withConnection { db in
            let statement = try KnowledgeStore.prepare(db, sql)
            defer { sqlite3_finalize(statement) }
            KnowledgeStore.bind(statement, values)
            var result: [KnowledgeHit] = []
            while true {
                let code = sqlite3_step(statement)
                if code == SQLITE_DONE { break }
                guard code == SQLITE_ROW else { throw KnowledgeStore.error(db) }
                guard let kindRaw = KnowledgeStore.text(statement, 1),
                      let kind = KnowledgeSourceKind(rawValue: kindRaw) else { continue }
                let text = KnowledgeStore.text(statement, 4) ?? ""
                let snippet = snippetColumn.flatMap { KnowledgeStore.text(statement, $0) }
                    ?? (text.count > 240 ? String(text.prefix(239)) + "…" : text)
                result.append(KnowledgeHit(
                    chunkID: sqlite3_column_int64(statement, 0),
                    kind: kind,
                    sourceID: KnowledgeStore.text(statement, 2) ?? "",
                    ordinal: Int(sqlite3_column_int(statement, 3)),
                    text: text,
                    snippet: snippet,
                    startTime: KnowledgeStore.optionalDouble(statement, 5),
                    endTime: KnowledgeStore.optionalDouble(statement, 6),
                    speaker: KnowledgeStore.text(statement, 7),
                    heading: KnowledgeStore.text(statement, 8),
                    occurredAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 9))),
                    score: scoreColumn.map { sqlite3_column_double(statement, $0) } ?? 0
                ))
            }
            return result
        }
    }

    private func count(_ match: String) throws -> Int {
        try store.withConnection { db in
            Int(try KnowledgeStore.optionalInt(db, "SELECT count(*) FROM chunk_fts WHERE chunk_fts MATCH ?1",
                                               [.text(match)]) ?? 0)
        }
    }

    private func group(_ column: String, match: String?) throws -> [String: Int] {
        let sql = match == nil
            ? "SELECT c.\(column), count(*) FROM chunk c WHERE c.\(column) IS NOT NULL GROUP BY c.\(column)"
            : """
              SELECT c.\(column), count(*) FROM chunk_fts JOIN chunk c ON c.id = chunk_fts.rowid
              WHERE chunk_fts MATCH ?1 AND c.\(column) IS NOT NULL GROUP BY c.\(column)
              """
        return try store.withConnection { db in
            let statement = try KnowledgeStore.prepare(db, sql)
            defer { sqlite3_finalize(statement) }
            if let match { KnowledgeStore.bind(statement, [.text(match)]) }
            var counts: [String: Int] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                if let key = KnowledgeStore.text(statement, 0) { counts[key] = Int(sqlite3_column_int(statement, 1)) }
            }
            return counts
        }
    }

    /// ` AND …` clauses with their values appended to `values`, numbered to follow them.
    static func whereClause(_ filter: KnowledgeFilter, values: inout [KnowledgeStore.SQLValue]) -> String {
        var clause = ""
        func list(_ column: String, _ items: [String]) {
            guard !items.isEmpty else { return }
            var placeholders: [String] = []
            for item in items {
                values.append(.text(item))
                placeholders.append("?\(values.count)")
            }
            clause += " AND c.\(column) IN (\(placeholders.joined(separator: ", ")))"
        }
        list("source_kind", filter.kinds.map(\.rawValue).sorted())
        list("source_id", filter.sourceIDs.sorted())
        list("speaker", filter.speakers.sorted())
        list("heading", filter.headings.sorted())
        if let from = filter.from {
            values.append(.int(Int64(from.timeIntervalSince1970.rounded(.down))))
            clause += " AND c.occurred_at >= ?\(values.count)"
        }
        if let to = filter.to {
            values.append(.int(Int64(to.timeIntervalSince1970.rounded(.up))))
            clause += " AND c.occurred_at <= ?\(values.count)"
        }
        return clause
    }
}

// MARK: - The whole library: passages and the user's own files

/// Everything Search can look through, as one list of sources.
///
/// A file is deliberately **not** a sixth kind of passage. `chunk.source_kind` says what
/// somebody said or wrote; a file row is a name, a path and a date, and nothing in it was
/// ever spoken — the index never opens a file. So files ride beside the passage kinds as
/// their own source, are labelled as their own source everywhere they surface, and an
/// answer can never quote one as though it were a sentence from a meeting.
enum LibrarySource: Hashable, Identifiable, Sendable {
    case passages(KnowledgeSourceKind)
    case files

    var id: String {
        switch self {
        case .passages(let kind): kind.rawValue
        case .files: "files"
        }
    }

    /// Plain words, because the rail is read by people who did not build this.
    var title: String {
        switch self {
        case .passages(let kind): kind.title
        case .files: "Files and folders"
        }
    }

    var kind: KnowledgeSourceKind? {
        if case .passages(let kind) = self { return kind }
        return nil
    }

    /// The passage kinds, then files. Files are offered only when the user has switched
    /// folder access on: there is nothing to count, and nothing to promise, otherwise.
    static func all(includingFiles: Bool) -> [LibrarySource] {
        KnowledgeSourceKind.allCases.map(Self.passages) + (includingFiles ? [.files] : [])
    }
}

/// What the facet rail has narrowed to, across both stores.
///
/// `KnowledgeFilter` stays exactly what it was — the clauses that go into the passage SQL.
/// This sits above it and adds the two things that are not passage columns: whether files
/// are in scope, and which resolved people are.
struct LibraryFilter: Equatable, Sendable {
    /// Ticked sources. Empty means every source there is, which is what an untouched rail
    /// means.
    var sources: Set<LibrarySource> = []
    var sourceIDs: Set<String> = []
    var speakers: Set<String> = []
    /// Resolved people, by the name shown in the rail. Expanded to every speaker label that
    /// turned out to be that person, so ticking "Margaret" finds the passages filed under
    /// "Margaret" and under "Margaret Sclafani" alike.
    var people: Set<String> = []
    var headings: Set<String> = []
    var from: Date?
    var to: Date?

    var isEmpty: Bool { self == LibraryFilter() }

    var searchesPassages: Bool { sources.isEmpty || sources.contains { $0.kind != nil } }
    var searchesFiles: Bool { sources.isEmpty || sources.contains(.files) }

    /// Filters that only a passage can satisfy. A search narrowed to one speaker or one
    /// meeting is a question about what was said, so the file leg sits it out rather than
    /// padding the answer with names that match the words by accident.
    var isPassageOnly: Bool {
        !sourceIDs.isEmpty || !speakers.isEmpty || !people.isEmpty || !headings.isEmpty
    }

    /// The SQL filter for the passage leg.
    func knowledgeFilter(aliases: [String: [String]] = [:]) -> KnowledgeFilter {
        var filter = KnowledgeFilter()
        filter.kinds = Set(sources.compactMap(\.kind))
        filter.sourceIDs = sourceIDs
        filter.speakers = speakers.union(people.flatMap { aliases[$0] ?? [$0] })
        filter.headings = headings
        filter.from = from
        filter.to = to
        return filter
    }
}

/// One row of results: a passage, or one of the user's own files.
enum LibraryHit: Identifiable, Equatable, Sendable {
    case passage(KnowledgeHit)
    case file(FileHit)

    var id: String {
        switch self {
        case .passage(let hit): "c\(hit.chunkID)"
        case .file(let hit): "f\(hit.path)"
        }
    }

    var isPassage: Bool {
        if case .passage = self { return true }
        return false
    }
}

/// Counts down the rail, for every source at once.
struct LibraryFacets: Equatable, Sendable {
    var knowledge = KnowledgeFacets()
    /// Matching files and folders. Nil when the user has not switched folder access on, so
    /// the row is absent rather than showing a hopeful zero.
    var files: Int?
    /// Resolved people, by display name, counting the passages under every name they go by.
    var people: [String: Int] = [:]

    func count(_ source: LibrarySource) -> Int? {
        switch source {
        case .passages(let kind): knowledge.kinds[kind]
        case .files: files
        }
    }
}

/// One retrieval engine for the whole library: the passages **and** the user's own folders.
///
/// The passage leg is `KnowledgeSearching` — FTS5 BM25, with cosine fused into it once an
/// embedding model is downloaded. The file leg is the FTS5 index over names and paths in
/// `file-index.sqlite`. Search, Ask and the agent's `search_knowledge` all come through
/// here, so a hit one of them can find is a hit all of them can find.
///
/// **Why file names are not embedded.** The vector set is loaded into memory whole and
/// compared by one `vDSP_mmul`; the user's 8,800 file rows would nearly double it, to buy
/// paraphrase matching over strings like `IMG_4821.HEIC` and `Screenshot 2026-09-20 at
/// 11.31.44 AM.png`, which have no paraphrase. What a file search actually needs is prefix
/// matching on the name and the path — someone typing `invo` means the invoice — and FTS5
/// does that in a few milliseconds over the whole tree. So the file leg is lexical, and it
/// is fused in by rank rather than by score, which is the same trick the hybrid passage
/// search already uses on its own two legs: nothing has to pretend a BM25 score and a file's
/// position are the same number.
struct LibrarySearch: Sendable {
    /// Reciprocal-rank fusion's constant, as in `HybridKnowledgeSearch`.
    static let rrfK = 60.0
    /// A file at rank *j* is ranked where a passage at rank *3j* would be, so roughly one
    /// result in four is a file when both legs match. Below parity on purpose: a name that
    /// contains a word is weaker evidence than a sentence that contains it, and there are
    /// nearly ten times as many file names as passages. A query only the files match still
    /// returns files alone — there is nothing for them to lose to.
    static let fileRankPenalty = 3.0

    let passages: any KnowledgeSearching
    let files: any FileRetrieving
    /// Person display name → every speaker label that turned out to be them.
    var aliases: [String: [String]] = [:]

    /// Whether the rail should offer a "Files and folders" row at all.
    var hasFiles: Bool { files.isAvailable }

    /// A query with whatever had to be awaited already done — embedding the words through a
    /// model actor. The file leg needs nothing awaited.
    struct Prepared: Sendable {
        var text: String
        var filter: LibraryFilter
        var limit: Int
        var passages: KnowledgeQuery
    }

    func prepare(text: String, filter: LibraryFilter, limit: Int = 50) async -> Prepared {
        var knowledge = KnowledgeQuery(text: text, filter: filter.knowledgeFilter(aliases: aliases), limit: limit)
        if filter.searchesPassages {
            knowledge = await passages.prepare(knowledge)
        }
        return Prepared(text: text, filter: filter, limit: limit, passages: knowledge)
    }

    /// Both legs, fused. Synchronous: it is SQL, and it runs off the main actor.
    func search(_ request: Prepared) throws -> [LibraryHit] {
        let found = request.filter.searchesPassages ? try passages.search(request.passages) : []
        return Self.fuse(passages: found, files: try fileHits(request), limit: request.limit)
    }

    func facets(_ request: Prepared) throws -> LibraryFacets {
        var facets = LibraryFacets()
        facets.knowledge = try passages.facets(request.passages)
        // Counted for the words alone, like every other row in the rail: the rail says what
        // is there to narrow to, not what the current selection has left.
        if files.isAvailable { facets.files = try files.count(query: request.text) }
        facets.people = Self.peopleCounts(speakers: facets.knowledge.speakers, aliases: aliases)
        return facets
    }

    /// The file leg, with the two reasons it stays quiet: a filter only a passage can
    /// satisfy, and a browse with nothing selected at all.
    private func fileHits(_ request: Prepared) throws -> [FileHit] {
        guard request.filter.searchesFiles, !request.filter.isPassageOnly, files.isAvailable else { return [] }
        let hasWords = !FileIndexStore.tokens(request.text).isEmpty
        // No words and no interest in files is the empty screen, not a dump of the disk.
        guard hasWords || request.filter.sources.contains(.files) || request.filter.from != nil else { return [] }
        return try files.find(query: request.text, category: nil, folder: nil,
                              modifiedAfter: request.filter.from, limit: request.limit)
    }

    /// Passages and files in one order, by rank rather than by score.
    static func fuse(passages: [KnowledgeHit], files: [FileHit], limit: Int) -> [LibraryHit] {
        let limit = max(0, limit)
        guard !files.isEmpty else { return passages.prefix(limit).map(LibraryHit.passage) }
        guard !passages.isEmpty else { return files.prefix(limit).map(LibraryHit.file) }
        var scored: [(hit: LibraryHit, score: Double, rank: Int)] = []
        scored.reserveCapacity(passages.count + files.count)
        for (rank, hit) in passages.enumerated() {
            scored.append((.passage(hit), 1 / (rrfK + Double(rank + 1)), rank))
        }
        for (rank, hit) in files.enumerated() {
            scored.append((.file(hit), 1 / (rrfK + Double(rank + 1) * fileRankPenalty), rank))
        }
        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            // A dead heat goes to the passage: it is the thing somebody actually said.
            if lhs.hit.isPassage != rhs.hit.isPassage { return lhs.hit.isPassage }
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            return lhs.hit.id < rhs.hit.id
        }
        return scored.prefix(limit).map(\.hit)
    }

    /// Speaker counts, gathered under the person each label turned out to be. A person whose
    /// names are not in this result at all is left out rather than shown as zero.
    static func peopleCounts(speakers: [String: Int], aliases: [String: [String]]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for (person, labels) in aliases {
            let total = labels.reduce(0) { $0 + (speakers[$1] ?? 0) }
            if total > 0 { counts[person] = total }
        }
        return counts
    }
}

/// Turns what someone typed into an FTS5 expression that cannot be a syntax error.
///
/// Every word is quoted, so `AND`, `NEAR`, `*`, `:` and unbalanced quotes are words rather
/// than operators; the porter tokenizer still stems inside the quotes.
enum KnowledgeFTSQuery {
    static let maxTokens = 16

    static func tokens(_ text: String) -> [String] {
        var seen: Set<String> = []
        return text.lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .map(String.init)
            .filter { seen.insert($0).inserted }
            .prefix(maxTokens)
            .map { $0 }
    }

    static func expression(_ tokens: [String], joiner: String) -> String {
        tokens.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }.joined(separator: joiner)
    }
}

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

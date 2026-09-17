import Accelerate
import Foundation

/// The vector set in memory, reloaded only when the store has been written since.
///
/// Brute force is the correct search at this size: 37,000 × 256 is one `vDSP_mmul` — about
/// ten million multiply-adds — and it is exact. ANN indexes earn their keep near a million
/// vectors; the upgrade then is `sqlite-vec` behind `KnowledgeSearching`, with no migration.
final class KnowledgeVectorIndex: @unchecked Sendable {
    private let lock = NSLock()
    private var cached: (mutation: UInt64, set: KnowledgeVectorSet)?

    init() {}

    func vectors(store: KnowledgeStore, model: String, dimensions: Int) throws -> KnowledgeVectorSet {
        let mutation = store.mutationCount
        lock.lock()
        if let cached, cached.mutation == mutation, cached.set.model == model, cached.set.dimensions == dimensions {
            lock.unlock()
            return cached.set
        }
        lock.unlock()
        let set = try store.vectorSet(model: model, dimensions: dimensions)
        lock.lock()
        cached = (mutation, set)
        lock.unlock()
        return set
    }

    /// Drops the matrix, for memory pressure or an embedder switch.
    func purge() {
        lock.lock()
        cached = nil
        lock.unlock()
    }

    /// The `k` best cosine scores above `minimum` (and above 0) among `allowed` (nil allows
    /// all). Vectors are unit length, so cosine is the dot product, and every dot product is
    /// one matrix-vector multiply. A passage at or below the floor is not a match: without
    /// it, a query that matches nothing would still return `k` unrelated passages.
    static func top(_ k: Int, query: [Float], in set: KnowledgeVectorSet, allowed: Set<Int64>?,
                    minimum: Float = 0) -> [(chunkID: Int64, score: Float)] {
        let rows = set.chunkIDs.count
        guard rows > 0, k > 0, query.count == set.dimensions else { return [] }
        var scores = [Float](repeating: 0, count: rows)
        // rows × dims times dims × 1 is rows × 1: M = rows, N = 1, P = dims.
        vDSP_mmul(set.matrix, 1, query, 1, &scores, 1, vDSP_Length(rows), 1, vDSP_Length(set.dimensions))
        var candidates: [(chunkID: Int64, score: Float)] = []
        candidates.reserveCapacity(allowed.map { min($0.count, rows) } ?? rows)
        let floor = max(0, minimum)
        for (index, id) in set.chunkIDs.enumerated() where scores[index] > floor && (allowed?.contains(id) ?? true) {
            candidates.append((id, scores[index]))
        }
        // Ties by chunk id, so a run is reproducible.
        candidates.sort { $0.score == $1.score ? $0.chunkID < $1.chunkID : $0.score > $1.score }
        return Array(candidates.prefix(k))
    }
}

/// Phase B: BM25 and cosine, fused.
///
/// Hybrid, always. Pure vectors underperform on names, codenames and jargon — most of
/// what meeting notes contain — and pure BM25 misses paraphrase, which is most of how people
/// ask. So:
///
/// 1. FTS5 BM25, top 50 (`KeywordKnowledgeSearch`, with its OR fallback).
/// 2. Cosine over the vector set, top 50 above the embedder's `minimumSimilarity`, with the
///    filters applied as SQL first.
/// 3. Reciprocal rank fusion, `k = 60`. Not score normalisation: BM25 and cosine are not
///    commensurable, and every attempt to make them so needs tuning per corpus.
/// 4. For conversation chunks only, a mild recency weight (30-day half-life, never below
///    0.8), relative to the newest conversation among the candidates — so it reorders
///    conversations among themselves rather than handing every conversation a penalty
///    against meetings. Transcripts and notes get none — an old decision is still a decision.
///    Two departures from the plan's wording: the weight is relative, not absolute age (the
///    newest conversation keeps 1 however old it is), and it exists only on this hybrid
///    path — with embedder `none`, `KeywordKnowledgeSearch` ranks conversations by BM25 alone.
///
/// `score` on a fused hit is the negated fused score, so lower is better everywhere.
/// Without a query vector (no embedder, a query not yet embedded, or no vectors written)
/// the result is BM25's, unchanged.
struct HybridKnowledgeSearch: KnowledgeSearching {
    static let candidates = 50
    static let rrfK: Double = 60
    static let conversationHalfLife: TimeInterval = 30 * 86_400
    static let recencyFloor: Double = 0.8

    let store: KnowledgeStore
    let embedder: (any KnowledgeEmbedder)?
    let vectors: KnowledgeVectorIndex
    var now: @Sendable () -> Date = { Date() }

    private var keyword: KeywordKnowledgeSearch { KeywordKnowledgeSearch(store: store) }

    /// The three rankings, for `--selftest-search`'s side-by-side columns.
    struct Rankings: Sendable {
        var bm25: [KnowledgeHit] = []
        var cosine: [(hit: KnowledgeHit, similarity: Float)] = []
        var fused: [KnowledgeHit] = []
        var usedVectors = false
    }

    func search(_ query: KnowledgeQuery) throws -> [KnowledgeHit] {
        try rankings(query).fused
    }

    func facets(_ query: KnowledgeQuery) throws -> KnowledgeFacets {
        // The rail counts passages that match the words. A passage only the vectors found has
        // no word to count it under, and a count that changed with the embedder would read
        // as the library changing.
        try keyword.facets(query)
    }

    func prepare(_ query: KnowledgeQuery) async -> KnowledgeQuery {
        guard query.vector == nil, let embedder, !KnowledgeFTSQuery.tokens(query.text).isEmpty else { return query }
        var prepared = query
        prepared.vector = try? await embedder.embed([query.text], purpose: .query).first
        // Off the caller's actor: load the matrix here and hand it to the synchronous search
        // that follows (on the main actor, for `memory.recall`), so a write in between cannot
        // make that search rebuild it from SQLite.
        if prepared.vector != nil {
            prepared.preparedVectors = (try? vectors.vectors(store: store, model: embedder.model,
                                                             dimensions: embedder.dimensions))
                .map(KnowledgePreparedVectors.init)
        }
        return prepared
    }

    func rankings(_ query: KnowledgeQuery) throws -> Rankings {
        let limit = max(1, query.limit)
        var rankings = Rankings()
        guard !KnowledgeFTSQuery.tokens(query.text).isEmpty else {
            // A browse by facet has no words to rank or embed.
            rankings.bm25 = try keyword.search(query)
            rankings.fused = rankings.bm25
            return rankings
        }
        var lexical = query
        lexical.limit = max(limit, Self.candidates)
        rankings.bm25 = try keyword.search(lexical)

        guard let embedder, let queryVector = try queryVector(query, embedder: embedder),
              queryVector.count == embedder.dimensions else {
            rankings.fused = Array(rankings.bm25.prefix(limit))
            return rankings
        }
        let set: KnowledgeVectorSet
        if let prepared = query.preparedVectors?.set, prepared.model == embedder.model,
           prepared.dimensions == embedder.dimensions {
            set = prepared
        } else {
            set = try vectors.vectors(store: store, model: embedder.model, dimensions: embedder.dimensions)
        }
        guard !set.chunkIDs.isEmpty else {
            rankings.fused = Array(rankings.bm25.prefix(limit))
            return rankings
        }
        let allowed = query.filter.isEmpty ? nil : try store.embeddedChunkIDs(model: embedder.model, filter: query.filter)
        let nearest = KnowledgeVectorIndex.top(Self.candidates, query: queryVector, in: set, allowed: allowed,
                                               minimum: embedder.minimumSimilarity)
        rankings.usedVectors = true

        // Hydrate what BM25 did not already return; `hits(ids:)` re-applies the filters.
        var byID = Dictionary(rankings.bm25.map { ($0.chunkID, $0) }, uniquingKeysWith: { first, _ in first })
        let missing = nearest.map(\.chunkID).filter { byID[$0] == nil }
        for hit in try keyword.hits(ids: missing, filter: query.filter) { byID[hit.chunkID] = hit }
        rankings.cosine = nearest.compactMap { entry in byID[entry.chunkID].map { ($0, entry.score) } }

        var fused: [Int64: Double] = [:]
        for (rank, hit) in rankings.bm25.prefix(Self.candidates).enumerated() {
            fused[hit.chunkID, default: 0] += 1 / (Self.rrfK + Double(rank + 1))
        }
        for (rank, entry) in rankings.cosine.enumerated() {
            fused[entry.hit.chunkID, default: 0] += 1 / (Self.rrfK + Double(rank + 1))
        }
        let current = now()
        // Relative to the newest conversation in the candidates: it keeps weight 1, older ones
        // are discounted against it, and nothing else is touched.
        let newestConversation = fused.keys.compactMap { byID[$0] }.filter { $0.kind == .conversation }
            .map { Self.recencyWeight(kind: .conversation, occurredAt: $0.occurredAt, now: current) }.max() ?? 1
        let ranked = fused.compactMap { id, score -> (KnowledgeHit, Double)? in
            guard let hit = byID[id] else { return nil }
            let weight = Self.recencyWeight(kind: hit.kind, occurredAt: hit.occurredAt, now: current)
            return (hit, score * (hit.kind == .conversation ? weight / newestConversation : weight))
        }
        .sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            if lhs.0.occurredAt != rhs.0.occurredAt { return lhs.0.occurredAt > rhs.0.occurredAt }
            return lhs.0.chunkID < rhs.0.chunkID
        }
        rankings.fused = ranked.prefix(limit).map { hit, score in hit.rescored(-score) }
        return rankings
    }

    /// 1 for everything but conversations; for a conversation, a 30-day half-life that
    /// never drops the weight below `recencyFloor`. Mild on purpose: it reorders near-ties,
    /// it does not bury an old answer that matches far better.
    static func recencyWeight(kind: KnowledgeSourceKind, occurredAt: Date, now: Date) -> Double {
        guard kind == .conversation else { return 1 }
        let age = max(0, now.timeIntervalSince(occurredAt))
        let decay = pow(0.5, age / conversationHalfLife)
        return recencyFloor + (1 - recencyFloor) * decay
    }

    private func queryVector(_ query: KnowledgeQuery, embedder: any KnowledgeEmbedder) throws -> [Float]? {
        if let vector = query.vector { return vector }
        guard let inline = embedder as? any SynchronousKnowledgeEmbedder else { return nil }
        // An embedder that cannot load (missing files) leaves the query on BM25 rather than
        // failing the search.
        return (try? inline.embedNow([query.text], purpose: .query))?.first
    }
}

extension KnowledgeHit {
    func rescored(_ score: Double) -> KnowledgeHit {
        KnowledgeHit(chunkID: chunkID, kind: kind, sourceID: sourceID, ordinal: ordinal, text: text, snippet: snippet,
                     startTime: startTime, endTime: endTime, speaker: speaker, heading: heading,
                     occurredAt: occurredAt, score: score)
    }
}

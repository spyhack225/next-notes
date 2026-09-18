import Foundation
import SQLite3

/// A chunk that has no vector from the current model yet.
struct KnowledgePendingEmbedding: Equatable, Sendable {
    let chunkID: Int64
    let text: String
}

/// Every vector from one model, as one contiguous row-major matrix for brute-force cosine.
struct KnowledgeVectorSet: Sendable {
    let model: String
    let dimensions: Int
    let chunkIDs: [Int64]
    /// `chunkIDs.count × dimensions` float32, each row L2-normalised.
    let matrix: [Float]

    static func empty(model: String, dimensions: Int) -> KnowledgeVectorSet {
        KnowledgeVectorSet(model: model, dimensions: dimensions, chunkIDs: [], matrix: [])
    }
}

/// The `embedding` table. Rows are keyed by chunk, so a chunk holds one vector at a time:
/// switching models replaces vectors as the backfill reaches them, and `deleteEmbeddings(
/// exceptModel:)` drops the old model's rest. `ON DELETE CASCADE` — live because every
/// connection sets `foreign_keys = ON` — removes a vector with its chunk.
extension KnowledgeStore {
    /// Newest first: the passages someone is most likely to search for get vectors first.
    func chunksNeedingEmbedding(model: String, limit: Int) throws -> [KnowledgePendingEmbedding] {
        try withConnection { db in
            let statement = try Self.prepare(db, """
                SELECT c.id, c.text FROM chunk c
                LEFT JOIN embedding e ON e.chunk_id = c.id AND e.model = ?1
                WHERE e.chunk_id IS NULL
                ORDER BY c.occurred_at DESC, c.id
                LIMIT ?2
                """)
            defer { sqlite3_finalize(statement) }
            Self.bind(statement, [.text(model), .int(Int64(max(1, limit)))])
            var result: [KnowledgePendingEmbedding] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                result.append(KnowledgePendingEmbedding(chunkID: sqlite3_column_int64(statement, 0),
                                                        text: Self.text(statement, 1) ?? ""))
            }
            return result
        }
    }

    /// Writes vectors in one transaction and returns how many landed. A chunk deleted while
    /// its vector was being computed is skipped rather than failing the batch on its foreign
    /// key. Vectors must already be `dimensions` long and unit length.
    @discardableResult
    func writeEmbeddings(_ rows: [(chunkID: Int64, vector: [Float])], model: String, dimensions: Int) throws -> Int {
        guard !rows.isEmpty else { return 0 }
        for row in rows where row.vector.count != dimensions {
            throw KnowledgeEmbeddingError.wrongDimensions(expected: dimensions, actual: row.vector.count)
        }
        return try withWritingConnection { db in
            try Self.transaction(db) {
                let insert = try Self.prepare(db, """
                    INSERT OR REPLACE INTO embedding (chunk_id, model, dims, vector)
                    SELECT ?1, ?2, ?3, ?4 WHERE EXISTS (SELECT 1 FROM chunk WHERE id = ?1)
                    """)
                defer { sqlite3_finalize(insert) }
                var written = 0
                for row in rows {
                    sqlite3_reset(insert)
                    sqlite3_clear_bindings(insert)
                    Self.bind(insert, [.int(row.chunkID), .text(model), .int(Int64(dimensions)),
                                       .blob(EmbeddingMath.blob(row.vector))])
                    guard sqlite3_step(insert) == SQLITE_DONE else { throw Self.error(db) }
                    written += Int(sqlite3_changes(db))
                }
                try Self.refreshEmbeddedFlags(db, model: model)
                return written
            }
        }
    }

    /// Drops vectors from every other model. Returns how many went.
    @discardableResult
    func deleteEmbeddings(exceptModel model: String) throws -> Int {
        // Every drain asks; almost always there is nothing to drop, and a write would make
        // search reload its vector matrix for no reason.
        let stale = try withConnection { db in
            try Self.optionalInt(db, "SELECT 1 FROM embedding WHERE model != ?1 LIMIT 1", [.text(model)]) != nil
        }
        guard stale else { return 0 }
        return try withWritingConnection { db in
            try Self.transaction(db) {
                try Self.run(db, "DELETE FROM embedding WHERE model != ?1", [.text(model)])
                let removed = Int(sqlite3_changes(db))
                try Self.refreshEmbeddedFlags(db, model: model)
                return removed
            }
        }
    }

    /// `index_state.embedded` is 1 exactly when every chunk of the source's current
    /// generation has a vector from `model`.
    private static func refreshEmbeddedFlags(_ db: OpaquePointer, model: String) throws {
        try run(db, """
            UPDATE index_state SET embedded = CASE WHEN EXISTS (
              SELECT 1 FROM chunk c LEFT JOIN embedding e ON e.chunk_id = c.id AND e.model = ?1
              WHERE c.source_kind = index_state.source_kind AND c.source_id = index_state.source_id
                AND c.generation = index_state.generation AND e.chunk_id IS NULL
            ) THEN 0 ELSE 1 END
            """, [.text(model)])
    }

    func embeddingCount(model: String? = nil) throws -> Int {
        try withConnection { db in
            if let model {
                return Int(try Self.optionalInt(db, "SELECT count(*) FROM embedding WHERE model = ?1", [.text(model)]) ?? 0)
            }
            return Int(try Self.int(db, "SELECT count(*) FROM embedding"))
        }
    }

    /// Sources whose current generation is fully embedded.
    func embeddedSourceCount() throws -> Int {
        try withConnection { db in Int(try Self.int(db, "SELECT count(*) FROM index_state WHERE embedded = 1")) }
    }

    /// Every vector `model` wrote, in chunk-id order.
    func vectorSet(model: String, dimensions: Int) throws -> KnowledgeVectorSet {
        try withConnection { db in
            let statement = try Self.prepare(
                db, "SELECT chunk_id, vector FROM embedding WHERE model = ?1 AND dims = ?2 ORDER BY chunk_id")
            defer { sqlite3_finalize(statement) }
            Self.bind(statement, [.text(model), .int(Int64(dimensions))])
            var ids: [Int64] = []
            var matrix: [Float] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                let bytes = Int(sqlite3_column_bytes(statement, 1))
                guard bytes == dimensions * 4, let raw = sqlite3_column_blob(statement, 1) else { continue }
                // One copy per row. The format is little-endian float32, which is this Mac's
                // native layout; the blob may not be aligned, so copy bytes, not floats.
                let start = matrix.count
                matrix.append(contentsOf: repeatElement(0, count: dimensions))
                matrix.withUnsafeMutableBytes { destination in
                    destination.baseAddress!.advanced(by: start * 4).copyMemory(from: raw, byteCount: bytes)
                }
                ids.append(sqlite3_column_int64(statement, 0))
            }
            return KnowledgeVectorSet(model: model, dimensions: dimensions, chunkIDs: ids, matrix: matrix)
        }
    }

    /// The stored vector for one chunk, for the self-test.
    func vector(chunkID: Int64) throws -> (model: String, vector: [Float])? {
        try withConnection { db in
            let statement = try Self.prepare(db, "SELECT model, dims, vector FROM embedding WHERE chunk_id = ?1")
            defer { sqlite3_finalize(statement) }
            Self.bind(statement, [.int(chunkID)])
            guard sqlite3_step(statement) == SQLITE_ROW, let model = Self.text(statement, 0) else { return nil }
            let dims = Int(sqlite3_column_int(statement, 1))
            let bytes = Int(sqlite3_column_bytes(statement, 2))
            guard let raw = sqlite3_column_blob(statement, 2) else { return nil }
            let data = Data(bytes: raw, count: bytes)
            return EmbeddingMath.vector(from: data, dimensions: dims).map { (model, $0) }
        }
    }

    /// Chunk ids that have a `model` vector and pass `filter`, as SQL — so a filter narrows
    /// the cosine leg before ranking, not after it.
    func embeddedChunkIDs(model: String, filter: KnowledgeFilter) throws -> Set<Int64> {
        var values: [SQLValue] = [.text(model)]
        let clause = KeywordKnowledgeSearch.whereClause(filter, values: &values)
        return try withConnection { db in
            let statement = try Self.prepare(db, """
                SELECT c.id FROM chunk c JOIN embedding e ON e.chunk_id = c.id
                WHERE e.model = ?1\(clause)
                """)
            defer { sqlite3_finalize(statement) }
            Self.bind(statement, values)
            var ids: Set<Int64> = []
            while sqlite3_step(statement) == SQLITE_ROW { ids.insert(sqlite3_column_int64(statement, 0)) }
            return ids
        }
    }
}

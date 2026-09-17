import Foundation
import SQLite3

// Part 4, Phase C: nodes, bi-temporal edges and traversal, in `knowledge.sqlite`.
//
// The graph is derived like everything else in the index: from `notes.json` (which is from
// `notes.md`), `meeting.json` and the chunk table. `rm knowledge.sqlite` loses nothing a
// backfill cannot rebuild from the meeting folders without calling a model.

extension KnowledgeStore {
    /// Additive, so it is safe on every connection. Edges reference their source chunk with
    /// `ON DELETE CASCADE`: a regenerated `notes.md` replaces its chunks, and an edge that
    /// cited the old text goes with it rather than citing a passage that no longer exists.
    static let graphSchema = """
        CREATE TABLE IF NOT EXISTS graph_node (
          id           TEXT PRIMARY KEY,     -- 'person:ana', 'decision:<meeting>:<ordinal>'
          type         TEXT NOT NULL,        -- an ontology node type
          label        TEXT NOT NULL,
          fields       TEXT NOT NULL,        -- JSON object of ontology fields
          meeting_id   TEXT,                 -- owning meeting; NULL for shared nodes
          source_chunk INTEGER REFERENCES chunk(id) ON DELETE SET NULL,
          observed_at  INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS graph_node_meeting ON graph_node(meeting_id);
        CREATE INDEX IF NOT EXISTS graph_node_type ON graph_node(type);
        CREATE INDEX IF NOT EXISTS graph_node_chunk ON graph_node(source_chunk);

        CREATE TABLE IF NOT EXISTS graph_edge (
          id           INTEGER PRIMARY KEY,
          type         TEXT NOT NULL,
          from_node    TEXT NOT NULL REFERENCES graph_node(id) ON DELETE CASCADE,
          to_node      TEXT NOT NULL REFERENCES graph_node(id) ON DELETE CASCADE,
          meeting_id   TEXT NOT NULL,
          observed_at  INTEGER NOT NULL,     -- when the meeting that stated this happened
          valid_from   INTEGER,              -- when the fact became true
          valid_to     INTEGER,              -- when it stopped being true; NULL = still true
          source_chunk INTEGER NOT NULL REFERENCES chunk(id) ON DELETE CASCADE,
          UNIQUE (type, from_node, to_node)
        );
        CREATE INDEX IF NOT EXISTS graph_edge_from ON graph_edge(from_node);
        CREATE INDEX IF NOT EXISTS graph_edge_to ON graph_edge(to_node);
        CREATE INDEX IF NOT EXISTS graph_edge_meeting ON graph_edge(meeting_id);
        -- Foreign keys: without these, every chunk DELETE scans both graph tables.
        CREATE INDEX IF NOT EXISTS graph_edge_chunk ON graph_edge(source_chunk);

        CREATE TABLE IF NOT EXISTS graph_state (
          meeting_id   TEXT PRIMARY KEY,
          fingerprint  INTEGER NOT NULL,
          nodes        INTEGER NOT NULL,
          edges        INTEGER NOT NULL,
          extracted_at INTEGER NOT NULL
        );
        """
}

/// One decision in a thread, oldest first.
struct DecisionThreadRow: Identifiable, Equatable, Sendable {
    var id: String
    var text: String
    var saidBy: String?
    var meetingID: String
    var meetingTitle: String
    var observedAt: Date
    /// Set when a later decision on the same subject superseded this one.
    var validTo: Date?
    var sourceChunk: Int64

    var isCurrent: Bool { validTo == nil }
}

/// One decision followed across meetings, including the day it was reversed.
struct DecisionThread: Identifiable, Equatable, Sendable {
    var id: String
    var subject: String
    var rows: [DecisionThreadRow]

    var latest: Date { rows.map(\.observedAt).max() ?? .distantPast }
    var wasReversed: Bool { rows.contains { !$0.isCurrent } }
}

/// An extracted action item, with the meeting it came from.
struct GraphActionItem: Identifiable, Equatable, Sendable {
    var id: String
    var text: String
    var owner: String?
    /// `YYYY-MM-DD`.
    var due: String?
    var meetingID: String
    var meetingTitle: String
    var observedAt: Date
    var sourceChunk: Int64
}

/// Nodes, bi-temporal edges and traversal over `knowledge.sqlite`.
///
/// - **One meeting, one transaction.** `replaceMeeting` removes what the meeting contributed
///   before and inserts what it contributes now, so a traversal never sees half of a
///   re-extraction, and a failed write leaves the previous graph whole.
/// - **Idempotent.** A fingerprint of the batch is kept per meeting; the same batch again
///   writes nothing.
/// - **Bi-temporal.** `decided_in` edges carry `valid_from` and `valid_to`. After every write
///   the decision threads are recomputed from the rows: a decision marked `supersedes` closes
///   every still-valid decision on the same subject observed before it, and a `supersedes`
///   edge links it to the one it replaced. Recomputed rather than patched, so the result
///   does not depend on the order meetings were extracted in.
struct GraphStore: KnowledgeGraphReading {
    let store: KnowledgeStore

    enum ReplaceOutcome: Equatable, Sendable {
        case unchanged
        case replaced(nodes: Int, edges: Int)
    }

    // MARK: - Writes

    @discardableResult
    func replaceMeeting(_ batch: GraphBatch, now: Date = Date()) throws -> ReplaceOutcome {
        let fingerprint = Self.fingerprint(batch)
        let ownedCount = batch.nodes.filter { $0.meetingID != nil }.count
        return try store.withWritingConnection { db in
            try KnowledgeStore.transaction(db) {
                let meeting = KnowledgeStore.SQLValue.text(batch.meetingID)
                let stored = try Self.stateRow(db, meetingID: batch.meetingID)
                if let stored, stored.fingerprint == fingerprint,
                   try KnowledgeStore.optionalInt(db, """
                       SELECT count(*) FROM graph_edge WHERE meeting_id = ?1 AND type != 'supersedes'
                       """, [meeting]) == Int64(stored.edges),
                   try KnowledgeStore.optionalInt(db, "SELECT count(*) FROM graph_node WHERE meeting_id = ?1",
                                                  [meeting]) == Int64(stored.nodes) {
                    return .unchanged
                }
                try Self.removeMeeting(db, meetingID: batch.meetingID)

                let insertNode = try KnowledgeStore.prepare(db, """
                    INSERT INTO graph_node (id, type, label, fields, meeting_id, source_chunk, observed_at)
                    VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
                    ON CONFLICT (id) DO UPDATE SET
                      source_chunk = COALESCE(graph_node.source_chunk, excluded.source_chunk),
                      observed_at = MIN(graph_node.observed_at, excluded.observed_at)
                    """)
                defer { sqlite3_finalize(insertNode) }
                for node in batch.nodes {
                    sqlite3_reset(insertNode)
                    sqlite3_clear_bindings(insertNode)
                    KnowledgeStore.bind(insertNode, [
                        .text(node.id), .text(node.type), .text(node.label), .text(Self.encode(node.fields)),
                        .optionalText(node.meetingID), node.sourceChunk.map { .int($0) } ?? .optionalText(nil),
                        .int(node.observedAt),
                    ])
                    guard sqlite3_step(insertNode) == SQLITE_DONE else { throw KnowledgeStore.error(db) }
                }

                let insertEdge = try KnowledgeStore.prepare(db, """
                    INSERT OR IGNORE INTO graph_edge
                      (type, from_node, to_node, meeting_id, observed_at, valid_from, valid_to, source_chunk)
                    VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
                    """)
                defer { sqlite3_finalize(insertEdge) }
                var edges = 0
                for edge in batch.edges {
                    sqlite3_reset(insertEdge)
                    sqlite3_clear_bindings(insertEdge)
                    KnowledgeStore.bind(insertEdge, [
                        .text(edge.type), .text(edge.from), .text(edge.to), .text(edge.meetingID), .int(edge.observedAt),
                        edge.validFrom.map { .int($0) } ?? .optionalText(nil),
                        edge.validTo.map { .int($0) } ?? .optionalText(nil),
                        .int(edge.sourceChunk),
                    ])
                    guard sqlite3_step(insertEdge) == SQLITE_DONE else { throw KnowledgeStore.error(db) }
                    edges += Int(sqlite3_changes(db))
                }
                try Self.pruneSharedNodes(db)
                try Self.recomputeTemporal(db)
                try KnowledgeStore.run(db, """
                    INSERT INTO graph_state (meeting_id, fingerprint, nodes, edges, extracted_at)
                    VALUES (?1, ?2, ?3, ?4, ?5)
                    ON CONFLICT (meeting_id) DO UPDATE SET fingerprint = excluded.fingerprint,
                      nodes = excluded.nodes, edges = excluded.edges, extracted_at = excluded.extracted_at
                    """, [meeting, .int(fingerprint), .int(Int64(ownedCount)), .int(Int64(edges)),
                          .int(Int64(now.timeIntervalSince1970))])
                return .replaced(nodes: batch.nodes.count, edges: edges)
            }
        }
    }

    /// Everything a meeting contributed. Shared nodes no other meeting uses go too.
    func deleteMeeting(_ meetingID: String) throws {
        guard store.existsOnDisk else { return }
        try store.withWritingConnection { db in
            try KnowledgeStore.transaction(db) {
                // The index calls this for every meeting without a current `notes.json`; one
                // that never had a graph costs a lookup, not a recompute of every thread.
                let owned = try KnowledgeStore.optionalInt(db, """
                    SELECT (SELECT count(*) FROM graph_node WHERE meeting_id = ?1)
                         + (SELECT count(*) FROM graph_edge WHERE meeting_id = ?1)
                         + (SELECT count(*) FROM graph_state WHERE meeting_id = ?1)
                    """, [.text(meetingID)]) ?? 0
                guard owned > 0 else { return }
                try Self.removeMeeting(db, meetingID: meetingID)
                try KnowledgeStore.run(db, "DELETE FROM graph_state WHERE meeting_id = ?1", [.text(meetingID)])
                try Self.pruneSharedNodes(db)
                try Self.recomputeTemporal(db)
            }
        }
    }

    /// The whole graph, when the switch is turned off.
    func deleteAll() throws {
        try store.withWritingConnection { db in
            try KnowledgeStore.transaction(db) {
                try KnowledgeStore.exec(db, "DELETE FROM graph_edge; DELETE FROM graph_node; DELETE FROM graph_state;")
            }
        }
    }

    /// Meeting ids that have a graph.
    func extractedMeetings() throws -> Set<String> {
        try store.withConnection { db in
            let statement = try KnowledgeStore.prepare(db, "SELECT meeting_id FROM graph_state")
            defer { sqlite3_finalize(statement) }
            var result: Set<String> = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let id = KnowledgeStore.text(statement, 0) { result.insert(id) }
            }
            return result
        }
    }

    private static func removeMeeting(_ db: OpaquePointer, meetingID: String) throws {
        try KnowledgeStore.run(db, "DELETE FROM graph_edge WHERE meeting_id = ?1", [.text(meetingID)])
        try KnowledgeStore.run(db, "DELETE FROM graph_node WHERE meeting_id = ?1", [.text(meetingID)])
    }

    private static func pruneSharedNodes(_ db: OpaquePointer) throws {
        try KnowledgeStore.exec(db, """
            DELETE FROM graph_node WHERE meeting_id IS NULL
              AND id NOT IN (SELECT from_node FROM graph_edge UNION SELECT to_node FROM graph_edge)
            """)
    }

    private static func stateRow(_ db: OpaquePointer, meetingID: String) throws
        -> (fingerprint: Int64, nodes: Int, edges: Int)? {
        let statement = try KnowledgeStore.prepare(db, "SELECT fingerprint, nodes, edges FROM graph_state WHERE meeting_id = ?1")
        defer { sqlite3_finalize(statement) }
        KnowledgeStore.bind(statement, [.text(meetingID)])
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return (sqlite3_column_int64(statement, 0), Int(sqlite3_column_int(statement, 1)),
                Int(sqlite3_column_int(statement, 2)))
    }

    // MARK: - Bi-temporal decisions

    /// A decision's subject, reduced so "Pricing page launch" and "pricing-page launch" are
    /// one thread.
    static func subjectKey(_ subject: String) -> String {
        subject.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
    }

    private static func recomputeTemporal(_ db: OpaquePointer) throws {
        try KnowledgeStore.exec(db, "DELETE FROM graph_edge WHERE type = 'supersedes'")
        try KnowledgeStore.exec(db, "UPDATE graph_edge SET valid_to = NULL WHERE type = 'decided_in' AND valid_to IS NOT NULL")

        struct Row {
            var node: String
            var subject: String
            var supersedes: Bool
            var observedAt: Int64
            var chunk: Int64
            var meetingID: String
            var edgeID: Int64
        }
        let statement = try KnowledgeStore.prepare(db, """
            SELECT n.id, n.fields, e.observed_at, e.source_chunk, e.meeting_id, e.id
            FROM graph_node n JOIN graph_edge e ON e.from_node = n.id AND e.type = 'decided_in'
            WHERE n.type = 'Decision'
            ORDER BY e.observed_at, n.id
            """)
        var rows: [Row] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let node = KnowledgeStore.text(statement, 0), let meetingID = KnowledgeStore.text(statement, 4)
            else { continue }
            let fields = decode(KnowledgeStore.text(statement, 1))
            rows.append(Row(node: node, subject: subjectKey(fields["subject"]?.string ?? ""),
                            supersedes: fields["supersedes"]?.bool ?? false,
                            observedAt: sqlite3_column_int64(statement, 2), chunk: sqlite3_column_int64(statement, 3),
                            meetingID: meetingID, edgeID: sqlite3_column_int64(statement, 5)))
        }
        sqlite3_finalize(statement)

        for group in Dictionary(grouping: rows, by: \.subject).values {
            var open: [Row] = []
            for row in group {
                // Two decisions from the same meeting are simultaneous: neither reverses the other.
                let earlier = open.filter { $0.observedAt < row.observedAt }
                if row.supersedes, let previous = earlier.last {
                    for closed in earlier {
                        try KnowledgeStore.run(db, "UPDATE graph_edge SET valid_to = ?1 WHERE id = ?2",
                                               [.int(row.observedAt), .int(closed.edgeID)])
                    }
                    try KnowledgeStore.run(db, """
                        INSERT OR IGNORE INTO graph_edge
                          (type, from_node, to_node, meeting_id, observed_at, valid_from, valid_to, source_chunk)
                        VALUES ('supersedes', ?1, ?2, ?3, ?4, ?4, NULL, ?5)
                        """, [.text(row.node), .text(previous.node), .text(row.meetingID), .int(row.observedAt),
                              .int(row.chunk)])
                    open.removeAll { $0.observedAt < row.observedAt }
                }
                open.append(row)
            }
        }
    }

    // MARK: - Reads

    /// True once any meeting has been extracted.
    var isAvailable: Bool {
        guard store.existsOnDisk else { return false }
        return ((try? store.withConnection { db in try KnowledgeStore.int(db, "SELECT count(*) FROM graph_node") }) ?? 0) > 0
    }

    func nodeCounts() throws -> [String: Int] {
        try store.withConnection { db in
            let statement = try KnowledgeStore.prepare(db, "SELECT type, count(*) FROM graph_node GROUP BY type")
            defer { sqlite3_finalize(statement) }
            var result: [String: Int] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                if let type = KnowledgeStore.text(statement, 0) { result[type] = Int(sqlite3_column_int(statement, 1)) }
            }
            return result
        }
    }

    func edgeCounts() throws -> [String: Int] {
        try store.withConnection { db in
            let statement = try KnowledgeStore.prepare(db, "SELECT type, count(*) FROM graph_edge GROUP BY type")
            defer { sqlite3_finalize(statement) }
            var result: [String: Int] = [:]
            while sqlite3_step(statement) == SQLITE_ROW {
                if let type = KnowledgeStore.text(statement, 0) { result[type] = Int(sqlite3_column_int(statement, 1)) }
            }
            return result
        }
    }

    /// Edges whose source chunk is missing from the chunk table, or whose endpoints are
    /// missing. Always zero while foreign keys are on; the self-test checks that it is.
    func danglingEdges() throws -> Int {
        try store.withConnection { db in
            Int(try KnowledgeStore.int(db, """
                SELECT count(*) FROM graph_edge e
                WHERE NOT EXISTS (SELECT 1 FROM chunk c WHERE c.id = e.source_chunk)
                   OR NOT EXISTS (SELECT 1 FROM graph_node n WHERE n.id = e.from_node)
                   OR NOT EXISTS (SELECT 1 FROM graph_node n WHERE n.id = e.to_node)
                """))
        }
    }

    /// Every row in a stable, id-free form, with chunk ids resolved to `kind:source:ordinal`
    /// — so two graphs built into different files, or in a different order, compare equal
    /// when they say the same thing. Shared nodes' first-seen chunk is left out: it depends
    /// on which meeting was extracted first.
    func canonicalDump() throws -> [String] {
        try store.withConnection { db in
            var lines: [String] = []
            let nodes = try KnowledgeStore.prepare(db, """
                SELECT n.id, n.type, n.label, n.fields, n.meeting_id, n.observed_at,
                       c.source_kind || ':' || c.source_id || ':' || c.ordinal
                FROM graph_node n LEFT JOIN chunk c ON c.id = n.source_chunk
                """)
            while sqlite3_step(nodes) == SQLITE_ROW {
                let meeting = KnowledgeStore.text(nodes, 4)
                let chunk = meeting == nil ? "-" : (KnowledgeStore.text(nodes, 6) ?? "-")
                lines.append(["node", KnowledgeStore.text(nodes, 0) ?? "", KnowledgeStore.text(nodes, 1) ?? "",
                              KnowledgeStore.text(nodes, 2) ?? "", KnowledgeStore.text(nodes, 3) ?? "",
                              meeting ?? "-", String(sqlite3_column_int64(nodes, 5)), chunk].joined(separator: "|"))
            }
            sqlite3_finalize(nodes)
            let edges = try KnowledgeStore.prepare(db, """
                SELECT e.type, e.from_node, e.to_node, e.meeting_id, e.observed_at, e.valid_from, e.valid_to,
                       c.source_kind || ':' || c.source_id || ':' || c.ordinal
                FROM graph_edge e LEFT JOIN chunk c ON c.id = e.source_chunk
                """)
            while sqlite3_step(edges) == SQLITE_ROW {
                func optional(_ column: Int32) -> String {
                    sqlite3_column_type(edges, column) == SQLITE_NULL ? "-" : String(sqlite3_column_int64(edges, column))
                }
                lines.append(["edge", KnowledgeStore.text(edges, 0) ?? "", KnowledgeStore.text(edges, 1) ?? "",
                              KnowledgeStore.text(edges, 2) ?? "", KnowledgeStore.text(edges, 3) ?? "",
                              String(sqlite3_column_int64(edges, 4)), optional(5), optional(6),
                              KnowledgeStore.text(edges, 7) ?? "missing"].joined(separator: "|"))
            }
            sqlite3_finalize(edges)
            return lines.sorted()
        }
    }

    /// Every decision, grouped by subject, each thread oldest first; threads with the most
    /// recent activity first.
    func decisionThreads() throws -> [DecisionThread] {
        guard store.existsOnDisk else { return [] }
        let rows: [(subject: String, row: DecisionThreadRow)] = try store.withConnection { db in
            let statement = try KnowledgeStore.prepare(db, """
                SELECT n.id, n.fields, e.meeting_id, m.label, e.observed_at, e.valid_to, e.source_chunk
                FROM graph_node n
                JOIN graph_edge e ON e.from_node = n.id AND e.type = 'decided_in'
                JOIN graph_node m ON m.id = e.to_node
                WHERE n.type = 'Decision'
                ORDER BY e.observed_at, n.id
                """)
            defer { sqlite3_finalize(statement) }
            var result: [(String, DecisionThreadRow)] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let id = KnowledgeStore.text(statement, 0) else { continue }
                let fields = Self.decode(KnowledgeStore.text(statement, 1))
                let validTo = sqlite3_column_type(statement, 5) == SQLITE_NULL
                    ? nil : Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 5)))
                result.append((fields["subject"]?.string ?? "", DecisionThreadRow(
                    id: id, text: fields["text"]?.string ?? "", saidBy: fields["said_by"]?.string,
                    meetingID: KnowledgeStore.text(statement, 2) ?? "", meetingTitle: KnowledgeStore.text(statement, 3) ?? "",
                    observedAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 4))),
                    validTo: validTo, sourceChunk: sqlite3_column_int64(statement, 6))))
            }
            return result
        }
        var threads: [String: DecisionThread] = [:]
        for (subject, row) in rows {
            let key = Self.subjectKey(subject)
            threads[key, default: DecisionThread(id: key, subject: subject, rows: [])].rows.append(row)
            // The newest wording names the thread.
            threads[key]?.subject = subject
        }
        return threads.values.sorted { $0.latest != $1.latest ? $0.latest > $1.latest : $0.id < $1.id }
    }

    /// Every action item, newest meeting first.
    func actionItems() throws -> [GraphActionItem] {
        guard store.existsOnDisk else { return [] }
        return try store.withConnection { db in
            let statement = try KnowledgeStore.prepare(db, """
                SELECT n.id, n.fields, e.meeting_id, m.label, e.observed_at, e.source_chunk
                FROM graph_node n
                JOIN graph_edge e ON e.from_node = n.id AND e.type = 'assigned_in'
                JOIN graph_node m ON m.id = e.to_node
                WHERE n.type = 'ActionItem'
                ORDER BY e.observed_at DESC, n.id
                """)
            defer { sqlite3_finalize(statement) }
            var result: [GraphActionItem] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let id = KnowledgeStore.text(statement, 0) else { continue }
                let fields = Self.decode(KnowledgeStore.text(statement, 1))
                result.append(GraphActionItem(
                    id: id, text: fields["text"]?.string ?? "", owner: fields["owner"]?.string, due: fields["due"]?.string,
                    meetingID: KnowledgeStore.text(statement, 2) ?? "", meetingTitle: KnowledgeStore.text(statement, 3) ?? "",
                    observedAt: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 4))),
                    sourceChunk: sqlite3_column_int64(statement, 5)))
            }
            return result
        }
    }

    // MARK: KnowledgeGraphReading

    func expand(nodeID: String, edgeTypes: Set<String>, depth: Int) throws -> KnowledgeGraphExpansion {
        try store.withConnection { db in
            guard let start = try Self.resolve(db, nodeID) else { return KnowledgeGraphExpansion() }
            var seenNodes: [String: KnowledgeGraphNode] = [:]
            var seenEdges: [Int64: KnowledgeGraphEdge] = [:]
            if let node = try Self.node(db, start) { seenNodes[start] = node }
            var frontier: [String] = [start]
            for _ in 0..<min(3, max(1, depth)) {
                var next: [String] = []
                for id in frontier {
                    let statement = try KnowledgeStore.prepare(db, """
                        SELECT id, type, from_node, to_node, observed_at, valid_from, valid_to, source_chunk
                        FROM graph_edge WHERE from_node = ?1 OR to_node = ?1
                        ORDER BY observed_at DESC, id
                        """)
                    KnowledgeStore.bind(statement, [.text(id)])
                    while sqlite3_step(statement) == SQLITE_ROW {
                        let rowID = sqlite3_column_int64(statement, 0)
                        guard let type = KnowledgeStore.text(statement, 1), edgeTypes.isEmpty || edgeTypes.contains(type),
                              let from = KnowledgeStore.text(statement, 2), let to = KnowledgeStore.text(statement, 3),
                              seenEdges[rowID] == nil else { continue }
                        seenEdges[rowID] = Self.edge(statement, type: type, from: from, to: to)
                        let other = from == id ? to : from
                        if seenNodes[other] == nil, let node = try Self.node(db, other) {
                            seenNodes[other] = node
                            next.append(other)
                        }
                    }
                    sqlite3_finalize(statement)
                }
                frontier = next
                if frontier.isEmpty { break }
            }
            return KnowledgeGraphExpansion(
                nodes: seenNodes.values.sorted { $0.id < $1.id },
                edges: seenEdges.sorted { $0.key < $1.key }.map(\.value))
        }
    }

    func timeline(entityID: String, from: Date?, to: Date?) throws -> [KnowledgeTimelineEntry] {
        try store.withConnection { db in
            guard let entity = try Self.resolve(db, entityID) else { return [] }
            var values: [KnowledgeStore.SQLValue] = [.text(entity)]
            var sql = """
                SELECT e.type, e.from_node, e.to_node, e.observed_at, e.source_chunk
                FROM graph_edge e WHERE (e.from_node = ?1 OR e.to_node = ?1)
                """
            if let from {
                values.append(.int(Int64(from.timeIntervalSince1970)))
                sql += " AND e.observed_at >= ?\(values.count)"
            }
            if let to {
                values.append(.int(Int64(to.timeIntervalSince1970)))
                sql += " AND e.observed_at <= ?\(values.count)"
            }
            sql += " ORDER BY e.observed_at DESC, e.id"
            let statement = try KnowledgeStore.prepare(db, sql)
            defer { sqlite3_finalize(statement) }
            KnowledgeStore.bind(statement, values)
            var entries: [KnowledgeTimelineEntry] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let type = KnowledgeStore.text(statement, 0), let fromNode = KnowledgeStore.text(statement, 1),
                      let toNode = KnowledgeStore.text(statement, 2) else { continue }
                let other = fromNode == entity ? toNode : fromNode
                let label = try Self.node(db, other)?.label ?? other
                entries.append(KnowledgeTimelineEntry(
                    at: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 3))),
                    nodeID: other, label: "\(type): \(label)", sourceChunk: sqlite3_column_int64(statement, 4)))
            }
            return entries
        }
    }

    /// An id as given, or a person or topic named by it — what a model is likely to pass.
    private static func resolve(_ db: OpaquePointer, _ raw: String) throws -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for candidate in [trimmed, "person:" + GraphIDs.slug(trimmed), "topic:" + GraphIDs.slug(trimmed)] {
            if try KnowledgeStore.optionalInt(db, "SELECT 1 FROM graph_node WHERE id = ?1", [.text(candidate)]) != nil {
                return candidate
            }
        }
        let statement = try KnowledgeStore.prepare(db, "SELECT id FROM graph_node WHERE label = ?1 COLLATE NOCASE ORDER BY id LIMIT 1")
        defer { sqlite3_finalize(statement) }
        KnowledgeStore.bind(statement, [.text(trimmed)])
        return sqlite3_step(statement) == SQLITE_ROW ? KnowledgeStore.text(statement, 0) : nil
    }

    private static func node(_ db: OpaquePointer, _ id: String) throws -> KnowledgeGraphNode? {
        let statement = try KnowledgeStore.prepare(db, "SELECT type, label, source_chunk FROM graph_node WHERE id = ?1")
        defer { sqlite3_finalize(statement) }
        KnowledgeStore.bind(statement, [.text(id)])
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return KnowledgeGraphNode(
            id: id, type: KnowledgeStore.text(statement, 0) ?? "", label: KnowledgeStore.text(statement, 1) ?? "",
            sourceChunk: sqlite3_column_type(statement, 2) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 2))
    }

    private static func edge(_ statement: OpaquePointer, type: String, from: String, to: String) -> KnowledgeGraphEdge {
        func date(_ column: Int32) -> Date? {
            sqlite3_column_type(statement, column) == SQLITE_NULL
                ? nil : Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, column)))
        }
        return KnowledgeGraphEdge(
            from: from, to: to, type: type,
            observedAt: date(4) ?? Date(timeIntervalSince1970: 0), validFrom: date(5), validTo: date(6),
            sourceChunk: sqlite3_column_int64(statement, 7))
    }

    // MARK: - Encoding

    static func encode(_ fields: [String: GraphFieldValue]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(fields), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    static func decode(_ text: String?) -> [String: GraphFieldValue] {
        guard let data = text?.data(using: .utf8),
              let fields = try? JSONDecoder().decode([String: GraphFieldValue].self, from: data) else { return [:] }
        return fields
    }

    /// FNV-1a over the batch's rows in a stable order.
    static func fingerprint(_ batch: GraphBatch) -> Int64 {
        var lines = batch.nodes.map { node in
            ["n", node.id, node.type, encode(node.fields), node.meetingID ?? "-",
             node.sourceChunk.map(String.init) ?? "-", String(node.observedAt)].joined(separator: "|")
        }
        lines += batch.edges.map { edge in
            ["e", edge.type, edge.from, edge.to, edge.meetingID, String(edge.observedAt),
             edge.validFrom.map(String.init) ?? "-", edge.validTo.map(String.init) ?? "-",
             String(edge.sourceChunk)].joined(separator: "|")
        }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for line in lines.sorted() {
            for byte in line.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
            hash ^= 0x0a
            hash = hash &* 0x0000_0100_0000_01b3
        }
        let folded = Int64(bitPattern: hash & 0x7fff_ffff_ffff_ffff)
        return folded == 0 ? 1 : folded
    }
}

/// How node ids are made. Code names nodes, never the model.
enum GraphIDs {
    static func meeting(_ id: String) -> String { "meeting:\(id)" }
    static func person(_ name: String) -> String { "person:\(slug(name))" }
    static func topic(_ label: String) -> String { "topic:\(slug(label))" }
    static func owned(_ type: String, meetingID: String, ordinal: Int) -> String {
        "\(type.lowercased()):\(meetingID):\(ordinal)"
    }

    static func slug(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "@" && $0 != "." })
            .joined(separator: "-")
    }
}

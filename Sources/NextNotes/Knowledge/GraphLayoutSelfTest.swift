import CoreGraphics
import Foundation
import SQLite3

/// `--selftest-graph-layout`: Part 4, Phase F/G — ForceLayout stays in-bounds, and
/// `personMeetings` / one-hop expand agree on a tiny fixture graph. No model, no grants.
enum GraphLayoutSelfTest {
    @MainActor
    static func run() async -> Bool {
        var failures: [String] = []
        func check(_ name: String, _ ok: Bool) {
            if !ok { failures.append(name) }
        }

        // MARK: ForceLayout — pure geometry

        let ids = (0..<12).map { "n\($0)" }
        let edges = (0..<11).map { (ids[$0], ids[$0 + 1]) } + [("n0", "n5"), ("n3", "n9")]
        let size = CGSize(width: 640, height: 420)
        let layout = ForceLayout(ids: ids, edges: edges, size: size)
        check("layout placed every node", layout.placements.count == ids.count)
        let inset = DS.Size.graphCanvasInset
        for id in ids {
            guard let point = layout.placements[id] else {
                check("missing placement for \(id)", false)
                continue
            }
            check("\(id) left of inset", point.x >= inset - 0.5)
            check("\(id) right of inset", point.x <= size.width - inset + 0.5)
            check("\(id) above inset", point.y >= inset - 0.5)
            check("\(id) below inset", point.y <= size.height - inset + 0.5)
        }
        let again = ForceLayout(ids: ids, edges: edges, size: size)
        check("layout is not stable for the same seeds", again.placements == layout.placements)

        let empty = ForceLayout(ids: [], edges: [], size: size)
        check("empty graph produced placements", empty.placements.isEmpty)

        let hugeIDs = (0..<420).map { "h\($0)" }
        let hugeEdges = (0..<419).map { (hugeIDs[$0], hugeIDs[$0 + 1]) }
        let huge = ForceLayout(ids: hugeIDs, edges: hugeEdges, size: CGSize(width: 900, height: 700))
        check("large layout did not place every node", huge.placements.count == hugeIDs.count)
        check("large layout left the frame",
              huge.placements.values.allSatisfy {
                  $0.x >= inset - 0.5 && $0.x <= 900 - inset + 0.5
                      && $0.y >= inset - 0.5 && $0.y <= 700 - inset + 0.5
              })

        // MARK: personMeetings + expand on a scratch store

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NextNotesSelfTest-graph-\(ProcessInfo.processInfo.processIdentifier)",
                                    isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            let store = KnowledgeStore(directory: root)
            let graph = GraphStore(store: store)
            let meetingA = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
            let meetingB = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
            let t0: Int64 = 1_700_000_000
            let t1: Int64 = 1_700_086_400

            _ = try store.replace(
                kind: .notes, sourceID: meetingA,
                chunks: [KnowledgeChunk(ordinal: 0, text: "Pricing notes.", occurredAt: t0)])
            _ = try store.replace(
                kind: .notes, sourceID: meetingB,
                chunks: [KnowledgeChunk(ordinal: 0, text: "Launch notes.", occurredAt: t1)])

            func chunkID(for meeting: String) throws -> Int64 {
                try store.withConnection { db in
                    let statement = try KnowledgeStore.prepare(
                        db, "SELECT id FROM chunk WHERE source_id = ?1 ORDER BY id LIMIT 1")
                    defer { sqlite3_finalize(statement) }
                    KnowledgeStore.bind(statement, [.text(meeting)])
                    guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
                    return sqlite3_column_int64(statement, 0)
                }
            }
            let idA = try chunkID(for: meetingA)
            let idB = try chunkID(for: meetingB)
            guard idA > 0, idB > 0 else {
                failures.append("chunk replace returned no ids")
                throw CancellationError()
            }

            func batch(meeting: String, title: String, at: Int64, chunk: Int64, owner: Bool) -> GraphBatch {
                let meetingNode = GraphIDs.meeting(meeting)
                let ana = GraphIDs.person("Ana")
                var nodes: [GraphNodeRecord] = [
                    GraphNodeRecord(id: meetingNode, type: "Meeting",
                                    fields: ["title": .text(title), "start": .text("2023-11-14T12:00:00Z")],
                                    meetingID: meeting, sourceChunk: chunk, observedAt: at),
                    GraphNodeRecord(id: ana, type: "Person",
                                    fields: ["name": .text("Ana")],
                                    meetingID: nil, sourceChunk: chunk, observedAt: at),
                ]
                var edges: [GraphEdgeRecord] = [
                    GraphEdgeRecord(type: "attended", from: ana, to: meetingNode, meetingID: meeting,
                                    observedAt: at, validFrom: nil, validTo: nil, sourceChunk: chunk),
                ]
                let decision = GraphIDs.owned("Decision", meetingID: meeting, ordinal: 0)
                nodes.append(GraphNodeRecord(
                    id: decision, type: "Decision",
                    fields: ["text": .text("Ship \(title)"), "subject": .text("ship"), "supersedes": .bool(false)],
                    meetingID: meeting, sourceChunk: chunk, observedAt: at))
                edges.append(GraphEdgeRecord(
                    type: "decided_in", from: decision, to: meetingNode, meetingID: meeting,
                    observedAt: at, validFrom: nil, validTo: nil, sourceChunk: chunk))
                let action = GraphIDs.owned("ActionItem", meetingID: meeting, ordinal: 0)
                nodes.append(GraphNodeRecord(
                    id: action, type: "ActionItem",
                    fields: ["text": .text("Write notes"), "owner": .text(owner ? "Ana" : "Bo")],
                    meetingID: meeting, sourceChunk: chunk, observedAt: at))
                edges.append(GraphEdgeRecord(
                    type: "assigned_in", from: action, to: meetingNode, meetingID: meeting,
                    observedAt: at, validFrom: nil, validTo: nil, sourceChunk: chunk))
                if owner {
                    edges.append(GraphEdgeRecord(
                        type: "owns", from: ana, to: action, meetingID: meeting,
                        observedAt: at, validFrom: nil, validTo: nil, sourceChunk: chunk))
                }
                return GraphBatch(meetingID: meeting, nodes: nodes, edges: edges)
            }

            _ = try graph.replaceMeeting(batch(meeting: meetingA, title: "Pricing sync", at: t0, chunk: idA, owner: true))
            _ = try graph.replaceMeeting(batch(meeting: meetingB, title: "Launch review", at: t1, chunk: idB, owner: false))

            let moments = try graph.personMeetings(personID: "Ana")
            check("personMeetings did not return both meetings \(moments.map(\.title))",
                  moments.count == 2 && moments.first?.title == "Launch review")
            check("newest meeting is not first", (moments.first?.at.timeIntervalSince1970 ?? 0) > (moments.last?.at.timeIntervalSince1970 ?? 0))
            check("Ana does not own the Pricing action",
                  moments.contains { $0.title == "Pricing sync" && !$0.ownedIDs.isEmpty })
            check("Ana owns an action in Launch",
                  moments.contains { $0.title == "Launch review" && $0.ownedIDs.isEmpty })
            check("decisions missing on a meeting", moments.allSatisfy { !$0.decisions.isEmpty })

            let local = try graph.expand(nodeID: GraphIDs.person("Ana"), edgeTypes: [], depth: 1)
            check("local expand has no Ana", local.nodes.contains { $0.id == GraphIDs.person("Ana") })
            check("local expand has no meetings",
                  local.nodes.filter { $0.type == "Meeting" }.count == 2)
            check("focus candidates skipped people",
                  (try graph.focusCandidates()).contains { $0.type == "Person" && $0.label == "Ana" })

            let overview = try graph.visualization(limit: 50)
            check("overview is empty", !overview.nodes.isEmpty)
            let overviewLayout = ForceLayout(
                ids: overview.nodes.map(\.id),
                edges: overview.edges.map { ($0.from, $0.to) },
                size: CGSize(width: 700, height: 480)
            )
            check("overview layout missed nodes", overviewLayout.placements.count == overview.nodes.count)
        } catch is CancellationError {
            // Already recorded.
        } catch {
            failures.append("fixture graph failed: \(error.localizedDescription)")
        }

        if failures.isEmpty {
            print("GRAPH_LAYOUT_OK")
            return true
        }
        for failure in failures { print("GRAPH_LAYOUT_FAILED: \(failure)") }
        print("GRAPH_LAYOUT_FAILED")
        return false
    }
}

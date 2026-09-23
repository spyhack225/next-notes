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

        // MARK: Memories drawn beside the extracted graph

        let memories = MemoryGraphOverlay(items: [
            .init(id: UUID(), kind: "profile", text: "Ana prefers the pricing page shipped first."),
            .init(id: UUID(), kind: "note", text: "The user asked about the STEP export."),
        ])
        let memoryNodes = memories.nodes()
        check("a memory produced no node", memoryNodes.count == 2)
        check("a memory node is not typed Memory", memoryNodes.allSatisfy { $0.type == "Memory" })
        check("a memory node lost its id", memoryNodes.allSatisfy {
            MemoryGraphOverlay.memoryID(of: $0.id) != nil
        })
        check("a memory node's id does not read back",
              memories.items.allSatisfy { MemoryGraphOverlay.memoryID(of: MemoryGraphOverlay.id($0)) == $0.id })
        check("another node's id read as a memory",
              !MemoryGraphOverlay.isMemoryNode("person:ana") && !MemoryGraphOverlay.isMemoryNode("file:/tmp/x"))

        let known = [
            KnowledgeGraphNode(id: "person:ana", type: "Person", label: "Ana", sourceChunk: 1),
            KnowledgeGraphNode(id: "project:pricing", type: "Project", label: "Pricing page", sourceChunk: 2),
            KnowledgeGraphNode(id: "person:sam", type: "Person", label: "Sam", sourceChunk: 3),
        ]
        let mentions = memories.mentions(among: known)
        check("a mentioned node got no edge",
              mentions.contains { $0.from == "person:ana" && $0.type == "remembered_as" })
        check("a node the memories never name got an edge", !mentions.contains { $0.from == "person:sam" })
        check("a drawn edge lost its source chunk", mentions.allSatisfy { $0.sourceChunk == FileGraphOverlay.noSourceChunk })
        check("a memory connected to itself", !mentions.contains { MemoryGraphOverlay.isMemoryNode($0.from) })

        // MARK: Unconnected groups do not line the frame
        //
        // The artefact this guards against: a map whose folders and files had no edge to
        // the rest of the graph got pushed outward by repulsion until the frame clamped
        // them, and came out as a rigid row along the top and a column down the right.
        // `ForceLayout` now gives every connected group its own gravity well and fits the
        // finished picture into the frame instead of clipping to it, so only the handful
        // of nodes that define the bounding box should touch an edge.
        //
        // The fixture is the real shape of the problem: one connected chain, plus six
        // folders each holding three files and joined to nothing else.
        var islandIDs = (0..<16).map { "chain\($0)" }
        var islandEdges = (0..<15).map { (islandIDs[$0], islandIDs[$0 + 1]) }
        var families: [[String]] = []
        for folder in 0..<6 {
            let root = "folder\(folder)"
            let files = (0..<3).map { "file\(folder)-\($0)" }
            islandIDs.append(root)
            islandIDs += files
            islandEdges += files.map { (root, $0) }
            families.append([root] + files)
        }
        let islandSize = CGSize(width: 760, height: 520)
        let islands = ForceLayout(ids: islandIDs, edges: islandEdges, size: islandSize)
        check("island layout missed nodes", islands.placements.count == islandIDs.count)

        let onEdge = islands.placements.values.filter {
            abs($0.x - inset) < 1 || abs($0.x - (islandSize.width - inset)) < 1
                || abs($0.y - inset) < 1 || abs($0.y - (islandSize.height - inset)) < 1
        }
        // The fit lands the bounding box on the frame, so the few nodes that define that
        // box do touch an edge — six of forty, at the time of writing. A quarter of the
        // map against the walls is the old picture, and that is what this catches. Widen
        // the allowance if the layout legitimately changes; do not delete the check.
        check("unconnected nodes are pinned to the frame edges (\(onEdge.count) of \(islandIDs.count))",
              onEdge.count <= max(10, islandIDs.count / 4))

        // Each folder should sit with its own files rather than be scattered through the
        // rest of the map: a file's nearest company is the folder that holds it.
        func centroid(_ ids: [String]) -> CGPoint {
            var sum = CGPoint.zero
            for id in ids {
                guard let point = islands.placements[id] else { continue }
                sum.x += point.x
                sum.y += point.y
            }
            return CGPoint(x: sum.x / CGFloat(ids.count), y: sum.y / CGFloat(ids.count))
        }
        let chainMiddle = centroid((0..<16).map { "chain\($0)" })
        for family in families {
            let home = centroid(family)
            let spread = family.compactMap { islands.placements[$0] }
                .map { hypot($0.x - home.x, $0.y - home.y) }
                .max() ?? .greatestFiniteMagnitude
            let away = hypot(home.x - chainMiddle.x, home.y - chainMiddle.y)
            check("folder group \(family[0]) did not stay together (spread \(Int(spread)), \(Int(away)) from the chain)",
                  spread < away)
        }

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

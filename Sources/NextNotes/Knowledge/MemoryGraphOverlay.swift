import Foundation

/// The user's core memories, drawn onto the life map.
///
/// **Why this is an overlay and not rows in `graph_node`.** Every edge in the extracted graph
/// carries a source chunk and is dropped without one, because an extracted claim is only ever
/// somebody's word for something and has to be traceable back to the sentence that caused it.
/// A memory is not a claim about a meeting — it is a fact the user (or the review) saved — and
/// forcing one through that invariant would mean inventing a citation. So memories are
/// assembled here, at draw time, from `NextMemory`, and merged into whatever the graph already
/// holds. Deleting either store leaves the other whole.
///
/// **Why only core entries.** Activity items rebuild from app state and are labels rather than
/// facts; the profile and note rows are the ones the Memories editor can change, and a dot
/// that opens the editor to the fact it names is the point of drawing them at all.
///
/// **Why the edges are conservative.** An edge is drawn only when a node's own label shares a
/// word with the memory's words, and the label has to be at least three characters — "Ana" is
/// a connection, "the" is not. The map shows the connection rather than claiming one.
struct MemoryGraphOverlay: Sendable {
    /// One memory, snapshotted on the main actor because `NextMemory` is main-actor state.
    struct Item: Sendable, Equatable {
        var id: UUID
        var kind: String
        var text: String
    }

    /// How many memories the map draws. A hundred facts is not a map of anything; the rest
    /// stay one search away.
    static let nodeLimit = 60
    /// Words shorter than this match half the graph. Three keeps names like "Ana" and drops
    /// articles.
    static let shortestWord = 3
    static let idPrefix = "memory:"
    /// Long facts would otherwise draw their whole sentence in the rail and the card.
    static let labelLimit = 90

    let items: [Item]

    @MainActor
    static func snapshot(_ memory: NextMemory) -> MemoryGraphOverlay {
        let items = memory.entries
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(nodeLimit)
            .map { Item(id: $0.id, kind: $0.kind.rawValue, text: $0.text) }
        return MemoryGraphOverlay(items: Array(items))
    }

    func nodes() -> [KnowledgeGraphNode] {
        items.map(Self.node)
    }

    /// Edges from a memory to the nodes its words name, among the nodes already being drawn.
    /// `known` is the drawn graph, so an edge can only exist to a dot that is on the map.
    func mentions(among known: [KnowledgeGraphNode]) -> [KnowledgeGraphEdge] {
        let itemWords = items.map { (item: $0, words: Set(Self.words(in: $0.text))) }
        var edges: [KnowledgeGraphEdge] = []
        var seen: Set<String> = []
        for node in known where node.type != "Memory" {
            let labelWords = Set(Self.words(in: node.label))
            guard !labelWords.isEmpty else { continue }
            for candidate in itemWords where !labelWords.isDisjoint(with: candidate.words) {
                let key = "\(node.id)|\(Self.id(candidate.item))"
                guard seen.insert(key).inserted else { continue }
                edges.append(KnowledgeGraphEdge(
                    from: node.id, to: Self.id(candidate.item), type: "remembered_as",
                    observedAt: Date(timeIntervalSince1970: 0),
                    validFrom: nil, validTo: nil, sourceChunk: FileGraphOverlay.noSourceChunk
                ))
            }
        }
        return edges
    }

    // MARK: - Node shapes

    static func id(_ item: Item) -> String { idPrefix + item.id.uuidString }

    /// The memory a `memory:` node id names, or nil for any other id.
    static func memoryID(of nodeID: String) -> UUID? {
        guard nodeID.hasPrefix(idPrefix) else { return nil }
        return UUID(uuidString: String(nodeID.dropFirst(idPrefix.count)))
    }

    static func isMemoryNode(_ nodeID: String) -> Bool { memoryID(of: nodeID) != nil }

    static func node(_ item: Item) -> KnowledgeGraphNode {
        let label = item.text.count > labelLimit
            ? String(item.text.prefix(labelLimit - 1)).trimmingCharacters(in: .whitespaces) + "…"
            : item.text
        return KnowledgeGraphNode(id: id(item), type: "Memory", label: label, sourceChunk: nil)
    }

    /// Lowercased words, punctuation stripped, short ones dropped.
    static func words(in text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= shortestWord }
    }
}

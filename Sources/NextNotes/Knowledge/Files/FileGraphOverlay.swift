import Foundation

/// The user's folders and files, drawn onto the life map.
///
/// **Why this is an overlay and not rows in `graph_node`.** Every edge in the extracted graph
/// carries a source chunk and is dropped without one, because an extracted claim is only ever
/// somebody's word for something and has to be traceable back to the sentence that caused it.
/// A file is not a claim — the path is its own evidence — and forcing one through that
/// invariant would mean inventing a citation. So folders and files are assembled here, at
/// draw time, from `file-index.sqlite`, and merged into whatever the graph already holds.
/// Deleting either database leaves the other whole.
///
/// **Why so few nodes.** A Downloads folder is twelve thousand files. Drawn, that is not a map
/// of anything. What is drawn is: the folders the user shared, their sub-folders when one is
/// opened, and the files that are *notable* — used in the last month, or named in a meeting,
/// a memory or a task. Everything else stays one `files.find` away.
struct FileGraphOverlay: Sendable {
    let store: FileIndexStore

    /// A file counts as recently used if it was changed or opened inside this window.
    static let recentWindow: TimeInterval = 30 * 86_400
    static let notableFileLimit = 24
    static let subfolderLimit = 16
    /// Short names match everything. "CV.pdf" is not worth a graph edge; "roadmap" is.
    static let shortestMeaningfulName = 4

    /// Edges assembled here carry this instead of a chunk id, because nothing said them.
    /// `KnowledgeGraphEdge.sourceChunk` is not optional, and a real chunk id would be a lie.
    static let noSourceChunk: Int64 = 0

    /// The top of the map: one node per folder the user shared, the sub-folders of the ones
    /// that are open, and the notable files.
    func map(expanded: Set<String> = [], now: Date = Date()) throws -> KnowledgeGraphExpansion {
        var nodes: [KnowledgeGraphNode] = []
        var edges: [KnowledgeGraphEdge] = []
        var known: Set<String> = []

        let roots = try store.roots()
        for root in roots {
            nodes.append(Self.node(root))
            known.insert(Self.id(root))
        }
        // Sub-folders only for folders somebody opened. Otherwise three shared folders bring
        // four hundred children with them and the map is unreadable on arrival.
        for raw in expanded.sorted() {
            let path = FileIndexStore.canonical(raw)
            for child in try store.subfolders(of: path, limit: Self.subfolderLimit) {
                let id = Self.id(child)
                if known.insert(id).inserted { nodes.append(Self.node(child)) }
                edges.append(Self.edge(type: "inside", from: id, to: "folder:\(path)", at: child.modifiedAt))
            }
        }
        for file in try store.recentlyUsed(since: now.addingTimeInterval(-Self.recentWindow),
                                           limit: Self.notableFileLimit) {
            let id = Self.id(file)
            guard known.insert(id).inserted else { continue }
            nodes.append(Self.node(file))
            let parent = (file.path as NSString).deletingLastPathComponent
            if known.contains("folder:\(parent)") {
                edges.append(Self.edge(type: "inside", from: id, to: "folder:\(parent)", at: file.modifiedAt))
            }
        }
        return KnowledgeGraphExpansion(nodes: nodes, edges: edges)
    }

    /// One hop around a folder or a file the user clicked.
    func neighbourhood(of nodeID: String) throws -> KnowledgeGraphExpansion {
        // Canonical, because the rows are: a node id built from a path the caller spelled
        // differently would find its own row and then fail to recognise it.
        guard let raw = Self.path(of: nodeID) else { return KnowledgeGraphExpansion() }
        let path = FileIndexStore.canonical(raw)
        var nodes: [KnowledgeGraphNode] = []
        var edges: [KnowledgeGraphEdge] = []
        let subtree = try store.tree(path: path, depth: 1, limit: Self.subfolderLimit * 3)
        guard let centre = subtree.first(where: { $0.path == path }) else { return KnowledgeGraphExpansion() }
        nodes.append(Self.node(centre))
        for child in subtree where child.path != path {
            nodes.append(Self.node(child))
            edges.append(Self.edge(type: "inside", from: Self.id(child), to: Self.id(centre),
                                   at: child.modifiedAt))
        }
        // A file's own neighbourhood is its folder, not its (empty) children.
        if !centre.isDirectory {
            let parent = FileIndexStore.canonical((path as NSString).deletingLastPathComponent)
            if let folder = try store.tree(path: parent, depth: 1, limit: 1).first(where: { $0.path == parent }) {
                nodes.append(Self.node(folder))
                edges.append(Self.edge(type: "inside", from: Self.id(centre), to: Self.id(folder),
                                       at: centre.modifiedAt))
            }
        }
        return KnowledgeGraphExpansion(nodes: nodes, edges: edges)
    }

    /// The folders, as rail entries.
    func candidates() throws -> [KnowledgeGraphNode] {
        try store.roots().map(Self.node)
    }

    /// Edges from whatever mentioned a file to the file itself.
    ///
    /// The mechanism is the knowledge index, not a guess: the file's name is searched for
    /// among the passages, the passages' chunk ids are looked up in `graph_node`, and every
    /// node extraction built from one of those chunks — the meeting, the person who said it,
    /// the project it was about — is joined to the file. A name too short or too generic to
    /// mean anything is skipped, because that is where false edges come from.
    func mentions(of files: [KnowledgeGraphNode], searcher: any KnowledgeSearching,
                  graph: GraphStore) -> [KnowledgeGraphEdge] {
        var edges: [KnowledgeGraphEdge] = []
        var seen: Set<String> = []
        for file in files where file.type == "File" {
            let stem = (file.label as NSString).deletingPathExtension
            let tokens = FileIndexStore.tokens(stem).filter { $0.count >= Self.shortestMeaningfulName }
            guard !tokens.isEmpty else { continue }
            let query = KnowledgeQuery(text: tokens.joined(separator: " "), limit: 3)
            guard let hits = try? searcher.search(query), !hits.isEmpty else { continue }
            guard let nodes = try? graph.nodes(forChunks: hits.map(\.chunkID)) else { continue }
            for node in nodes where node.type != "File" {
                guard seen.insert("\(node.id)|\(file.id)").inserted else { continue }
                edges.append(Self.edge(type: "refers_to", from: node.id, to: file.id,
                                       at: hits.first?.occurredAt))
            }
        }
        return edges
    }

    /// Nodes for the meetings, people and projects those edges reach, so the map is not full
    /// of edges to nothing.
    func mentioningNodes(for edges: [KnowledgeGraphEdge], graph: GraphStore,
                         known: Set<String>) -> [KnowledgeGraphNode] {
        let wanted = Array(Set(edges.map(\.from)).subtracting(known))
        return (try? graph.nodes(ids: wanted)) ?? []
    }

    // MARK: - Node shapes

    static func id(_ hit: FileHit) -> String {
        (hit.isDirectory ? "folder:" : "file:") + hit.path
    }

    /// The path a `folder:` / `file:` node id names, or nil for any other id.
    static func path(of nodeID: String) -> String? {
        for prefix in ["folder:", "file:"] where nodeID.hasPrefix(prefix) {
            return String(nodeID.dropFirst(prefix.count))
        }
        return nil
    }

    static func isFileNode(_ nodeID: String) -> Bool { path(of: nodeID) != nil }

    static func node(_ hit: FileHit) -> KnowledgeGraphNode {
        KnowledgeGraphNode(id: id(hit), type: hit.isDirectory ? "Folder" : "File",
                           label: hit.name, sourceChunk: nil)
    }

    private static func edge(type: String, from: String, to: String, at: Date?) -> KnowledgeGraphEdge {
        KnowledgeGraphEdge(from: from, to: to, type: type, observedAt: at ?? Date(timeIntervalSince1970: 0),
                           validFrom: nil, validTo: nil, sourceChunk: noSourceChunk)
    }
}

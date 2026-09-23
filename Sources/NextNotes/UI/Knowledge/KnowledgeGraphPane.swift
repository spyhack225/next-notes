import AppKit
import SwiftUI

/// Agent ▸ Graph: the local neighbourhood, the person timeline and the library overview —
/// with the user's own folders and files drawn onto the same map.
///
/// It lives under Agent rather than Search because it is the assistant's picture of a life:
/// who is in it, what is being worked on, and where things are on the Mac. Search is for
/// finding the sentence where something was said, and it kept that job.
///
/// Two sources, one canvas. The extracted graph (people, meetings, decisions, projects) comes
/// from `knowledge.sqlite`; the folders and files come from `file-index.sqlite` through
/// `FileGraphOverlay`, which is merged in at draw time rather than written into the graph —
/// see that file for why. Either half can be switched off and the other still draws.
struct KnowledgeGraphPane: View {
    @Environment(\.openSettings) private var openSettings
    @State private var settings = Settings.shared
    @State private var indexer = KnowledgeIndexer.shared
    @State private var people = PersonResolutionService.shared
    @State private var navigation = NavigationState.shared
    @State private var folders = IndexedFoldersStore.shared
    @State private var fileIndex = FileIndexer.shared
    @State private var showingPeople = false

    @State private var focusID: String?
    @State private var focusType: String?
    @State private var focusLabel = ""
    @State private var expansion = KnowledgeGraphExpansion()
    @State private var overview = KnowledgeGraphExpansion()
    @State private var candidates: [KnowledgeGraphNode] = []
    @State private var moments: [PersonMeetingMoment] = []
    @State private var problem: String?
    @State private var showingOverview = false
    /// The sidebar's own selection, kept in step with `focusID` in both directions so the
    /// system highlight is the one source of "which row is current".
    @State private var railSelection: String?
    /// Folders whose children are drawn. A shared folder brings hundreds of sub-folders with
    /// it; they arrive when somebody opens that folder, and not before.
    @State private var expandedFolders: Set<String> = []

    private var hasExtractedGraph: Bool { settings.knowledgeGraphEnabled && settings.knowledgeIndexEnabled }
    private var hasFiles: Bool { folders.isEnabled && !folders.folders.isEmpty }

    var body: some View {
        Group {
            if !hasExtractedGraph && !hasFiles {
                OrbUnavailableView(
                    .connecting,
                    title: "Nothing to map yet",
                    message: "The map shows the people, projects and places your notes mention, and the "
                        + "folders you let your assistant look through. Turn one of them on to start it."
                ) {
                    Button("Map my notes") { settings.knowledgeGraphEnabled = true }
                        .buttonStyle(.borderedProminent)
                    Button("Choose folders…") {
                        navigation.selectedSettingsTab = .agent
                        openSettings()
                    }
                }
            } else if candidates.isEmpty && expansion.nodes.isEmpty && overview.nodes.isEmpty {
                OrbUnavailableView(
                    .searching,
                    title: "No map yet",
                    message: "Your map fills in after your notes have been read: people, projects, places, "
                        + "hobbies, goals and meetings — and the folders you share, with the files you have "
                        + "used lately. Turn on Index + Extract in Settings, then use Decisions → Extract library."
                ) {
                    Button("People…") { showingPeople = true }
                }
            } else {
                HSplitView {
                    rail
                        .frame(minWidth: DS.Size.meetingListMin, idealWidth: DS.Size.meetingListMin,
                               maxWidth: DS.Size.sidebarMax)
                    detail
                        .frame(minWidth: DS.Size.meetingDetailMin, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task(id: reloadKey) { await reload() }
        .sheet(isPresented: $showingPeople) { MergePeopleSheet() }
    }

    // MARK: - Rail

    /// A native sidebar: the system's own selection highlight through `List(selection:)`
    /// rather than a hand-drawn ring, one symbol per kind in its own ink, and a count on
    /// each section header so the shape of the library is readable without opening it.
    private var rail: some View {
        List(selection: $railSelection) {
            Section {
                Button {
                    withAnimation(DS.Motion.reveal) {
                        showingOverview = true
                        focusID = nil
                        focusType = nil
                        focusLabel = ""
                        railSelection = nil
                        expansion = KnowledgeGraphExpansion()
                        moments = []
                    }
                } label: {
                    Label("Whole map", systemImage: "circle.grid.cross")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    showingPeople = true
                } label: {
                    Label(peopleActionTitle, systemImage: "person.2")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } header: {
                Text("Navigate")
            }

            ForEach(railSections) { section in
                Section {
                    ForEach(section.nodes, id: \.id) { node in
                        railRow(node).tag(node.id)
                    }
                } header: {
                    HStack(spacing: DS.Space.xs) {
                        Text(section.title)
                        Spacer(minLength: DS.Space.xs)
                        Text(section.nodes.count.formatted())
                            .font(DS.Font.caption2)
                            .monospacedDigit()
                            .foregroundStyle(DS.Color.textTertiary)
                    }
                }
            }

            if let problem {
                Section {
                    Text(problem)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.warning)
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: railSelection) { _, id in
            guard let id, id != focusID else { return }
            Task { await select(id) }
        }
        .onChange(of: focusID) { _, id in
            if railSelection != id { railSelection = id }
        }
    }

    private func railRow(_ node: KnowledgeGraphNode) -> some View {
        Label {
            Text(node.label)
                .lineLimit(2)
        } icon: {
            Image(systemName: GraphNodeStyle.symbol(for: node.type))
                .foregroundStyle(DS.Color.graphNode(node.type))
        }
        .accessibilityLabel("\(node.label), \(GraphNodeStyle.singular(for: node.type))")
    }

    private var peopleActionTitle: String {
        people.candidates.isEmpty ? "People…" : "People (\(people.candidates.count))…"
    }

    /// One section per kind, people first and meetings last, with the life domains that
    /// actually have something in them in between.
    private struct RailSection: Identifiable {
        let id: String
        let title: String
        let nodes: [KnowledgeGraphNode]
    }

    private var railSections: [RailSection] {
        GraphNodeStyle.focusOrder.compactMap { type in
            let nodes = candidates.filter { $0.type == type }
            guard !nodes.isEmpty else { return nil }
            return RailSection(id: type, title: GraphNodeStyle.title(for: type), nodes: nodes)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if showingOverview || focusID == nil {
            overviewDetail
        } else if let focusID {
            neighbourhoodDetail(focusID: focusID)
        }
    }

    /// The map takes the whole pane. No scroll view, no card, no page margin: the heading,
    /// the controls and the card all float on glass over the canvas, which is what turns a
    /// picture of a graph into somewhere you can be.
    private var overviewDetail: some View {
        GlobalGraphView(
            expansion: overview,
            eyebrow: "Your life and your Mac",
            title: "The whole map",
            subtitle: subtitle
        ) { id in
            Task { await select(id) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Plain language, and honest about what is not drawn: only the files you have used
    /// lately are dots, and the rest are one search away.
    private var subtitle: String {
        var lines = ["Click a dot to see what it is."]
        if hasFiles, fileIndex.stats.files > 0 {
            lines.append("Your folders are here with the files you have used in the last month — "
                + "the other \(fileIndex.stats.files.formatted()) are found by asking.")
        }
        return lines.joined(separator: " ")
    }

    private func neighbourhoodDetail(focusID: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.section) {
                HStack(alignment: .top, spacing: DS.Space.m) {
                    SectionHeading(
                        title: focusLabel.isEmpty ? focusID : focusLabel,
                        eyebrow: "Around this",
                        subtitle: focusType.map { "One step from this \(GraphNodeStyle.singular(for: $0))." },
                        orb: .searching,
                        isOrbAnimated: false
                    )
                    Spacer(minLength: DS.Space.s)
                    if let focusType {
                        StatusChip(
                            text: GraphNodeStyle.title(for: focusType),
                            color: DS.Color.graphNode(focusType),
                            systemImage: GraphNodeStyle.symbol(for: focusType)
                        )
                    }
                    if let path = FileGraphOverlay.path(of: focusID) {
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        }
                        .buttonStyle(.bordered)
                    }
                    Button("Whole map") {
                        withAnimation(DS.Motion.reveal) {
                            showingOverview = true
                            self.focusID = nil
                        }
                    }
                    .buttonStyle(.bordered)
                }

                LocalGraphView(expansion: expansion, focusID: focusID) { id in
                    Task { await select(id) }
                }
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.glass, style: .continuous))

                if focusType == "Person" {
                    PersonTimelineView(
                        personLabel: focusLabel.isEmpty ? focusID : focusLabel,
                        moments: moments,
                        onOpenMeeting: openMeeting,
                        onFocusNode: { id in Task { await select(id) } }
                    )
                }
            }
            .padding(DS.Space.page)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .orbBackdrop(.searching)
    }

    private func openMeeting(_ meetingID: String) {
        guard let id = UUID(uuidString: meetingID) else { return }
        navigation.show(meeting: id)
    }

    // MARK: - Loading

    private struct ReloadKey: Equatable {
        let enabled: Bool
        let revision: Int
        let people: Int
        let files: Int
        let folders: Int
        let focus: String?
        let expanded: Int
        let memory: String
    }

    /// Memories are not in `knowledge.sqlite`, so nothing else here moves when one is edited
    /// or forgotten; this is what redraws their dots.
    private var memoryFingerprint: String {
        let entries = NextMemory.shared.entries
        let latest = entries.map(\.updatedAt).max()?.timeIntervalSince1970 ?? 0
        return "\(entries.count)-\(latest)"
    }

    private var reloadKey: ReloadKey {
        ReloadKey(
            enabled: hasExtractedGraph,
            revision: indexer.revision,
            people: people.revision,
            files: fileIndex.revision,
            folders: folders.revision,
            focus: focusID,
            expanded: expandedFolders.count,
            memory: memoryFingerprint
        )
    }

    /// One pass off the main actor: the extracted graph, the file overlay, and the edges that
    /// join them. Both halves are optional and a missing one is simply nothing to draw.
    private func reload() async {
        // Kicked off, not waited on: the probe runs off the main actor and publishes its
        // verdicts into `folders.accessProblems`, which re-renders this pane on its own.
        folders.refreshAccessProblems()
        let graph = indexer.graph
        // Snapshotted here, on the main actor: `NextMemory` is main-actor state and the
        // drawing half below runs off it.
        let memoryOverlay = MemoryGraphOverlay.snapshot(NextMemory.shared)
        let overlay = hasFiles && fileIndex.store.existsOnDisk
            ? FileGraphOverlay(store: fileIndex.store) : nil
        guard graph != nil || overlay != nil else {
            candidates = []
            overview = KnowledgeGraphExpansion()
            expansion = KnowledgeGraphExpansion()
            moments = []
            return
        }
        let searcher = indexer.searcher
        let focus = focusID
        let expanded = expandedFolders
        let result = await Task.detached(priority: .userInitiated) { () -> Result<(
            candidates: [KnowledgeGraphNode],
            overview: KnowledgeGraphExpansion,
            expansion: KnowledgeGraphExpansion,
            moments: [PersonMeetingMoment],
            focusNode: KnowledgeGraphNode?
        ), Error> in
            Result {
                var candidates = try graph?.focusCandidates() ?? []
                var overview = try graph?.visualization() ?? KnowledgeGraphExpansion()
                if graph != nil {
                    // The user's own memories, drawn beside the extracted graph. They are an
                    // overlay rather than rows: a memory has no source chunk to cite, and
                    // every edge in the store must have one.
                    let memoryNodes = memoryOverlay.nodes()
                    candidates = memoryNodes + candidates
                    overview.nodes += memoryNodes
                    overview.edges += memoryOverlay.mentions(among: overview.nodes)
                }
                if let overlay {
                    let map = try overlay.map(expanded: expanded)
                    candidates = map.nodes.filter { $0.type == "Folder" } + candidates
                    overview.nodes += map.nodes
                    overview.edges += map.edges
                    if let graph {
                        // What mentioned a file, joined to it: the whole reason files are on
                        // this map rather than only in search.
                        let mentions = overlay.mentions(of: map.nodes, searcher: searcher, graph: graph)
                        let known = Set(overview.nodes.map(\.id))
                        overview.nodes += overlay.mentioningNodes(for: mentions, graph: graph, known: known)
                        overview.edges += mentions
                    }
                }
                var expansion = KnowledgeGraphExpansion()
                var focusNode: KnowledgeGraphNode?
                var moments: [PersonMeetingMoment] = []
                if let focus {
                    if MemoryGraphOverlay.isMemoryNode(focus) {
                        // A memory's neighbourhood is what its words name: the people,
                        // projects and meetings already on the map that it mentions.
                        let known = overview.nodes + candidates
                        let mine = memoryOverlay.mentions(among: known)
                            .filter { $0.from == focus || $0.to == focus }
                        let related = Set(mine.map { $0.from == focus ? $0.to : $0.from })
                        expansion = KnowledgeGraphExpansion(
                            nodes: memoryOverlay.nodes().filter { $0.id == focus }
                                + known.filter { related.contains($0.id) },
                            edges: mine
                        )
                        focusNode = expansion.nodes.first { $0.id == focus }
                    } else if FileGraphOverlay.isFileNode(focus) {
                        expansion = try overlay?.neighbourhood(of: focus) ?? KnowledgeGraphExpansion()
                        if let graph, let overlay {
                            let mentions = overlay.mentions(of: expansion.nodes, searcher: searcher, graph: graph)
                            let known = Set(expansion.nodes.map(\.id))
                            expansion.nodes += overlay.mentioningNodes(for: mentions, graph: graph, known: known)
                            expansion.edges += mentions
                        }
                        focusNode = expansion.nodes.first { $0.id == focus }
                    } else if let graph {
                        expansion = try graph.expand(nodeID: focus, edgeTypes: [], depth: 1)
                        focusNode = expansion.nodes.first { $0.id == focus }
                            ?? expansion.nodes.first {
                                $0.label.compare(focus, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                            }
                            ?? candidates.first { $0.id == focus }
                            ?? candidates.first {
                                $0.label.compare(focus, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                            }
                        let personFocus = (focusNode?.type == "Person") || focus.hasPrefix("person:")
                        if personFocus, let id = focusNode?.id ?? (focus.hasPrefix("person:") ? focus : nil) {
                            moments = try graph.personMeetings(personID: id)
                        }
                    }
                }
                return (candidates, overview, expansion, moments, focusNode)
            }
        }.value
        switch result {
        case .success(let loaded):
            candidates = loaded.candidates
            overview = loaded.overview
            expansion = loaded.expansion
            moments = loaded.moments
            if let node = loaded.focusNode {
                focusType = node.type
                focusLabel = node.label
                focusID = node.id
                showingOverview = false
            } else if focusID != nil, loaded.expansion.nodes.isEmpty {
                // Focus vanished after a rebuild, or a file was deleted — fall back to the map.
                focusID = nil
                focusType = nil
                focusLabel = ""
                showingOverview = true
            }
            problem = fileProblem
            if focusID == nil, showingOverview == false, !loaded.candidates.isEmpty {
                // First open: land on the first person, else the first folder, else the map.
                if let first = loaded.candidates.first(where: { $0.type == "Person" })
                    ?? loaded.candidates.first
                {
                    await select(first.id)
                } else {
                    showingOverview = true
                }
            }
        case .failure(let error):
            problem = error.localizedDescription
        }
    }

    /// A folder macOS has not let the app read is the one file problem worth saying out loud.
    ///
    /// Reads the cached verdict only. This runs on the main actor at the tail of every reload,
    /// and asking the file system here — once per folder, per reload — would stall the window
    /// on exactly the slow volume the message is about.
    private var fileProblem: String? {
        guard hasFiles else { return nil }
        for folder in folders.folders {
            if let problem = folders.accessProblem(for: folder) {
                return "\(folder.lastPathComponent): \(problem)"
            }
        }
        return fileIndex.lastError
    }

    private func select(_ id: String) async {
        // A memory dot is a fact, not a place to explore: a click opens the Memories editor
        // on the fact it names, which is the only thing it could usefully do.
        if let memoryID = MemoryGraphOverlay.memoryID(of: id) {
            navigation.openMemories(memoryID)
            return
        }
        focusID = id
        showingOverview = false
        // Opening a folder is what brings its sub-folders onto the map.
        if let path = FileGraphOverlay.path(of: id), id.hasPrefix("folder:") {
            expandedFolders.insert(path)
        }
        await reload()
    }
}

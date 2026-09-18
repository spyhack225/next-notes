import SwiftUI

/// Local graph + person timeline as one screen (Part 4, Phase F), with the optional global
/// overview (Phase G) as the way to pick a starting node.
///
/// Selection is shared: focusing a person fills the timeline; focusing anything else keeps
/// the one-hop neighbourhood. The global canvas is only useful as navigation into that —
/// click a node, walk from there.
struct KnowledgeGraphPane: View {
    @State private var settings = Settings.shared
    @State private var indexer = KnowledgeIndexer.shared
    @State private var people = PersonResolutionService.shared
    @State private var navigation = NavigationState.shared
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

    var body: some View {
        Group {
            if !settings.knowledgeGraphEnabled {
                OrbUnavailableView(
                    .connecting,
                    title: "Graph is off",
                    message: "Turn on extraction to map people, projects, places, activities and decisions "
                        + "from meetings, dictations and Agent chats — one hop at a time."
                ) {
                    Button("Extract life map") { settings.knowledgeGraphEnabled = true }
                        .buttonStyle(.borderedProminent)
                }
            } else if candidates.isEmpty && expansion.nodes.isEmpty && overview.nodes.isEmpty {
                OrbUnavailableView(
                    .searching,
                    title: "No graph yet",
                    message: "Your life map fills in after extraction: people, projects, places, hobbies, "
                        + "goals and meetings from notes — and from dictations and Agent chats once those "
                        + "are indexed. Turn on Index + Extract in Settings, include dictation if you want "
                        + "it, then use Decisions → Extract library."
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

    private var rail: some View {
        List {
            Section {
                Button {
                    withAnimation(DS.Motion.reveal) {
                        showingOverview = true
                        focusID = nil
                        focusType = nil
                        focusLabel = ""
                        expansion = KnowledgeGraphExpansion()
                        moments = []
                    }
                } label: {
                    Label("Library overview", systemImage: "circle.grid.cross")
                }
                Button(people.candidates.isEmpty ? "People…" : "People (\(people.candidates.count))…") {
                    showingPeople = true
                }
            } header: {
                Text("Navigate")
            }

            if !peopleCandidates.isEmpty {
                Section("People") {
                    ForEach(peopleCandidates, id: \.id) { node in
                        focusRow(node)
                    }
                }
            }
            ForEach(lifeDomainSections, id: \.title) { section in
                Section(section.title) {
                    ForEach(section.nodes, id: \.id) { node in
                        focusRow(node)
                    }
                }
            }
            if !meetingCandidates.isEmpty {
                Section("Meetings") {
                    ForEach(meetingCandidates, id: \.id) { node in
                        focusRow(node)
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
    }

    private func focusRow(_ node: KnowledgeGraphNode) -> some View {
        Button {
            Task { await select(node.id) }
        } label: {
            HStack(spacing: DS.Space.s) {
                ZStack {
                    Circle()
                        .fill(DS.Color.graphNode(node.type).opacity(
                            focusID == node.id ? 1 : DS.Opacity.secondaryFill
                        ))
                        .frame(width: DS.Size.graphRailSwatch, height: DS.Size.graphRailSwatch)
                    if focusID == node.id {
                        Circle()
                            .strokeBorder(DS.Color.accent, lineWidth: DS.Border.hairline)
                            .frame(
                                width: DS.Size.graphRailSwatch + DS.Space.xs,
                                height: DS.Size.graphRailSwatch + DS.Space.xs
                            )
                    }
                }
                .frame(width: DS.Size.iconMedium, height: DS.Size.iconMedium)

                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(node.label)
                        .font(focusID == node.id ? DS.Font.callout.weight(.semibold) : DS.Font.callout)
                        .foregroundStyle(DS.Color.text)
                        .lineLimit(2)
                    if focusID == node.id, let focusType {
                        Text(GraphNodeStyle.title(for: focusType))
                            .font(DS.Font.caption2)
                            .foregroundStyle(DS.Color.textTertiary)
                    }
                }
                Spacer(minLength: DS.Space.xs)
            }
            .padding(.vertical, DS.Space.xxs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(focusID == node.id ? .isSelected : [])
    }

    private var peopleCandidates: [KnowledgeGraphNode] {
        candidates.filter { $0.type == "Person" }
    }

    private var meetingCandidates: [KnowledgeGraphNode] {
        candidates.filter { $0.type == "Meeting" }
    }

    private var lifeDomainSections: [(title: String, nodes: [KnowledgeGraphNode])] {
        let lifeTypes = ["Project", "Organization", "Activity", "Place", "Goal", "Event", "Preference", "Topic"]
        return lifeTypes.compactMap { type in
            let nodes = candidates.filter { $0.type == type }
            guard !nodes.isEmpty else { return nil }
            return (GraphNodeStyle.title(for: type), nodes)
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

    private var overviewDetail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.section) {
                SectionHeading(
                    title: "Library overview",
                    eyebrow: "Life map",
                    subtitle: "Click a node to open its neighbourhood. At a few hundred nodes this is a map; "
                        + "past that, prefer the people and life-domain lists.",
                    orb: .breathing,
                    isOrbAnimated: false
                )

                GlassCard(padding: DS.Space.cardTight) {
                    GlobalGraphView(expansion: overview) { id in
                        Task { await select(id) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.glassSmall, style: .continuous))
                }
            }
            .padding(DS.Space.page)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .orbBackdrop(.breathing)
    }

    private func neighbourhoodDetail(focusID: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.section) {
                HStack(alignment: .top, spacing: DS.Space.m) {
                    SectionHeading(
                        title: focusLabel.isEmpty ? focusID : focusLabel,
                        eyebrow: "Neighbourhood",
                        subtitle: focusType.map { "One hop from this \(GraphNodeStyle.singular(for: $0))." },
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
                    Button("Overview") {
                        withAnimation(DS.Motion.reveal) {
                            showingOverview = true
                            self.focusID = nil
                        }
                    }
                    .buttonStyle(.bordered)
                }

                GlassCard(padding: DS.Space.cardTight) {
                    LocalGraphView(expansion: expansion, focusID: focusID) { id in
                        Task { await select(id) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.glassSmall, style: .continuous))
                }

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
        let focus: String?
    }

    private var reloadKey: ReloadKey {
        ReloadKey(
            enabled: settings.knowledgeGraphEnabled && settings.knowledgeIndexEnabled,
            revision: indexer.revision,
            people: people.revision,
            focus: focusID
        )
    }

    private func reload() async {
        guard let graph = indexer.graph else {
            candidates = []
            overview = KnowledgeGraphExpansion()
            expansion = KnowledgeGraphExpansion()
            moments = []
            return
        }
        let focus = focusID
        let result = await Task.detached(priority: .userInitiated) { () -> Result<(
            candidates: [KnowledgeGraphNode],
            overview: KnowledgeGraphExpansion,
            expansion: KnowledgeGraphExpansion,
            moments: [PersonMeetingMoment],
            focusNode: KnowledgeGraphNode?
        ), Error> in
            Result {
                let candidates = try graph.focusCandidates()
                let overview = try graph.visualization()
                let expansion: KnowledgeGraphExpansion
                var focusNode: KnowledgeGraphNode?
                var moments: [PersonMeetingMoment] = []
                if let focus {
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
                } else {
                    expansion = KnowledgeGraphExpansion()
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
                // Focus vanished after a rebuild — fall back to the overview.
                focusID = nil
                focusType = nil
                focusLabel = ""
                showingOverview = true
            }
            problem = nil
            if focusID == nil, showingOverview == false, !loaded.candidates.isEmpty {
                // First open: land on the first person, else the overview.
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

    private func select(_ id: String) async {
        focusID = id
        showingOverview = false
        await reload()
    }
}

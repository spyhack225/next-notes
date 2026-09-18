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
                    message: "Turn on extraction to walk people, meetings and decisions one hop at a time, "
                        + "and to see one person's meetings against time."
                ) {
                    Button("Extract decisions and action items") { settings.knowledgeGraphEnabled = true }
                        .buttonStyle(.borderedProminent)
                }
            } else if candidates.isEmpty && expansion.nodes.isEmpty && overview.nodes.isEmpty {
                OrbUnavailableView(
                    .connecting,
                    title: "No graph yet",
                    message: "People and meetings appear here after notes are extracted. "
                        + "Use Decisions → Extract past meetings if the library already has notes."
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
                    showingOverview = true
                    focusID = nil
                    focusType = nil
                    focusLabel = ""
                    expansion = KnowledgeGraphExpansion()
                    moments = []
                } label: {
                    Label("Library overview", systemImage: "circle.grid.cross")
                }
                Button(people.candidates.isEmpty ? "People…" : "People (\(people.candidates.count))…") {
                    showingPeople = true
                }
            }
            if !peopleCandidates.isEmpty {
                Section("People") {
                    ForEach(peopleCandidates, id: \.id) { node in
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
                Image(systemName: focusID == node.id ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(focusID == node.id ? DS.Color.accent : DS.Color.textTertiary)
                Text(node.label)
                    .lineLimit(2)
                Spacer(minLength: DS.Space.xs)
            }
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

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if showingOverview || focusID == nil {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                Text("Library overview")
                    .font(DS.Font.headline)
                Text("Click a node to open its neighbourhood. At a few hundred nodes this is a map; "
                    + "past that, prefer the people and meetings lists.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
                GlobalGraphView(expansion: overview) { id in
                    Task { await select(id) }
                }
                .glassSurface(cornerRadius: DS.Radius.glass)
            }
            .padding(DS.Space.page)
        } else if let focusID {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    HStack(spacing: DS.Space.s) {
                        Text(focusLabel.isEmpty ? focusID : focusLabel)
                            .font(DS.Font.headline)
                        if let focusType {
                            StatusChip(text: focusType, systemImage: symbol(for: focusType))
                        }
                        Spacer()
                        Button("Overview") {
                            showingOverview = true
                            self.focusID = nil
                        }
                    }
                    LocalGraphView(expansion: expansion, focusID: focusID) { id in
                        Task { await select(id) }
                    }
                    .glassSurface(cornerRadius: DS.Radius.glass)

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
        }
    }

    private func symbol(for type: String) -> String {
        switch type {
        case "Person": return "person"
        case "Meeting": return "calendar"
        case "Decision": return "checkmark.seal"
        case "ActionItem": return "checklist"
        default: return "circle"
        }
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

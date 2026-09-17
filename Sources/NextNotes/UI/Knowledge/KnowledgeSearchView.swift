import SwiftUI

/// Search: ranked passages beside a facet rail.
///
/// Results are the interface. The rail down the left narrows them by source kind, meeting,
/// speaker and notes heading, each with a count — the node types a graph would draw, demoted
/// to filters. It needs nothing but the chunk table, which is why it is the one knowledge
/// screen that is useful with two meetings in the library.
///
/// A transcript passage jumps to its second in the meeting's transcript; a notes passage
/// opens the meeting; a conversation opens the Agent.
struct KnowledgeSearchView: View {
    @State private var settings = Settings.shared
    @State private var indexer = KnowledgeIndexer.shared
    @State private var navigation = NavigationState.shared
    @State private var meetings = MeetingStore.shared

    @State private var query = ""
    @State private var filter = KnowledgeFilter()
    @State private var hits: [KnowledgeHit] = []
    @State private var facets = KnowledgeFacets()
    @State private var problem: String?
    @State private var hasSearched = false

    var body: some View {
        Group {
            if settings.knowledgeIndexEnabled {
                HSplitView {
                    rail
                        .frame(minWidth: DS.Size.meetingListMin, idealWidth: DS.Size.meetingListMin,
                               maxWidth: DS.Size.sidebarMax)
                    results
                        .frame(minWidth: DS.Size.meetingDetailMin, maxWidth: .infinity, maxHeight: .infinity)
                }
                .searchable(text: $query, prompt: Text("Search meetings, notes and conversations"))
            } else {
                OrbUnavailableView(
                    .searching,
                    title: "Search is off",
                    message: "Turn on the knowledge index to search every transcript, set of notes and "
                        + "Agent conversation by passage. It stays on this Mac."
                ) {
                    Button("Turn on the knowledge index") { settings.knowledgeIndexEnabled = true }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle(SidebarSection.search.title)
        .task(id: searchKey) { await runSearch() }
    }

    // MARK: - Rail

    private var rail: some View {
        List {
            Section("Sources") {
                ForEach(KnowledgeSourceKind.allCases) { kind in
                    facetRow(kind.title, count: facets.kinds[kind], isOn: filter.kinds.contains(kind)) {
                        filter.kinds.formSymmetricDifference([kind])
                    }
                }
            }
            if !meetingFacets.isEmpty {
                Section("Meetings") {
                    ForEach(meetingFacets, id: \.id) { facet in
                        facetRow(facet.title, count: facet.count, isOn: filter.sourceIDs.contains(facet.id)) {
                            filter.sourceIDs.formSymmetricDifference([facet.id])
                        }
                    }
                }
            }
            if !facets.speakers.isEmpty {
                Section("Speakers") {
                    ForEach(sorted(facets.speakers), id: \.key) { speaker, count in
                        facetRow(speaker, count: count, isOn: filter.speakers.contains(speaker)) {
                            filter.speakers.formSymmetricDifference([speaker])
                        }
                    }
                }
            }
            if !facets.headings.isEmpty {
                Section("Notes sections") {
                    ForEach(sorted(facets.headings), id: \.key) { heading, count in
                        facetRow(heading, count: count, isOn: filter.headings.contains(heading)) {
                            filter.headings.formSymmetricDifference([heading])
                        }
                    }
                }
            }
            Section {
                if !filter.isEmpty {
                    Button("Clear filters") { filter = KnowledgeFilter() }
                }
                status
            }
        }
        .listStyle(.sidebar)
    }

    private func facetRow(_ title: String, count: Int?, isOn: Bool, toggle: @escaping () -> Void) -> some View {
        Button(action: toggle) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? DS.Color.accent : DS.Color.textTertiary)
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: DS.Space.xs)
                Text(count.map(String.init) ?? "0")
                    .font(DS.Font.timestamp)
                    .foregroundStyle(DS.Color.textSecondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            if indexer.isIndexing {
                Label("Indexing… \(indexer.pending.count) left", systemImage: "arrow.triangle.2.circlepath")
            }
            Text("\(indexer.stats.chunks) passages")
            if let error = indexer.lastError ?? problem {
                Text(error)
                    .foregroundStyle(DS.Color.warning)
            }
        }
        .font(DS.Font.caption)
        .foregroundStyle(DS.Color.textSecondary)
    }

    private var meetingFacets: [(id: String, title: String, count: Int)] {
        facets.sources.compactMap { id, count in
            guard let uuid = UUID(uuidString: id), let meeting = meetings.meeting(id: uuid) else { return nil }
            return (id, meeting.title, count)
        }
        .sorted { $0.count != $1.count ? $0.count > $1.count : $0.title < $1.title }
    }

    private func sorted(_ counts: [String: Int]) -> [(key: String, value: Int)] {
        counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
    }

    // MARK: - Results

    @ViewBuilder
    private var results: some View {
        if hits.isEmpty {
            if query.trimmingCharacters(in: .whitespaces).isEmpty && filter.isEmpty {
                OrbUnavailableView(
                    .searching,
                    title: indexer.stats.chunks == 0 ? "Nothing indexed yet" : "Search your library",
                    message: indexer.stats.chunks == 0
                        ? "Finished meetings and ended Agent conversations are indexed in the background, "
                            + "and never while something is recording."
                        : "Find the passage where something was said, not just the meeting it was in."
                )
            } else if hasSearched {
                ContentUnavailableView.search(text: query)
            } else {
                Color.clear
            }
        } else {
            List(hits) { hit in
                Button { open(hit) } label: { HitRow(hit: hit, source: sourceTitle(for: hit)) }
                    .buttonStyle(.plain)
            }
            .listStyle(.inset)
        }
    }

    private func sourceTitle(for hit: KnowledgeHit) -> String {
        switch hit.kind {
        case .transcript, .notes:
            UUID(uuidString: hit.sourceID).flatMap { meetings.meeting(id: $0)?.title } ?? "Deleted meeting"
        case .conversation: "Agent conversation"
        case .routine: "Routine run"
        case .dictation: "Dictation"
        }
    }

    private func open(_ hit: KnowledgeHit) {
        switch hit.kind {
        case .transcript:
            guard let id = UUID(uuidString: hit.sourceID) else { return }
            navigation.show(meeting: id, at: hit.startTime ?? 0)
        case .notes:
            guard let id = UUID(uuidString: hit.sourceID) else { return }
            navigation.show(meeting: id)
        case .conversation:
            navigation.showConversation()
        case .routine:
            navigation.showRoutines()
        case .dictation:
            navigation.show(.dictation)
        }
    }

    // MARK: - Search

    private struct SearchKey: Equatable {
        let query: String
        let filter: KnowledgeFilter
        let revision: Int
        let enabled: Bool
    }

    private var searchKey: SearchKey {
        SearchKey(query: query, filter: filter, revision: indexer.revision, enabled: settings.knowledgeIndexEnabled)
    }

    /// Off the main actor, a keystroke after the last one: a search is a few milliseconds,
    /// but it still waits behind an indexing transaction.
    private func runSearch() async {
        guard settings.knowledgeIndexEnabled else { return }
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        let searcher = indexer.searcher
        // Embedding the query may wait on a model; the search itself does not.
        let request = await searcher.prepare(KnowledgeQuery(text: query, filter: filter))
        guard !Task.isCancelled else { return }
        let result = await Task.detached(priority: .userInitiated) { () -> Result<([KnowledgeHit], KnowledgeFacets), Error> in
            Result { (try searcher.search(request), try searcher.facets(request)) }
        }.value
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let (found, counts)):
            hits = found
            facets = counts
            problem = nil
        case .failure(let error):
            problem = error.localizedDescription
        }
        hasSearched = true
    }
}

/// One passage: where it came from, when, who, and the words that matched.
private struct HitRow: View {
    let hit: KnowledgeHit
    let source: String

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                Image(systemName: symbol)
                    .foregroundStyle(DS.Color.textSecondary)
                Text(source)
                    .font(DS.Font.headline)
                    .lineLimit(1)
                if let start = hit.startTime {
                    Text(start.counterText)
                        .font(DS.Font.timestamp)
                        .foregroundStyle(DS.Color.accent)
                }
                Spacer(minLength: DS.Space.s)
                Text(hit.occurredAt.formatted(date: .abbreviated, time: .shortened))
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textTertiary)
            }
            if let label = hit.speaker ?? hit.heading {
                Text(label)
                    .font(DS.Font.chip)
                    .foregroundStyle(DS.Color.textSecondary)
            }
            Text(highlighted)
                .font(DS.Font.body)
                .lineLimit(4)
                .frame(maxWidth: DS.Size.readingWidth, alignment: .leading)
        }
        .padding(.vertical, DS.Space.xs)
        .contentShape(Rectangle())
    }

    private var symbol: String {
        switch hit.kind {
        case .transcript: "waveform"
        case .notes: "list.bullet.rectangle"
        case .conversation: "ear"
        case .routine: "clock.arrow.circlepath"
        case .dictation: "mic"
        }
    }

    /// The snippet with its matched words in bold.
    private var highlighted: AttributedString {
        var result = AttributedString()
        var bold = false
        var run = ""
        func flush() {
            guard !run.isEmpty else { return }
            var part = AttributedString(run)
            if bold { part.inlinePresentationIntent = .stronglyEmphasized }
            result += part
            run = ""
        }
        for character in hit.snippet {
            switch String(character) {
            case KnowledgeHit.snippetOpen:
                flush()
                bold = true
            case KnowledgeHit.snippetClose:
                flush()
                bold = false
            default:
                run.append(character)
            }
        }
        flush()
        return result
    }
}

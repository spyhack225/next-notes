import AppKit
import SwiftUI

/// Search: ranked results beside a facet rail.
///
/// Results are the interface. The rail down the left narrows them by source, meeting,
/// person, speaker and notes heading, each with a count — the node types a graph would draw,
/// demoted to filters.
///
/// One engine answers all of it (`LibrarySearch`): the passages of every transcript, set of
/// notes, Agent conversation, routine run and dictation, and — when the user has let the
/// assistant look through their folders — the names of their own files and folders, as a
/// source of their own. A transcript passage jumps to its second in the meeting's transcript;
/// a notes passage opens the meeting; a conversation opens the Agent; a file is revealed in
/// the Finder. Nothing here ever opens a file: the index holds names, paths and dates only.
/// The toolbar switches to Ask, which searches the same sources.
struct KnowledgeSearchView: View {
    @State private var settings = Settings.shared
    @State private var indexer = KnowledgeIndexer.shared
    @State private var navigation = NavigationState.shared
    @State private var meetings = MeetingStore.shared
    @State private var fileIndexer = FileIndexer.shared
    @State private var folders = IndexedFoldersStore.shared
    @State private var resolution = PersonResolutionService.shared

    @State private var query = ""
    @State private var filter = LibraryFilter()
    @State private var hits: [LibraryHit] = []
    @State private var facets = LibraryFacets()
    @State private var problem: String?
    @State private var hasSearched = false
    @State private var mode: Mode = .search

    /// Search finds passages and files; Ask answers a question from them, with citations
    /// (Phase E); Decisions follows each extracted decision across meetings (Phase C).
    ///
    /// The graph used to be a fourth mode here and now lives in Agent ▸ Graph: it is the
    /// assistant's map of people, projects and the Mac's folders, which is something to
    /// explore, not a way to find the sentence where something was said. Search keeps search.
    enum Mode: Hashable {
        case search
        case ask
        case decisions
    }

    var body: some View {
        Group {
            if settings.knowledgeIndexEnabled {
                switch mode {
                case .search:
                    HSplitView {
                        rail
                            .frame(minWidth: DS.Size.meetingListMin, idealWidth: DS.Size.meetingListMin,
                                   maxWidth: DS.Size.sidebarMax)
                        results
                            .frame(minWidth: DS.Size.meetingDetailMin, maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .searchable(text: $query, prompt: Text(searchPrompt))
                case .ask:
                    AskView()
                case .decisions:
                    DecisionThreadView()
                }
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
        .toolbar {
            if settings.knowledgeIndexEnabled {
                ToolbarItem(placement: .principal) {
                    Picker("Mode", selection: $mode) {
                        Text("Search").tag(Mode.search)
                        Text("Ask").tag(Mode.ask)
                        if settings.knowledgeGraphEnabled {
                            Text("Decisions").tag(Mode.decisions)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                if settings.knowledgeGraphEnabled {
                    ToolbarItem(placement: .automatic) {
                        Button("Graph", systemImage: "point.3.connected.trianglepath.dotted") {
                            navigation.showGraph()
                        }
                        .help("The map of your people, projects and folders now lives in Agent ▸ Graph.")
                    }
                }
            }
        }
        .task { if resolution.isEnabled, !resolution.hasLoaded { resolution.reload() } }
        .task(id: searchKey) { await runSearch() }
    }

    private var searchPrompt: String {
        searchesFiles
            ? "Search meetings, notes, conversations and your files"
            : "Search meetings, notes and conversations"
    }

    /// Whether the rail should offer files at all: the switch is on, a folder is listed, and
    /// something has been crawled.
    private var searchesFiles: Bool { fileIndexer.isAvailable }

    // MARK: - Rail

    private var rail: some View {
        List {
            Section("Sources") {
                ForEach(LibrarySource.all(includingFiles: searchesFiles)) { source in
                    facetRow(source.title, count: facets.count(source),
                             isOn: filter.sources.contains(source)) {
                        filter.sources.formSymmetricDifference([source])
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
            if !facets.people.isEmpty {
                Section("People") {
                    ForEach(sorted(facets.people), id: \.key) { person, count in
                        facetRow(person, count: count, isOn: filter.people.contains(person)) {
                            filter.people.formSymmetricDifference([person])
                        }
                    }
                }
            }
            if !facets.knowledge.speakers.isEmpty {
                Section("Speakers") {
                    ForEach(sorted(facets.knowledge.speakers), id: \.key) { speaker, count in
                        facetRow(speaker, count: count, isOn: filter.speakers.contains(speaker)) {
                            filter.speakers.formSymmetricDifference([speaker])
                        }
                    }
                }
            }
            if !facets.knowledge.headings.isEmpty {
                Section("Notes sections") {
                    ForEach(sorted(facets.knowledge.headings), id: \.key) { heading, count in
                        facetRow(heading, count: count, isOn: filter.headings.contains(heading)) {
                            filter.headings.formSymmetricDifference([heading])
                        }
                    }
                }
            }
            Section {
                if !filter.isEmpty {
                    Button("Clear filters") { filter = LibraryFilter() }
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
            if fileIndexer.isScanning {
                Label("Reading your folders…", systemImage: "folder.badge.gearshape")
            }
            Text("\(indexer.stats.chunks) passages")
            if searchesFiles {
                Text("\((fileIndexer.stats.files + fileIndexer.stats.folders).formatted()) files and folders")
            }
            if let error = indexer.lastError ?? problem {
                Text(error)
                    .foregroundStyle(DS.Color.warning)
            }
        }
        .font(DS.Font.caption)
        .foregroundStyle(DS.Color.textSecondary)
    }

    private var meetingFacets: [(id: String, title: String, count: Int)] {
        facets.knowledge.sources.compactMap { id, count in
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
                        : searchesFiles
                            ? "Find the passage where something was said, and the file it was about."
                            : "Find the passage where something was said, not just the meeting it was in."
                )
            } else if hasSearched {
                ContentUnavailableView.search(text: query)
            } else {
                Color.clear
            }
        } else {
            List(hits) { hit in
                Button { open(hit) } label: {
                    switch hit {
                    case .passage(let passage):
                        HitRow(hit: passage, source: sourceTitle(for: passage))
                    case .file(let file):
                        FileHitRow(hit: file)
                    }
                }
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
        case .routine: "Goal run"
        case .dictation: "Dictation"
        }
    }

    private func open(_ hit: LibraryHit) {
        switch hit {
        case .passage(let passage): open(passage)
        case .file(let file):
            // Shown in the Finder, never opened by us and never read: the whole promise of
            // the file index is that it knows names and dates and nothing else.
            let url = URL(fileURLWithPath: file.path)
            guard FileManager.default.fileExists(atPath: file.path) else {
                problem = "\(file.name) isn’t there any more."
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
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

    /// Everything a result depends on. `fileRevision` and `folderRevision` are why adding or
    /// removing a folder — or switching the whole thing off — re-runs the search on the spot:
    /// a folder the user has just taken away must stop answering now, not after a restart.
    private struct SearchKey: Equatable {
        let query: String
        let filter: LibraryFilter
        let revision: Int
        let fileRevision: Int
        let folderRevision: Int
        let filesAvailable: Bool
        let people: Int
        let enabled: Bool
    }

    private var searchKey: SearchKey {
        SearchKey(query: query, filter: filter, revision: indexer.revision,
                  fileRevision: fileIndexer.revision, folderRevision: folders.revision,
                  filesAvailable: searchesFiles, people: resolution.revision,
                  enabled: settings.knowledgeIndexEnabled)
    }

    /// Person display name → every speaker label that turned out to be them.
    private var aliases: [String: [String]] {
        var map: [String: [String]] = [:]
        for person in resolution.people {
            let labels = Set(person.aliases + [person.name]).sorted()
            guard !labels.isEmpty else { continue }
            map[person.name, default: []].append(contentsOf: labels)
        }
        return map.mapValues { Array(Set($0)).sorted() }
    }

    /// Off the main actor, a keystroke after the last one: a search is a few milliseconds,
    /// but it still waits behind an indexing transaction — and now behind a file crawl's.
    private func runSearch() async {
        guard settings.knowledgeIndexEnabled else { return }
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        let searcher = LibrarySearch(passages: indexer.searcher, files: LiveFileRetrieval(), aliases: aliases)
        let totalTrace = LatencyTrace.start(.searchTotal)
        // Embedding the query may wait on a model; neither SQL leg does.
        let embedTrace = LatencyTrace.start(.searchEmbed)
        let embedBegan = Date()
        let request = await searcher.prepare(text: query, filter: filter)
        let embedSeconds = Date().timeIntervalSince(embedBegan)
        embedTrace.end(note: "vector=\(request.passages.vector == nil ? "none" : "ready")")
        guard !Task.isCancelled else { return }
        let queryTrace = LatencyTrace.start(.searchQuery)
        let queryBegan = Date()
        let result = await Task.detached(priority: .userInitiated) { () -> Result<([LibraryHit], LibraryFacets), Error> in
            Result { (try searcher.search(request), try searcher.facets(request)) }
        }.value
        let querySeconds = Date().timeIntervalSince(queryBegan)
        guard !Task.isCancelled else { return }
        switch result {
        case .success(let (found, counts)):
            hits = found
            facets = counts
            problem = nil
            queryTrace.end(note: "hits=\(found.count)")
            let total = totalTrace.end(note: "hits=\(found.count)")
            if !KnowledgeFTSQuery.tokens(query).isEmpty {
                let fileHits = found.filter { !$0.isPassage }.count
                Log.app.info("""
                    search · embed \(embedSeconds, format: .fixed(precision: 3))s · \
                    query \(querySeconds, format: .fixed(precision: 3))s · \
                    total \(total.durationSeconds, format: .fixed(precision: 3))s · \
                    hits \(found.count, privacy: .public) · files \(fileHits, privacy: .public)
                    """)
            }
        case .failure(let error):
            problem = error.localizedDescription
            queryTrace.end(note: "error")
            totalTrace.end(note: "error")
            Log.app.info("search · failed · \(error.localizedDescription, privacy: .public)")
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

/// One of the user's own files or folders: its name, the folder it sits in, and when it last
/// changed. No snippet, because there is nothing to snippet — this row is a name that matched,
/// not a sentence, and it says so rather than letting a name read like a quotation.
private struct FileHitRow: View {
    let hit: FileHit

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                Image(systemName: hit.isDirectory ? "folder" : hit.category.symbol)
                    .foregroundStyle(DS.Color.textSecondary)
                Text(hit.name)
                    .font(DS.Font.headline)
                    .lineLimit(1)
                Spacer(minLength: DS.Space.s)
                if let modified = hit.modifiedAt {
                    Text(modified.formatted(date: .abbreviated, time: .shortened))
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textTertiary)
                }
            }
            Text(hit.isDirectory ? "Folder on your Mac" : "File on your Mac")
                .font(DS.Font.chip)
                .foregroundStyle(DS.Color.textSecondary)
            HStack(spacing: DS.Space.xs) {
                Text(folder)
                    .lineLimit(1)
                    .truncationMode(.head)
                if let size = hit.size, !hit.isDirectory {
                    Text("·")
                    Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                }
            }
            .font(DS.Font.caption)
            .foregroundStyle(DS.Color.textTertiary)
            .frame(maxWidth: DS.Size.readingWidth, alignment: .leading)
        }
        .padding(.vertical, DS.Space.xs)
        .contentShape(Rectangle())
        .help("Show in Finder")
    }

    /// The containing folder, written the way someone would say it: `~/Documents/Work`.
    private var folder: String {
        let parent = (hit.path as NSString).deletingLastPathComponent
        return (parent as NSString).abbreviatingWithTildeInPath
    }
}

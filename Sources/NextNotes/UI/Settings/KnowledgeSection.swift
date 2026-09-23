import AppKit
import SwiftUI

/// Settings → Agent → Search and knowledge index.
///
/// The switch and what it covers, how much is indexed, and *Rebuild index*. The index is
/// derived from the meeting folders and conversation history, so rebuilding it loses
/// nothing but the time it takes — except conversation turns older than the history the
/// Agent keeps on disk, which the footer says.
struct KnowledgeSection: View {
    @State private var settings = Settings.shared
    @State private var indexer = KnowledgeIndexer.shared
    @State private var confirmingRebuild = false

    var body: some View {
        Group {
            indexSection
            IndexedFoldersSection()
        }
    }

    @ViewBuilder private var indexSection: some View {
        Section {
            Toggle("Index meetings for search", isOn: $settings.knowledgeIndexEnabled)
            Toggle("Include Agent conversations", isOn: $settings.knowledgeIncludeConversations)
                .disabled(!settings.knowledgeIndexEnabled)
            Toggle("Include dictation", isOn: $settings.knowledgeIncludeDictation)
                .disabled(!settings.knowledgeIndexEnabled)
            Toggle("Include reminder and goal results", isOn: $settings.knowledgeIncludeRoutines)
                .disabled(!settings.knowledgeIndexEnabled)

            Toggle("Let the Agent search and answer from the index", isOn: $settings.knowledgeAgentToolsEnabled)
                .disabled(!settings.knowledgeIndexEnabled)
            Toggle("Extract a life map from notes, dictation and chats", isOn: $settings.knowledgeGraphEnabled)
                .disabled(!settings.knowledgeIndexEnabled)
            if settings.knowledgeGraphEnabled {
                Toggle("Let a cloud model read the life map", isOn: $settings.knowledgeGraphCloudConsent)
                    .disabled(!settings.knowledgeIndexEnabled)
            }

            searchByMeaningRow

            LabeledContent("Indexed") {
                Text(summary)
                    .foregroundStyle(DS.Color.textSecondary)
            }
            if let error = indexer.lastError {
                Text(error)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.warning)
            }
            HStack {
                Spacer()
                Button("Rebuild index…") { confirmingRebuild = true }
                    .disabled(!settings.knowledgeIndexEnabled || indexer.isIndexing)
                    .confirmationDialog("Delete the knowledge index and build it again?",
                                        isPresented: $confirmingRebuild) {
                        Button("Rebuild index", role: .destructive) {
                            Task { await indexer.rebuild() }
                        }
                    }
            }
        } header: {
            Text("Search and knowledge index")
        } footer: {
            SettingsNote(
                text: "Finished meetings, their notes and ended Agent conversations are split into "
                    + "passages in knowledge.sqlite on this Mac, for Search and for the Agent's recall. "
                    + "Indexing waits while anything is recording. Deleting a meeting, clearing the "
                    + "conversation or forgetting everything removes its passages. Rebuilding reads every "
                    + "meeting again; conversations older than the Agent's saved history cannot be re-read. "
                    + "Letting the Agent use the index adds search_knowledge to what it can look up without "
                    + "asking (when looking things up is allowed), to routines, and to Ask, whose answers cite "
                    + "the passage each sentence came from. "
                    + "When a cloud model answers, the passages recall, search or Ask finds are sent with the prompt. "
                    + "Semantic search adds vectors computed on this Mac after you download a model; "
                    + "it waits while anything is recording or the notes model is loaded. "
                    + "Extracting reads each meeting's notes — and, when included, dictations and Agent chats — "
                    + "once more with the on-device model — never a cloud one — and saves notes.json / life.json: "
                    + "decisions you can follow across meetings, action items you own with a date, and a life map of "
                    + "people, projects, places, activities, goals and preferences. Tool and MCP payloads are not "
                    + "scraped into the graph; only user-authored passages and plain Agent replies. Nothing is "
                    + "created for you. What it extracts stays on this Mac: a cloud model the Agent, Ask or a routine "
                    + "uses cannot read it unless you let it. "
                    + "People mentioned by different names — an address, initials, a first name, an unnamed "
                    + "speaker whose voice matches — are merged into one only on strong evidence; each meeting's "
                    + "speaker voice prints are saved beside it while this is on. Decisions → People lists every "
                    + "merge with its reason, and Split undoes one. "
                    + "With extraction on, Agent → Graph opens the whole map (every recent node), what is "
                    + "around a focus, and — for a person — their meetings against time.",
                orb: indexer.isIndexing ? .searching : nil
            )
        }
        .onAppear { indexer.refreshStats() }
    }

    private var selectedEmbedder: KnowledgeEmbedderChoice {
        KnowledgeEmbedderChoice(rawValue: settings.knowledgeEmbedder) ?? .none
    }

    /// One compact line: what "search by meaning" is doing right now, and a link to the
    /// Models tab, which owns the picker, the download and the licence — every downloadable
    /// model lives there now, so this section only says which one is in play.
    @ViewBuilder private var searchByMeaningRow: some View {
        HStack(spacing: DS.Space.xs) {
            Text(searchByMeaningSummary)
                .font(DS.Font.callout)
            Text("·")
                .foregroundStyle(DS.Color.textSecondary)
            Button("Manage in Models") {
                NavigationState.shared.selectedSettingsTab = .models
            }
            .buttonStyle(.link)
            .font(DS.Font.callout)
        }
    }

    private var searchByMeaningSummary: String {
        selectedEmbedder == .none
            ? "Search by meaning — off"
            : "Search by meaning — uses \(plainEmbedderName(selectedEmbedder))"
    }

    /// The same plain names the Models tab uses for these two choices, so the two screens
    /// never disagree about what to call them. Duplicated rather than shared from the enum
    /// itself, which stays technical (`KnowledgeEmbedderChoice.title`) for the places that
    /// still want the model name.
    private func plainEmbedderName(_ choice: KnowledgeEmbedderChoice) -> String {
        switch choice {
        case .none: "Off"
        case .potion: "Fast search by meaning"
        case .embeddinggemma: "Best search by meaning"
        }
    }

    private var summary: String {
        let stats = indexer.stats
        guard stats.chunks > 0 else { return indexer.isIndexing ? "Indexing…" : "Nothing yet" }
        let size = ByteCountFormatter.string(fromByteCount: stats.bytes, countStyle: .file)
        let pending = indexer.isIndexing ? " · \(indexer.pending.count) left" : ""
        let vectors = stats.embedded > 0 ? " · \(stats.embedded) with vectors" : ""
        return "\(stats.chunks) passages from \(stats.sources) sources\(vectors) · \(size)\(pending)"
    }
}

/// Settings → Agent → "Folders your assistant can look through".
///
/// Plain language throughout: no "index", no "crawler", no "UTType". What the user is being
/// asked is a question about trust — which folders may this thing see the names of — and the
/// answer to it is a list with a plus and a minus, three one-click suggestions, and a sentence
/// saying that only names are read.
struct IndexedFoldersSection: View {
    @State private var folders = IndexedFoldersStore.shared
    @State private var index = FileIndexer.shared

    var body: some View {
        Section {
            Toggle("Let your assistant look through your folders", isOn: $folders.isEnabled)
            if folders.isEnabled {
                Toggle("Let a cloud model see these folder and file names", isOn: $folders.cloudConsent)
            }

            ForEach(folders.folders, id: \.path) { folder in
                folderRow(folder)
            }

            if folders.folders.isEmpty {
                Text("No folders yet.")
                    .font(DS.Font.callout)
                    .foregroundStyle(DS.Color.textSecondary)
            }

            if !suggestions.isEmpty {
                HStack(spacing: DS.Space.s) {
                    Text("Suggested")
                        .font(DS.Font.callout)
                        .foregroundStyle(DS.Color.textSecondary)
                    ForEach(suggestions, id: \.path) { folder in
                        Button("＋ \(folder.lastPathComponent)") { folders.add(folder) }
                            .buttonStyle(.bordered)
                    }
                    Spacer()
                }
            }

            HStack {
                if index.isScanning {
                    Label(index.scanningFolder.map { "Looking through \($0)…" } ?? "Looking…",
                          systemImage: "arrow.triangle.2.circlepath")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                } else if let scanned = index.stats.scannedAt, !folders.folders.isEmpty {
                    Text("Last checked \(scanned.formatted(date: .abbreviated, time: .shortened))")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                }
                Spacer()
                Button("Add a folder…") { chooseFolder() }
                Button("Check again") { index.scanAll() }
                    .disabled(folders.folders.isEmpty || !folders.isEnabled || index.isScanning)
            }

            if let error = index.lastError {
                Text(error)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.warning)
            }
        } header: {
            Text("Folders your assistant can look through")
        } footer: {
            SettingsNote(
                text: "Only the names, sizes and dates of what is in these folders are read — never what "
                    + "is inside a file. That list is kept on this Mac, in its own file, and is how your "
                    + "assistant can answer \"where did I put the lease?\" without you telling it where to "
                    + "look. Hidden files, apps' innards and developer folders are skipped. Remove a folder "
                    + "and everything it added is forgotten straight away. The first time you add your "
                    + "Desktop, Documents or Downloads, macOS will ask you to allow it. "
                    + "The on-device assistant can always look through them. A cloud model is told nothing "
                    + "about them and cannot look, unless you switch that on above — folder and file names "
                    + "say a lot about your work and the people in it, so that is your call to make.",
                orb: index.isScanning ? .searching : nil
            )
        }
        .onAppear {
            index.refreshStats()
            folders.refreshAccessProblems()
            if folders.isEnabled { index.start() }
        }
    }

    /// One row. The access verdict is read once and reused for both the text and its colour —
    /// it is a cached value now, but a row should not ask the same question twice either way.
    private func folderRow(_ folder: URL) -> some View {
        let problem = folders.accessProblem(for: folder)
        return HStack(spacing: DS.Space.s) {
            Image(systemName: "folder")
                .foregroundStyle(DS.Color.graphFolder)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(folder.lastPathComponent)
                    .font(DS.Font.callout)
                Text(problem ?? summary(for: folder))
                    .font(DS.Font.caption)
                    .foregroundStyle(problem == nil ? DS.Color.textSecondary : DS.Color.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DS.Space.s)
            Button("Remove") { folders.remove(folder) }
                .buttonStyle(.borderless)
                .accessibilityLabel("Stop looking through \(folder.lastPathComponent)")
        }
    }

    /// One line per folder: what was found and when. An access problem replaces it; the caller
    /// has already read that verdict, so this does not ask again.
    private func summary(for folder: URL) -> String {
        guard let state = index.rootStates.first(where: { $0.root == folder.path }) else {
            return index.isScanning ? "Looking…" : "Not checked yet"
        }
        var parts = ["\(state.files.formatted()) files in \(state.folders.formatted()) folders"]
        if let scanned = state.scannedAt {
            parts.append("checked \(scanned.formatted(date: .abbreviated, time: .shortened))")
        }
        if let note = state.note { parts.append(note) }
        return parts.joined(separator: " · ")
    }

    private var suggestions: [URL] {
        IndexedFoldersStore.suggested.filter { candidate in
            !folders.folders.contains { $0.path == candidate.path }
        }
    }

    /// The system's own folder chooser. Nothing is read until the user picks one, and picking
    /// one through this panel is also what makes macOS grant access to it.
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose a folder your assistant may look through. Only names are read."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { folders.add(url) }
    }
}

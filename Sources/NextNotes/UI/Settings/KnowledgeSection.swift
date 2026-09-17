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
    @State private var models = LocalModelStore.shared

    var body: some View {
        Section {
            Toggle("Index meetings for search", isOn: $settings.knowledgeIndexEnabled)
            Toggle("Include Agent conversations", isOn: $settings.knowledgeIncludeConversations)
                .disabled(!settings.knowledgeIndexEnabled)
            Toggle("Include dictation", isOn: $settings.knowledgeIncludeDictation)
                .disabled(!settings.knowledgeIndexEnabled)
            Toggle("Include routine results", isOn: $settings.knowledgeIncludeRoutines)
                .disabled(!settings.knowledgeIndexEnabled)

            Picker("Semantic search", selection: embedderChoice) {
                ForEach(KnowledgeEmbedderChoice.allCases) { choice in
                    Text(choice.title).tag(choice)
                }
            }
            .disabled(!settings.knowledgeIndexEnabled)
            if selectedEmbedder != .none {
                embeddingModelRow
            }

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
                    + "When a cloud model answers, the passages recall finds are sent with the prompt. "
                    + "Semantic search adds vectors computed on this Mac after you download a model; "
                    + "it waits while anything is recording or the notes model is loaded.",
                orb: indexer.isIndexing ? .searching : nil
            )
        }
        .onAppear { indexer.refreshStats() }
    }

    private var selectedEmbedder: KnowledgeEmbedderChoice {
        KnowledgeEmbedderChoice(rawValue: settings.knowledgeEmbedder) ?? .none
    }

    private var embedderChoice: Binding<KnowledgeEmbedderChoice> {
        Binding(
            get: { selectedEmbedder },
            set: { choice in
                settings.knowledgeEmbedder = choice.rawValue
                models.selectEmbeddingModel(choice)
            }
        )
    }

    /// Download state, the button, and the licence — shown before anything is fetched.
    @ViewBuilder private var embeddingModelRow: some View {
        let choice = selectedEmbedder
        let state = models.embeddingModelChoice == choice
            ? models.embeddingModelState
            : (EmbeddingModels.isDownloaded(choice) ? .ready : .notDownloaded)
        LabeledContent("Model") {
            switch state {
            case .ready:
                Text("Downloaded").foregroundStyle(DS.Color.textSecondary)
            case .preparing(let message):
                HStack(spacing: DS.Space.s) {
                    Text(message).foregroundStyle(DS.Color.textSecondary)
                    Button("Cancel") { models.cancelEmbeddingModel() }
                }
            case .notDownloaded, .failed:
                Button("Download (\(EmbeddingModels.displaySize(choice)))") {
                    models.prepareEmbeddingModel(choice)
                }
                .disabled(!settings.knowledgeIndexEnabled)
            }
        }
        if case .failed(let reason) = state {
            Text(reason)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.warning)
        }
        if let licence = EmbeddingModels.licence(choice) {
            HStack(spacing: DS.Space.xs) {
                Text("Licence:")
                Link(licence.name, destination: licence.url)
                Text("·")
                Link("Model card", destination: licence.source)
            }
            .font(DS.Font.caption)
            .foregroundStyle(DS.Color.textSecondary)
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

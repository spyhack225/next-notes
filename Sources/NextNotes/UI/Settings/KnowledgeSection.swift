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
        Section {
            Toggle("Index meetings for search", isOn: $settings.knowledgeIndexEnabled)
            Toggle("Include Agent conversations", isOn: $settings.knowledgeIncludeConversations)
                .disabled(!settings.knowledgeIndexEnabled)
            Toggle("Include dictation", isOn: $settings.knowledgeIncludeDictation)
                .disabled(!settings.knowledgeIndexEnabled)
            Toggle("Include routine results", isOn: $settings.knowledgeIncludeRoutines)
                .disabled(!settings.knowledgeIndexEnabled)

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
                    + "When a cloud model answers, the passages recall finds are sent with the prompt.",
                orb: indexer.isIndexing ? .searching : nil
            )
        }
        .onAppear { indexer.refreshStats() }
    }

    private var summary: String {
        let stats = indexer.stats
        guard stats.chunks > 0 else { return indexer.isIndexing ? "Indexing…" : "Nothing yet" }
        let size = ByteCountFormatter.string(fromByteCount: stats.bytes, countStyle: .file)
        let pending = indexer.isIndexing ? " · \(indexer.pending.count) left" : ""
        return "\(stats.chunks) passages from \(stats.sources) sources · \(size)\(pending)"
    }
}

import SwiftUI

/// Every model that lives on disk, in one place.
///
/// Downloads are deliberate rather than implicit: fetching hundreds of megabytes on the
/// first hold of the key looks exactly like a hang.
struct ModelsSettingsTab: View {
    @State private var settings = Settings.shared
    @State private var models = LocalModelStore.shared

    var body: some View {
        Form {
            Section {
                ModelStatusRow(
                    title: "Parakeet",
                    detail: "Batch transcription through FluidAudio · ~470 MB",
                    state: models.parakeetState,
                    downloadTitle: "Download…"
                ) {
                    models.prepareParakeet()
                }

                ModelStatusRow(
                    title: "S1-mini",
                    detail: "Transcript cleanup by Superwhisper · \(S1MiniModels.spec.displaySize)",
                    state: models.s1MiniState,
                    downloadTitle: "Download…"
                ) {
                    models.prepareS1Mini()
                }

                ModelStatusRow(
                    title: NotesModels.spec.displayName,
                    detail: "Meeting notes · \(NotesModels.spec.displaySize)",
                    state: models.notesModelState,
                    downloadTitle: "Download…"
                ) {
                    models.prepareNotesModel()
                }

                ModelStatusRow(
                    title: "Speaker models",
                    detail: "Telling meeting participants apart · through FluidAudio",
                    state: models.diarizerState,
                    downloadTitle: "Download…"
                ) {
                    models.prepareDiarizer()
                }
            } header: {
                Text("On-device models")
            } footer: {
                SettingsNote(text: "\(NotesModels.spec.displayName) reads a whole meeting at "
                             + "once, which is what lets it tell a decision from a "
                             + "suggestion. Without it, notes are written by the Apple "
                             + "Foundation Model in pieces.")
            }

            Section {
                Toggle("Run local language models on the GPU", isOn: $settings.llmMetalEnabled)
            } header: {
                Text("Acceleration")
            } footer: {
                SettingsNote(text: "Takes effect at next launch: the llama.cpp backend is "
                             + "initialised once per process. Turn this off if Metal shader "
                             + "compilation wedges.")
            }
        }
        .formStyle(.grouped)
        .onAppear { models.refresh() }
    }
}

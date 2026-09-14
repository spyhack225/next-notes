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

                ModelStatusRow(
                    title: "Wake phrase",
                    detail: "Local sherpa-onnx keyword model · \(WakeWordModels.archive.displaySize)",
                    state: models.wakeWordState,
                    downloadTitle: "Download…"
                ) {
                    models.prepareWakeWord()
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
                LabeledContent {
                    Label("Active", systemImage: "checkmark.circle.fill")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.success)
                } label: {
                    Text("Apple system voice")
                    Text("Agent speech · built into macOS")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                }

                LabeledContent {
                    Label(
                        kokoroBenchmarkFilesPresent ? "Benchmark files present" : "Benchmark only",
                        systemImage: "waveform"
                    )
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
                } label: {
                    Text("Kokoro 82M")
                    Text("Experimental local speech model · ONNX benchmark")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                }
            } header: {
                Text("Speech synthesis")
            } footer: {
                SettingsNote(text: "Kokoro's benchmark files do not power Agent speech. "
                             + "Its Core ML runtime can crash on macOS 26.5, so the "
                             + "Apple system voice remains active on this Mac.")
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

    private var kokoroBenchmarkFilesPresent: Bool {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/NextNotesTTS/kokoro-model")
        return FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("kokoro-v1.0.onnx").path
        ) && FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("voices-v1.0.bin").path
        )
    }
}

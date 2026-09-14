import AVFoundation
import SwiftUI

/// Every model that lives on disk, in one place.
///
/// Downloads are deliberate rather than implicit: fetching hundreds of megabytes on the
/// first hold of the key looks exactly like a hang.
struct ModelsSettingsTab: View {
    @State private var settings = Settings.shared
    @State private var models = LocalModelStore.shared
    @State private var pocket = PocketAgentVoice.shared
    @State private var catalog = OpenRouterCatalog.shared
    @State private var openRouterKeyInput = ""
    @State private var openRouterKeyStatus: String?
    @State private var hasOpenRouterKey = OpenRouterKeyStore.key != nil

    var body: some View {
        Form {
            Section {
                Link("Get an OpenRouter API key", destination: URL(string: "https://openrouter.ai/settings/keys")!)
                SecureField("OpenRouter API key", text: $openRouterKeyInput)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: DS.Space.s) {
                    Button("Save key") {
                        do {
                            try OpenRouterKeyStore.save(openRouterKeyInput)
                            openRouterKeyInput = ""
                            hasOpenRouterKey = true
                            openRouterKeyStatus = "Saved in Keychain"
                            Task { await catalog.refresh() }
                        } catch {
                            openRouterKeyStatus = error.localizedDescription
                        }
                    }
                    .disabled(openRouterKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if hasOpenRouterKey {
                        Button("Remove key") {
                            OpenRouterKeyStore.clear()
                            catalog.clear()
                            hasOpenRouterKey = false
                            openRouterKeyStatus = "Key removed"
                        }
                        Button("Refresh models") { Task { await catalog.refresh() } }
                    }
                }
                if let openRouterKeyStatus { Text(openRouterKeyStatus).font(DS.Font.caption) }
                if let problem = catalog.problem {
                    Text(problem).foregroundStyle(DS.Color.warning)
                }
                LabeledContent("Catalog", value: "\(catalog.models.count) text models")
            } header: {
                Text("OpenRouter")
            } footer: {
                SettingsNote(text: "Optional cloud models for Agent answers and meeting notes. "
                    + "Your key stays in this Mac’s Keychain. When selected, prompts and "
                    + "meeting transcripts are sent to OpenRouter and may incur charges. "
                    + "Capability tags come from OpenRouter model metadata.")
            }

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
                    detail: "Meeting notes and Agent answers · \(NotesModels.spec.displaySize)",
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
                Picker("Speech engine", selection: $settings.agentVoiceEngine) {
                    Text("macOS voices").tag("apple")
                    Text("Pocket TTS · local neural voice").tag("pocket")
                        .disabled(!pocket.isReady && settings.agentVoiceEngine != "pocket")
                }
                Picker("Agent voice", selection: $settings.agentVoiceIdentifier) {
                    Text("System default").tag("")
                    ForEach(availableVoices, id: \.identifier) { voice in
                        Text("\(voice.name) · \(voice.language)\(qualityLabel(voice))")
                            .tag(voice.identifier)
                    }
                }
                .disabled(settings.agentVoiceEngine == "pocket")
                if settings.agentVoiceEngine == "pocket" || pocket.isReady {
                    Picker("Pocket voice", selection: $settings.agentPocketVoice) {
                        Text("Alba").tag("alba")
                        Text("Azelma").tag("azelma")
                        Text("Cosette").tag("cosette")
                        Text("Javert").tag("javert")
                    }
                }
                if !pocket.isReady {
                    Button(pocket.isPreparing ? "Preparing Pocket TTS…"
                           : "Prepare Pocket TTS · about 550 MB on first use") {
                        Task {
                            await pocket.prepare()
                            if pocket.isReady { settings.agentVoiceEngine = "pocket" }
                        }
                    }
                    .disabled(pocket.isPreparing)
                }
                if let error = pocket.errorMessage {
                    Text(error).foregroundStyle(DS.Color.warning)
                }
                Button("Preview voice") {
                    AgentSpeechSynthesizer.shared.speak(
                        "Hi, I'm Next. I can check your calendar and help with your notes."
                    )
                }
                Button("Stop preview") { AgentSpeechSynthesizer.shared.stop() }
                LabeledContent {
                    Label(settings.agentVoiceEngine == "apple" ? "Active" : "Available",
                          systemImage: "checkmark.circle.fill")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.success)
                } label: {
                    Text("Apple system voice")
                    Text("Agent speech · built into macOS")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                }

                LabeledContent {
                    Label(pocket.isReady ? "Ready" : "Optional download", systemImage: "waveform")
                        .font(DS.Font.caption)
                } label: {
                    Text("Pocket TTS")
                    Text("Neural speech · FluidAudio · local, four voices")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                }

                LabeledContent {
                    Label(
                        kokoroBenchmarkFilesPresent ? "Benchmark files present" : "No benchmark files",
                        systemImage: "waveform"
                    )
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
                } label: {
                    Text("Kokoro 82M")
                    Text("ONNX benchmark · not selectable for Agent speech")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                }
            } header: {
                Text("Speech synthesis")
            } footer: {
                SettingsNote(text: "Choose and preview an installed macOS voice, or download "
                    + "Pocket TTS for more natural local speech. Initial download is about "
                    + "550 MB. Pocket TTS model by Kyutai, CC BY 4.0. "
                    + kokoroExplanation)
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
        .onAppear {
            models.refresh()
            if settings.agentVoiceEngine == "pocket" {
                Task { await pocket.prepare() }
            }
        }
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

    private var availableVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en-") }
            .sorted { lhs, rhs in
                if lhs.quality != rhs.quality { return lhs.quality.rawValue > rhs.quality.rawValue }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    private func qualityLabel(_ voice: AVSpeechSynthesisVoice) -> String {
        switch voice.quality {
        case .premium: " · Premium"
        case .enhanced: " · Enhanced"
        default: ""
        }
    }

    private var kokoroExplanation: String {
        let activeEngine = settings.agentVoiceEngine == "pocket"
            ? "Pocket TTS" : "Apple system speech"
        let version = ProcessInfo.processInfo.operatingSystemVersion
        if version.majorVersion == 26 && (4...5).contains(version.minorVersion) {
            return "These Kokoro files were downloaded for a separate benchmark and do not "
                + "power Agent speech. Its Core ML runtime can crash on this macOS version. "
                + "\(activeEngine) remains active."
        }
        return "These Kokoro files were downloaded for a separate benchmark and do not "
            + "power Agent speech. Playback and interruption have not been integrated or "
            + "validated in this app. \(activeEngine) remains active."
    }
}

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
    @State private var kokoro = KokoroAgentVoice.shared
    @State private var isPreviewing = false
    @State private var previewTask: Task<Void, Never>?
    @State private var catalog = OpenRouterCatalog.shared
    @State private var openRouterKeyInput = ""
    @State private var openRouterKeyStatus: String?
    @State private var hasOpenRouterKey = false
    @State private var isCheckingOpenRouterKey = true
    @State private var isChangingOpenRouterKey = false

    var body: some View {
        Form {
            Section {
                Link("Get an OpenRouter API key", destination: URL(string: "https://openrouter.ai/settings/keys")!)
                SecureField("OpenRouter API key", text: $openRouterKeyInput)
                    .textFieldStyle(.roundedBorder)
                HStack(spacing: DS.Space.s) {
                    Button("Save key") {
                        let value = openRouterKeyInput
                        isChangingOpenRouterKey = true
                        Task {
                            defer { isChangingOpenRouterKey = false }
                            do {
                                try await OpenRouterKeyStore.saveAsync(value)
                                OpenRouterKeyStore.invalidateCache()
                                openRouterKeyInput = ""
                                hasOpenRouterKey = true
                                openRouterKeyStatus = "Saved in Keychain"
                                await catalog.refresh()
                            } catch {
                                openRouterKeyStatus = error.localizedDescription
                            }
                        }
                    }
                    .disabled(isChangingOpenRouterKey || openRouterKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if hasOpenRouterKey {
                        Button("Remove key") {
                            isChangingOpenRouterKey = true
                            Task {
                                defer { isChangingOpenRouterKey = false }
                                do {
                                    try await OpenRouterKeyStore.clearAsync()
                                    OpenRouterKeyStore.invalidateCache()
                                    catalog.clear()
                                    hasOpenRouterKey = false
                                    openRouterKeyStatus = "Key removed"
                                } catch {
                                    openRouterKeyStatus = error.localizedDescription
                                }
                            }
                        }
                        .disabled(isChangingOpenRouterKey)
                        Button("Refresh models") { Task { await catalog.refresh() } }
                    }
                }
                if let openRouterKeyStatus { Text(openRouterKeyStatus).font(DS.Font.caption) }
                if isCheckingOpenRouterKey { Text("Checking saved key…").font(DS.Font.caption) }
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

            speechSynthesis

            PersonaSection()

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
            Task {
                if !SelfTest.isRunning {
                    let found = await OpenRouterKeyStore.hasKeyAsync()
                    if found { hasOpenRouterKey = true }
                }
                isCheckingOpenRouterKey = false
            }
            if settings.agentVoiceEngine == "pocket" {
                Task { await pocket.prepare() }
            } else if settings.agentVoiceEngine == "kokoro", KokoroAgentVoice.isSupportedOS {
                Task { await kokoro.prepare() }
            }
        }
        .onDisappear { if isPreviewing { stopPreview() } }
    }

    private enum VoiceEngine: String, CaseIterable, Identifiable {
        case apple, pocket, kokoro
        var id: String { rawValue }
        var name: String {
            switch self {
            case .apple: "macOS"
            case .pocket: "Pocket"
            case .kokoro: "Kokoro"
            }
        }
        var icon: String {
            switch self {
            case .apple: "speaker.wave.2"
            case .pocket: "waveform"
            case .kokoro: "waveform.path"
            }
        }
    }

    private var speechSynthesis: some View {
        Section {
            HStack(spacing: DS.Space.s) {
                ForEach(VoiceEngine.allCases) { engine in
                    engineChoice(engine)
                }
            }

            if pocket.isPreparing || kokoro.isPreparing {
                ProgressView(pocket.isPreparing ? "Preparing Pocket TTS…" : "Preparing Kokoro…")
            }
            if let error = pocket.errorMessage {
                Text(error).font(DS.Font.caption).foregroundStyle(DS.Color.warning)
            }
            if let error = kokoro.errorMessage, KokoroAgentVoice.isSupportedOS {
                Text(error).font(DS.Font.caption).foregroundStyle(DS.Color.warning)
            }

            switch settings.agentVoiceEngine {
            case "pocket":
                HStack(spacing: DS.Space.s) {
                    Text("Voice")
                    Spacer()
                    ForEach(["alba", "azelma", "cosette", "javert"], id: \.self) { voice in
                        Button {
                            stopPreview()
                            settings.agentPocketVoice = voice
                        } label: {
                            Label(voice.capitalized,
                                  systemImage: settings.agentPocketVoice == voice
                                      ? "checkmark.circle.fill" : "circle")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            case "kokoro":
                LabeledContent("Voice", value: "Heart")
            default:
                Picker("Voice", selection: $settings.agentVoiceIdentifier) {
                    Text("System default").tag("")
                    ForEach(availableVoices, id: \.identifier) { voice in
                        Text("\(voice.name) · \(voice.language)\(qualityLabel(voice))")
                            .tag(voice.identifier)
                    }
                }
                .onChange(of: settings.agentVoiceIdentifier) { _, _ in stopPreview() }
            }

            HStack(spacing: DS.Space.s) {
                Button {
                    if isPreviewing { stopPreview() }
                    else { startPreview() }
                } label: {
                    Label(isPreviewing ? "Stop preview" : "Preview voice",
                          systemImage: isPreviewing ? "stop.fill" : "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canPreviewVoice)
                Text(activeVoiceDescription)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
            }
        } header: {
            Text("Speech synthesis")
        } footer: {
            SettingsNote(text: voiceExplanation)
        }
    }

    private func engineChoice(_ engine: VoiceEngine) -> some View {
        let selected = settings.agentVoiceEngine == engine.rawValue
        let unavailable = engine == .kokoro && !KokoroAgentVoice.isSupportedOS
        return Button {
            select(engine)
        } label: {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Label(engine.name, systemImage: engine.icon)
                    .font(DS.Font.callout)
                Text(engineStatus(engine))
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.Space.s)
            .background(DS.Color.groupedFill, in: RoundedRectangle(cornerRadius: DS.Radius.card))
            .overlay {
                RoundedRectangle(cornerRadius: DS.Radius.card)
                    .strokeBorder(selected ? DS.Color.accent : DS.Color.separator,
                                  lineWidth: DS.Size.voiceChoiceBorder)
            }
        }
        .buttonStyle(.plain)
        .disabled(unavailable || (engine == .pocket && pocket.isPreparing)
                  || (engine == .kokoro && kokoro.isPreparing))
        .help(unavailable ? KokoroAgentVoice.unavailableMessage : "Use \(engine.name) for Agent speech")
    }

    private func engineStatus(_ engine: VoiceEngine) -> String {
        switch engine {
        case .apple: "Built in"
        case .pocket: pocket.isReady ? "4 voices · ready" : "4 voices · download"
        case .kokoro:
            KokoroAgentVoice.isSupportedOS
                ? (kokoro.isReady ? "Heart · ready" : "Heart · download")
                : "Needs macOS 26.6"
        }
    }

    private func select(_ engine: VoiceEngine) {
        stopPreview()
        switch engine {
        case .apple:
            settings.agentVoiceEngine = engine.rawValue
        case .pocket:
            if pocket.isReady { settings.agentVoiceEngine = engine.rawValue }
            else {
                Task {
                    await pocket.prepare()
                    if pocket.isReady { settings.agentVoiceEngine = engine.rawValue }
                }
            }
        case .kokoro:
            guard KokoroAgentVoice.isSupportedOS else { return }
            if kokoro.isReady { settings.agentVoiceEngine = engine.rawValue }
            else {
                Task {
                    await kokoro.prepare()
                    if kokoro.isReady { settings.agentVoiceEngine = engine.rawValue }
                }
            }
        }
    }

    private var activeVoiceDescription: String {
        switch settings.agentVoiceEngine {
        case "pocket": settings.agentPocketVoice.capitalized
        case "kokoro": "Kokoro · Heart"
        default:
            availableVoices.first(where: { $0.identifier == settings.agentVoiceIdentifier })?.name
                ?? "macOS system default"
        }
    }

    private var voiceExplanation: String {
        if !KokoroAgentVoice.isSupportedOS {
            return "Pocket TTS and macOS voices work now. Kokoro is disabled on macOS 26.4–26.5 "
                + "because its Core ML runtime can crash; macOS 26.6 is required."
        }
        return "Choose one engine, then a voice, and preview it here. Pocket TTS downloads "
            + "about 550 MB on first use; Kokoro downloads its Core ML model when selected."
    }

    private func startPreview() {
        guard canPreviewVoice else { return }
        let synthesizer = AgentSpeechSynthesizer.shared
        synthesizer.speak("Hi, I'm Next. I can check your calendar and help with your notes.")
        isPreviewing = true
        previewTask?.cancel()
        previewTask = Task { @MainActor in
            while !Task.isCancelled && synthesizer.isSpeaking {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if !Task.isCancelled { isPreviewing = false }
        }
    }

    private var canPreviewVoice: Bool {
        switch settings.agentVoiceEngine {
        case "pocket": pocket.isReady && !pocket.isPreparing
        case "kokoro": kokoro.isReady && !kokoro.isPreparing
        default: true
        }
    }

    private func stopPreview() {
        previewTask?.cancel()
        previewTask = nil
        if isPreviewing { AgentSpeechSynthesizer.shared.stop() }
        isPreviewing = false
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

}

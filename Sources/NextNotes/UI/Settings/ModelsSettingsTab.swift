import AVFoundation
import SwiftUI

/// Every model that lives on disk, in one place.
///
/// Downloads are deliberate rather than implicit: fetching hundreds of megabytes on the
/// first hold of the key looks exactly like a hang.
///
/// The tab is built around one question — *will this run on my Mac?* — which is why it opens
/// with what this machine is, then what is already on it, then what is worth adding. The
/// speech and acceleration sections that follow are unchanged; they are about the same
/// files, and splitting them into a second tab would only hide them.
struct ModelsSettingsTab: View {
    @State private var settings = Settings.shared
    @State private var models = LocalModelStore.shared
    @State private var library = ModelLibraryStore.shared
    @State private var installed = InstalledModelLibrary.shared
    @State private var loadNotice = ModelLoadNotice.shared
    @State private var pocket = PocketAgentVoice.shared
    @State private var kokoro = KokoroAgentVoice.shared
    @State private var functionCalls = FunctionCallStore.shared
    @State private var isPreviewing = false
    @State private var previewTask: Task<Void, Never>?
    @State private var catalog = OpenRouterCatalog.shared
    @State private var openRouterKeyInput = ""
    @State private var openRouterKeyStatus: String?
    @State private var hasOpenRouterKey = false
    @State private var isCheckingOpenRouterKey = true
    @State private var isChangingOpenRouterKey = false
    @State private var showingSpaceManager = false

    var body: some View {
        Form {
            yourMac
            diskUsage
            installedModels
            recommendedModels
            findAModel

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

            hearingYou
            tidyingYourWords
            findingThings
            noticingThings
            speechSynthesis

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
            installed.refresh()
            library.refreshHardware()
            Task {
                if !SelfTest.isRunning {
                    let found = await OpenRouterKeyStore.hasKeyAsync()
                    if found { hasOpenRouterKey = true }
                }
                isCheckingOpenRouterKey = false
            }
            Task {
                await library.refreshAccessKey()
                await library.loadRecommended()
            }
            if settings.agentVoiceEngine == "pocket" {
                Task { await pocket.prepare() }
            } else if settings.agentVoiceEngine == "kokoro", KokoroAgentVoice.isSupportedOS {
                Task { await kokoro.prepare() }
            }
        }
        .onDisappear { if isPreviewing { stopPreview() } }
        .sheet(item: $library.pendingConfirmation) { pending in
            ModelDownloadConfirmSheet(
                pending: pending,
                onConfirm: { chosenPolicy in library.confirmPendingDownload(policy: chosenPolicy) },
                onCancel: { library.pendingConfirmation = nil }
            )
        }
        .sheet(isPresented: accessSheetBinding) {
            if let request = library.accessRequest {
                HuggingFaceAccessSheet(
                    request: request,
                    onSaveKey: { await library.saveAccessKey($0) },
                    onDismiss: { library.accessRequest = nil }
                )
            }
        }
    }

    private var accessSheetBinding: Binding<Bool> {
        Binding(
            get: { library.accessRequest != nil },
            set: { if !$0 { library.accessRequest = nil } }
        )
    }

    // MARK: - Your Mac

    private var yourMac: some View {
        Section {
            YourMacCard(hardware: library.hardware)
            if let message = loadNotice.message {
                HStack(alignment: .top, spacing: DS.Space.s) {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.warning)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("OK") { loadNotice.clear() }
                }
            }
        } header: {
            Text("Your Mac")
        } footer: {
            SettingsNote(text: "Everything below is judged against this machine. Next Notes "
                         + "never stops you downloading something — it only tells you what to "
                         + "expect first.")
        }
    }

    // MARK: - Disk usage

    /// Every model file this app has fetched, added up from what is actually on disk — not a
    /// running total kept in memory, which would drift the moment somebody deletes a file in
    /// Finder. Two roots cover it: this app's own `Models` folder (the writing models, the
    /// embeddings, the wake phrase, the fast-listening engine) and FluidAudio's shared model
    /// cache (Parakeet, speaker models, and the two TTS voices), which several FluidAudio
    /// features on this Mac draw from.
    private var diskUsage: some View {
        Section {
            LabeledContent("Models are using") {
                Text(diskUsageSentence)
                    .foregroundStyle(DS.Color.textSecondary)
            }
        } footer: {
            SettingsNote(text: "Paused downloads count too, until you resume or discard them "
                         + "below. \u{201c}Free up space\u{2026}\u{201d} in \u{201c}Your "
                         + "assistant\u{2019}s brain\u{201d} lists everything not in use, "
                         + "largest first.")
        }
    }

    private var diskUsageSentence: String {
        let used = Self.directorySize(ModelSpec.directory) + Self.directorySize(Self.fluidAudioModelsRoot)
        let free = ModelDownloader.availableDiskBytes()
        guard used > 0 else { return "Nothing yet · \(Self.bytesText(free)) free on this Mac" }
        return "\(Self.bytesText(used)) · \(Self.bytesText(free)) free on this Mac"
    }

    private static func bytesText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }

    private static var fluidAudioModelsRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models", isDirectory: true)
    }

    private static func directorySize(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    // MARK: - Installed

    private var installedModels: some View {
        Section {
            if !NotesModels.isDownloaded {
                ModelStatusRow(
                    title: "Built-in brain",
                    detail: "\(NotesModels.spec.displayName) · \(NotesModels.spec.displaySize)",
                    state: models.notesModelState,
                    downloadTitle: "Download…"
                ) {
                    models.prepareNotesModel()
                }
                ModelTechnicalDetails(
                    modelID: NotesModels.spec.fileName,
                    licenceName: "Publisher's own terms",
                    licenceURL: nil,
                    modelCardURL: Self.modelCardURL(for: NotesModels.spec.url)
                )
            }
            if installed.models.isEmpty, NotesModels.isDownloaded {
                Text("No writing model is on this Mac yet. Pick one from the list below.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
            }
            ForEach(installed.models) { model in
                InstalledModelRow(
                    model: model,
                    fit: library.fit(for: model),
                    isActive: installed.activeAgentModelID == model.id,
                    canRemove: installed.canRemove(model),
                    lastUsed: installed.lastUsedDate(for: model.id),
                    onUse: { library.makeActive(model) },
                    onDelete: { library.delete(model) }
                )
            }
            Picker("When I download a new brain", selection: $library.postDownloadPolicy) {
                ForEach(ModelLibraryStore.PostDownloadPolicy.allCases) { policy in
                    Text(policy.title).tag(policy)
                }
            }
            Text(library.postDownloadPolicy.sentence)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)

            if !installed.models.isEmpty {
                HStack {
                    Spacer()
                    Button("Free up space…") { showingSpaceManager = true }
                        .disabled(installed.models.allSatisfy { !installed.canRemove($0) })
                }
            }
            partialDownloadsList

            HStack(spacing: DS.Space.s) {
                Text("Which model writes agent replies, meeting notes and cleanup is chosen "
                     + "in Settings ▸ Agent.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
                Spacer()
                Button("Open Agent settings") {
                    NavigationState.shared.selectedSettingsTab = .agent
                }
                .buttonStyle(.link)
                .font(DS.Font.caption)
            }
        } header: {
            Text("Your assistant's brain")
        } footer: {
            SettingsNote(text: "One model writes your notes and answers you at a time. "
                         + "Switching takes effect the next time Next Notes needs to think — "
                         + "nothing is interrupted mid-sentence. The built-in model can be "
                         + "removed once another is installed and in use, and downloaded "
                         + "again any time.")
        }
        .sheet(isPresented: $showingSpaceManager) {
            ModelSpaceManagerSheet()
        }
    }

    /// Anything left half-fetched — the app was quit, the network dropped, Stop was pressed —
    /// shown as real disk usage with a way to get it back, since a `.part` file is otherwise
    /// invisible to everyone but Finder.
    @ViewBuilder private var partialDownloadsList: some View {
        let partials = library.partialDownloads()
        if !partials.isEmpty {
            ForEach(partials) { partial in
                LabeledContent {
                    Button("Discard") { library.discardPartial(partial) }
                        .buttonStyle(.borderless)
                } label: {
                    Text(partial.displayName)
                    Text("Paused · \(Self.bytesText(partial.bytes)) so far — download it again "
                         + "from Recommended or Find a model to pick up where it left off.")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                }
            }
        }
    }

    /// Strips a file's own path down to the repository or release page it came from, for the
    /// "Model card" link in a technical-details disclosure. Works for both the Hugging Face
    /// `/resolve/<ref>/<path>` shape and GitHub's `/releases/download/<tag>/<file>` shape,
    /// which is every model this tab downloads.
    static func modelCardURL(for url: URL) -> URL {
        let text = url.absoluteString
        for marker in ["/resolve/", "/releases/"] {
            if let range = text.range(of: marker) {
                if let trimmed = URL(string: String(text[text.startIndex..<range.lowerBound])) {
                    return trimmed
                }
            }
        }
        return url
    }

    // MARK: - Recommended

    private var recommendedModels: some View {
        Section {
            if library.isLoadingRecommended && library.recommended.isEmpty {
                ProgressView("Looking for models that suit this Mac…")
            }
            ForEach(library.recommended) { listing in
                browseRow(listing)
            }
            if !library.isLoadingRecommended && library.recommended.isEmpty {
                Text("Couldn’t reach the model library just now. Check your internet "
                     + "connection and reopen this tab.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
            }
            Button("Refresh") { Task { await library.loadRecommended(force: true) } }
                .disabled(library.isLoadingRecommended)
        } header: {
            Text("Recommended for this Mac")
        } footer: {
            SettingsNote(text: "Chosen from the most-used models people share publicly, "
                         + "filtered down to the ones this Mac can actually run well.")
        }
    }

    // MARK: - Search

    private var findAModel: some View {
        Section {
            HStack(spacing: DS.Space.s) {
                TextField("Search for a model by name", text: $library.searchText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { library.search() }
                    .onChange(of: library.searchText) { _, _ in library.search() }
                if library.isSearching { ProgressView().controlSize(.small) }
            }
            if let problem = library.problem {
                Text(problem)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.warning)
            }
            ForEach(library.searchResults) { listing in
                browseRow(listing)
            }
            if library.nextSearchPage != nil && !library.searchResults.isEmpty {
                Button("Show more") { Task { await library.loadNextSearchPage() } }
                    .disabled(library.isSearching)
            }
            if library.hasAccessKey {
                HStack {
                    Label("Signed in to Hugging Face", systemImage: "checkmark.circle.fill")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.success)
                    Spacer()
                    Button("Sign out") { Task { await library.removeAccessKey() } }
                }
            }
        } header: {
            Text("Find a model")
        } footer: {
            SettingsNote(text: "Models come from Hugging Face, where people publish them "
                         + "openly. Most need no account. A few ask you to agree to their "
                         + "makers’ terms first, and Next Notes will walk you through that.")
        }
    }

    private func browseRow(_ listing: ModelListing) -> some View {
        ModelBrowseRow(
            listing: listing,
            downloadState: library.state(for: listing.model.id),
            isInstalled: installed.models.contains { $0.id.hasPrefix(listing.model.id + "/") },
            onDownload: { library.startDownload(listing.model) },
            onCancel: { library.cancelDownload(listing.model.id) }
        )
    }

    // MARK: - Hearing you

    private var hearingYou: some View {
        Section {
            ModelStatusRow(
                title: "Understanding speech",
                detail: "Parakeet, through FluidAudio · ~470 MB",
                state: models.parakeetState,
                downloadTitle: "Download…"
            ) {
                models.prepareParakeet()
            }
            ModelTechnicalDetails(
                modelID: "NVIDIA Parakeet TDT (FluidAudio build)",
                licenceName: "Publisher's own terms",
                licenceURL: nil,
                modelCardURL: URL(string: "https://github.com/FluidInference/FluidAudio")!
            )

            ModelStatusRow(
                title: "Wake phrase",
                detail: "Hears \u{201c}\(WakeWordConfiguration.current.validatedPhrase() ?? settings.wakePhrase)\u{201d} · \(WakeWordModels.archive.displaySize)",
                state: models.wakeWordState,
                downloadTitle: "Download…"
            ) {
                models.prepareWakeWord()
            }
            ModelTechnicalDetails(
                modelID: WakeWordModels.name,
                licenceName: "Apache-2.0",
                licenceURL: URL(string: "https://www.apache.org/licenses/LICENSE-2.0"),
                modelCardURL: Self.modelCardURL(for: WakeWordModels.archive.url)
            )

            ModelStatusRow(
                title: "Telling speakers apart",
                detail: "Speaker models, through FluidAudio",
                state: models.diarizerState,
                downloadTitle: "Download…"
            ) {
                models.prepareDiarizer()
            }
            ModelTechnicalDetails(
                modelID: "FluidAudio speaker diarization (segmentation + embedding)",
                licenceName: "Publisher's own terms",
                licenceURL: nil,
                modelCardURL: URL(string: "https://github.com/FluidInference/FluidAudio")!
            )
        } header: {
            Text("Hearing you")
        } footer: {
            SettingsNote(text: "What turns a meeting or a hold of the key into text, notices "
                         + "the wake phrase while asleep, and tells one speaker from another "
                         + "afterwards.")
        }
    }

    // MARK: - Tidying your words

    private var tidyingYourWords: some View {
        Section {
            ModelStatusRow(
                title: "S1-mini",
                detail: "Cleans up dictation, by Superwhisper · \(S1MiniModels.spec.displaySize)",
                state: models.s1MiniState,
                downloadTitle: "Download…"
            ) {
                models.prepareS1Mini()
            }
            ModelTechnicalDetails(
                modelID: S1MiniModels.spec.fileName,
                licenceName: "Publisher's own terms",
                licenceURL: nil,
                modelCardURL: Self.modelCardURL(for: S1MiniModels.spec.url)
            )
        } header: {
            Text("Tidying your words")
        } footer: {
            SettingsNote(text: "Fixes punctuation and stray words in what dictation heard, "
                         + "right after you speak. Without it, dictation still works — it is "
                         + "just less polished.")
        }
    }

    // MARK: - Finding things (semantic search)

    private var findingThings: some View {
        Section {
            Picker("Search by meaning", selection: embedderChoice) {
                ForEach(KnowledgeEmbedderChoice.allCases) { choice in
                    Text(plainEmbedderName(choice)).tag(choice)
                }
            }
            .disabled(!settings.knowledgeIndexEnabled)

            if selectedEmbedder != .none {
                ModelStatusRow(
                    title: plainEmbedderName(selectedEmbedder),
                    detail: "Turns your notes into vectors for search · "
                        + EmbeddingModels.displaySize(selectedEmbedder),
                    state: embeddingRowState,
                    downloadTitle: "Download (\(EmbeddingModels.displaySize(selectedEmbedder)))"
                ) {
                    models.prepareEmbeddingModel(selectedEmbedder)
                }
                if embeddingRowState.isBusy {
                    HStack {
                        Spacer()
                        Button("Cancel") { models.cancelEmbeddingModel() }
                    }
                }
                if let licence = EmbeddingModels.licence(selectedEmbedder) {
                    ModelTechnicalDetails(
                        modelID: EmbeddingModels.specs(selectedEmbedder).last?.displayName
                            ?? selectedEmbedder.rawValue,
                        licenceName: licence.name,
                        licenceURL: licence.url,
                        modelCardURL: licence.source
                    )
                }
            }
        } header: {
            Text("Finding things")
        } footer: {
            SettingsNote(text: "Lets Search and the Agent match what you meant, not just the "
                         + "words you typed. Off by default — turned on, it waits while "
                         + "anything is recording or the notes model is loaded. Switching "
                         + "models here re-indexes everything with the new one; nothing is "
                         + "lost while that runs. Search and the knowledge index itself are "
                         + "in Settings ▸ Agent.")
        }
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

    private var embeddingRowState: LocalModelStore.State {
        models.embeddingModelChoice == selectedEmbedder
            ? models.embeddingModelState
            : (EmbeddingModels.isDownloaded(selectedEmbedder) ? .ready : .notDownloaded)
    }

    /// Plain names for the two real choices. `KnowledgeEmbedderChoice.title` stays technical
    /// (it names the model) for the disclosure and for places outside this tab.
    private func plainEmbedderName(_ choice: KnowledgeEmbedderChoice) -> String {
        switch choice {
        case .none: "Off"
        case .potion: "Fast search by meaning"
        case .embeddinggemma: "Best search by meaning"
        }
    }

    // MARK: - Noticing things (fast listening)

    private var noticingThings: some View {
        Section {
            ModelStatusRow(
                title: "Fast listening engine",
                detail: "Needle 3, by Cactus Compute · \(NeedleModels.displaySize)",
                state: fastListeningState,
                downloadTitle: "Download (\(NeedleModels.displaySize))"
            ) {
                Task { await functionCalls.downloadFastEngine() }
            }
            ModelTechnicalDetails(
                modelID: NeedleModels.weights.fileName,
                licenceName: "Apache-2.0",
                licenceURL: URL(string: "https://www.apache.org/licenses/LICENSE-2.0"),
                modelCardURL: Self.modelCardURL(for: NeedleModels.engine.url)
            )
        } header: {
            Text("Noticing things")
        } footer: {
            SettingsNote(text: "Notices, while you talk, when you have asked for something "
                         + "Next Notes could do, and offers it on a card — it never acts on "
                         + "its own. Works without this download, using the model that writes "
                         + "your notes, only slower. Turn the feature on or off in Settings ▸ "
                         + "Agent.")
        }
        .task { if !SelfTest.isRunning { await functionCalls.refreshStatus() } }
    }

    /// `LocalModelStore.State`, translated from `FunctionCallStore.Status` so this row can
    /// reuse the same `ModelStatusRow` every other download uses. `FunctionCallStore` keeps
    /// its own richer status (it also has to describe "ready without the download, using the
    /// notes model instead"), which is why the translation lives here rather than there.
    private var fastListeningState: LocalModelStore.State {
        switch functionCalls.status {
        case .downloading(let fraction):
            .preparing("Downloading… \(Int(fraction * 100))%")
        case .problem(let why):
            .failed(why)
        case .ready(.needle, _):
            .ready
        case .off, .unavailable, .ready:
            .notDownloaded
        }
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

            if settings.agentVoiceEngine != "apple" {
                ModelTechnicalDetails(
                    modelID: settings.agentVoiceEngine == "pocket"
                        ? "Pocket TTS (FluidAudio)" : "Kokoro-82M (FluidAudio)",
                    licenceName: "Publisher's own terms",
                    licenceURL: nil,
                    modelCardURL: URL(string: "https://github.com/FluidInference/FluidAudio")!
                )
            }
        } header: {
            Text("Speaking back")
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

/// The disclosure every local model row ends in: what it actually is, once "Fast search by
/// meaning" or "Wake phrase" isn't enough to identify it — a model id, its licence, and a
/// link to read more. Collapsed by default, same idiom as `ModelBrowseRow`'s own "Technical
/// details" in the Hugging Face browse list, so a person who never opens it sees one plain
/// row and a person who does gets the same shape everywhere.
private struct ModelTechnicalDetails: View {
    let modelID: String
    let licenceName: String
    let licenceURL: URL?
    let modelCardURL: URL

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup("Technical details", isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(modelID)
                HStack(spacing: DS.Space.xs) {
                    Text("Licence:")
                    if let licenceURL {
                        Link(licenceName, destination: licenceURL)
                    } else {
                        Text(licenceName)
                    }
                }
                Link("Model card", destination: modelCardURL)
            }
            .font(DS.Font.caption)
            .foregroundStyle(DS.Color.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, DS.Space.xxs)
        }
        .font(DS.Font.caption)
    }
}

import FluidAudio
import Foundation
import Observation

@MainActor
@Observable
final class LocalModelStore {
    static let shared = LocalModelStore()

    enum State: Equatable {
        case notDownloaded
        case preparing(String)
        case ready
        case failed(String)

        var isBusy: Bool {
            if case .preparing = self { return true }
            return false
        }
    }

    private(set) var parakeetState: State
    private(set) var s1MiniState: State
    private(set) var notesModelState: State
    private(set) var diarizerState: State
    private(set) var wakeWordState: State
    /// The embedding model `knowledgeEmbedder` names. `embeddingModelChoice` is which one
    /// the state describes.
    private(set) var embeddingModelState: State
    private(set) var embeddingModelChoice: KnowledgeEmbedderChoice
    @ObservationIgnored private var embeddingTask: Task<Void, Never>?
    /// Which download `embeddingTask` is. A cancelled task's late success or catch must not
    /// overwrite the state of a download started after it.
    @ObservationIgnored private var embeddingGeneration = 0

    private init() {
        parakeetState = ParakeetModels.isDownloaded ? .ready : .notDownloaded
        s1MiniState = S1MiniModels.isDownloaded ? .ready : .notDownloaded
        notesModelState = NotesModels.isDownloaded ? .ready : .notDownloaded
        diarizerState = MeetingDiarizer.isDownloaded ? .ready : .notDownloaded
        wakeWordState = WakeWordModelManager.isReadyToLoad ? .ready : .notDownloaded
        let choice = KnowledgeIndexSettings.fromDefaults.embedder
        embeddingModelChoice = choice
        embeddingModelState = EmbeddingModels.isDownloaded(choice) ? .ready : .notDownloaded
    }

    func prepareParakeet() {
        guard !parakeetState.isBusy else { return }
        parakeetState = .preparing(
            ParakeetModels.isDownloaded ? "Loading Parakeet…" : "Downloading Parakeet…"
        )
        Task {
            do {
                _ = try await ParakeetModels.shared.manager { [weak self] progress in
                    Task { @MainActor [weak self] in
                        let percent = Int((progress.fractionCompleted * 100).rounded())
                        self?.parakeetState = .preparing("Preparing Parakeet… \(percent)%")
                    }
                }
                parakeetState = .ready
            } catch {
                parakeetState = .failed(error.localizedDescription)
                Log.speech.error("Parakeet preparation failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func prepareS1Mini() {
        guard !s1MiniState.isBusy else { return }
        s1MiniState = .preparing(
            S1MiniModels.isDownloaded
                ? "Loading S1-mini…"
                : "Downloading S1-mini (\(S1MiniModels.spec.displaySize))…"
        )
        Task {
            do {
                try await S1MiniModels.download { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        let percent = Int((fraction * 100).rounded())
                        self?.s1MiniState = .preparing("Downloading S1-mini… \(percent)%")
                    }
                }
                s1MiniState = .preparing("Loading S1-mini…")
                try await S1MiniRuntime.shared.prepare()
                s1MiniState = .ready
            } catch {
                s1MiniState = .failed(error.localizedDescription)
                Log.speech.error("S1-mini preparation failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Fetches the notes model, then loads it so the first meeting to finish doesn't pay
    /// the cold start on top of transcription.
    ///
    /// The disk check happens here as well as inside `ModelDownloader` so that a machine
    /// with no room says so before spending an hour on a transfer it will then refuse.
    func prepareNotesModel() {
        guard !notesModelState.isBusy else { return }

        if !NotesModels.isDownloaded {
            let free = ModelDownloader.availableDiskBytes()
            let needed = NotesModels.spec.expectedBytes + ModelDownloader.minimumFreeBytesAfterDownload
            guard free >= needed else {
                notesModelState = .failed(
                    ModelDownloadError.insufficientDisk(
                        free: free,
                        needed: NotesModels.spec.expectedBytes
                    ).localizedDescription
                )
                return
            }
        }

        notesModelState = .preparing(
            NotesModels.isDownloaded
                ? "Loading \(NotesModels.spec.displayName)…"
                : "Downloading \(NotesModels.spec.displayName) (\(NotesModels.spec.displaySize))…"
        )
        Task {
            do {
                try await NotesModels.download { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        let percent = Int((fraction * 100).rounded())
                        self?.notesModelState = .preparing(
                            "Downloading \(NotesModels.spec.displayName)… \(percent)%"
                        )
                    }
                }
                notesModelState = .preparing("Loading \(NotesModels.spec.displayName)…")
                // The library lists the built-in model the moment its file is complete, so
                // the Models tab shows it beside anything fetched from Hugging Face.
                InstalledModelLibrary.shared.refresh()
                try await NotesModelRuntime.shared.prepare()
                notesModelState = .ready
            } catch {
                notesModelState = .failed(error.localizedDescription)
                Log.llm.error("notes model preparation failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Fetches the speaker-identification models, then compiles them.
    ///
    /// No percentage: FluidAudio's `prepareModels()` owns the download and reports nothing
    /// while it runs. These are tens of megabytes rather than gigabytes, so the honest
    /// "working on it" is better than a fabricated bar.
    func prepareDiarizer() {
        guard !diarizerState.isBusy else { return }
        diarizerState = .preparing(
            MeetingDiarizer.isDownloaded ? "Loading speaker models\u{2026}" : "Downloading speaker models\u{2026}"
        )
        Task {
            do {
                try await MeetingDiarizer.shared.prepare()
                diarizerState = .ready
            } catch {
                diarizerState = .failed(error.localizedDescription)
                Log.meeting.error("diarizer preparation failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Fetches the files one embedding model needs: pinned URL, pinned size and SHA-256,
    /// only when the user asks, and cancellable. Nothing loads here — the indexer loads the
    /// model when nothing is recording and the notes model is idle.
    ///
    /// The licence is shown beside the button that calls this (`KnowledgeSection`), before
    /// anything is fetched.
    func prepareEmbeddingModel(_ choice: KnowledgeEmbedderChoice) {
        guard choice != .none else { return }
        if embeddingModelChoice != choice {
            cancelEmbeddingModel()
            embeddingModelChoice = choice
        }
        guard !embeddingModelState.isBusy else { return }
        guard !EmbeddingModels.isDownloaded(choice) else {
            embeddingModelState = .ready
            return
        }
        let specs = EmbeddingModels.specs(choice)
        let free = ModelDownloader.availableDiskBytes()
        let needed = EmbeddingModels.totalBytes(choice) + ModelDownloader.minimumFreeBytesAfterDownload
        guard free >= needed else {
            embeddingModelState = .failed(ModelDownloadError.insufficientDisk(
                free: free, needed: EmbeddingModels.totalBytes(choice)).localizedDescription)
            return
        }
        let total = Double(max(1, EmbeddingModels.totalBytes(choice)))
        let name = specs.last?.displayName ?? choice.rawValue
        embeddingModelState = .preparing("Downloading \(name) (\(EmbeddingModels.displaySize(choice)))…")
        embeddingGeneration += 1
        let generation = embeddingGeneration
        // Strong captures: the store is the app-lifetime singleton.
        embeddingTask = Task { @MainActor in
            do {
                var done: Int64 = 0
                for spec in specs {
                    try Task.checkCancellation()
                    let before = Double(done)
                    let bytes = Double(spec.expectedBytes)
                    try await ModelDownloader.download(spec) { fraction in
                        let percent = Int(((before + fraction * bytes) / total * 100).rounded())
                        Task { @MainActor in
                            self.showEmbeddingProgress("Downloading \(name)… \(percent)%", for: choice, generation: generation)
                        }
                    }
                    done += spec.expectedBytes
                }
                try Task.checkCancellation()
                guard self.embeddingGeneration == generation, self.embeddingModelChoice == choice else { return }
                self.embeddingModelState = .ready
                Log.app.info("embedding model ready: \(choice.rawValue, privacy: .public)")
            } catch {
                guard self.embeddingGeneration == generation, self.embeddingModelChoice == choice else { return }
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    self.embeddingModelState = EmbeddingModels.isDownloaded(choice) ? .ready : .notDownloaded
                } else {
                    self.embeddingModelState = .failed(error.localizedDescription)
                    Log.app.error("embedding model download failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private func showEmbeddingProgress(_ message: String, for choice: KnowledgeEmbedderChoice, generation: Int) {
        guard embeddingGeneration == generation, embeddingModelState.isBusy, embeddingModelChoice == choice else { return }
        embeddingModelState = .preparing(message)
    }

    /// Stops a download in progress. A file already verified and moved into place stays.
    func cancelEmbeddingModel() {
        embeddingTask?.cancel()
        embeddingTask = nil
        embeddingGeneration += 1
        if embeddingModelState.isBusy {
            embeddingModelState = EmbeddingModels.isDownloaded(embeddingModelChoice) ? .ready : .notDownloaded
        }
    }

    /// The state for `choice`, re-read from disk when nothing is downloading it.
    func selectEmbeddingModel(_ choice: KnowledgeEmbedderChoice) {
        guard choice != embeddingModelChoice || !embeddingModelState.isBusy else { return }
        if choice != embeddingModelChoice { cancelEmbeddingModel() }
        embeddingModelChoice = choice
        embeddingModelState = EmbeddingModels.isDownloaded(choice) ? .ready : .notDownloaded
    }

    func prepareWakeWord() {
        guard !wakeWordState.isBusy else { return }
        wakeWordState = .preparing(
            WakeWordModelManager.isReadyToLoad
                ? "Loading wake phrase…"
                : "Downloading wake phrase (\(WakeWordModels.archive.displaySize))…"
        )
        Task {
            do {
                try await WakeWordModelManager.download(configuration: WakeWordConfiguration.current) { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        let percent = Int((fraction * 100).rounded())
                        self?.wakeWordState = .preparing("Downloading wake phrase… \(percent)%")
                    }
                }
                wakeWordState = .preparing("Loading wake phrase…")
                WakeWordPhoneLexicon.reset()
                _ = try WakeWordModelManager.loadSpotter()
                wakeWordState = .ready
                WakeWordAudioMonitor.shared.sync()
            } catch {
                wakeWordState = .failed(error.localizedDescription)
                Log.agent.error("wake model preparation failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func refresh() {
        if !parakeetState.isBusy {
            parakeetState = ParakeetModels.isDownloaded ? .ready : .notDownloaded
        }
        if !s1MiniState.isBusy {
            s1MiniState = S1MiniModels.isDownloaded ? .ready : .notDownloaded
        }
        if !notesModelState.isBusy {
            notesModelState = NotesModels.isDownloaded ? .ready : .notDownloaded
        }
        if !diarizerState.isBusy {
            diarizerState = MeetingDiarizer.isDownloaded ? .ready : .notDownloaded
        }
        if !wakeWordState.isBusy {
            wakeWordState = WakeWordModelManager.isReadyToLoad ? .ready : .notDownloaded
        }
        if !embeddingModelState.isBusy {
            embeddingModelState = EmbeddingModels.isDownloaded(embeddingModelChoice) ? .ready : .notDownloaded
        }
    }
}

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

    private init() {
        parakeetState = ParakeetModels.isDownloaded ? .ready : .notDownloaded
        s1MiniState = S1MiniModels.isDownloaded ? .ready : .notDownloaded
        notesModelState = NotesModels.isDownloaded ? .ready : .notDownloaded
        diarizerState = MeetingDiarizer.isDownloaded ? .ready : .notDownloaded
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
    }
}

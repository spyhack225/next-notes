import FluidAudio
import Foundation

/// Who said what on the system track of a finished meeting.
///
/// Only the system track. The microphone track is one person by construction — the person
/// holding the Mac — so running a clustering model over it can only invent speakers that
/// aren't there. Everyone else arrives mixed down into one channel, and that mixdown is the
/// only place the question "was that Ana or Ben?" is even askable.
///
/// It runs after the recording rather than during it: the offline diarizer clusters over the
/// whole file, which is what lets it give the same person the same label at minute 3 and at
/// minute 58. A streaming diarizer would answer sooner and change its mind later, and a
/// transcript whose speaker labels shuffle while you read it is worse than no labels.
actor MeetingDiarizer {
    static let shared = MeetingDiarizer()

    /// One stretch of one speaker, in seconds from the start of the recording.
    ///
    /// FluidAudio's own `TimedSpeakerSegment` carries a 256-float embedding per segment that
    /// nothing here wants to keep, and lifting the result into this type is what lets
    /// `assign(_:to:)` be tested without a CoreML model.
    struct SpeakerRun: Sendable, Equatable {
        let speakerID: String
        let start: TimeInterval
        let end: TimeInterval
    }

    /// Windows shorter than this are a door closing, not a turn in a conversation, and the
    /// segmentation model has nothing to cluster from them.
    private static let minimumAudioSeconds: Double = 2

    /// Where FluidAudio caches the offline diarization models.
    ///
    /// `OfflineDiarizerModels.load` is handed `Application Support/FluidAudio/Models`, and
    /// `ModelHub` appends the repo's folder name under it — so the four compiled models and
    /// the PLDA parameters land here.
    private static var modelsRoot: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("FluidAudio/Models/speaker-diarization", isDirectory: true)
    }

    /// Whether the models are already on disk, checked without loading them.
    ///
    /// `nonisolated` and filesystem-based for the same reason `ParakeetModels.isDownloaded`
    /// is: Settings draws this synchronously, and an in-memory "have I loaded yet" flag
    /// would report "not downloaded" on every fresh launch.
    nonisolated static var isDownloaded: Bool {
        let required = [
            "Segmentation.mlmodelc/coremldata.bin",
            "FBank.mlmodelc/coremldata.bin",
            "Embedding.mlmodelc/coremldata.bin",
            "PldaRho.mlmodelc/coremldata.bin",
            "plda-parameters.json",
        ]
        let root = modelsRoot
        guard required.allSatisfy({ FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) })
        else { return false }

        // A resumed download leaves the compiled directory in place while it is still a
        // fragment. Never advertise that as installed.
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let file = enumerator?.nextObject() as? URL {
            if file.lastPathComponent.contains(".partial") { return false }
        }
        return true
    }

    /// The prepared models, once. Kept for the life of the process because compiling them
    /// is seconds of work and a meeting is not the moment to spend it twice.
    private var models: Models?

    /// In-flight load, so the Settings download button and a meeting that has just stopped
    /// don't each start their own. `prepare()` suspends over a download, and an actor is
    /// reentrant across a suspension — without this the second caller walks straight past
    /// the `manager == nil` guard and downloads the models a second time.
    private var loadTask: Task<Void, Error>?

    /// Downloads and compiles the models if they aren't already on disk.
    func prepare() async throws {
        if models != nil { return }
        if let loadTask { return try await loadTask.value }

        let task = Task<Void, Error> { [weak self] in try await self?.load() }
        loadTask = task
        defer { loadTask = nil }
        try await task.value
    }

    private func load() async throws {
        guard models == nil else { return }
        let started = Date()
        models = try await Self.loaded()
        Log.meeting.info("""
            diarizer ready in \(Date().timeIntervalSince(started), format: .fixed(precision: 1))s
            """)
    }

    /// Clusters one mono 16 kHz track into speaker runs.
    ///
    /// - Parameter progress: fraction of the segmentation pass, 0…1.
    func speakerRuns(
        in samples: [Float],
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> [SpeakerRun] {
        guard Double(samples.count) / ChunkedTranscriber.sampleRate >= Self.minimumAudioSeconds else {
            return []
        }
        try await prepare()
        guard let models else { throw DiarizationError.notPrepared }
        return try await Self.speakerRuns(from: models, in: samples, progress: progress)
    }

    /// Frees the models. Called when nothing is going to be diarized for a while.
    func unload() {
        models = nil
    }

    // MARK: - Off the actor

    /// FluidAudio's `OfflineDiarizerManager` is a class that holds its CoreML models
    /// `nonisolated(unsafe)` and only reads them once prepared. That makes it safe to use
    /// from one place at a time, which is exactly what this actor guarantees — but it is not
    /// `Sendable`, and an actor may not hand a non-`Sendable` value to a `nonisolated async`
    /// method. So the manager never crosses the boundary: it is created, prepared and used
    /// entirely off the actor, and only this box — which states the guarantee — is stored.
    private final class Models: @unchecked Sendable {
        let manager: OfflineDiarizerManager

        init(manager: OfflineDiarizerManager) {
            self.manager = manager
        }
    }

    private nonisolated static func loaded() async throws -> Models {
        let manager = OfflineDiarizerManager(config: .default)
        try await manager.prepareModels()
        return Models(manager: manager)
    }

    private nonisolated static func speakerRuns(
        from models: Models,
        in samples: [Float],
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> [SpeakerRun] {
        let result = try await models.manager.process(audio: samples) { done, total in
            guard total > 0 else { return }
            progress?(Double(done) / Double(total))
        }
        return result.segments.map {
            SpeakerRun(
                speakerID: $0.speakerId,
                start: TimeInterval($0.startTimeSeconds),
                end: TimeInterval($0.endTimeSeconds)
            )
        }
    }

    // MARK: - Assignment

    /// Labels the system-track segments of a transcript from a set of speaker runs.
    ///
    /// Assignment is by overlap rather than by midpoint: a transcript segment is a window of
    /// audio Parakeet decided to cut, and it routinely spans the moment one person stops and
    /// another starts. Whoever holds the most of it owns it, which is the same answer a
    /// reader would give.
    ///
    /// Labels are numbered by when each speaker is first heard, so "Speaker 1" is whoever
    /// opened the call. The cluster ids the model produces are stable within one run but say
    /// nothing about order, and a transcript that starts at Speaker 4 reads like a bug.
    ///
    /// The resolution ceiling is the transcript's, not the model's: `ChunkedTranscriber` cuts
    /// windows of thirty to sixty seconds and gives a segment no timing inside them, so a
    /// window in which three people spoke can only be attributed to the one who held most of
    /// it. The clustering underneath is far finer — it routinely returns a dozen runs for one
    /// transcript segment — and none of that detail survives here. Fixing it means word-level
    /// timings out of Parakeet, not a better rule in this function.
    ///
    /// Pure and static so the mapping can be exercised without a model, a file, or a meeting.
    static func assign(_ segments: [TranscriptSegment], to runs: [SpeakerRun]) -> [TranscriptSegment] {
        guard !runs.isEmpty else { return segments }

        var labels: [String: String] = [:]
        for run in runs.sorted(by: { $0.start < $1.start }) where labels[run.speakerID] == nil {
            labels[run.speakerID] = "Speaker \(labels.count + 1)"
        }

        return segments.map { segment in
            guard segment.source == .system else { return segment }

            var best: (id: String, overlap: TimeInterval)?
            for run in runs {
                let overlap = min(segment.end, run.end) - max(segment.start, run.start)
                guard overlap > 0 else { continue }
                if overlap > (best?.overlap ?? 0) { best = (run.speakerID, overlap) }
            }

            // No overlap at all — a window the segmentation model heard as silence. Left
            // unlabelled rather than guessed at, so it falls back to "Others".
            guard let best, let label = labels[best.id] else { return segment }
            var labelled = segment
            labelled.speaker = label
            return labelled
        }
    }

    /// Every generated speaker label in a transcript, in the order they were assigned.
    ///
    /// What the rename sheet lists, and what tells the detail view whether there is anything
    /// to rename in the first place.
    static func labels(in segments: [TranscriptSegment]) -> [String] {
        var seen: [String] = []
        for segment in segments {
            guard let speaker = segment.speaker, !seen.contains(speaker) else { continue }
            seen.append(speaker)
        }
        return seen
    }
}

enum DiarizationError: LocalizedError {
    case notPrepared
    case noAudio
    case tooShort

    var errorDescription: String? {
        switch self {
        case .notPrepared:
            "The speaker models couldn't be loaded."
        case .noAudio:
            "This meeting kept no audio, so its speakers can't be identified."
        case .tooShort:
            "This recording is too short to tell speakers apart."
        }
    }
}

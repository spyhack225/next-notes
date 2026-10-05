import AVFoundation
import CoreML
import FluidAudio
import Foundation

/// NVIDIA Parakeet TDT 0.6B, compiled to CoreML and run locally via FluidAudio.
///
/// **Near-streaming while the key is held.** Audio is still buffered in process,
/// and every ~2 s of new speech a provisional pass re-transcribes the buffer so
/// the HUD can show live text. On release, if the leftover since the last
/// partial is tiny, that partial is promoted to the final rather than paying a
/// cold full-buffer pass again; otherwise one final batch pass runs as before.
/// Models stay warm via `ParakeetModels`.
actor ParakeetEngine: TranscriptionEngine {
    /// Self-test probe: the engine yields non-final chunks during a hold.
    nonisolated static let emitsPartialsWhileHeld = true

    private var samples: [Float] = []
    private var continuation: AsyncThrowingStream<TranscriptionChunk, Error>.Continuation?

    /// Sample count at which the last provisional was fired.
    private var lastPartialAt = 0
    /// Most recent completed provisional text — reused on release when leftover audio is short.
    private var lastPartialText = ""
    /// Sample position represented by `lastPartialText`.
    private var lastCompletedPartialAt = 0
    /// One active provisional pass. A second pass never starts until this one completes.
    private var partialTask: Task<Void, Never>?
    /// The newest snapshot waiting behind the active pass. Older snapshots are discarded.
    private var queuedPartial: (samples: [Float], at: Int)?

    /// `ComputeScheduler` lane held for this engine instance from successful
    /// `start()` through `finish()`. Notes take `.background` and checkpoint;
    /// holding `.realtimeASR` here is what makes them park during live ASR.
    /// Owned by this engine so a superseded start releases *its* job, not a
    /// later hold's.
    private var schedulerJobID: UUID?
    /// Seconds the last `start()` waited to be scheduled on the shared `.realtimeASR`
    /// lane (F-01). The meeting side records the same number per window
    /// (`MeetingTranscribeTally.laneWait`); without it here, the question "did a dictation
    /// queue behind a meeting?" is unanswerable from a hold's own row, and the gate for the
    /// per-pass-acquire change has nothing to read.
    private var startLaneWaitSeconds: TimeInterval = 0

    /// The value above, read by the tail after `finish()` for the `dictation.asr` usage row.
    /// Actor-isolated, so the read is an `await`. 0 when the acquire did not wait.
    var startLaneWait: TimeInterval { startLaneWaitSeconds }
    /// Bumped by `finish()` (and each new `start()`) so a start that was
    /// suspended across `acquire` / model load can tell it was cancelled and
    /// release its own lane — actors are re-entrant at `await`.
    private var recognitionGeneration = 0
    /// Lifecycle token in the shared model registry. Kept separate from the
    /// engine generation because a stale model load may finish after a new
    /// recognition session has already started.
    private var runtimeGeneration: UInt64?
    private var runtimeLoaded = false

    private let converter = AudioConverter()

    private var partialIntervalSamples: Int {
        Int(StreamingASR.dictationPartialIntervalSeconds * 16_000)
    }

    private var reuseBelowSamples: Int {
        Int(StreamingASR.dictationReusePartialBelowSeconds * 16_000)
    }

    func preferredInputFormat() async -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
    }

    func start() async throws -> AsyncThrowingStream<TranscriptionChunk, Error> {
        let generation = recognitionGeneration &+ 1
        recognitionGeneration = generation

        samples.removeAll(keepingCapacity: true)
        lastPartialAt = 0
        lastPartialText = ""
        lastCompletedPartialAt = 0
        partialTask?.cancel()
        let oldPartial = partialTask
        partialTask = nil
        queuedPartial = nil
        await oldPartial?.value
        // A previous start that never reached finish must not leave a stale id;
        // only this instance's lane is released below on failure.
        await releaseSchedulerLane()

        let (stream, continuation) = AsyncThrowingStream<TranscriptionChunk, Error>.makeStream()
        self.continuation = continuation

        // Hold the ASR lane for load + feed + partials + finish so notes
        // checkpoints yield for the whole recognition window, not only the
        // final batch pass. Store the id before the (slow) model load so a
        // timed-out start whose finish() races us still finds something to
        // release — unless finish already invalidated `generation`.
        // How long the queueing took, measured where the queueing happens (F-01). Recorded
        // before the generation check below, so a start that was cancelled while parked
        // still files what it waited — that wait is exactly the contention being measured.
        let laneBegan = Date()
        let jobID = await ComputeScheduler.shared.acquire(.realtimeASR)
        startLaneWaitSeconds = Date().timeIntervalSince(laneBegan)
        guard recognitionGeneration == generation else {
            await ComputeScheduler.shared.release(jobID)
            continuation.finish()
            self.continuation = nil
            throw CancellationError()
        }
        schedulerJobID = jobID
        let runtimeGeneration = await ModelRuntimeManager.shared.beginLoading(.parakeetASR)
        self.runtimeGeneration = runtimeGeneration
        runtimeLoaded = false
        do {
            // Force the (possibly very slow) first load to happen here rather than on release,
            // so the user waits before speaking instead of losing an utterance to a timeout.
            _ = try await ParakeetModels.shared.manager()
            runtimeLoaded = true
            _ = await ModelRuntimeManager.shared.markReady(
                .parakeetASR,
                generation: runtimeGeneration
            )
        } catch {
            _ = await ModelRuntimeManager.shared.markWedged(
                .parakeetASR,
                generation: runtimeGeneration,
                error: error.localizedDescription
            )
            await releaseSchedulerLane()
            throw error
        }
        guard recognitionGeneration == generation else {
            // The model cache is process-wide. A superseded engine must not
            // call it unloaded when another session (or the shared load task)
            // still owns resident weights.
            if await ParakeetModels.shared.isLoaded {
                _ = await ModelRuntimeManager.shared.markReady(
                    .parakeetASR,
                    generation: runtimeGeneration
                )
            }
            await releaseSchedulerLane()
            continuation.finish()
            self.continuation = nil
            throw CancellationError()
        }

        _ = await ModelRuntimeManager.shared.markBusy(
            .parakeetASR,
            generation: runtimeGeneration
        )

        return stream
    }

    func feed(_ chunk: AudioChunk) async {
        let buffer = chunk.buffer
        guard buffer.frameLength > 0 else { return }

        // Delegated to FluidAudio's own converter rather than hand-rolled, for one reason
        // that matters more than tidiness: `AsrManager.transcribe(_ samples: [Float])`
        // performs **no resampling and no rate validation**. Feed it the wrong sample rate
        // and it doesn't throw — it silently transcribes garbage.
        do {
            samples.append(contentsOf: try converter.resampleBuffer(buffer))
        } catch {
            Log.speech.error("Parakeet: audio conversion failed — \(error.localizedDescription, privacy: .public)")
            return
        }

        await maybeEmitPartial()
    }

    func finish() async {
        // Invalidate any in-flight start suspended across acquire / load.
        recognitionGeneration &+= 1

        // Take ownership of the lane id up front so every exit path — short
        // audio, reuse, full pass, error — releases exactly once.
        let jobID = schedulerJobID
        schedulerJobID = nil

        // ParakeetModels intentionally remains resident between turns. Reflect
        // that truth in the registry; a cancelled start that never completed a
        // load leaves the registry in loading state until the shared load task
        // resolves, rather than falsely claiming the cache was unloaded.
        if let runtimeGeneration {
            if runtimeLoaded {
                _ = await ModelRuntimeManager.shared.markReady(
                    .parakeetASR,
                    generation: runtimeGeneration
                )
            }
            self.runtimeGeneration = nil
            runtimeLoaded = false
        }

        let activePartial = partialTask
        partialTask?.cancel()
        partialTask = nil
        queuedPartial = nil

        // Do not begin the final model pass while a provisional pass still owns the manager.
        // FluidAudio cancellation is cooperative, so the controller's finish deadline is
        // the upper bound on this wait rather than spawning two recognizers concurrently.
        await activePartial?.value

        defer {
            continuation?.finish()
            continuation = nil
            samples.removeAll(keepingCapacity: true)
            lastPartialAt = 0
            lastPartialText = ""
            lastCompletedPartialAt = 0
            partialTask = nil
            queuedPartial = nil
        }

        guard samples.count >= ParakeetInput.minimumCapturedSamples else {
            Log.speech.info("Parakeet: skipped — only \(self.samples.count) samples captured")
            if let jobID { await ComputeScheduler.shared.release(jobID) }
            return
        }

        let leftover = samples.count - lastCompletedPartialAt
        let reusable = !lastPartialText.isEmpty
            && leftover < reuseBelowSamples
            && lastCompletedPartialAt >= ParakeetInput.minimumModelSamples

        do {
            var text: String
            let elapsed: TimeInterval
            let audioSeconds = Double(samples.count) / 16_000

            if reusable {
                text = lastPartialText
                elapsed = 0
                Log.speech.info("""
                    Parakeet: reused partial (\(audioSeconds, format: .fixed(precision: 1))s audio, \
                    leftover \(Double(leftover) / 16_000, format: .fixed(precision: 2))s)
                    """)
            } else {
                let manager = try await ParakeetModels.shared.manager()
                var decoderState = try TdtDecoderState()
                let started = Date()
                // D-04: 0.1–0.3 s of audio is zero-padded to the model's 0.3 s
                // floor. Padding silence can make the model invent words on a
                // near-empty tap, so a long answer from almost no audio is
                // treated as empty.
                let realSamples = samples.count
                let result = try await manager.transcribe(
                    ParakeetInput.padded(samples), decoderState: &decoderState)
                elapsed = Date().timeIntervalSince(started)
                text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if realSamples < 3_200, text.split(whereSeparator: \.isWhitespace).count > 2 {
                    Log.speech.info("Parakeet: padded short audio produced words from noise — treating as empty")
                    text = ""
                }
                Log.speech.info("""
                    Parakeet: \(audioSeconds, format: .fixed(precision: 1))s audio in \
                    \(elapsed, format: .fixed(precision: 2))s (\(audioSeconds / max(elapsed, 0.0001), format: .fixed(precision: 0))× realtime)
                    """)
            }

            continuation?.yield(
                TranscriptionChunk(
                    text: text,
                    isFinal: true
                )
            )
        } catch {
            Log.speech.error("Parakeet failed: \(error.localizedDescription, privacy: .public)")
            continuation?.finish(throwing: error)
            continuation = nil
        }

        if let jobID { await ComputeScheduler.shared.release(jobID) }
    }

    private func releaseSchedulerLane() async {
        guard let jobID = schedulerJobID else { return }
        schedulerJobID = nil
        await ComputeScheduler.shared.release(jobID)
    }

    // MARK: - Partials

    /// Re-transcribes the buffer so far when enough new audio has arrived.
    /// Model work runs off the feed path's critical section via one bounded task;
    /// the audio thread only ever handed us a copied buffer.
    private func maybeEmitPartial() async {
        // A partial below the model's 0.3 s floor would only throw (D-04); it is
        // never padded — partials keep their cadence and their own audio.
        guard samples.count >= ParakeetInput.minimumModelSamples else { return }
        guard samples.count - lastPartialAt >= partialIntervalSamples else { return }

        let snapshot = samples
        let at = samples.count
        lastPartialAt = at

        if partialTask != nil {
            // Keep only the newest complete view of the audio. Older snapshots can never
            // improve the transcript and used to form an unbounded chain when inference lagged.
            queuedPartial = (snapshot, at)
            return
        }
        startPartial(snapshot: snapshot, at: at, generation: recognitionGeneration)
    }

    private func startPartial(snapshot: [Float], at: Int, generation: Int) {
        partialTask = Task { [weak self] in
            await self?.runPartial(snapshot: snapshot, at: at, generation: generation)
            await self?.partialDidFinish(generation: generation)
        }
    }

    private func partialDidFinish(generation: Int) {
        guard generation == recognitionGeneration else {
            partialTask = nil
            queuedPartial = nil
            return
        }
        partialTask = nil
        guard let queued = queuedPartial else { return }
        queuedPartial = nil
        startPartial(snapshot: queued.samples, at: queued.at, generation: generation)
    }

    private func runPartial(snapshot: [Float], at: Int, generation: Int) async {
        guard generation == recognitionGeneration, !Task.isCancelled else { return }
        do {
            let manager = try await ParakeetModels.shared.manager()
            var decoderState = try TdtDecoderState()
            let result = try await manager.transcribe(snapshot, decoderState: &decoderState)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard generation == recognitionGeneration, !Task.isCancelled else { return }
            guard !text.isEmpty else { return }
            lastPartialText = text
            lastCompletedPartialAt = at
            continuation?.yield(TranscriptionChunk(text: text, isFinal: false))
        } catch {
            // A failed partial must not kill the hold — finish() still has the buffer.
            Log.speech.error(
                "Parakeet partial failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}

/// Process-wide model cache.
///
/// Loading is expensive — ~470 MB downloaded on first ever run, then a few seconds from
/// disk per process — and the models are immutable once loaded, so every dictation shares
/// one instance rather than paying that per utterance. Its own actor because `static var`
/// on `ParakeetEngine` would be unprotected global mutable state under Swift 6.
///
/// Residency: `ModelResidencyPolicy.alwaysWarm` includes `.asr`. Under memory pressure
/// the policy unloads notes then diarization; it does not call into this actor. Keeping
/// Parakeet warm is deliberate — a cold ANE compile on the first utterance after a
/// pressure event is worse than the resident footprint while dictation or a meeting
/// may still need ASR.
actor ParakeetModels {
    static let shared = ParakeetModels()

    /// Whether the models are already on disk, checked without loading them.
    ///
    /// `nonisolated` and filesystem-based on purpose: the menu needs this synchronously
    /// while drawing, and an in-memory "have I loaded yet" flag would wrongly report
    /// "not downloaded" on every fresh launch.
    nonisolated static var isDownloaded: Bool {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = support.appendingPathComponent("FluidAudio/Models/parakeet-tdt-0.6b-v3")
        let required: [(String, Int64)] = [
            ("Encoder.mlmodelc/weights/weight.bin", 400_000_000),
            ("Decoder.mlmodelc/weights/weight.bin", 20_000_000),
            ("JointDecisionv3.mlmodelc/weights/weight.bin", 10_000_000),
            ("Preprocessor.mlmodelc/weights/weight.bin", 400_000),
            ("parakeet_v3_vocab.json", 100_000),
        ]
        let complete = required.allSatisfy { relativePath, minimumBytes in
            let url = root.appendingPathComponent(relativePath)
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                return false
            }
            return Int64(size) >= minimumBytes
        }
        guard complete else { return false }

        // FluidAudio resumes these files, but while one exists the CoreML directory itself
        // is already present. Never advertise that half-written directory as installed.
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let file = enumerator?.nextObject() as? URL {
            if file.lastPathComponent.contains(".partial") { return false }
        }
        return true
    }

    private var loaded: AsrManager?
    private var loadTask: Task<AsrManager, Error>?
    private let terminationFixtureRoot: URL?
    private let terminationFixtureTrace: StartupTerminationTrace?

    init() {
        terminationFixtureRoot = nil
        terminationFixtureTrace = nil
    }

    init(terminationFixtureRoot: URL, trace: StartupTerminationTrace) throws {
        self.terminationFixtureRoot = try NativeStartupTerminationSelfTest.validateAssets(terminationFixtureRoot, pocket: false)
        self.terminationFixtureTrace = trace
    }
    private var terminationRequested = false
    private var terminationLoadTask: Task<AsrManager, Error>?

    /// Quit owns the SAME coalesced load handle even if manager() later clears its slot.
    func beginTermination() {
        guard !terminationRequested else { return }
        terminationRequested = true
        terminationLoadTask = loadTask
        terminationLoadTask?.cancel()
    }

    /// Model preparation only: live recognition remains owned by engine/meeting callers.
    func finishTermination() async {
        beginTermination()
        if let owned = terminationLoadTask { _ = await owned.result }
        terminationLoadTask = nil
    }

    private func checkTerminationAdmission() throws {
        guard !terminationRequested else { throw CancellationError() }
        try Task.checkCancellation()
    }

    var isLoaded: Bool { loaded != nil }

    /// The loaded weights, kept so a second manager can share them.
    private var loadedModels: AsrModels?
    private var keyUp: AsrManager?

    /// A second `AsrManager` over the same loaded weights, for the dictation key-up pass.
    ///
    /// `AsrManager` is an actor, so a key-up pass on the shared manager would queue behind
    /// a stale partial still running on it. FluidAudio builds exactly this kind of clone
    /// for its own parallel chunk workers (`AsrManager.makeWorkerClone`: `init(config:models:)`
    /// over the same `MLModel` instances), so it costs no weights and no load — only the
    /// actor. Falls back to the shared manager when the weights are not held here.
    func keyUpManager() async throws -> AsrManager {
        let shared = try await manager()
        if let keyUp { return keyUp }
        guard let loadedModels else { return shared }
        let made = AsrManager(config: .default, models: loadedModels)
        keyUp = made
        return made
    }

    /// Loads once; concurrent callers await the same task rather than racing to download.
    func manager(progressHandler: ProgressHandler? = nil) async throws -> AsrManager {
        try checkTerminationAdmission()
        if let loaded { return loaded }
        if let loadTask {
            let existing = try await loadTask.value
            try checkTerminationAdmission()
            return existing
        }

        let task = Task<AsrManager, Error> {
            defer { terminationFixtureTrace?.taskEnded() }
            try checkTerminationAdmission()
            // Built as a value first: os.Logger requires a literal interpolation, so a
            // ternary can't be passed directly as the argument.
            let stage = terminationFixtureRoot != nil ? "loading isolated public model copy" : (Self.isDownloaded
                ? "loading models from disk"
                : "downloading models (~470 MB, one time)")
            Log.speech.info("Parakeet: \(stage, privacy: .public)")
            let started = Date()
            // ANE is FluidAudio's default and the bench path (~100× realtime). CPU-only was
            // a reliability hedge: first ANE compile can stall, and GPU can wedge
            // MTLCompilerService on macOS 26. That hedge made every release wait 10–15s on
            // this machine — comfortably is not what the runs show. We already warm the
            // models at launch, so the compile stall lands on startup rather than on the
            // utterance, and `.cpuAndNeuralEngine` never opens the GPU path. CPU remains
            // the fallback if ANE refuses to load, not the steady state.
            let models: AsrModels
            do {
                if let root = terminationFixtureRoot {
                    terminationFixtureTrace?.loadEntered(pocket: false)
                    defer { terminationFixtureTrace?.loadReturned() }
                    let trace = terminationFixtureTrace
                    let progress: ProgressHandler = { update in
                        trace?.progress(update)
                        progressHandler?(update)
                    }
                    models = try await AsrModels.load(
                        from: root.appendingPathComponent(Repo.parakeetV3.folderName),
                        version: .v3, encoderPrecision: .int8,
                        encoderComputeUnits: .cpuAndNeuralEngine, progressHandler: progress
                    )
                } else {
                models = try await AsrModels.downloadAndLoad(
                    version: .v3,
                    encoderPrecision: .int8,
                    encoderComputeUnits: .cpuAndNeuralEngine,
                    progressHandler: progressHandler
                )
                }
            } catch {
                // Cancellation/quit is not evidence that ANE needs a CPU replacement.
                try checkTerminationAdmission()
                if error is CancellationError { throw error }
                Log.speech.error(
                    "Parakeet: Neural Engine load failed — \(error.localizedDescription, privacy: .public) — retrying on CPU"
                )
                if let root = terminationFixtureRoot {
                    terminationFixtureTrace?.loadEntered(pocket: false)
                    defer { terminationFixtureTrace?.loadReturned() }
                    let trace = terminationFixtureTrace
                    let progress: ProgressHandler = { update in
                        trace?.progress(update)
                        progressHandler?(update)
                    }
                    models = try await AsrModels.load(
                        from: root.appendingPathComponent(Repo.parakeetV3.folderName),
                        version: .v3, encoderPrecision: .int8,
                        encoderComputeUnits: .cpuOnly, progressHandler: progress
                    )
                } else {
                models = try await AsrModels.downloadAndLoad(
                    version: .v3,
                    encoderPrecision: .int8,
                    encoderComputeUnits: .cpuOnly,
                    progressHandler: progressHandler
                )
                }
            }
            try checkTerminationAdmission()
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            loadedModels = models
            try checkTerminationAdmission()
            Log.speech.info("Parakeet: ready in \(Date().timeIntervalSince(started), format: .fixed(precision: 1))s")
            return manager
        }
        loadTask = task
        terminationFixtureTrace?.assigned()

        do {
            let manager = try await task.value
            try checkTerminationAdmission()
            loaded = manager
            terminationFixtureTrace?.readyPublished()
            return manager
        } catch {
            // Don't cache a failed load — a transient download error shouldn't wedge the
            // engine for the rest of the session.
            loadTask = nil
            throw error
        }
    }
}

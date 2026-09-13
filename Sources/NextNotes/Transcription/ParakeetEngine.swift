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
    /// Most recent provisional text — reused on release when leftover audio is short.
    private var lastPartialText = ""
    /// Serialises provisional passes so two CoreML calls never overlap inside one hold.
    private var partialTail: Task<Void, Never>?

    /// `ComputeScheduler` lane held for this engine instance from successful
    /// `start()` through `finish()`. Notes take `.background` and checkpoint;
    /// holding `.realtimeASR` here is what makes them park during live ASR.
    /// Owned by this engine so a superseded start releases *its* job, not a
    /// later hold's.
    private var schedulerJobID: UUID?
    /// Bumped by `finish()` (and each new `start()`) so a start that was
    /// suspended across `acquire` / model load can tell it was cancelled and
    /// release its own lane — actors are re-entrant at `await`.
    private var recognitionGeneration = 0

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
        partialTail = nil
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
        let jobID = await ComputeScheduler.shared.acquire(.realtimeASR)
        guard recognitionGeneration == generation else {
            await ComputeScheduler.shared.release(jobID)
            continuation.finish()
            self.continuation = nil
            throw CancellationError()
        }
        schedulerJobID = jobID
        do {
            // Force the (possibly very slow) first load to happen here rather than on release,
            // so the user waits before speaking instead of losing an utterance to a timeout.
            _ = try await ParakeetModels.shared.manager()
        } catch {
            await releaseSchedulerLane()
            throw error
        }
        guard recognitionGeneration == generation else {
            await releaseSchedulerLane()
            continuation.finish()
            self.continuation = nil
            throw CancellationError()
        }

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

        defer {
            continuation?.finish()
            continuation = nil
            samples.removeAll(keepingCapacity: true)
            lastPartialAt = 0
            lastPartialText = ""
            partialTail = nil
        }

        // Let any in-flight provisional land before deciding whether to reuse it.
        await partialTail?.value

        guard samples.count >= 1_600 else {
            Log.speech.info("Parakeet: skipped — only \(self.samples.count) samples captured")
            if let jobID { await ComputeScheduler.shared.release(jobID) }
            return
        }

        let leftover = samples.count - lastPartialAt
        let reusable = !lastPartialText.isEmpty
            && leftover < reuseBelowSamples
            && lastPartialAt >= 1_600

        do {
            let text: String
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
                let result = try await manager.transcribe(samples, decoderState: &decoderState)
                elapsed = Date().timeIntervalSince(started)
                text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
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
    /// Model work runs off the feed path's critical section via `partialTail`;
    /// the audio thread only ever handed us a copied buffer.
    private func maybeEmitPartial() async {
        guard samples.count >= 1_600 else { return }
        guard samples.count - lastPartialAt >= partialIntervalSamples else { return }

        let snapshot = samples
        let at = samples.count
        lastPartialAt = at

        let previous = partialTail
        partialTail = Task {
            await previous?.value
            await self.runPartial(snapshot: snapshot)
        }
    }

    private func runPartial(snapshot: [Float]) async {
        do {
            let manager = try await ParakeetModels.shared.manager()
            var decoderState = try TdtDecoderState()
            let result = try await manager.transcribe(snapshot, decoderState: &decoderState)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            lastPartialText = text
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

    var isLoaded: Bool { loaded != nil }

    /// Loads once; concurrent callers await the same task rather than racing to download.
    func manager(progressHandler: ProgressHandler? = nil) async throws -> AsrManager {
        if let loaded { return loaded }
        if let loadTask { return try await loadTask.value }

        let task = Task<AsrManager, Error> {
            // Built as a value first: os.Logger requires a literal interpolation, so a
            // ternary can't be passed directly as the argument.
            let stage = Self.isDownloaded
                ? "loading models from disk"
                : "downloading models (~470 MB, one time)"
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
                models = try await AsrModels.downloadAndLoad(
                    version: .v3,
                    encoderPrecision: .int8,
                    encoderComputeUnits: .cpuAndNeuralEngine,
                    progressHandler: progressHandler
                )
            } catch {
                Log.speech.error(
                    "Parakeet: Neural Engine load failed — \(error.localizedDescription, privacy: .public) — retrying on CPU"
                )
                models = try await AsrModels.downloadAndLoad(
                    version: .v3,
                    encoderPrecision: .int8,
                    encoderComputeUnits: .cpuOnly,
                    progressHandler: progressHandler
                )
            }
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            Log.speech.info("Parakeet: ready in \(Date().timeIntervalSince(started), format: .fixed(precision: 1))s")
            return manager
        }
        loadTask = task

        do {
            let manager = try await task.value
            loaded = manager
            return manager
        } catch {
            // Don't cache a failed load — a transient download error shouldn't wedge the
            // engine for the rest of the session.
            loadTask = nil
            throw error
        }
    }
}

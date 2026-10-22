import AVFoundation
import CoreML
import FluidAudio
import Foundation

/// NVIDIA Parakeet TDT 0.6B, compiled to CoreML and run locally via FluidAudio.
///
/// **Segments are transcribed once, while the key is held.** `DictationSegmenter` cuts the
/// hold at pauses (≥ 3 s per segment, hard cap 14.5 s), and each cut segment is transcribed
/// on its own and its text frozen. Live text re-runs only the **open tail** — every second
/// of new speech, and immediately when the speaker stops — so a model pass never covers
/// more than one native 15 s encoder window, whatever the length of the hold. The old
/// engine re-transcribed the whole buffer every second: O(n²), 82 s of model time inside a
/// 120 s hold, and a key-up pass over everything.
///
/// **Key-up reuses only covered audio.** The end-of-speech event starts a tail pass while
/// the key is still held. `finish()` asks `ParakeetKeyUp.plan` what accepted PCM is still
/// missing: nothing (all samples are covered), the pass already running, or one fresh pass
/// over the uncovered tail. That pass starts on a second manager over the same weights
/// rather than queueing behind a stale partial. A pause's RMS floor cannot establish that
/// quiet captured words are absent, so it is not the final-reuse boundary.
///
/// **The `.realtimeASR` lane is held per model pass**, not for the whole hold. Notes and
/// the pre-clean LLM jobs run in the gaps between passes and park again (at their next
/// checkpoint) for each one. `start()` still owns the lane around a cold model load.
/// Models stay warm via `ParakeetModels`.
actor ParakeetEngine: TranscriptionEngine {
    /// Self-test probe: the engine yields non-final chunks during a hold.
    nonisolated static let emitsPartialsWhileHeld = true

    private var samples: [Float] = []
    /// Absolute start of retained uncommitted PCM. Retry audio belongs to AudioCounter.
    private var sampleOffset = 0
    private var sampleCount: Int { sampleOffset + samples.count }
    private var continuation: AsyncThrowingStream<TranscriptionChunk, Error>.Continuation?

    // MARK: Segments

    private var segmenter = DictationSegmenter()
    /// Cuts found but not transcribed yet, in order.
    private var pendingCuts: [Int] = []
    /// The frozen text of every transcribed segment, in order.
    private var committedText = ""
    private var committedSegments = 0
    /// Where the transcribed segments end: the start of the open tail.
    private var committedEnd = 0

    // MARK: Tail partials

    /// Sample count at which the last tail pass was requested.
    private var lastTailRequestAt = 0
    private var tailRequested = false
    /// The newest completed tail pass, kept for key-up when nothing was said after it.
    private var tailPartial: (start: Int, end: Int, text: String)?

    // MARK: Work

    /// One model pass at a time while the key is down. The pass itself is a separate task
    /// so `finish()` can await exactly that pass (or leave a stale one behind).
    private var worker: Task<Void, Never>?
    private var inflight: (pass: ParakeetKeyUp.Pass, task: Task<String?, Never>)?
    /// The session the worker serves; nil outside start()…finish().
    private var activeSession: Int?
    /// Set by `finish()`: from here on it, not the worker, owns every result.
    private var finishing = false

    // MARK: Lane

    /// `ComputeScheduler` lane held around a cold model load in `start()`. Owned by this
    /// engine so a superseded start releases *its* job, not a later hold's.
    private var schedulerJobID: UUID?
    /// One `.realtimeASR` job shared by this engine's overlapping passes (the key-up pass
    /// can run beside a stale partial). Released when the last of them leaves.
    private var laneAcquire: Task<UUID, Never>?
    private var laneHolders = 0
    /// Seconds `start()` waited for the lane (F-01), and the sum over every pass since.
    private var startLaneWaitSeconds: TimeInterval = 0
    private var passLaneWaitSeconds: TimeInterval = 0

    /// What this hold's ASR waited on the shared `.realtimeASR` lane: the start's wait
    /// around a cold load plus every model pass's own wait (F-01). With the lane held per
    /// pass rather than for the whole hold, a dictation that queued behind a meeting window
    /// queues at its passes, so that sum is the honest answer to "was it ever blocked?".
    /// Read by the tail after `finish()` for the `dictation.asr` usage row.
    var startLaneWait: TimeInterval { startLaneWaitSeconds + passLaneWaitSeconds }

    /// Bumped by `finish()` (and each new `start()`) so a start that was
    /// suspended across `acquire` / model load can tell it was cancelled and
    /// release its own lane — actors are re-entrant at `await`.
    private var recognitionGeneration = 0
    /// Lifecycle token in the shared model registry. Kept separate from the
    /// engine generation because a stale model load may finish after a new
    /// recognition session has already started.
    private var runtimeGeneration: UInt64?
    private var runtimeLoaded = false

    /// Measurements of the last hold, read by `--selftest-dictation-segments`.
    struct Diagnostics: Sendable {
        var passes = 0
        var segmentPasses = 0
        var computeSeconds: TimeInterval = 0
        /// One entry per emitted partial: the audio it covers (samples) and when it landed.
        var partials: [(end: Int, at: TimeInterval)] = []
        var keyUpPlan = ""
        var keyUpSeconds: TimeInterval = 0
        var finalText = ""
    }
    private(set) var diagnostics = Diagnostics()

    private let converter = AudioConverter()

    private var partialIntervalSamples: Int {
        Int(StreamingASR.dictationPartialIntervalSeconds * 16_000)
    }

    func preferredInputFormat() async -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
    }

    func start() async throws -> AsyncThrowingStream<TranscriptionChunk, Error> {
        let generation = recognitionGeneration &+ 1
        recognitionGeneration = generation

        // A previous session's pass may still be running on the Neural Engine; it cannot be
        // stopped, and its result is ignored (`activeSession` no longer matches). Nothing
        // here waits for it: two managers can run side by side over the shared weights.
        activeSession = nil
        worker?.cancel()
        worker = nil
        resetSession()
        // Not in `resetSession()`: the tail reads both after `finish()`.
        startLaneWaitSeconds = 0
        passLaneWaitSeconds = 0
        diagnostics = Diagnostics()
        // A previous start that never reached finish must not leave a stale id;
        // only this instance's lane is released below on failure.
        await releaseSchedulerLane()

        let (stream, continuation) = AsyncThrowingStream<TranscriptionChunk, Error>.makeStream()
        self.continuation = continuation

        // The lane is held around a cold load only: loading compiles for the Neural Engine,
        // and notes checkpoints must yield to it. A warm start has nothing to schedule, and
        // each model pass takes the lane itself. How long the queueing took is measured
        // where it happens (F-01), before the generation check, so a start that was
        // cancelled while parked still files what it waited.
        if !(await ParakeetModels.shared.isLoaded) {
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
        }
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
        await releaseSchedulerLane()
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
            continuation.finish()
            self.continuation = nil
            throw CancellationError()
        }

        _ = await ModelRuntimeManager.shared.markBusy(
            .parakeetASR,
            generation: runtimeGeneration
        )
        activeSession = generation
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
        schedule()
    }

    func finish() async {
        // Invalidate any in-flight start suspended across acquire / load.
        recognitionGeneration &+= 1
        finishing = true
        let keyUp = Date()

        // A start that was cancelled mid-load may still hold its lane.
        await releaseSchedulerLane()

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

        defer {
            continuation?.finish()
            continuation = nil
            activeSession = nil
            worker = nil
            resetSession()
        }

        guard sampleCount >= ParakeetInput.minimumCapturedSamples else {
            Log.speech.info("Parakeet: skipped — only \(self.sampleCount) samples captured")
            return
        }

        // Every complete frame, so "was anything said after this pass" sees the last word.
        _ = segmenter.advance(over: samples, sampleOffset: sampleOffset)
        let total = sampleCount
        let committed = committedText
        let plan = ParakeetKeyUp.plan(
            committedEnd: committedEnd,
            hasCommitted: committedSegments > 0,
            tail: tailPartial.map { ParakeetKeyUp.Pass(isSegment: false, start: $0.start, end: $0.end) },
            inflight: inflight?.pass,
            capturedEnd: total
        )

        do {
            var texts = committedText.isEmpty ? [] : [committedText]
            switch plan {
            case .reuseTail:
                texts.append(tailPartial?.text ?? "")
            case .committedOnly:
                break
            case .awaitInflight:
                if let text = await inflight?.task.value {
                    texts.append(text)
                } else {
                    // The pass failed: transcribe what it was for, once, now.
                    texts.append(try await keyUpPass(from: committedEnd, to: total))
                }
            case .awaitSegmentAndTranscribe(let from):
                // Both start now: the remainder is not queued behind the segment.
                async let rest = keyUpPass(from: from, to: total)
                if let segment = await inflight?.task.value {
                    texts.append(segment)
                    texts.append(try await rest)
                } else {
                    _ = try? await rest
                    texts.append(try await keyUpPass(from: committedEnd, to: total))
                }
            case .transcribe(let from):
                texts.append(try await keyUpPass(from: from, to: total))
            }

            let text = joined(texts)
            let waited = Date().timeIntervalSince(keyUp)
            diagnostics.keyUpPlan = plan.name
            diagnostics.keyUpSeconds = waited
            diagnostics.finalText = text
            Log.speech.info("""
                Parakeet: final \(Double(total) / 16_000, format: .fixed(precision: 1))s audio, \
                \(self.committedSegments) segment(s), key-up \(plan.name, privacy: .public) \
                in \(waited, format: .fixed(precision: 3))s
                """)
            continuation?.yield(
                TranscriptionChunk(text: text, isFinal: true, committedText: committed)
            )
        } catch {
            Log.speech.error("Parakeet failed: \(error.localizedDescription, privacy: .public)")
            continuation?.finish(throwing: error)
            continuation = nil
        }
    }

    private func releaseSchedulerLane() async {
        guard let jobID = schedulerJobID else { return }
        schedulerJobID = nil
        await ComputeScheduler.shared.release(jobID)
    }

    private func resetSession() {
        samples.removeAll(keepingCapacity: false)
        sampleOffset = 0
        segmenter = DictationSegmenter()
        pendingCuts = []
        committedText = ""
        committedSegments = 0
        committedEnd = 0
        lastTailRequestAt = 0
        tailRequested = false
        tailPartial = nil
        inflight = nil
        finishing = false
    }

    private func joined(_ texts: [String]) -> String {
        texts.filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: - While the key is down

    /// Cuts and tail requests for the audio just fed, and the worker if it is idle.
    private func schedule() {
        guard let session = activeSession, !finishing else { return }
        let scan = segmenter.advance(over: samples, sampleOffset: sampleOffset)
        pendingCuts += scan.cuts
        let spokeSinceRequest = segmenter.lastSpeechEnd > lastTailRequestAt
        let tailLength = sampleCount - committedEnd
        let interval = diagnostics.partials.isEmpty && lastTailRequestAt == 0
            ? Int(StreamingASR.dictationFirstPartialSeconds * 16_000)
            : partialIntervalSamples
        if tailLength >= ParakeetInput.minimumModelSamples, spokeSinceRequest,
           scan.speechEnded || sampleCount - lastTailRequestAt >= interval {
            // End of speech starts the tail pass at once: by key-up it is usually done.
            tailRequested = true
            lastTailRequestAt = sampleCount
        }
        if worker == nil, !pendingCuts.isEmpty || tailRequested {
            worker = Task { [weak self] in await self?.drain(session: session) }
        }
    }

    /// Runs segment passes (in order) and then the newest tail pass, one at a time.
    private func drain(session: Int) async {
        while activeSession == session, !finishing, let pass = nextPass() {
            let audio = Array(samples[(pass.start - sampleOffset)..<(pass.end - sampleOffset)])
            let task = Task { [weak self] () -> String? in
                await self?.modelPass(audio, isSegment: pass.isSegment)
            }
            inflight = (pass, task)
            let text = await task.value
            // From key-up on, `finish()` owns the in-flight pass and its result.
            guard activeSession == session, !finishing else { return }
            inflight = nil
            if pass.isSegment {
                pendingCuts.removeFirst()
                // A failed segment pass leaves its audio in the open tail.
                guard let text else { continue }
                if !text.isEmpty {
                    if !committedText.isEmpty { committedText.append(" ") }
                    committedText.append(text)
                }
                committedSegments += 1
                committedEnd = pass.end
                // Only a successful segment can retire PCM. In-flight passes already
                // own copied audio; failures keep every uncommitted sample for key-up.
                samples = Array(samples[(committedEnd - sampleOffset)...])
                sampleOffset = committedEnd
                tailPartial = nil
                // Publish the frozen prefix now, even if another tail pass is needed.
                // Hiding this behind that pass delayed both the live UI and pre-cleaning.
                emitPartial(end: pass.end)
                if segmenter.lastSpeechEnd > committedEnd,
                   sampleCount - committedEnd >= ParakeetInput.minimumModelSamples {
                    tailRequested = true
                    lastTailRequestAt = sampleCount
                }
            } else if let text, !text.isEmpty {
                tailPartial = (pass.start, pass.end, text)
                emitPartial(end: pass.end)
            }
        }
        if activeSession == session, !finishing { worker = nil }
    }

    private func nextPass() -> ParakeetKeyUp.Pass? {
        if let cut = pendingCuts.first {
            return ParakeetKeyUp.Pass(isSegment: true, start: committedEnd, end: cut)
        }
        guard tailRequested else { return nil }
        tailRequested = false
        // A tail with no speech in it (a segment just took the last words) needs no pass.
        guard sampleCount - committedEnd >= ParakeetInput.minimumModelSamples,
              segmenter.lastSpeechEnd > committedEnd else { return nil }
        return ParakeetKeyUp.Pass(isSegment: false, start: committedEnd, end: sampleCount)
    }

    private func emitPartial(end: Int) {
        var texts = committedText.isEmpty ? [] : [committedText]
        if let tail = tailPartial, tail.start == committedEnd { texts.append(tail.text) }
        let text = joined(texts)
        guard !text.isEmpty else { return }
        diagnostics.partials.append((end, ProcessInfo.processInfo.systemUptime))
        continuation?.yield(
            TranscriptionChunk(text: text, isFinal: false, committedText: committedText)
        )
    }

    // MARK: - Model passes

    /// One pass while the key is down. A failed pass must not kill the hold — `finish()`
    /// still has the audio — so it is logged and answered with nil.
    private func modelPass(_ audio: [Float], isSegment: Bool) async -> String? {
        do {
            let manager = try await ParakeetModels.shared.manager()
            return try await transcribe(audio, with: manager, isSegment: isSegment)
        } catch {
            Log.speech.error(
                "Parakeet partial failed: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// The key-up pass over `[from, to)`. On the second manager, so it never queues behind
    /// a stale partial still running on the first.
    private func keyUpPass(from: Int, to: Int) async throws -> String {
        let audio = Array(samples[(from - sampleOffset)..<(to - sampleOffset)])
        let manager = try await ParakeetModels.shared.keyUpManager()
        var text = try await transcribe(ParakeetInput.padded(audio), with: manager, isSegment: false)
        // D-04: 0.1–0.3 s of audio is zero-padded to the model's 0.3 s floor. Padding
        // silence can make the model invent words on a near-empty tap, so a long answer
        // from almost no audio is treated as empty.
        if audio.count < 3_200, text.split(whereSeparator: \.isWhitespace).count > 2 {
            Log.speech.info("Parakeet: padded short audio produced words from noise — treating as empty")
            text = ""
        }
        return text
    }

    /// One model pass inside the shared `.realtimeASR` lane.
    private func transcribe(_ audio: [Float], with manager: AsrManager, isSegment: Bool) async throws -> String {
        await enterLane()
        let started = Date()
        do {
            var decoderState = try TdtDecoderState()
            let result = try await manager.transcribe(audio, decoderState: &decoderState)
            await leaveLane()
            diagnostics.passes += 1
            if isSegment { diagnostics.segmentPasses += 1 }
            diagnostics.computeSeconds += Date().timeIntervalSince(started)
            return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            await leaveLane()
            throw error
        }
    }

    /// Joins (or takes) this engine's `.realtimeASR` job. The first pass in acquires it and
    /// records the wait; a pass that overlaps one already running shares its job.
    private func enterLane() async {
        laneHolders += 1
        if let laneAcquire {
            _ = await laneAcquire.value
            return
        }
        let began = Date()
        let acquire = Task { await ComputeScheduler.shared.acquire(.realtimeASR) }
        laneAcquire = acquire
        _ = await acquire.value
        passLaneWaitSeconds += Date().timeIntervalSince(began)
    }

    private func leaveLane() async {
        laneHolders -= 1
        guard laneHolders == 0, let acquire = laneAcquire else { return }
        laneAcquire = nil
        await ComputeScheduler.shared.release(await acquire.value)
    }
}

/// What key-up still has to transcribe. Pure, so `--selftest-dictation-segments` pins the
/// decision without a model.
enum ParakeetKeyUp {
    /// A model pass over `[start, end)` of the hold.
    struct Pass: Equatable, Sendable {
        var isSegment: Bool
        var start: Int
        var end: Int
    }

    enum Plan: Equatable, Sendable {
        /// The last completed tail pass covers every captured frame: no model work.
        case reuseTail
        /// All captured audio is already committed: no model work.
        case committedOnly
        /// The pass already running covers every captured frame: wait for it, start nothing.
        case awaitInflight
        /// The running segment pass is still needed, and the speech after it gets its own
        /// pass, started now beside it.
        case awaitSegmentAndTranscribe(from: Int)
        /// One pass from `from` to the end, started now. A running tail pass that does not
        /// reach the last word is stale and is not waited for.
        case transcribe(from: Int)

        var name: String {
            switch self {
            case .reuseTail: "reused-tail"
            case .committedOnly: "committed-only"
            case .awaitInflight: "awaited-inflight"
            case .awaitSegmentAndTranscribe: "segment+tail-pass"
            case .transcribe: "tail-pass"
            }
        }
    }

    /// - Parameters:
    ///   - capturedEnd: exclusive end of every accepted sample. An RMS silence decision
    ///     locates pauses; it cannot prove that recognizable quiet words are absent.
    ///   - hasCommitted: whether a successful segment is frozen, including an empty answer.
    ///     A hold with no successful segment still receives its final pass.
    static func plan(
        committedEnd: Int,
        hasCommitted: Bool,
        tail: Pass?,
        inflight: Pass?,
        capturedEnd: Int
    ) -> Plan {
        if let tail, tail.start == committedEnd, capturedEnd <= tail.end {
            return .reuseTail
        }
        if let inflight, inflight.start == committedEnd {
            if capturedEnd <= inflight.end { return .awaitInflight }
            if inflight.isSegment { return .awaitSegmentAndTranscribe(from: inflight.end) }
        }
        if hasCommitted, capturedEnd <= committedEnd { return .committedOnly }
        return .transcribe(from: committedEnd)
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

    /// Wake confirmation borrows only an already-resident manager. Never wait for
    /// loadTask, inspect installed files, clone weights, download, or call manager().
    func residentManager() -> AsrManager? {
        guard !terminationRequested, !Task.isCancelled else { return nil }
        return loaded
    }

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

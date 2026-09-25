import FluidAudio
import Foundation

/// Turns one continuous audio track into transcript segments while it is still running.
///
/// Parakeet is a batch engine — it transcribes a window and returns — so a meeting has to
/// be cut into windows somewhere. The live tier cuts **2–5 s** windows so the UI can show
/// provisional text quickly (roadmap §11 moved them down from 30–60 s for exactly that).
/// Cutting on a clock alone would slice words in half, so the cut still waits for a pause:
/// after the provisional minimum of audio the first gap of at least 600 ms ends the window,
/// and a hard limit of five seconds keeps an uninterrupted monologue from growing without
/// bound.
///
/// The 2–5 s windows are the live tier only. After Stop, `MeetingFinalPass` re-reads each
/// track in long windows (`WindowConfig.finals`, same pause rule) and replaces the finals,
/// keeping the live transcript as `transcript.live.json` — short windows flip French into
/// English-sounding text, and only the long tier gives the decoder enough context.
/// A window is a unit of *compute*, not of speech, so it is cut again before finals leave:
/// Parakeet's per-token times are grouped into words and split at the pauses inside the
/// window, and each utterance becomes its own segment. Everything downstream that feeds
/// diarization still reads turns rather than multi-second blocks — which is what lets
/// diarization put a speaker on each one instead of on the whole window. Provisional
/// emissions may show the raw window text early; finals keep the punctuation rule.
///
/// One instance per `AudioSource`. They share `TranscriptionQueue`, because the two of them
/// running CoreML concurrently on an 8-core M3 is slower than running them one at a time.
actor ChunkedTranscriber {
    typealias SegmentHandler = @Sendable (TranscriptSegment) async -> Void
    typealias ProvisionalHandler = @Sendable (TranscriptEvent) async -> Void

    /// Parakeet's training rate. Feeding anything else transcribes silently-wrong text.
    static let sampleRate: Double = 16_000
    /// Maximum number of windows retained by one track while Parakeet catches up. Newest
    /// windows are dropped after this point so a stalled model cannot grow memory forever.
    static let maxPendingWindows = 8
    /// Maximum audio one track may keep queued while Parakeet catches up, in seconds
    /// (M-07). The old window count was sized for 30–60 s windows and read as 16–40 s of
    /// tolerance once the live tier moved to 2–5 s; seconds are what memory and loss are
    /// actually made of. ≈ 19 MB of Float32 per track at 300 s. Do not raise this above
    /// 300 s without a memory measurement.
    static let maxPendingAudioSeconds: TimeInterval = 300
    /// Merging ceiling for one transcribed batch: one native FluidAudio encoder pass
    /// (anything ≤ 15 s is padded to a full 15 s pass, so a 14 s pass costs about what a
    /// 2 s pass costs). The same number M-01 measured for the final tier's maximum.
    static let maxMergedWindowSeconds: TimeInterval = StreamingASR.meetingFinalMaxSeconds

    /// Meeting ASR window sizes. Defaults are the 2–5 s provisional path; `.legacy`
    /// preserves the old 30/60 numbers for comparison in self-tests.
    struct WindowConfig: Sendable, Equatable {
        var minWindowSeconds: TimeInterval
        var maxWindowSeconds: TimeInterval
        /// Reserved for a future overlapping-ASR path. Advancing the buffer by a
        /// partial cut today would double-emit finals into diarization, so the
        /// default keeps this at zero and relies on the short window for latency.
        var overlapSeconds: TimeInterval
        /// When true, each transcribed window also emits a provisional event before the
        /// sentence/pause split that produces finals.
        var emitsProvisionals: Bool

        static let `default` = WindowConfig(
            minWindowSeconds: StreamingASR.meetingProvisionalMinSeconds,
            maxWindowSeconds: StreamingASR.meetingProvisionalMaxSeconds,
            overlapSeconds: StreamingASR.meetingOverlapSeconds,
            emitsProvisionals: true
        )

        /// M-01 final-pass sizes: long windows cut at pauses, no provisionals. The live
        /// tier keeps `.default`; the pass after Stop cuts with this.
        static let finals = WindowConfig(
            minWindowSeconds: StreamingASR.meetingFinalMinSeconds,
            maxWindowSeconds: StreamingASR.meetingFinalMaxSeconds,
            overlapSeconds: 0,
            emitsProvisionals: false
        )

        /// Pre-Wave-2 sizes — only for self-tests that assert we moved off this path.
        static let legacy = WindowConfig(
            minWindowSeconds: 30,
            maxWindowSeconds: 60,
            overlapSeconds: 0,
            emitsProvisionals: false
        )

        var minWindowSamples: Int { Int(minWindowSeconds * ChunkedTranscriber.sampleRate) }
        var maxWindowSamples: Int { Int(maxWindowSeconds * ChunkedTranscriber.sampleRate) }
    }

    /// Silence is measured on 20 ms frames: short enough to find the edge of a pause,
    /// long enough that one plosive doesn't read as speech.
    private static let frameSamples = 320
    /// Linear RMS below which a frame counts as silence — roughly -40 dBFS, under the
    /// noise floor of a built-in microphone in a quiet room but above digital silence.
    private static let silenceThreshold: Float = 0.01
    private static let silenceSamples = Int(0.6 * sampleRate)
    /// The pause that ends an utterance *within* a window, in seconds.
    ///
    /// Keep at 600 ms — lowering this to ~0.4 s cuts mid-clause because that is where
    /// breath gaps actually land on Parakeet's 80 ms token grid.
    private static let utteranceGap: TimeInterval = 0.6
    /// A finished sentence also ends a segment, once the segment is at least this long.
    ///
    /// The pause rule alone is not enough, and measuring told us why: Parakeet reports
    /// token times on an 80 ms grid, and on continuous speech the largest gap between two
    /// words runs about half a second and falls wherever the speaker drew breath — often
    /// mid-clause. Punctuation is the signal that actually tracks meaning. The floor is
    /// what keeps "Right." from becoming its own row.
    private static let minSentenceSeconds: TimeInterval = 2.0
    /// Characters that end a sentence, once trailing quotes and brackets are peeled off.
    private static let sentenceTerminators: Set<Character> = [".", "?", "!", "…"]
    /// Parakeet's encoder needs a minimum window; anything shorter is a click, not speech.
    private static let minTranscribableSamples = 1_600

    private let source: AudioSource
    private let config: WindowConfig
    private let meetingID: UUID?
    private let onSegment: SegmentHandler
    private let onProvisional: ProvisionalHandler?
    /// The model call, injected so `--selftest-meeting-backlog` can put a slow fake
    /// behind the queue (M-07). Production passes nothing and gets the shared lane.
    private let transcribe: @Sendable ([Float]) async throws -> ASRResult

    private var buffer: [Float] = []
    /// Absolute position of `buffer[0]` in the recording, in samples.
    private var bufferOrigin = 0
    /// How far into `buffer` silence detection has already looked.
    private var scanned = 0
    /// Length, in samples, of the silence run ending at `scanned`.
    private var silenceRun = 0

    /// Windows are transcribed in a chain rather than in parallel tasks, so segments reach
    /// the session in the order they were spoken.
    private var pending: Task<Void, Never>?
    private var pendingCount = 0
    private var generation = 0
    /// Audio this track shed because the backlog was full (M-07). The seconds are logged
    /// at Stop — "the final pass covers them" when `audio.caf` exists — and each drop
    /// also writes its `meeting.windows_dropped` span.
    private var droppedSamples = 0

    /// Seconds of this track's audio the live tier skipped. Nothing more than a counter:
    /// the final pass re-reads `audio.caf` and covers what this reports.
    var droppedAudioSeconds: Double { Double(droppedSamples) / Self.sampleRate }

    init(
        source: AudioSource,
        config: WindowConfig = .default,
        meetingID: UUID? = nil,
        onProvisional: ProvisionalHandler? = nil,
        transcribe: @escaping @Sendable ([Float]) async throws -> ASRResult = {
            try await TranscriptionQueue.shared.transcribe($0)
        },
        onSegment: @escaping SegmentHandler
    ) {
        self.source = source
        self.config = config
        self.meetingID = meetingID
        self.onProvisional = onProvisional
        self.transcribe = transcribe
        self.onSegment = onSegment
    }

    /// Appends 16 kHz mono samples. Never suspends: a suspension here would let a second
    /// `append` interleave and reorder the recording.
    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        buffer.append(contentsOf: samples)

        while let cut = nextCut() {
            enqueue(window: Array(buffer[0..<cut]))
            buffer.removeFirst(cut)
            bufferOrigin += cut
            scanned = max(0, scanned - cut)
            silenceRun = 0
        }
    }

    /// Transcribes whatever is left and waits for every queued window to finish.
    func flush() async {
        if !buffer.isEmpty {
            enqueue(window: buffer)
            bufferOrigin += buffer.count
            buffer.removeAll(keepingCapacity: false)
            scanned = 0
            silenceRun = 0
        }
        await pending?.value
        pending = nil
        // P0-20b: one `meeting.transcribe` row per track, assembled from the window
        // outcomes `transcribe(window:…)` noted while the queue drained.
        if let row = await MeetingTranscribeTally.shared.drain(meetingID: meetingID, source: source) {
            UsageLog.shared.record(row)
        }
    }

    /// Cancel queued work when a meeting session is abandoned. The generation check also
    /// prevents a task that was already inside FluidAudio from publishing stale segments.
    func cancel() {
        generation &+= 1
        pending?.cancel()
        pending = nil
        pendingCount = 0
        buffer.removeAll(keepingCapacity: false)
        bufferOrigin = 0
        scanned = 0
        silenceRun = 0
    }

    // MARK: - Windowing

    /// - Returns: how many samples to cut from the front of `buffer`, or `nil` to wait.
    private func nextCut() -> Int? {
        while scanned + Self.frameSamples <= buffer.count {
            let frame = buffer[scanned..<(scanned + Self.frameSamples)]
            if Self.frameIsSilent(frame) {
                silenceRun += Self.frameSamples
            } else {
                silenceRun = 0
            }
            scanned += Self.frameSamples

            // Cut at the end of the pause, so the next window starts on speech rather than
            // opening with the silence we just measured.
            if scanned >= config.minWindowSamples, silenceRun >= Self.silenceSamples {
                return scanned
            }
        }
        return buffer.count >= config.maxWindowSamples ? config.maxWindowSamples : nil
    }

    /// Whether one 20 ms frame counts as silence. Shared by the streaming `nextCut`
    /// and the whole-track `cutPoints`, so the live tier and the final pass cannot
    /// drift into different definitions of a pause.
    static func frameIsSilent(_ frame: ArraySlice<Float>) -> Bool {
        AudioConversion.rms(of: frame) < silenceThreshold
    }

    /// Whole-track window cuts with the same silence rule `nextCut` streams with:
    /// the first ≥ 600 ms pause after the minimum ends the window, a hard cut at the
    /// maximum bounds a monologue, and a short tail is returned as the last window.
    ///
    /// - Returns: cumulative sample offsets, the last always `samples.count` (empty
    ///   when `samples` is empty).
    static func cutPoints(in samples: [Float], config: WindowConfig) -> [Int] {
        var cuts: [Int] = []
        var scanned = 0
        var silenceRun = 0
        var windowStart = 0
        let minSamples = Int(config.minWindowSeconds * sampleRate)
        let maxSamples = Int(config.maxWindowSeconds * sampleRate)
        while scanned + frameSamples <= samples.count {
            if frameIsSilent(samples[scanned..<(scanned + frameSamples)]) {
                silenceRun += frameSamples
            } else {
                silenceRun = 0
            }
            scanned += frameSamples
            if scanned - windowStart >= minSamples, silenceRun >= silenceSamples {
                cuts.append(scanned)
                windowStart = scanned
                silenceRun = 0
            } else if scanned - windowStart >= maxSamples {
                cuts.append(scanned)
                windowStart = scanned
                silenceRun = 0
            }
        }
        if windowStart < samples.count {
            cuts.append(samples.count)
        }
        return cuts
    }

    private func enqueue(window: [Float]) {
        guard pendingCount < Self.maxPendingWindows else {
            // M-16a: a dropped window is a marker span as well as a log line.
            // The seconds are the dropped audio; the note names the track.
            droppedSamples += window.count
            LatencyTrace.record(
                .meetingWindowsDropped,
                seconds: Double(window.count) / Self.sampleRate,
                note: "source=\(source.rawValue)"
            )
            Log.meeting.error("transcription backlog full — dropped window")
            return
        }
        let start = Double(bufferOrigin) / Self.sampleRate
        let source = self.source
        let meetingID = self.meetingID
        let handler = onSegment
        let provisional = onProvisional
        let emitProvisionals = config.emitsProvisionals
        let transcribe = self.transcribe
        let previous = pending
        let generation = self.generation
        let shouldContinue: @Sendable () async -> Bool = { [weak self] in
            guard let self else { return false }
            return await self.isCurrent(generation)
        }
        pendingCount += 1

        pending = Task {
            await previous?.value
            guard !Task.isCancelled, self.isCurrent(generation) else {
                self.windowFinished(generation)
                return
            }
            await Self.transcribeWindow(
                window: window,
                start: start,
                source: source,
                meetingID: meetingID,
                emitProvisionals: emitProvisionals,
                onProvisional: provisional,
                onSegment: handler,
                transcribe: transcribe,
                shouldContinue: shouldContinue
            )
            self.windowFinished(generation)
        }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        self.generation == generation
    }

    private func windowFinished(_ generation: Int) {
        if self.generation == generation {
            pendingCount = max(0, pendingCount - 1)
        }
    }

    /// Whether any 20 ms frame in the window is above the silence floor.
    ///
    /// Measured frame by frame rather than as one RMS over the whole window: the threshold
    /// is a frame-level one, and averaging it across thirty seconds buries a two-second
    /// "yes, agreed" under the silence around it — the window is then dropped and the reply
    /// never appears in the transcript at all.
    static func containsSpeech(_ window: [Float]) -> Bool {
        var index = 0
        while index + frameSamples <= window.count {
            if AudioConversion.rms(of: window[index..<(index + frameSamples)]) >= silenceThreshold {
                return true
            }
            index += frameSamples
        }
        return false
    }

    /// Deliberately `static`: it runs off the actor so a long transcription never blocks
    /// `append`, and it touches nothing but its arguments.
    private static func transcribeWindow(
        window: [Float],
        start: TimeInterval,
        source: AudioSource,
        meetingID: UUID?,
        emitProvisionals: Bool,
        onProvisional: ProvisionalHandler?,
        onSegment: SegmentHandler,
        transcribe: @escaping @Sendable ([Float]) async throws -> ASRResult,
        shouldContinue: @escaping @Sendable () async -> Bool
    ) async {
        let duration = Double(window.count) / sampleRate
        guard window.count >= minTranscribableSamples else {
            // A tail shorter than Parakeet's encoder can read. Counted as a window the
            // pre-model filters skipped, exactly like digital silence.
            await MeetingTranscribeTally.shared.note(
                meetingID: meetingID, source: source,
                audioSeconds: 0, computeSeconds: 0, laneWait: 0,
                outcome: .silentSkipped)
            return
        }
        guard !Task.isCancelled, await shouldContinue() else { return }
        // Running the model over a window of pure silence costs a second of CPU to produce
        // an empty string; the meters already say nothing was said.
        guard containsSpeech(window) else {
            await MeetingTranscribeTally.shared.note(
                meetingID: meetingID, source: source,
                audioSeconds: 0, computeSeconds: 0, laneWait: 0,
                outcome: .silentSkipped)
            return
        }

        do {
            let began = ContinuousClock.now
            let timing = try await TranscriptionQueue.shared.transcribeWithLaneWait(window)
            // P0-20b: the model ran, whatever it produced — a window whose text was
            // dropped by a superseding session still spent the compute.
            await MeetingTranscribeTally.shared.note(
                meetingID: meetingID, source: source,
                audioSeconds: duration, computeSeconds: timing.compute,
                laneWait: timing.laneWait, outcome: .transcribed)
            let result = timing.result
            guard !Task.isCancelled, await shouldContinue() else { return }
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let elapsed = Self.seconds(began.duration(to: .now))
            Log.meeting.info("""
                \(source.rawValue, privacy: .public) window \
                \(duration, format: .fixed(precision: 1))s in \
                \(elapsed, format: .fixed(precision: 2))s
                """)
            guard !text.isEmpty else { return }

            let provisionalID = UUID()
            if emitProvisionals, let onProvisional {
                guard !Task.isCancelled, await shouldContinue() else { return }
                await onProvisional(
                    TranscriptEvent(
                        meetingID: meetingID,
                        source: source,
                        text: text,
                        start: start,
                        end: start + duration,
                        isFinal: false,
                        provisionalID: provisionalID
                    )
                )
            }

            // Finals still respect sentence / pause boundaries for diarization.
            for segment in segments(from: result, text: text, start: start, duration: duration, source: source) {
                guard !Task.isCancelled, await shouldContinue() else { return }
                await onSegment(segment)
            }
        } catch {
            // Only `.transcribed` windows contribute audio, compute and lane wait, so a
            // failure is a count on the row and nothing more (the `Outcome` doc).
            await MeetingTranscribeTally.shared.note(
                meetingID: meetingID, source: source,
                audioSeconds: 0, computeSeconds: 0, laneWait: 0,
                outcome: .failed)
            Log.meeting.error("\(source.rawValue, privacy: .public) window failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Duration arithmetic for the transcribe path; `Duration.components` is the only way
    /// to get fractional seconds out of a `ContinuousClock` measurement.
    static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    /// Cuts one transcribed window into utterances.
    ///
    /// A window is now 2–5 seconds of *compute* — it is not a unit anybody spoke.
    /// Emitting it whole made every downstream consumer coarser than it needed to be:
    /// diarization assigns a speaker by overlap, so a window two people shared went
    /// entirely to whoever held most of it. Splitting on the pauses *inside* the window
    /// costs nothing — Parakeet already returns per-token times — and gives each consumer
    /// the turn as its unit instead. The punctuation rule is load-bearing here.
    ///
    /// Falls back to the whole window when the model returns no timings, which is the only
    /// case where a single segment is still the honest answer.
    ///
    /// `internal` rather than `private` so the M-01 final pass segments long windows
    /// with this same rule instead of a second copy.
    static func segments(
        from result: ASRResult,
        text: String,
        start: TimeInterval,
        duration: TimeInterval,
        source: AudioSource
    ) -> [TranscriptSegment] {
        let words = buildWordTimings(from: result.tokenTimings ?? [])
        guard !words.isEmpty else {
            return [TranscriptSegment(start: start, end: start + duration, text: text, source: source)]
        }

        var segments: [TranscriptSegment] = []
        var current: [WordTiming] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let words = current.map(\.word).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !words.isEmpty else { return }
            segments.append(
                TranscriptSegment(
                    start: start + first.startTime,
                    end: start + last.endTime,
                    text: words,
                    source: source
                )
            )
        }

        for word in words {
            if let previous = current.last, let opened = current.first {
                let paused = word.startTime - previous.endTime >= utteranceGap
                let sentenceEnded = endsSentence(previous.word)
                    && previous.endTime - opened.startTime >= minSentenceSeconds
                if paused || sentenceEnded {
                    flush()
                    current = []
                }
            }
            current.append(word)
        }
        flush()

        return segments
    }

    /// Whether a word closes a sentence, ignoring any quotes or brackets after the mark.
    private static func endsSentence(_ word: String) -> Bool {
        guard let last = word.reversed().first(where: { !")\"'”’]".contains($0) }) else { return false }
        return sentenceTerminators.contains(last)
    }
}

/// The single lane every Parakeet call in a meeting goes through.
///
/// The mic track and the system track both finish windows at unpredictable times, and two
/// CoreML inferences in flight on this machine contend for the same cores — so they queue.
/// An `actor` alone wouldn't be enough: actors are reentrant, so a second caller would slip
/// in at the first `await`. The chain of tasks below is what actually serialises them.
///
/// Each window also holds `ComputeScheduler`'s `.realtimeASR` for the duration of the
/// CoreML pass — the same class dictation Parakeet uses — so notes checkpoints park
/// while a meeting window is recognizing. Acquire sits *after* the previous window in
/// the chain finishes, so waiting in the queue does not pin the lane; release is on
/// every exit of that pass so nothing leaks across meetings.
actor TranscriptionQueue {
    static let shared = TranscriptionQueue()

    private var tail: Task<Void, Never>?

    /// Loads the model before a recording starts, so the first window doesn't pay for it.
    /// Does not hold `.realtimeASR` — warm-up is not a recognition pass.
    func warmUp() async throws {
        _ = try await ParakeetModels.shared.manager()
    }

    func transcribe(_ samples: [Float], lane: WorkClass = .realtimeASR) async throws -> ASRResult {
        try await transcribeWithLaneWait(samples, lane: lane).result
    }

    /// As `transcribe`, plus the two times the live tier's usage row needs: how long the
    /// call waited for `ComputeScheduler`'s lane, and how long the model itself ran.
    ///
    /// The wait for the chain's previous window is neither: it is compute already counted
    /// on that window's own note. Only the `acquire` call is lane contention.
    func transcribeWithLaneWait(
        _ samples: [Float],
        lane: WorkClass = .realtimeASR
    ) async throws -> (result: ASRResult, laneWait: TimeInterval, compute: TimeInterval) {
        let previous = tail
        let work = Task { () throws -> (ASRResult, TimeInterval, TimeInterval) in
            await previous?.value
            // After Stop nothing may run at `.realtimeASR` (P0-06): the M-01 final pass
            // acquires `.background` per window through `acquireCancellable`, so a live
            // dictation or meeting window always goes first. The chain (`tail`) is
            // shared, so final-pass windows still never run two CoreML passes at once.
            let laneBegan = ContinuousClock.now
            let jobID: UUID
            if lane == .realtimeASR {
                jobID = await ComputeScheduler.shared.acquire(lane)
            } else {
                guard let acquired = await ComputeScheduler.shared.acquireCancellable(lane) else {
                    throw CancellationError()
                }
                jobID = acquired
            }
            let laneWait = ChunkedTranscriber.seconds(laneBegan.duration(to: .now))
            let computeBegan = ContinuousClock.now
            do {
                let manager = try await ParakeetModels.shared.manager()
                // A fresh decoder state per window: the windows are cut at silence, so there is
                // no context to carry, and sharing one across two tracks would splice them.
                var decoderState = try TdtDecoderState()
                let result = try await manager.transcribe(samples, decoderState: &decoderState)
                let compute = ChunkedTranscriber.seconds(computeBegan.duration(to: .now))
                await ComputeScheduler.shared.release(jobID)
                return (result, laneWait, compute)
            } catch {
                await ComputeScheduler.shared.release(jobID)
                throw error
            }
        }
        tail = Task { _ = try? await work.value }
        return try await work.value
    }
}

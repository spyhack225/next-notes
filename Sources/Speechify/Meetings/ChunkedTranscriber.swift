import FluidAudio
import Foundation

/// Turns one continuous audio track into transcript segments while it is still running.
///
/// Parakeet is a batch engine — it transcribes a window and returns — so a meeting has to
/// be cut into windows somewhere. Cutting on a clock alone would slice words in half, so
/// the cut waits for a pause: after 30 seconds of audio the first gap of at least 600 ms
/// ends the window, and a hard limit of 60 seconds keeps an uninterrupted monologue from
/// growing without bound.
///
/// A window is a unit of *compute*, not of speech, so it is cut again before it leaves:
/// Parakeet's per-token times are grouped into words and split at the pauses inside the
/// window, and each utterance becomes its own segment. Everything downstream reads turns
/// rather than minute-long blocks — which is what lets diarization put a speaker on each
/// one instead of on the whole window.
///
/// One instance per `AudioSource`. They share `TranscriptionQueue`, because the two of them
/// running CoreML concurrently on an 8-core M3 is slower than running them one at a time.
actor ChunkedTranscriber {
    typealias SegmentHandler = @Sendable (TranscriptSegment) async -> Void

    /// Parakeet's training rate. Feeding anything else transcribes silently-wrong text.
    static let sampleRate: Double = 16_000

    /// Silence is measured on 20 ms frames: short enough to find the edge of a pause,
    /// long enough that one plosive doesn't read as speech.
    private static let frameSamples = 320
    /// Linear RMS below which a frame counts as silence — roughly -40 dBFS, under the
    /// noise floor of a built-in microphone in a quiet room but above digital silence.
    private static let silenceThreshold: Float = 0.01
    private static let silenceSamples = Int(0.6 * sampleRate)
    /// The pause that ends an utterance *within* a window, in seconds.
    ///
    /// The same 600 ms the window cutter treats as a break, for the same reason — it is
    /// long enough to be a turn boundary and short enough to catch one. A window only cuts
    /// on such a pause after 30 seconds have accumulated, so most pauses this size fall
    /// inside a window; this is what finds them.
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
    private static let minWindowSamples = Int(30 * sampleRate)
    private static let maxWindowSamples = Int(60 * sampleRate)
    /// Parakeet's encoder needs a minimum window; anything shorter is a click, not speech.
    private static let minTranscribableSamples = 1_600

    private let source: AudioSource
    private let onSegment: SegmentHandler

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

    init(source: AudioSource, onSegment: @escaping SegmentHandler) {
        self.source = source
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
    }

    // MARK: - Windowing

    /// - Returns: how many samples to cut from the front of `buffer`, or `nil` to wait.
    private func nextCut() -> Int? {
        while scanned + Self.frameSamples <= buffer.count {
            let frame = buffer[scanned..<(scanned + Self.frameSamples)]
            if AudioConversion.rms(of: frame) < Self.silenceThreshold {
                silenceRun += Self.frameSamples
            } else {
                silenceRun = 0
            }
            scanned += Self.frameSamples

            // Cut at the end of the pause, so the next window starts on speech rather than
            // opening with the silence we just measured.
            if scanned >= Self.minWindowSamples, silenceRun >= Self.silenceSamples {
                return scanned
            }
        }
        return buffer.count >= Self.maxWindowSamples ? Self.maxWindowSamples : nil
    }

    private func enqueue(window: [Float]) {
        let start = Double(bufferOrigin) / Self.sampleRate
        let source = self.source
        let handler = onSegment
        let previous = pending

        pending = Task {
            await previous?.value
            await Self.transcribe(window: window, start: start, source: source, onSegment: handler)
        }
    }

    /// Whether any 20 ms frame in the window is above the silence floor.
    ///
    /// Measured frame by frame rather than as one RMS over the whole window: the threshold
    /// is a frame-level one, and averaging it across thirty seconds buries a two-second
    /// "yes, agreed" under the silence around it — the window is then dropped and the reply
    /// never appears in the transcript at all.
    private static func containsSpeech(_ window: [Float]) -> Bool {
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
    private static func transcribe(
        window: [Float],
        start: TimeInterval,
        source: AudioSource,
        onSegment: SegmentHandler
    ) async {
        let duration = Double(window.count) / sampleRate
        guard window.count >= minTranscribableSamples else { return }
        // Running the model over a window of pure silence costs a second of CPU to produce
        // an empty string; the meters already say nothing was said.
        guard containsSpeech(window) else { return }

        do {
            let began = Date()
            let result = try await TranscriptionQueue.shared.transcribe(window)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let elapsed = Date().timeIntervalSince(began)
            Log.meeting.info("""
                \(source.rawValue, privacy: .public) window \
                \(duration, format: .fixed(precision: 1))s in \
                \(elapsed, format: .fixed(precision: 2))s
                """)
            guard !text.isEmpty else { return }


            for segment in segments(from: result, text: text, start: start, duration: duration, source: source) {
                await onSegment(segment)
            }
        } catch {
            Log.meeting.error("\(source.rawValue, privacy: .public) window failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Cuts one transcribed window into utterances.
    ///
    /// A window is 30–60 seconds because that is what Parakeet is cheap to run on — it is
    /// not a unit anybody spoke. Emitting it whole made every downstream consumer coarser
    /// than it needed to be: diarization assigns a speaker by overlap, so a window two
    /// people shared went entirely to whoever held most of it, and the transcript read as
    /// minute-long paragraphs. Splitting on the pauses *inside* the window costs nothing —
    /// Parakeet already returns per-token times — and gives each consumer the turn as its
    /// unit instead.
    ///
    /// Falls back to the whole window when the model returns no timings, which is the only
    /// case where a single segment is still the honest answer.
    private static func segments(
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
actor TranscriptionQueue {
    static let shared = TranscriptionQueue()

    private var tail: Task<Void, Never>?

    /// Loads the model before a recording starts, so the first window doesn't pay for it.
    func warmUp() async throws {
        _ = try await ParakeetModels.shared.manager()
    }

    func transcribe(_ samples: [Float]) async throws -> ASRResult {
        let previous = tail
        let work = Task { () throws -> ASRResult in
            await previous?.value
            let manager = try await ParakeetModels.shared.manager()
            // A fresh decoder state per window: the windows are cut at silence, so there is
            // no context to carry, and sharing one across two tracks would splice them.
            var decoderState = try TdtDecoderState()
            return try await manager.transcribe(samples, decoderState: &decoderState)
        }
        tail = Task { _ = try? await work.value }
        return try await work.value
    }
}

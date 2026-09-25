import FluidAudio
import Foundation

/// `--selftest-meeting-backlog` (M-07): the live transcription backlog is bounded by
/// audio **seconds**, queued windows merge while the lane is behind, and nothing is
/// dropped below the bound.
///
/// 180 s of synthetic speech-level noise (0.1 RMS, 0.8 s of silence every 3 s) is fed at
/// ten times real time into a `ChunkedTranscriber` whose transcriber sleeps 1.5 s per call
/// — windows arrive every 3 s of audio, so the queue is behind the whole way. After
/// `flush()`:
///
/// * the emitted segments cover ≥ 99 % of the non-silent input — **0 s lost**;
/// * no `meeting.windows_dropped` span was written and the track's drop counter is 0;
/// * the fake saw fewer calls than the windows the cut rule produced (merging ran).
///
/// The old window-count bound fails the first two of those: 8 pending windows is 16–40 s
/// of audio at the 2–5 s cut, so the newest windows were dropped and the speech was gone
/// from the live transcript for good.
///
/// Marker `MEETING_BACKLOG_OK` / `MEETING_BACKLOG_FAILED: <n> check(s) wrong`. No model,
/// no microphone, none of the user's stores — the drop spans go to the harness's own
/// `MetricsStore.shared`.
@MainActor
enum MeetingBacklogSelfTest {
    /// Three minutes: long enough that a window-count backlog cannot hide behind it,
    /// short enough that the run is half a minute.
    private static let inputSeconds = 180.0
    /// Per cycle: `speechSeconds` of noise at 0.1 RMS, then silence to `cycleSeconds`.
    private static let cycleSeconds = 3.0
    private static let speechSeconds = 2.2
    /// The fake model's cost per call. Windows arrive every 0.3 s of wall clock at the
    /// ×10 feed, so this is slow enough that a backlog exists from the first cut on.
    private nonisolated static let fakeCallSeconds = 1.5

    static func run(log: (String) -> Void) async -> Bool {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        // Pure half: the bound is seconds, at the 300 s the roadmap measured, and the
        // merge ceiling is one native encoder pass rather than a window count.
        check("backlog bound is \(ChunkedTranscriber.maxPendingAudioSeconds)s, expected 300 s",
              ChunkedTranscriber.maxPendingAudioSeconds == 300)
        check("merge ceiling \(ChunkedTranscriber.maxMergedWindowSeconds)s is not one encoder pass",
              ChunkedTranscriber.maxMergedWindowSeconds > 5
                && ChunkedTranscriber.maxMergedWindowSeconds <= 15)

        let audio = syntheticAudio()
        let cuts = ChunkedTranscriber.cutPoints(in: audio, config: .default).count
        let dropSpansBefore = MetricsStore.shared.spans(named: .meetingWindowsDropped).count

        let collector = BacklogCollector()
        let fake = FakeASR()
        let transcriber = ChunkedTranscriber(
            source: .system,
            transcribe: { samples in try await fake.transcribe(samples) },
            onSegment: { await collector.add($0) }
        )

        // Ten times real time: one second of audio every hundred milliseconds.
        let began = Date()
        let step = Int(ChunkedTranscriber.sampleRate)
        var index = 0
        while index < audio.count {
            let end = min(index + step, audio.count)
            await transcriber.append(Array(audio[index..<end]))
            index = end
            try? await Task.sleep(for: .milliseconds(100))
        }
        await transcriber.flush()
        let elapsed = Date().timeIntervalSince(began)

        let segments = await collector.all()
        let calls = await fake.calls
        let droppedSeconds = await transcriber.droppedAudioSeconds
        let dropSpans = MetricsStore.shared.spans(named: .meetingWindowsDropped).count
            - dropSpansBefore

        let spans = nonSilentSpans()
        let nonSilent = spans.reduce(0.0) { $0 + ($1.upperBound - $1.lowerBound) }
        let covered = coverage(of: segments.map { $0.start...$0.end }, in: spans)
        let lost = max(0, nonSilent - covered)
        let share = nonSilent > 0 ? covered / nonSilent : 0

        log(String(format: "MEETING_BACKLOG_COVERED=%.4f lost=%.3fs of %.1fs non-silent in %.1fs wall",
                   share, lost, nonSilent, elapsed))
        log("MEETING_BACKLOG_CALLS=\(calls) CUTS=\(cuts) "
            + "DROPPED_S=\(String(format: "%.1f", droppedSeconds)) DROP_SPANS=\(dropSpans)")

        check("segments covered \(String(format: "%.2f", share * 100))% of the non-silent input (need ≥ 99%)",
              share >= 0.99)
        check("\(String(format: "%.2f", lost))s of speech lost behind the transcriber",
              lost <= 0.1)
        check("the track dropped \(String(format: "%.1f", droppedSeconds))s below the "
                + "\(Int(ChunkedTranscriber.maxPendingAudioSeconds))s bound",
              droppedSeconds == 0)
        check("\(dropSpans) meeting.windows_dropped span(s) written below the bound",
              dropSpans == 0)
        check("the injected transcriber never ran — the seam is not wired through",
              calls > 0)
        check("fake saw \(calls) calls for \(cuts) cut windows — nothing merged",
              calls < cuts)

        for failure in failures { log("MEETING_BACKLOG_WRONG: \(failure)") }
        log(failures.isEmpty
            ? "MEETING_BACKLOG_OK: 0 s lost behind a slow transcriber over \(Int(inputSeconds))s of input"
            : "MEETING_BACKLOG_FAILED: \(failures.count) check(s) wrong")
        return failures.isEmpty
    }

    // MARK: - Fixture

    /// `inputSeconds` of audio: `speechSeconds` of noise at 0.1 RMS, then silence, every
    /// `cycleSeconds`. Deterministic, so a red/green comparison is about the code and not
    /// about the dice.
    private static func syntheticAudio() -> [Float] {
        let total = Int(inputSeconds * ChunkedTranscriber.sampleRate)
        var samples = [Float](repeating: 0, count: total)
        let speech = Int(speechSeconds * ChunkedTranscriber.sampleRate)
        let cycle = Int(cycleSeconds * ChunkedTranscriber.sampleRate)
        // A uniform draw in ±a has RMS a/√3; a = 0.1√3 is the 0.1 the roadmap asks for.
        let amplitude = Float(0.1 * 3.0.squareRoot())
        var state: UInt64 = 0x5EED_1234_9876_ABCD
        var index = 0
        while index < total {
            let end = min(index + speech, total)
            for slot in index..<end {
                state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                let unit = Double(state >> 11) / Double(1 << 53)
                samples[slot] = Float(unit * 2 - 1) * amplitude
            }
            index += cycle
        }
        return samples
    }

    /// The spans of `syntheticAudio()` that are not silence — the speech the transcript
    /// is supposed to carry.
    private static func nonSilentSpans() -> [ClosedRange<Double>] {
        var spans: [ClosedRange<Double>] = []
        var start = 0.0
        while start < inputSeconds {
            spans.append(start...min(start + speechSeconds, inputSeconds))
            start += cycleSeconds
        }
        return spans
    }

    /// Seconds of `spans` that `intervals` cover (intervals merged first).
    private static func coverage(
        of intervals: [ClosedRange<Double>], in spans: [ClosedRange<Double>]
    ) -> Double {
        var merged: [ClosedRange<Double>] = []
        for interval in intervals.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, interval.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, interval.upperBound)
            } else {
                merged.append(interval)
            }
        }
        var total = 0.0
        for span in spans {
            for interval in merged {
                let low = max(span.lowerBound, interval.lowerBound)
                let high = min(span.upperBound, interval.upperBound)
                if high > low { total += high - low }
            }
        }
        return total
    }

    // MARK: - Fakes

    /// The injected transcriber: `fakeCallSeconds` per call, and a result whose text is
    /// the window's own `[start–end]` in seconds with word timings that cover it — so the
    /// segments it produces tile the window and the coverage number is meaningful.
    ///
    /// `start` is tracked from the audio it has been handed; nothing is skipped before the
    /// seam on this fixture (the only window that never arrives is the all-silence tail),
    /// so the tracking is the recording's own clock.
    private actor FakeASR {
        private var consumed = 0
        private(set) var calls = 0

        func transcribe(_ samples: [Float]) async throws -> (
            result: ASRResult, laneWait: TimeInterval, compute: TimeInterval
        ) {
            calls += 1
            let start = Double(consumed) / ChunkedTranscriber.sampleRate
            let duration = Double(samples.count) / ChunkedTranscriber.sampleRate
            consumed += samples.count
            try await Task.sleep(for: .milliseconds(Int(fakeCallSeconds * 1000)))
            return (result: Self.result(start: start, duration: duration),
                    laneWait: 0, compute: fakeCallSeconds)
        }

        private static func result(start: Double, duration: Double) -> ASRResult {
            var timings: [TokenTiming] = []
            var at = 0.0
            while at < duration {
                let end = min(at + 0.4, duration)
                // A leading space starts a word, so every token is one word and the
                // words tile the window without a pause for `segments(from:)` to cut on.
                timings.append(TokenTiming(
                    token: " w", tokenId: 0, startTime: at, endTime: end, confidence: 1
                ))
                at = end
            }
            return ASRResult(
                text: String(format: "[%.1f-%.1f]", start, start + duration),
                confidence: 1,
                duration: duration,
                processingTime: fakeCallSeconds,
                tokenTimings: timings
            )
        }
    }

    /// Segments in the order the transcriber emitted them.
    private actor BacklogCollector {
        private var segments: [TranscriptSegment] = []

        func add(_ segment: TranscriptSegment) {
            segments.append(segment)
        }

        func all() -> [TranscriptSegment] {
            segments
        }
    }
}

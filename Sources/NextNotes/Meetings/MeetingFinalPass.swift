import FluidAudio
import Foundation

/// Long-window re-transcription of each meeting track after Stop (M-01).
///
/// The live tier keeps 2–5 s windows for provisional text and in-meeting finals.
/// This tier re-reads each channel of `audio.caf` in long windows cut at pauses
/// (`ChunkedTranscriber.cutPoints` with `.finals`, the same silence rule the live
/// tier streams with), transcribes each window, and segments each result with the
/// unchanged sentence/pause rule (`ChunkedTranscriber.segments`). Short-window
/// French flips into English-sounding text; long windows give the decoder context.
enum MeetingFinalPass {
    /// Transcribes `samples` window by window.
    ///
    /// Windows below the capture floor and windows of pure silence are skipped
    /// exactly as the live tier skips them; windows between the capture and model
    /// floors are zero-padded through `ParakeetInput.padded` (D-04's helper).
    ///
    /// - Returns: the segments and the closed window ranges that produced them, in
    ///   seconds from the start of the track.
    static func transcribeTrack(
        _ samples: [Float],
        source: AudioSource,
        config: ChunkedTranscriber.WindowConfig = .finals,
        transcribe: @Sendable ([Float]) async throws -> ASRResult
    ) async throws -> (segments: [TranscriptSegment], windows: [ClosedRange<TimeInterval>]) {
        let cuts = ChunkedTranscriber.cutPoints(in: samples, config: config)
        var segments: [TranscriptSegment] = []
        var windows: [ClosedRange<TimeInterval>] = []
        var offset = 0
        for cut in cuts {
            let window = Array(samples[offset..<cut])
            let start = Double(offset) / ChunkedTranscriber.sampleRate
            offset = cut
            guard window.count >= ParakeetInput.minimumCapturedSamples else { continue }
            guard ChunkedTranscriber.containsSpeech(window) else { continue }
            try Task.checkCancellation()
            let result = try await transcribe(ParakeetInput.padded(window))
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let duration = Double(window.count) / ChunkedTranscriber.sampleRate
            windows.append(start...(start + duration))
            segments.append(contentsOf: ChunkedTranscriber.segments(
                from: result, text: text, start: start, duration: duration, source: source
            ))
        }
        return (segments, windows)
    }

    /// Pure. Keeps live `.agentCommand` segments; drops final mic segments
    /// overlapping them (the command was not meeting speech). Final system
    /// segments stand even over a command — the far end kept talking.
    static func merge(final: [TranscriptSegment], live: [TranscriptSegment]) -> [TranscriptSegment] {
        let commands = live.filter { $0.kind == .agentCommand }
        guard !commands.isEmpty else { return final }
        var kept = final.filter { segment in
            guard segment.source == .mic else { return true }
            return !commands.contains { segment.start < $0.end && segment.end > $0.start }
        }
        kept.append(contentsOf: commands)
        return kept
    }

    /// Pure. False when the final track has < 60 % of the live track's words —
    /// that track keeps its live segments instead. An empty live track accepts
    /// anything: there is nothing to lose.
    static func accept(
        final: [TranscriptSegment],
        live: [TranscriptSegment],
        source: AudioSource
    ) -> Bool {
        func words(_ segments: [TranscriptSegment]) -> Int {
            segments.filter { $0.source == source }
                .reduce(0) { $0 + $1.text.split(separator: " ").count }
        }
        let liveWords = words(live)
        guard liveWords > 0 else { return true }
        return 5 * words(final) >= 3 * liveWords
    }
}

import Foundation

/// IM-15 — a voice note is transcribed and becomes a turn. Nothing more.
///
/// **A batch path, not a session.** The file is decoded once to mono samples
/// and fed through the same `ChunkedTranscriber` windowing `--selftest-transcribe`
/// uses — no `afconvert`, no transcode step, no re-encoding. The model call is
/// injected (production passes the shared lane explicitly; there is no hidden
/// default that spends model time), so the plumbing pins without a model.
///
/// **The constraint that matters:** nothing here touches `RealtimeAudioSession`,
/// `AgentCaptureController`, the `AudioCaptureHub`, or the microphone. A remote
/// voice note is a file: bytes in, words out. The source on every segment is
/// `.mic` for one reason only — it is the user speaking, so the default speaker
/// is "You" — and it names no hardware.
///
/// A reply to a voice note is text: turns perform as `.iMessage`, which never
/// takes the voice branch, so there is no TTS path to close here.
enum VoiceNoteTranscriber {
    /// Transcribes a voice-note file to text: decode, window, join.
    ///
    /// - Parameters:
    ///   - url: the copied file (IM-14's working copy, never Apple's original).
    ///   - transcribe: one window of 16 kHz mono samples to words. Explicit —
    ///     no default lane, so no call site spends model time by accident.
    /// - Returns: the segments' text joined in order, or "" when no window spoke.
    static func transcribe(url: URL,
                           transcribe: @escaping ChunkedTranscriber.Transcribe) async throws -> String {
        let samples = try AudioConversion.monoSamples(
            fromFileAt: url, sampleRate: ChunkedTranscriber.sampleRate)
        let collector = SegmentCollector()
        let transcriber = ChunkedTranscriber(source: .mic, transcribe: transcribe) { segment in
            await collector.add(segment)
        }
        await transcriber.append(samples)
        await transcriber.flush()
        let segments = await collector.all
        return segments
            .sorted { $0.start < $1.start }
            .map(\.text)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Segment sink: the handler runs off the transcriber's executor, so a plain
    /// captured array would be a data race.
    private actor SegmentCollector {
        private var segments: [TranscriptSegment] = []
        func add(_ segment: TranscriptSegment) { segments.append(segment) }
        var all: [TranscriptSegment] { segments }
    }
}

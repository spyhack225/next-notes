import Foundation

/// Shared knobs for streaming / near-streaming ASR (dictation partials and
/// meeting provisional windows). Kept as plain numbers so a self-test can
/// assert the API exists without loading a model.
enum StreamingASR {
    /// Start the live display before the ordinary one-second refresh cadence. Subsequent
    /// passes retain that cadence so a long hold doesn't double its model workload.
    static let dictationFirstPartialSeconds: TimeInterval = 0.4
    /// How often Parakeet re-transcribes the **open tail** (the audio after the last
    /// pause-committed segment) while the key is down, when there was speech since the last
    /// pass. End of speech also starts a tail pass at once (`DictationSegmenter`). The tail
    /// is at most one 14.5 s segment, so this cadence costs the same at minute two as at
    /// second two; it used to re-transcribe the whole buffer, which was O(n²).
    static let dictationPartialIntervalSeconds: TimeInterval = 1.0

    /// Meeting compute windows (roadmap §11): provisional ASR every 2–5 s.
    /// Finals still split on sentence punctuation + 600 ms pause for diarization.
    static let meetingProvisionalMinSeconds: TimeInterval = 2.0
    static let meetingProvisionalMaxSeconds: TimeInterval = 5.0
    /// Reserved for overlapping ASR. Kept at zero so finals are not double-emitted
    /// into diarization; short 2–5 s windows carry the latency win on their own.
    static let meetingOverlapSeconds: TimeInterval = 0

    /// Meeting final-pass windows (M-01): after Stop each track is re-transcribed in
    /// long windows cut at pauses, while the 2–5 s windows above stay the live tier.
    /// 10 s minimum keeps every window near one native 15 s encoder pass; 14.5 s maximum
    /// stays just under it so FluidAudio never pays a chunk merge. The pair was chosen
    /// by measuring `--selftest-meeting-finals --finals-window` (see STATUS.md, M-01).
    static let meetingFinalMinSeconds: TimeInterval = 10.0
    static let meetingFinalMaxSeconds: TimeInterval = 14.5

    /// Asserts the streaming window API is the 2–5 s provisional path, not the
    /// old 30/60-only hard path. Does not load Parakeet. Wire later with
    /// `--selftest-stream`:
    /// ```
    /// if arguments.contains("--selftest-stream") {
    ///     _ = StreamingASR.runSelfTest()
    ///     _ = await TranscriptBus.runSelfTest()
    ///     NSApp.terminate(nil)
    ///     return true
    /// }
    /// ```
    @discardableResult
    static func runSelfTest() -> Bool {
        var failures: [String] = []

        let config = ChunkedTranscriber.WindowConfig.default
        if config.minWindowSeconds < 2.0 || config.minWindowSeconds > 5.0 {
            failures.append(
                "meeting min window \(config.minWindowSeconds)s is outside the 2–5 s provisional band"
            )
        }
        if config.maxWindowSeconds < 2.0 || config.maxWindowSeconds > 5.0 {
            failures.append(
                "meeting max window \(config.maxWindowSeconds)s is outside the 2–5 s provisional band"
            )
        }
        if config.maxWindowSeconds < config.minWindowSeconds {
            failures.append("max window shorter than min window")
        }
        // Guard against a silent revert to the old hard path.
        if config.minWindowSeconds >= 30 || config.maxWindowSeconds >= 60 {
            failures.append(
                "meeting windows still look like the old 30/60-only path "
                    + "(min=\(config.minWindowSeconds), max=\(config.maxWindowSeconds))"
            )
        }
        if !config.emitsProvisionals {
            failures.append("WindowConfig.default does not advertise a provisional path")
        }
        if ChunkedTranscriber.WindowConfig.legacy.minWindowSeconds < 30 {
            failures.append("legacy WindowConfig should preserve the 30 s floor for comparison")
        }
        if dictationPartialIntervalSeconds < 0.5 || dictationPartialIntervalSeconds > 5.0 {
            failures.append(
                "dictation partial interval \(dictationPartialIntervalSeconds)s is not a near-stream cadence"
            )
        }
        // Every dictation model pass must fit one native 15 s encoder window, and a
        // segment must be long enough to punctuate (8 s floors forced mid-word cuts).
        let dictation = DictationSegmenter.Rule.dictation
        if dictation.maxSegmentSeconds > 15 || dictation.maxSegmentSeconds <= dictation.minSegmentSeconds {
            failures.append("dictation segment cap \(dictation.maxSegmentSeconds)s is not one encoder window")
        }
        if dictation.minSegmentSeconds < 2 || dictation.minSegmentSeconds > 5 {
            failures.append("dictation segment floor \(dictation.minSegmentSeconds)s is outside 2–5 s")
        }
        if dictation.endOfSpeechSeconds > dictation.longPauseSeconds {
            failures.append("end of speech is detected later than a segment commits")
        }
        // M-07: the live backlog is bounded by audio seconds and merged by the drain
        // task, not by a window count — the old 8-window cap read as 16–40 s at the
        // 2–5 s live cut and shed the newest window when full.
        if ChunkedTranscriber.maxPendingAudioSeconds < 60
            || ChunkedTranscriber.maxPendingAudioSeconds > 600 {
            failures.append(
                "meeting transcription backlog bound "
                    + "\(ChunkedTranscriber.maxPendingAudioSeconds)s is unreasonable"
            )
        }
        if ChunkedTranscriber.maxMergedWindowSeconds <= meetingProvisionalMaxSeconds
            || ChunkedTranscriber.maxMergedWindowSeconds > 15 {
            failures.append(
                "meeting merge ceiling \(ChunkedTranscriber.maxMergedWindowSeconds)s "
                    + "does not cover a native encoder pass above the provisional window"
            )
        }
        if !ParakeetEngine.emitsPartialsWhileHeld {
            failures.append("ParakeetEngine no longer reports partials-while-held")
        }
        // M-01: the final tier is long windows, strictly above the live band, with no
        // provisionals of its own. (The exact pair is measured; these are the shape.)
        if meetingFinalMinSeconds < 8 || meetingFinalMinSeconds > 30 {
            failures.append(
                "meeting final min window \(meetingFinalMinSeconds)s is not a long window"
            )
        }
        if meetingFinalMaxSeconds <= meetingFinalMinSeconds || meetingFinalMaxSeconds > 32 {
            failures.append(
                "meeting final max window \(meetingFinalMaxSeconds)s does not bound the min"
            )
        }
        let finals = ChunkedTranscriber.WindowConfig.finals
        if finals.minWindowSeconds != meetingFinalMinSeconds
            || finals.maxWindowSeconds != meetingFinalMaxSeconds {
            failures.append("WindowConfig.finals does not match meetingFinalMin/MaxSeconds")
        }
        if finals.emitsProvisionals {
            failures.append("WindowConfig.finals must not emit provisionals")
        }
        if finals.overlapSeconds != 0 {
            failures.append("WindowConfig.finals must not overlap")
        }

        for failure in failures {
            print("STREAM_WRONG: \(failure)")
        }
        if failures.isEmpty {
            print("STREAM_OK")
            return true
        }
        print("STREAM_FAILED")
        return false
    }
}

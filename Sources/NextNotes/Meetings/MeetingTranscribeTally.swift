import Foundation

/// Accumulates one meeting track's transcription windows, so `ChunkedTranscriber.flush()`
/// can write one `meeting.transcribe` usage row per track (P0-20b).
///
/// `ChunkedTranscriber.transcribe(window:…)` runs off the actor and cannot touch disk, so
/// each window's outcome is noted here — success, silent skip, failure — and the row is
/// assembled once, when the track flushes. The actor is deliberately tiny: a few numbers
/// per active track, and `append` is never made to wait on it.
actor MeetingTranscribeTally {
    /// What one window did.
    enum Outcome: Sendable, Equatable {
        /// The model transcribed it. Only these windows contribute audio, compute and lane
        /// wait to the row; every outcome still counts toward `windows`.
        case transcribed
        /// A pre-model filter skipped it — the silence floor, or a window too short to
        /// transcribe.
        case silentSkipped
        /// The model call threw.
        case failed
    }

    /// The model the row reports. FluidAudio's on-disk name for the Parakeet build the app
    /// loads — `ParakeetModels.isDownloaded` checks this same directory.
    static let parakeetModelID = "parakeet-tdt-0.6b-v3"

    static let shared = MeetingTranscribeTally()

    private struct Key: Hashable {
        let meetingID: UUID?
        let source: AudioSource
    }

    private struct Totals {
        var windows = 0
        var silentSkipped = 0
        var failed = 0
        /// Only the `.transcribed` windows' contribution, as the `Outcome` doc pins.
        var audioSeconds = 0.0
        var computeSeconds = 0.0
        var laneWait = 0.0
    }

    private var totals: [Key: Totals] = [:]

    /// Notes one window outcome for a (meeting, track). `audioSeconds` is the window's
    /// length, `computeSeconds` the model time it spent, `laneWait` the seconds it waited
    /// for the `.realtimeASR` lane.
    func note(
        meetingID: UUID?,
        source: AudioSource,
        audioSeconds: Double,
        computeSeconds: Double,
        laneWait: Double,
        outcome: Outcome
    ) {
        let key = Key(meetingID: meetingID, source: source)
        var entry = totals[key] ?? Totals()
        entry.windows += 1
        switch outcome {
        case .transcribed:
            entry.audioSeconds += audioSeconds
            entry.computeSeconds += computeSeconds
            entry.laneWait += laneWait
        case .silentSkipped:
            entry.silentSkipped += 1
        case .failed:
            entry.failed += 1
        }
        totals[key] = entry
    }

    /// Removes and returns the row for one track, or nil when nothing was noted.
    func drain(meetingID: UUID?, source: AudioSource) -> UsageRecord? {
        let key = Key(meetingID: meetingID, source: source)
        guard let entry = totals.removeValue(forKey: key) else { return nil }
        let totalMs = Int((entry.computeSeconds * 1_000).rounded())
        return UsageRecord(
            v: 1,
            id: UUID(),
            ts: Date(),
            feature: UsageFeature.meetingTranscribe.rawValue,
            pass: source.rawValue,
            round: nil,
            provider: UsageProvider.parakeet.rawValue,
            modelID: Self.parakeetModelID,
            locality: "local",
            requestedRole: nil,
            requestedModel: nil,
            fallbackReason: nil,
            warm: nil,
            loadMs: nil,
            promptTokens: nil,
            cachedTokens: nil,
            completionTokens: nil,
            reasoningTokens: nil,
            countsEstimated: nil,
            ttftMs: nil,
            totalMs: totalMs,
            tokensPerSec: nil,
            finishReason: nil,
            truncated: nil,
            toolsProposed: nil,
            toolsExecuted: nil,
            errorClass: nil,
            errorMessage: nil,
            audioSeconds: entry.audioSeconds,
            realtimeFactor: entry.audioSeconds > 0
                ? entry.computeSeconds / entry.audioSeconds
                : nil,
            stages: ["laneWait": entry.laneWait],
            counts: [
                "windows": entry.windows,
                "silentSkipped": entry.silentSkipped,
                "failed": entry.failed,
            ],
            turnID: nil,
            conversationID: nil,
            workID: nil,
            revision: nil,
            meetingID: meetingID,
            dictationRunID: nil,
            scheduleID: nil
        )
    }
}

import Foundation

/// The stall rule for the two model stages of a meeting (M-08, I2 #9).
///
/// A diarization or notes pass that hangs shows "Writing notes…" until the next
/// launch, which used to delete the audio. A hard wall-clock deadline for a whole
/// stage would punish long meetings, which legitimately take minutes — so the rule
/// watches *progress*, not the clock: too long since the last reported step, minus
/// time a more urgent lane (`.realtimeASR`, `.realtimeAgent`) kept the machine,
/// means stalled.
enum StageWatchdog {
    /// Above the longest single legitimate gap: a single-pass generation on the
    /// local model (both estimates). `nonisolated(unsafe)` like the blessed
    /// `startTimeoutOverrideForTesting` pattern: read on the services' actor and
    /// written through the test-only setter below, never raced.
    nonisolated(unsafe) static var diarizeLimit: TimeInterval = 5 * 60
    nonisolated(unsafe) static var notesLimit: TimeInterval = 10 * 60

    /// Plain words for the banner and the problem row (no developer words).
    static let stallMessage =
        "This took much longer than it should, so it was stopped. Try again."

    /// Pure: `busySeconds` is how much of the silent stretch a more urgent lane
    /// was busy. Stalled when the quiet stretch outlasts the limit.
    static func isStalled(
        sinceProgress: TimeInterval,
        busySeconds: TimeInterval,
        limit: TimeInterval
    ) -> Bool {
        sinceProgress - busySeconds >= limit
    }

    /// The lanes that outrank a meeting's model stages: dictation ASR and the
    /// interactive agent. Time they hold the machine is not a stall — a notes pass
    /// that is waiting for a dictation to finish is waiting, not wedged.
    static func urgentLaneBusy() async -> Bool {
        if await ComputeScheduler.shared.isBusy(.realtimeASR) { return true }
        return await ComputeScheduler.shared.isBusy(.realtimeAgent)
    }

    /// Test-only seam for proving the stall path without waiting minutes (the
    /// `startTimeoutOverrideForTesting` pattern in `Core/SystemAudioCapture.swift`).
    /// Never gated on `SelfTest.isRunning` in production logic.
    static func setLimitsForTesting(diarize: TimeInterval, notes: TimeInterval) {
        diarizeLimit = diarize
        notesLimit = notes
    }

    static func resetLimitsForTesting() {
        diarizeLimit = 5 * 60
        notesLimit = 10 * 60
    }
}

/// Samples one running stage and fires `onStall` once when it stalls.
///
/// `lastProgress` is the stage's own clock (updated wherever the service reports
/// progress); `isLaneBusy` reports the more urgent lanes; `onStall` cancels the
/// work, sets the problem and logs it. `pollInterval` is 15 s in production and
/// short under test.
@MainActor
final class StageWatch {
    private let limit: TimeInterval
    private let pollInterval: TimeInterval
    private let lastProgress: @MainActor () -> Date
    private let isLaneBusy: @MainActor () async -> Bool
    private let onStall: @MainActor () -> Void
    private var task: Task<Void, Never>?

    init(
        limit: TimeInterval,
        pollInterval: TimeInterval = 15,
        lastProgress: @escaping @MainActor () -> Date,
        isLaneBusy: @escaping @MainActor () async -> Bool,
        onStall: @escaping @MainActor () -> Void
    ) {
        self.limit = limit
        self.pollInterval = pollInterval
        self.lastProgress = lastProgress
        self.isLaneBusy = isLaneBusy
        self.onStall = onStall
    }

    func start() {
        cancel()
        let poll = pollInterval
        task = Task { @MainActor [weak self] in
            var busySeconds: TimeInterval = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(poll))
                guard !Task.isCancelled, let self else { break }
                if await self.isLaneBusy() {
                    busySeconds += poll
                }
                let since = Date().timeIntervalSince(self.lastProgress())
                guard StageWatchdog.isStalled(
                    sinceProgress: since,
                    busySeconds: busySeconds,
                    limit: self.limit
                ) else { continue }
                self.task = nil
                self.onStall()
                break
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

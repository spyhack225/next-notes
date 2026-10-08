import Foundation

/// Bounded observations retained on the existing meeting record. Peaks are sampled
/// values, not a continuous trace or allocation attribution. No per-sample history.
struct MeetingPerformanceSummary: Codable, Sendable, Equatable {
    let recordingStartedAt: Date
    private(set) var samples = 0
    private(set) var footprintSamples = 0
    private(set) var firstSampleAt: Date?
    private(set) var lastSampleAt: Date?
    private(set) var maximumSampleGapSeconds: Double = 0
    private(set) var peakSampledFootprintBytes: UInt64?
    private(set) var peakSampledResidentBytes: UInt64?
    private(set) var peakQueuedBytes = 0
    private(set) var peakActiveBytes = 0
    private(set) var pausedSamples = 0

    mutating func observe(at date: Date, process: ProcessSnapshot,
                         queuedBytes: Int, activeBytes: Int, paused: Bool) {
        // A clock moving backwards must not fabricate coverage or erase prior peaks.
        guard date >= recordingStartedAt, lastSampleAt.map({ date >= $0 }) ?? true else { return }
        maximumSampleGapSeconds = max(maximumSampleGapSeconds,
            date.timeIntervalSince(lastSampleAt ?? recordingStartedAt))
        firstSampleAt = firstSampleAt ?? date
        lastSampleAt = date
        samples += 1
        if let footprint = process.physicalFootprintBytes {
            footprintSamples += 1
            peakSampledFootprintBytes = max(peakSampledFootprintBytes ?? footprint, footprint)
        }
        if let resident = process.residentMemoryBytes {
            peakSampledResidentBytes = max(peakSampledResidentBytes ?? resident, resident)
        }
        peakQueuedBytes = max(peakQueuedBytes, max(0, queuedBytes))
        peakActiveBytes = max(peakActiveBytes, max(0, activeBytes))
        if paused { pausedSamples += 1 }
    }

    /// Other existing metadata writers may hold an older meeting value. Preserve
    /// the latest aggregate from the same recording; never sum replayed snapshots.
    func preserving(_ stored: Self?) -> Self {
        guard let stored, stored.recordingStartedAt == recordingStartedAt,
              stored.samples > samples else { return self }
        return stored
    }
}

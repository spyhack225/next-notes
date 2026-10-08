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

    init(recordingStartedAt: Date) {
        self.recordingStartedAt = recordingStartedAt
    }

    // MeetingStore's ISO8601 strategy drops fractional seconds. These new clock
    // facts must survive that boundary exactly: otherwise fresh readers lose sample
    // precision and the same recording no longer matches its older metadata writer.
    // Reference-date doubles retain Date's native precision without changing any
    // existing meeting timestamps or the enclosing store's encoding strategy.
    private enum CodingKeys: String, CodingKey {
        case recordingStartedAtReferenceSeconds, firstSampleReferenceSeconds, lastSampleReferenceSeconds
        case recordingStartedAt, firstSampleAt, lastSampleAt // early diagnostic representation
        case samples, footprintSamples, maximumSampleGapSeconds
        case peakSampledFootprintBytes, peakSampledResidentBytes
        case peakQueuedBytes, peakActiveBytes, pausedSamples
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let seconds = try c.decodeIfPresent(Double.self, forKey: .recordingStartedAtReferenceSeconds) {
            recordingStartedAt = Date(timeIntervalSinceReferenceDate: seconds)
        } else {
            recordingStartedAt = try c.decode(Date.self, forKey: .recordingStartedAt)
        }
        func date(_ precise: CodingKeys, _ legacy: CodingKeys) throws -> Date? {
            if let seconds = try c.decodeIfPresent(Double.self, forKey: precise) {
                return Date(timeIntervalSinceReferenceDate: seconds)
            }
            return try c.decodeIfPresent(Date.self, forKey: legacy)
        }
        firstSampleAt = try date(.firstSampleReferenceSeconds, .firstSampleAt)
        lastSampleAt = try date(.lastSampleReferenceSeconds, .lastSampleAt)
        samples = try c.decode(Int.self, forKey: .samples)
        footprintSamples = try c.decode(Int.self, forKey: .footprintSamples)
        maximumSampleGapSeconds = try c.decode(Double.self, forKey: .maximumSampleGapSeconds)
        peakSampledFootprintBytes = try c.decodeIfPresent(UInt64.self, forKey: .peakSampledFootprintBytes)
        peakSampledResidentBytes = try c.decodeIfPresent(UInt64.self, forKey: .peakSampledResidentBytes)
        peakQueuedBytes = try c.decode(Int.self, forKey: .peakQueuedBytes)
        peakActiveBytes = try c.decode(Int.self, forKey: .peakActiveBytes)
        pausedSamples = try c.decode(Int.self, forKey: .pausedSamples)
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(recordingStartedAt.timeIntervalSinceReferenceDate, forKey: .recordingStartedAtReferenceSeconds)
        try c.encodeIfPresent(firstSampleAt?.timeIntervalSinceReferenceDate, forKey: .firstSampleReferenceSeconds)
        try c.encodeIfPresent(lastSampleAt?.timeIntervalSinceReferenceDate, forKey: .lastSampleReferenceSeconds)
        try c.encode(samples, forKey: .samples)
        try c.encode(footprintSamples, forKey: .footprintSamples)
        try c.encode(maximumSampleGapSeconds, forKey: .maximumSampleGapSeconds)
        try c.encodeIfPresent(peakSampledFootprintBytes, forKey: .peakSampledFootprintBytes)
        try c.encodeIfPresent(peakSampledResidentBytes, forKey: .peakSampledResidentBytes)
        try c.encode(peakQueuedBytes, forKey: .peakQueuedBytes)
        try c.encode(peakActiveBytes, forKey: .peakActiveBytes)
        try c.encode(pausedSamples, forKey: .pausedSamples)
    }

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

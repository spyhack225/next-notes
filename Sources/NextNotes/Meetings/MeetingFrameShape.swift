import AVFoundation
import Foundation

/// What a meeting track's frame cadence says about the clock it was captured on.
///
/// The 2026-10-13 audit found live meetings whose system-track timestamps ended
/// near half the wall duration and saved system channels that were digital zero,
/// with the capture-drop counters reporting nothing — because nothing counted
/// what this measures: buffers per second against the host clock, format
/// stability, conversion outcomes, and stream yields. `.ok` is only ever
/// returned when the window is old enough and the numbers match it; every
/// uncertain shape stays `.unknownShape` rather than guessing health.
enum MeetingFrameVerdict: String, Sendable, Equatable {
    /// The cadence matches the elapsed host-clock window within tolerance.
    case ok
    /// The samples arriving are about half of what the wall clock says should
    /// have arrived — the audit's live symptom.
    case halfCadenceSuspect
    /// No progress for the minimum window, or conversion failing on every buffer.
    case stalled
    /// Too little evidence, an unstable format, or a mismatch no rule names.
    case unknownShape
}

/// The AudioStreamBasicDescription shape of one delivered buffer.
///
/// `framesPerBuffer` is deliberately not part of `layoutChanged(from:)`: it is
/// the format's nominal hint, and a variable-size process tap may legally hand
/// buffers of different lengths through one unchanged format. What matters is
/// that the bytes describe one stream — rate, layout and buffer organisation.
struct MeetingFrameASBDSignature: Sendable, Equatable {
    let sampleRate: Double
    let formatID: UInt32
    let channelsPerFrame: UInt32
    let bytesPerFrame: UInt32
    let framesPerBuffer: UInt32
    let numberBuffers: UInt32

    init(
        sampleRate: Double,
        formatID: UInt32,
        channelsPerFrame: UInt32,
        bytesPerFrame: UInt32,
        framesPerBuffer: UInt32,
        numberBuffers: UInt32
    ) {
        self.sampleRate = sampleRate
        self.formatID = formatID
        self.channelsPerFrame = channelsPerFrame
        self.bytesPerFrame = bytesPerFrame
        self.framesPerBuffer = framesPerBuffer
        self.numberBuffers = numberBuffers
    }

    init(_ format: AVAudioFormat, numberBuffers: UInt32) {
        let description = format.streamDescription.pointee
        self.init(
            sampleRate: description.mSampleRate,
            formatID: description.mFormatID,
            channelsPerFrame: description.mChannelsPerFrame,
            bytesPerFrame: description.mBytesPerFrame,
            framesPerBuffer: description.mFramesPerPacket,
            numberBuffers: numberBuffers
        )
    }

    func layoutChanged(from other: MeetingFrameASBDSignature) -> Bool {
        sampleRate != other.sampleRate
            || formatID != other.formatID
            || channelsPerFrame != other.channelsPerFrame
            || bytesPerFrame != other.bytesPerFrame
            || numberBuffers != other.numberBuffers
    }
}

/// Outcomes of one input-buffer conversion, as the capture path saw it.
enum MeetingConversionOutcome: Sendable, Equatable {
    /// Converted to the expected sample count.
    case success
    /// Converted to measurably fewer samples than the rate change allows for.
    case incomplete
    /// The converter refused the buffer — the frame never became deliverable.
    case error
    /// No conversion needed; the buffer was copied as-is.
    case passthrough
}

/// Converter outcomes counted per track over the snapshot window.
struct MeetingConverterStatusCounts: Sendable, Equatable {
    var success = 0
    var incomplete = 0
    var error = 0

    /// An error becomes the track's verdict only when it outnumbers both other
    /// outcomes: a converter failing every buffer has stopped the track, one
    /// failed buffer among thousands has not.
    var errorsDominate: Bool {
        error > 0 && error > success && error > incomplete
    }
}

/// One track's frame/clock facts as of `asOfHostTime`, measured — never inferred.
struct MeetingFrameShape: Sendable, Equatable {
    var captureStartedHostTime: UInt64?
    var firstHostTime: UInt64?
    var lastHostTime: UInt64?
    var asOfHostTime: UInt64 = 0
    var bufferCount = 0
    var inputSamples = 0
    var convertedSamples = 0
    var deliveredBuffers = 0
    /// Samples as the delivering side handed them over — the 16 kHz domain the
    /// session and transcribers see, which is also the domain of
    /// `expectedSamplesFromElapsed`, so `clockDriftSamples` is same-vs-same.
    var deliveredSamples = 0
    var asbdSignature: MeetingFrameASBDSignature?
    var signatureTransitions = 0
    var converterStatusCounts = MeetingConverterStatusCounts()
    var terminatedYields = 0
    var unmatchedYields = 0
    /// Buffers whose own frame count disagreed with the count the buffer list
    /// really carried. A non-interleaved stereo list counted with the
    /// interleaved rule reads exactly half, and that is the shape a track
    /// running at half speed would produce.
    var underCountedBuffers = 0
    /// `window × ChunkedTranscriber.sampleRate`, from the anchor to `asOfHostTime`.
    var expectedSamplesFromElapsed = 0
    /// Actual samples (converted when present, delivered otherwise) minus expected.
    var clockDriftSamples = 0

    static let minimumWindowSeconds = 60.0
    static let halfCadenceRange = 0.45...0.55

    /// The verdict ladder, in order, and none of the rungs may be skipped.
    ///
    /// A conversion failing every buffer is a stall before cadence is read;
    /// nothing delivered with a stale start is a stall, but a quiet fresh start
    /// is honestly unknown; a gap of the minimum window is a stall; an unstable
    /// or missing format shape can never read `.ok`; and only then does the
    /// elapsed window get a chance to be judged healthy, half cadence, or — at
    /// any mismatch the rules do not name — inconclusive.
    func verdict() -> MeetingFrameVerdict {
        if converterStatusCounts.errorsDominate { return .stalled }
        // A stream that ended while the meeting was recording stopped
        // delivering, whatever the counts say.
        if terminatedYields > 0 { return .stalled }
        let hasEvidence = bufferCount > 0 || deliveredBuffers > 0
        if !hasEvidence {
            if let started = captureStartedHostTime,
               Self.seconds(asOfHostTime) - Self.seconds(started) >= Self.minimumWindowSeconds {
                return .stalled
            }
            return .unknownShape
        }
        if let last = lastHostTime,
           Self.seconds(asOfHostTime) - Self.seconds(last) >= Self.minimumWindowSeconds {
            return .stalled
        }
        guard asbdSignature != nil, signatureTransitions == 0 else { return .unknownShape }
        guard let first = firstHostTime else { return .unknownShape }
        let window = Self.seconds(asOfHostTime) - Self.seconds(first)
        let expected = Double(expectedSamplesFromElapsed)
        guard expected > 0 else { return .unknownShape }
        let actual = Double(clockDriftSamples) + expected
        // One ladder: the pure rule decides "aligned / half / unknown", and the
        // window gate is this verdict's own — a short window is never "ok",
        // whatever the ratio says.
        switch AudioFrameLayout.cadenceOnly(
            deliveredFrames: Int(actual),
            expectedFrames: Int(expected),
            elapsedSeconds: window) {
        case .aligned:
            return window >= Self.minimumWindowSeconds ? .ok : .unknownShape
        case .halfCadence:
            return .halfCadenceSuspect
        case .stalled:
            return .stalled
        case .unknown:
            return .unknownShape
        }
    }

    private static func seconds(_ hostTime: UInt64) -> TimeInterval {
        AVAudioTime.seconds(forHostTime: hostTime)
    }

}

/// Thread-safe frame-shape facts for one capture source.
///
/// Every recording callback the app runs reaches at least one of these: the
/// audio delivery worker (buffers, conversion, deliveries), a session stream
/// closure (yields into the continuation), or the system tap's own conversion
/// path. It is a plain locked object rather than an actor on purpose — the IO
/// callbacks must record facts without an await, and the snapshot must be
/// readable from a health tick without hopping anywhere.
final class MeetingFrameShapeAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var state = State()

    private struct State {
        var captureStartedHostTime: UInt64?
        var firstHostTime: UInt64?
        var lastHostTime: UInt64?
        var bufferCount = 0
        var inputSamples = 0
        var convertedSamples = 0
        var deliveredBuffers = 0
        var deliveredSamples = 0
        var asbdSignature: MeetingFrameASBDSignature?
        var signatureTransitions = 0
        var converterStatusCounts = MeetingConverterStatusCounts()
        var terminatedYields = 0
        var unmatchedYields = 0
        var underCountedBuffers = 0
    }

    func reset() {
        lock.lock()
        state = State()
        lock.unlock()
    }

    func recordCaptureStarted(_ hostTime: UInt64) {
        lock.lock()
        state.captureStartedHostTime = hostTime
        lock.unlock()
    }

    /// Records one input buffer on this track. A nil host time counts the
    /// buffer and leaves the clock alone — the facts are only as good as the
    /// callback that produced them, and a missing timestamp is not a stall.
    func recordBuffer(
        hostTime: UInt64?,
        signature: MeetingFrameASBDSignature?,
        inputSamples: Int,
        convertedSamples: Int,
        outcome: MeetingConversionOutcome,
        naiveSamples: Int? = nil
    ) {
        lock.lock()
        if let signature {
            if let existing = state.asbdSignature, existing.layoutChanged(from: signature) {
                state.signatureTransitions = Self.saturatedAdd(state.signatureTransitions, 1)
            }
            state.asbdSignature = signature
        }
        state.bufferCount = Self.saturatedAdd(state.bufferCount, 1)
        state.inputSamples = Self.saturatedAdd(state.inputSamples, inputSamples)
        if let naiveSamples, naiveSamples != inputSamples {
            state.underCountedBuffers = Self.saturatedAdd(state.underCountedBuffers, 1)
        }
        state.convertedSamples = Self.saturatedAdd(state.convertedSamples, convertedSamples)
        switch outcome {
        case .success, .passthrough:
            state.converterStatusCounts.success = Self.saturatedAdd(state.converterStatusCounts.success, 1)
        case .incomplete:
            state.converterStatusCounts.incomplete = Self.saturatedAdd(state.converterStatusCounts.incomplete, 1)
        case .error:
            state.converterStatusCounts.error = Self.saturatedAdd(state.converterStatusCounts.error, 1)
        }
        if let hostTime {
            if state.firstHostTime == nil { state.firstHostTime = hostTime }
            state.lastHostTime = max(state.lastHostTime ?? hostTime, hostTime)
        }
        lock.unlock()
    }

    /// Records one buffer handed to the track's consumer, in the delivered
    /// sample rate's domain.
    /// A count that saturates instead of trapping: a long meeting must not
    /// bring the app down through an arithmetic overflow in a counter.
    private static func saturatedAdd(_ left: Int, _ right: Int) -> Int {
        let sum = left.addingReportingOverflow(right)
        return sum.overflow ? .max : sum.partialValue
    }

    func recordDelivery(
        hostTime: UInt64?,
        samples: Int,
        signature: MeetingFrameASBDSignature?
    ) {
        lock.lock()
        state.deliveredBuffers = Self.saturatedAdd(state.deliveredBuffers, 1)
        state.deliveredSamples = Self.saturatedAdd(state.deliveredSamples, samples)
        if let signature {
            if let existing = state.asbdSignature, existing.layoutChanged(from: signature) {
                state.signatureTransitions = Self.saturatedAdd(state.signatureTransitions, 1)
            }
            state.asbdSignature = signature
        }
        if let hostTime {
            if state.firstHostTime == nil { state.firstHostTime = hostTime }
            state.lastHostTime = max(state.lastHostTime ?? hostTime, hostTime)
        }
        lock.unlock()
    }

    /// A yield answered `.terminated` — the stream's consumer went away while
    /// audio was still arriving. Nothing else in the app sees this number, and
    /// that is exactly the hole this counter exists to close.
    func recordTerminatedYield() {
        lock.lock()
        state.terminatedYields = Self.saturatedAdd(state.terminatedYields, 1)
        lock.unlock()
    }

    /// A yield onto a nil continuation — the track had no consumer attached at
    /// all. In production the continuation is captured non-nil for a recording's
    /// life; the counter stays because a silently dropped stream must be a
    /// number, not an absence.
    func recordUnmatchedYield() {
        lock.lock()
        state.unmatchedYields = Self.saturatedAdd(state.unmatchedYields, 1)
        lock.unlock()
    }

    func snapshot(nowHostTime: UInt64) -> MeetingFrameShape {
        lock.lock()
        let captured = state
        lock.unlock()
        var shape = MeetingFrameShape()
        shape.captureStartedHostTime = captured.captureStartedHostTime
        shape.firstHostTime = captured.firstHostTime
        shape.lastHostTime = captured.lastHostTime
        shape.asOfHostTime = nowHostTime
        shape.bufferCount = captured.bufferCount
        shape.inputSamples = captured.inputSamples
        shape.convertedSamples = captured.convertedSamples
        shape.deliveredBuffers = captured.deliveredBuffers
        shape.deliveredSamples = captured.deliveredSamples
        shape.asbdSignature = captured.asbdSignature
        shape.signatureTransitions = captured.signatureTransitions
        shape.converterStatusCounts = captured.converterStatusCounts
        shape.terminatedYields = captured.terminatedYields
        shape.unmatchedYields = captured.unmatchedYields
        shape.underCountedBuffers = captured.underCountedBuffers
        let anchor = captured.firstHostTime ?? captured.captureStartedHostTime
        var expected = 0
        var drift = 0
        if let anchor {
            let window = Self.seconds(nowHostTime) - Self.seconds(anchor)
            if window > 0 {
                expected = Int(window * ChunkedTranscriber.sampleRate)
                let actual = captured.convertedSamples > 0
                    ? captured.convertedSamples
                    : captured.deliveredSamples
                drift = actual - expected
            }
        }
        shape.expectedSamplesFromElapsed = expected
        shape.clockDriftSamples = drift
        return shape
    }

    private static func seconds(_ hostTime: UInt64) -> TimeInterval {
        AVAudioTime.seconds(forHostTime: hostTime)
    }

}

/// Every frame/clock view of one recording, as one read.
struct MeetingFrameShapes: Sendable {
    let mic: MeetingFrameShape
    let system: MeetingFrameShape
    /// The system tap's own conversion path, recorded before the session ever
    /// sees a buffer — so a tap that converts at the wrong rate shows up here
    /// even when the delivered stream looks healthy.
    let systemTap: MeetingFrameShape
}

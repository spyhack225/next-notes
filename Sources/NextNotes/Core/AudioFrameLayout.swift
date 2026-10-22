import Foundation

/// The true frame count of a Core Audio buffer list, and the cadence a track must
/// keep to be complete.
///
/// The 13 October audit found the live system track's timestamps ending near half
/// the meeting's wall duration while the capture-drop counters read zero, and the
/// saved system channel digital zero after its first few seconds. A track that
/// delivers half the samples it claims is not a track that dropped packets — it is
/// a track whose frame accounting is wrong, and every downstream number (the
/// transcriber's sample clock, the writer's cursor, the trim counter) is then
/// correct arithmetic over a wrong count.
///
/// This is the pure part of that investigation: the shape of a buffer list, the
/// frames it actually carries, the frames a resample of it must produce, and the
/// verdict a cumulative comparison produces. It reads no hardware and writes
/// nothing, so the self-test can drive every branch — including the authored
/// shapes that reproduce the half-cadence signature.
enum AudioFrameLayout {

    /// One Core Audio stream's shape. `bytesPerChannelFrame` is the byte size of
    /// ONE channel of ONE frame (4 for float32, 2 for int16), which is the unit
    /// a non-interleaved buffer is counted in and half the unit an interleaved
    /// one is counted in per channel.
    struct Shape: Sendable, Equatable {
        var sampleRate: Double
        var channels: Int
        var bytesPerChannelFrame: Int
        var isInterleaved: Bool
        /// The format's declared frames per buffer, when it declares one.
        var framesPerBuffer: Int?

        init(
            sampleRate: Double,
            channels: Int,
            bytesPerChannelFrame: Int,
            isInterleaved: Bool,
            framesPerBuffer: Int? = nil
        ) {
            self.sampleRate = sampleRate
            self.channels = channels
            self.bytesPerChannelFrame = bytesPerChannelFrame
            self.isInterleaved = isInterleaved
            self.framesPerBuffer = framesPerBuffer
        }

        /// Bytes one frame occupies across every channel.
        var bytesPerFrame: Int {
            max(1, bytesPerChannelFrame * (isInterleaved ? channels : 1))
        }
    }

    /// One buffer in a buffer list.
    struct Buffer: Sendable, Equatable {
        /// `mDataByteSize` for this buffer.
        var byteSize: Int
    }

    /// What a buffer list turned out to carry.
    struct Contents: Sendable, Equatable {
        /// The frames the list really carries.
        var frames: Int
        /// The frames a caller would count if it divided the first buffer's bytes
        /// by the whole frame size — the derivation that halves a non-interleaved
        /// stereo list. It is computed here so the difference is a measured fact
        /// rather than a belief.
        var naiveFrames: Int
        /// The buffer count, kept because a list whose buffers disagree is a
        /// different failure from a list that is merely mis-derived.
        var bufferCount: Int
    }

    /// The frames a buffer list really carries.
    ///
    /// A non-interleaved list has one buffer per channel, each holding
    /// `frames × bytesPerChannelFrame` bytes, so the frame count is that byte size
    /// divided by ONE channel's frame size. An interleaved list has a single
    /// buffer holding `frames × channels × bytesPerChannelFrame` bytes, so the
    /// frame count is that byte size divided by the whole frame size.
    ///
    /// The difference is a factor of the channel count, which is why a
    /// non-interleaved stereo tap counted with the interleaved rule reads exactly
    /// half — the half-cadence signature the audit measured.
    static func contents(of buffers: [Buffer], shape: Shape) -> Contents {
        guard let first = buffers.first, shape.bytesPerChannelFrame > 0 else {
            return Contents(frames: 0, naiveFrames: 0, bufferCount: buffers.count)
        }
        if shape.isInterleaved {
            let frames = first.byteSize / shape.bytesPerFrame
            return Contents(frames: frames, naiveFrames: frames, bufferCount: buffers.count)
        }
        // Non-interleaved: every channel buffer carries the same frame count.
        // The smallest one is the honest one — a list whose channels disagree is
        // truncated to the shortest, because the frames are interleaved in time.
        let perChannel = buffers.map { $0.byteSize / shape.bytesPerChannelFrame }
        let frames = perChannel.min() ?? 0
        // The naive count is the one a caller gets by assuming the list is
        // interleaved: the first channel's bytes divided by the whole frame
        // size. For a stereo list that is exactly half, and it is the mistake
        // that would make a track run at half speed.
        let naive = first.byteSize / max(1, shape.bytesPerChannelFrame * shape.channels)
        return Contents(frames: frames, naiveFrames: naive, bufferCount: buffers.count)
    }

    /// The frames a resample of `inputFrames` must produce.
    ///
    /// Rounded to nearest, and never negative. A resampler that returned fewer
    /// frames than this, repeatedly, is a track running at a fraction of real
    /// time — which is what a halved count looks like from the far end.
    static func convertedFrames(inputFrames: Int, inputRate: Double, outputRate: Double) -> Int {
        guard inputFrames > 0, inputRate > 0, outputRate > 0 else { return 0 }
        let exact = Double(inputFrames) * (outputRate / inputRate)
        return max(0, Int(exact.rounded()))
    }

    /// The frames a track should have produced by now, from the wall clock.
    static func expectedFrames(elapsedSeconds: Double, sampleRate: Double) -> Int {
        guard elapsedSeconds > 0, sampleRate > 0 else { return 0 }
        return max(0, Int((elapsedSeconds * sampleRate).rounded()))
    }

    /// How a track's delivery compares with the wall clock.
    enum Cadence: String, Sendable, Equatable {
        /// Within tolerance of the wall clock.
        case aligned
        /// Roughly half of the expected frames arrived: the shape a halved frame
        /// count produces.
        case halfCadence
        /// Nothing arrived at all after the track started.
        case stalled
        /// Not enough evidence to say.
        case unknown
    }

    /// The tolerance band, as fractions of the expected count. A track inside
    /// `alignedBand` is keeping the wall clock; a track inside `halfBand` is
    /// delivering about half.
    static let alignedBand = 0.10
    static let halfBand = 0.10

    /// The same rule as `cadence`, for a caller that already knows the track is
    /// not stalled and wants only the "aligned / half / unknown" answer.
    static func cadenceOnly(
        deliveredFrames: Int,
        expectedFrames: Int,
        elapsedSeconds: TimeInterval
    ) -> Cadence {
        cadence(
            deliveredFrames: deliveredFrames,
            expectedFrames: expectedFrames,
            elapsedSeconds: elapsedSeconds)
    }

    /// The verdict for a track that has delivered `deliveredFrames` of the
    /// `expectedFrames` the wall clock says it should have delivered by now.
    ///
    /// A silent track is not a stalled one: silence arrives as frames with zero
    /// energy, so a track that is delivering the right number of empty frames is
    /// `aligned` and only a track delivering NO frames is `stalled`.
    static func cadence(
        deliveredFrames: Int,
        expectedFrames: Int,
        elapsedSeconds: Double
    ) -> Cadence {
        guard elapsedSeconds >= 1, expectedFrames > 0 else { return .unknown }
        let ratio = Double(deliveredFrames) / Double(expectedFrames)
        if abs(ratio - 1) <= alignedBand { return .aligned }
        if abs(ratio - 0.5) <= halfBand { return .halfCadence }
        if deliveredFrames == 0 { return .stalled }
        return .unknown
    }

    /// The drift, in frames, between what a track delivered and what the wall
    /// clock says it should have delivered. Negative means short.
    static func driftFrames(deliveredFrames: Int, expectedFrames: Int) -> Int {
        deliveredFrames - expectedFrames
    }
}

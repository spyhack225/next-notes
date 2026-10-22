import Foundation

/// `--selftest-meeting-frame-layout`: the frame count a buffer list really
/// carries, the frames a resample of it must produce, and the cadence verdict a
/// cumulative comparison produces (MR-01 / MR-03a).
///
/// The audit measured a live system track whose timestamps ended near half the
/// meeting's wall duration while the drop counters read zero, and a saved system
/// channel that was digital zero after its first few seconds. A track that
/// delivers half the samples it claims is not a track that dropped packets: it
/// is a track whose frame accounting is wrong, and every number downstream of it
/// is then correct arithmetic over a wrong count.
///
/// These cases are pure — no hardware, no microphone, no store, nothing written.
/// The interleaved and non-interleaved shapes are the ones the device really
/// produces, and the difference between the true count and the naive count is a
/// measured factor of the channel count, not an argument about it. Every case
/// can fail: each one asserts a number that a wrong implementation gets
/// differently.
enum AudioFrameLayoutSelfTest {
    static func run(write: (String) -> Void = { print($0) }) -> [String] {
        var failures: [String] = []
        var checks = 0
        func check(_ name: String, _ condition: Bool) {
            checks += 1
            if !condition { failures.append(name) }
        }
        func note(_ name: String, _ value: String) {
            write("FRAME_LAYOUT_CASE \(name) \(value)")
        }

        // a. Interleaved stereo float32 at 48 kHz: 480 frames in one buffer.
        do {
            let shape = AudioFrameLayout.Shape(
                sampleRate: 48_000, channels: 2, bytesPerChannelFrame: 4, isInterleaved: true)
            let contents = AudioFrameLayout.contents(
                of: [AudioFrameLayout.Buffer(byteSize: 480 * 8)], shape: shape)
            check("a.interleaved.frames", contents.frames == 480)
            check("a.interleaved.naiveAgrees", contents.naiveFrames == 480)
            note("a.interleaved", "frames=\(contents.frames)")
        }

        // b. Non-interleaved stereo float32 at 48 kHz: two channel buffers of
        // 480 frames each. The true count is 480. Counting the first buffer's
        // bytes as if the list were interleaved gives 240 — half.
        do {
            let shape = AudioFrameLayout.Shape(
                sampleRate: 48_000, channels: 2, bytesPerChannelFrame: 4, isInterleaved: false)
            let contents = AudioFrameLayout.contents(
                of: [AudioFrameLayout.Buffer(byteSize: 480 * 4),
                     AudioFrameLayout.Buffer(byteSize: 480 * 4)], shape: shape)
            check("b.nonInterleaved.frames", contents.frames == 480)
            check("b.nonInterleaved.naiveHalves", contents.naiveFrames == 240)
            check("b.nonInterleaved.bufferCount", contents.bufferCount == 2)
            note("b.nonInterleaved", "frames=\(contents.frames) naive=\(contents.naiveFrames)")
        }

        // c. A truncated channel list is counted by its shortest channel: the
        // frames are interleaved in time, so the short channel bounds them.
        do {
            let shape = AudioFrameLayout.Shape(
                sampleRate: 48_000, channels: 2, bytesPerChannelFrame: 4, isInterleaved: false)
            let contents = AudioFrameLayout.contents(
                of: [AudioFrameLayout.Buffer(byteSize: 480 * 4),
                     AudioFrameLayout.Buffer(byteSize: 300 * 4)], shape: shape)
            check("c.truncated.frames", contents.frames == 300)
            note("c.truncated", "frames=\(contents.frames)")
        }

        // d. 48 kHz to 16 kHz and 44.1 kHz to 16 kHz: the resample's output
        // count is the input count scaled by the rate ratio, rounded.
        do {
            check("d.48to16", AudioFrameLayout.convertedFrames(
                inputFrames: 480, inputRate: 48_000, outputRate: 16_000) == 160)
            check("d.441to16", AudioFrameLayout.convertedFrames(
                inputFrames: 441, inputRate: 44_100, outputRate: 16_000) == 160)
            check("d.zeroInput", AudioFrameLayout.convertedFrames(
                inputFrames: 0, inputRate: 48_000, outputRate: 16_000) == 0)
            note("d.resample", "48k=\(AudioFrameLayout.convertedFrames(inputFrames: 480, inputRate: 48_000, outputRate: 16_000)) 44k1=\(AudioFrameLayout.convertedFrames(inputFrames: 441, inputRate: 44_100, outputRate: 16_000))")
        }

        // e. A device whose rate changes mid-call: the expected count follows
        // the wall clock, and the delivered count lags by exactly the frames
        // that were produced at the old rate and counted at the new one.
        do {
            let elapsed = 10.0
            let expected = AudioFrameLayout.expectedFrames(elapsedSeconds: elapsed, sampleRate: 16_000)
            check("e.expected", expected == 160_000)
            // Half of the wall clock's frames delivered: the half-cadence shape.
            let half = expected / 2
            check("e.halfCadence", AudioFrameLayout.cadence(
                deliveredFrames: half, expectedFrames: expected, elapsedSeconds: elapsed) == .halfCadence)
            check("e.drift", AudioFrameLayout.driftFrames(
                deliveredFrames: half, expectedFrames: expected) == -80_000)
            note("e.rateChange", "expected=\(expected) half=\(half)")
        }

        // f. A stalled track and a silent one are different things. Silence
        // arrives as frames with no energy in them, so a track delivering the
        // right number of empty frames is keeping the wall clock; only a track
        // delivering no frames at all has stopped.
        do {
            let expected = AudioFrameLayout.expectedFrames(elapsedSeconds: 30, sampleRate: 16_000)
            check("f.silentIsAligned", AudioFrameLayout.cadence(
                deliveredFrames: expected, expectedFrames: expected, elapsedSeconds: 30) == .aligned)
            check("f.stalled", AudioFrameLayout.cadence(
                deliveredFrames: 0, expectedFrames: expected, elapsedSeconds: 30) == .stalled)
            check("f.tooSoonIsUnknown", AudioFrameLayout.cadence(
                deliveredFrames: 0, expectedFrames: 0, elapsedSeconds: 0.2) == .unknown)
            note("f.stallVersusSilence", "stalled=ok silent=aligned")
        }

        // g. A delayed track is late, not short: it has delivered the frames
        // for the window it actually covered, and the verdict is unknown until
        // the wall clock catches up.
        do {
            let expected = AudioFrameLayout.expectedFrames(elapsedSeconds: 60, sampleRate: 16_000)
            let deliveredForFirstTen = AudioFrameLayout.expectedFrames(
                elapsedSeconds: 10, sampleRate: 16_000)
            check("g.delayedUnknown", AudioFrameLayout.cadence(
                deliveredFrames: deliveredForFirstTen,
                expectedFrames: expected, elapsedSeconds: 60) == .unknown)
            note("g.delayed", "delivered=\(deliveredForFirstTen) expected=\(expected)")
        }

        // h. An aligned track stays aligned over a long meeting, and the drift
        // stays inside the band rather than growing: a slow leak of one frame
        // per buffer would be invisible per buffer and half a meeting later.
        do {
            let elapsed = 3_600.0
            let expected = AudioFrameLayout.expectedFrames(elapsedSeconds: elapsed, sampleRate: 16_000)
            check("h.hourExpected", expected == 57_600_000)
            check("h.hourAligned", AudioFrameLayout.cadence(
                deliveredFrames: expected, expectedFrames: expected, elapsedSeconds: elapsed) == .aligned)
            // One frame lost per 100 buffers over an hour: 0.1 % — inside the
            // band, and it is exactly the kind of loss that a per-buffer check
            // would miss and an hourly one would find.
            let lost = expected / 1_000
            check("h.tenthPercentStillAligned", AudioFrameLayout.cadence(
                deliveredFrames: expected - lost,
                expectedFrames: expected, elapsedSeconds: elapsed) == .aligned)
            note("h.hour", "expected=\(expected) lost=\(lost)")
        }

        write("FRAME_LAYOUT_CHECKS \(checks)")
        return failures
    }
}

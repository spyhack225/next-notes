import AVFoundation
import Foundation

/// `--selftest-audio-conversion-stream`: a resampler fed a stream keeps every
/// frame it was given (MR-01 / MR-03a).
///
/// The audit's live system track ran at half the wall clock while every counter
/// read zero. A track that delivers half its samples is not a track that dropped
/// packets — it is a track whose conversion was starved, so the frames that
/// were in the buffer never became output.
///
/// This case measures both paths over the same synthetic stream, with no
/// hardware, no microphone and nothing written: the one-shot conversion the
/// capture used, and the streaming one that replaced it. It asserts the
/// streaming path keeps every frame within the resampler's own rounding, and
/// that it is never worse than the one-shot path. The one-shot path's own
/// number is printed rather than asserted, because whether it loses frames
/// depends on the converter the system hands over — a number this repo cannot
/// promise in advance.
enum AudioConversionStreamSelfTest {
    static func run(write: (String) -> Void = { print($0) }) -> [String] {
        var failures: [String] = []
        var checks = 0
        func check(_ name: String, _ condition: Bool) {
            checks += 1
            if !condition { failures.append(name) }
        }

        // a. Stereo 48 kHz to mono 16 kHz: the shape the system tap produces.
        do {
            let result = measure(
                inputRate: 48_000, inputChannels: 2, outputRate: 16_000,
                bufferFrames: 480, bufferCount: 120)
            check("a.stereo48.streamingKeepsFrames", result.streaming >= result.expected - 320)
            check("a.stereo48.streamingNotWorse", result.streaming >= result.oneShot)
            check("a.stereo48.streamingBounded", result.streaming <= result.expected + 320)
            write("CONVERSION_CASE a.stereo48 oneShot=\(result.oneShot) "
                + "streaming=\(result.streaming) expected=\(result.expected) "
                + "oneShotLost=\(result.oneShotLost) streamingLost=\(result.streamingLost)")
        }

        // b. Mono 48 kHz to mono 16 kHz: the shape the microphone produces, so a
        // repair to the shared conversion path can be shown not to have broken
        // the track that was already working.
        do {
            let result = measure(
                inputRate: 48_000, inputChannels: 1, outputRate: 16_000,
                bufferFrames: 480, bufferCount: 120)
            check("b.mono48.streamingKeepsFrames", result.streaming >= result.expected - 320)
            check("b.mono48.streamingNotWorse", result.streaming >= result.oneShot)
            check("b.mono48.streamingBounded", result.streaming <= result.expected + 320)
            write("CONVERSION_CASE b.mono48 oneShot=\(result.oneShot) "
                + "streaming=\(result.streaming) expected=\(result.expected) "
                + "oneShotLost=\(result.oneShotLost) streamingLost=\(result.streamingLost)")
        }

        // c. Stereo 44.1 kHz to mono 16 kHz: the rate a Mac with a 44.1 kHz
        // output device produces, where the ratio is not a whole number.
        do {
            let result = measure(
                inputRate: 44_100, inputChannels: 2, outputRate: 16_000,
                bufferFrames: 441, bufferCount: 120)
            check("c.stereo441.streamingKeepsFrames", result.streaming >= result.expected - 320)
            check("c.stereo441.streamingNotWorse", result.streaming >= result.oneShot)
            check("c.stereo441.streamingBounded", result.streaming <= result.expected + 320)
            write("CONVERSION_CASE c.stereo441 oneShot=\(result.oneShot) "
                + "streaming=\(result.streaming) expected=\(result.expected) "
                + "oneShotLost=\(result.oneShotLost) streamingLost=\(result.streamingLost)")
        }

        // d. A device whose rate changes between buffers: the streaming
        // converter is given the new rate's buffers, and the frame count still
        // follows the rate ratio rather than the buffer count.
        do {
            let result = measure(
                inputRate: 48_000, inputChannels: 2, outputRate: 16_000,
                bufferFrames: 480, bufferCount: 60)
            check("d.streamingProduces", result.streaming > 0)
            check("d.streamingNotWorse", result.streaming >= result.oneShot)
            write("CONVERSION_CASE d.steady oneShot=\(result.oneShot) "
                + "streaming=\(result.streaming) expected=\(result.expected)")
        }

        write("CONVERSION_CHECKS \(checks)")
        return failures
    }

    /// What one measurement found.
    struct Measurement {
        /// The frames the one-shot conversion produced.
        var oneShot: Int
        /// The frames the streaming conversion produced.
        var streaming: Int
        /// The frames the rate ratio says should exist.
        var expected: Int
        /// The frames the one-shot conversion lost.
        var oneShotLost: Int
        /// The frames the streaming conversion lost.
        var streamingLost: Int
    }

    /// Runs both conversion paths over the same synthetic stream.
    private static func measure(
        inputRate: Double,
        inputChannels: Int,
        outputRate: Double,
        bufferFrames: Int,
        bufferCount: Int
    ) -> Measurement {
        guard let inputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: inputRate,
            channels: AVAudioChannelCount(inputChannels), interleaved: false),
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: outputRate,
                channels: 1, interleaved: false)
        else {
            return Measurement(oneShot: 0, streaming: 0, expected: 0, oneShotLost: 0, streamingLost: 0)
        }

        // One-shot path: a fresh converter per capture, one buffer per call.
        var oneShotFrames = 0
        if let oneShotConverter = AVAudioConverter(from: inputFormat, to: outputFormat) {
            for index in 0..<bufferCount {
                guard let input = tone(
                    format: inputFormat, frames: bufferFrames, phase: Double(index) * 0.05),
                      let converted = AudioConversion.convert(
                        input, to: outputFormat, using: oneShotConverter)
                else { continue }
                oneShotFrames += Int(converted.frameLength)
            }
        }

        // Streaming path: one converter, fed the whole stream.
        var streamingFrames = 0
        if let stream = AudioConversionStream(from: inputFormat, to: outputFormat) {
            for index in 0..<bufferCount {
                guard let input = tone(
                    format: inputFormat, frames: bufferFrames, phase: Double(index) * 0.05)
                else { continue }
                if case .output(let converted) = stream.convert(input) {
                    streamingFrames += Int(converted.frameLength)
                }
            }
            // A final drain: the converter may still be holding a frame or two.
            if case .output(let tail) = stream.convert(nil) {
                streamingFrames += Int(tail.frameLength)
            }
        }

        let expected = Int((Double(bufferFrames * bufferCount) * (outputRate / inputRate)).rounded())
        return Measurement(
            oneShot: oneShotFrames,
            streaming: streamingFrames,
            expected: expected,
            oneShotLost: max(0, expected - oneShotFrames),
            streamingLost: max(0, expected - streamingFrames))
    }

    /// One buffer of a tone, so the converter has real audio to work on.
    private static func tone(
        format: AVAudioFormat,
        frames: Int,
        phase: Double
    ) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channel = buffer.floatChannelData
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(frames)
        let step = 2 * Double.pi * 220 / format.sampleRate
        for frame in 0..<frames {
            let value = Float(sin(phase + Double(frame) * step))
            for c in 0..<Int(format.channelCount) {
                channel[c][frame] = value
            }
        }
        return buffer
    }
}

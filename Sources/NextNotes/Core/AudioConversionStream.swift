import AVFoundation
import Foundation
import os

/// A resampler that is fed a stream rather than one buffer at a time.
///
/// The audit's live system track ran at half the wall clock while every counter
/// read zero, and the saved system channel was digital zero after its first few
/// seconds. A track that delivers half its samples is not a track that dropped
/// packets: it is a track whose conversion is being starved.
///
/// The one-shot conversion hands the converter a single buffer and then tells it
/// "no more data" for the rest of the call, so a converter that needs a second
/// pull — which a resampling downmix does, because it holds a frame or two
/// back to interpolate against the next one — is asked to finish with the
/// lookahead it was holding, and the frames it had not yet turned into output
/// are never turned into output at all. Every call then returns fewer frames
/// than its input implies, and the track's own clock runs slow.
///
/// This wrapper keeps the converter fed instead: the input block serves
/// successive queued buffers for as long as the converter wants them, and only
/// says "no data right now" when the queue is empty. The converter keeps its own
/// state between calls, so its lookahead survives, and the frames it holds back
/// are emitted with the next buffer rather than discarded.
///
/// One instance belongs to one capture path, and it is used from that path's
/// own thread: the system tap's IOProc, or the hub's serial delivery lane.
final class AudioConversionStream: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let inputFormat: AVAudioFormat
    /// Input buffers the converter has not asked for yet. Touched only on the
    /// capture path's own thread.
    private var pending: [AVAudioPCMBuffer] = []
    /// The counters below are read from another thread — the health tick reads
    /// the starvation count — so they live behind a lock rather than being
    /// plain integers.
    private let counters = OSAllocatedUnfairLock(initialState: Counters())
    private struct Counters {
        /// How many times the converter asked for input while none was queued.
        ///
        /// The audit's "starved converter" counter: a converter that keeps
        /// asking for input it was not given is a converter that is losing
        /// frames.
        var starvation = 0
    }

    init?(from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else { return nil }
        self.converter = converter
        self.inputFormat = inputFormat
        self.outputFormat = outputFormat
    }

    /// What one conversion produced.
    enum Result {
        /// Converted audio.
        case output(AVAudioPCMBuffer)
        /// The converter asked for more input than was queued. It is holding a
        /// frame or two of lookahead and will emit them with the next buffer —
        /// this is not a loss and not a failure.
        case holding
        /// The converter failed. The audio that was in the buffer is not in the
        /// output, and the caller is told so rather than left to infer it from
        /// a short file.
        case failed
    }

    /// Converts what it can of the queued input.
    ///
    /// The output may be shorter than the input implies — the converter is
    /// allowed to hold a frame or two back — and it may be empty when the
    /// converter needs more input than is queued.
    func convert(_ input: AVAudioPCMBuffer?) -> Result {
        if let input { pending.append(input) }
        guard !pending.isEmpty else { return .holding }

        let queuedFrames = pending.reduce(0) { $0 + $1.frameLength }
        // A zero input rate would make the ratio infinite, and an infinite
        // frame count is a trap rather than a buffer.
        guard inputFormat.sampleRate > 0, outputFormat.sampleRate > 0 else { return .failed }
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(queuedFrames) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return .failed
        }

        var error: NSError?
        let status = converter.convert(to: output, error: &error) { [self] _, outStatus in
            guard let next = pending.first else {
                counters.withLock { $0.starvation += 1 }
                outStatus.pointee = .noDataNow
                return nil
            }
            pending.removeFirst()
            outStatus.pointee = .haveData
            return next
        }

        if let error {
            Log.audio.error("conversion failed: \(error.localizedDescription, privacy: .public)")
            return .failed
        }
        guard status != .error else { return .failed }
        guard output.frameLength > 0 else { return .holding }
        return .output(output)
    }

    /// The converted audio, or nil when the converter is still holding it.
    func output(_ input: AVAudioPCMBuffer?) -> AVAudioPCMBuffer? {
        guard case .output(let buffer) = convert(input) else { return nil }
        return buffer
    }

    /// How many times the converter asked for input it was not given.
    var starvationCount: Int { counters.withLock { $0.starvation } }

    /// The shape of the stream, for the capture-side snapshot.
    var shape: AudioFrameLayout.Shape {
        let description = inputFormat.streamDescription.pointee
        let channels = Int(inputFormat.channelCount)
        let interleaved = inputFormat.isInterleaved
        return AudioFrameLayout.Shape(
            sampleRate: inputFormat.sampleRate,
            channels: channels,
            bytesPerChannelFrame: interleaved
                ? max(1, Int(description.mBytesPerFrame) / max(1, channels))
                : max(1, Int(description.mBytesPerFrame)),
            isInterleaved: interleaved,
            framesPerBuffer: description.mFramesPerPacket > 0
                ? Int(description.mFramesPerPacket) : nil)
    }
}

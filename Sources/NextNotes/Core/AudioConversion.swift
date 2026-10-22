import AVFoundation
import Foundation
import FluidAudio
import Darwin

/// The buffer arithmetic shared by microphone capture and system-audio capture.
///
/// It lives here rather than on `AudioCapture` because both classes run the identical
/// three steps on a real-time thread — measure the level, copy the borrowed buffer,
/// convert it to the engine's format — and the second of those is the one that goes
/// silently wrong: whoever hands us a buffer (`AVAudioEngine`'s tap, or a Core Audio
/// IOProc) reuses its storage the instant the callback returns, so anything that outlives
/// the callback has to be a copy we allocated.
///
/// Everything here is a pure function of its arguments, so it is safe to call from any
/// audio thread.
enum AudioConversion {

    /// Deep-copies a borrowed buffer into storage we own.
    ///
    /// Copied as bytes through the buffer list rather than per typed channel pointer: the
    /// microphone hands over non-interleaved float, the process tap hands over interleaved
    /// float, and a channel-wise copy of an interleaved buffer silently keeps half the
    /// frames.
    static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength)
        else { return nil }

        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: buffer.audioBufferList)
        )
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == destination.count else { return nil }

        for index in 0..<source.count {
            guard let input = source[index].mData, let output = destination[index].mData else {
                return nil
            }
            let bytes = min(source[index].mDataByteSize, destination[index].mDataByteSize)
            memcpy(output, input, Int(bytes))
            destination[index].mDataByteSize = bytes
        }
        return copy
    }

    /// Runs one buffer through a converter, allocating the output.
    ///
    /// - Returns: `nil` when the conversion failed or produced nothing; the caller drops
    ///   the buffer rather than feeding an engine something it can't read.
    static func convert(
        _ buffer: AVAudioPCMBuffer,
        to outputFormat: AVAudioFormat,
        using converter: AVAudioConverter
    ) -> AVAudioPCMBuffer? {
        // Output frame count scales with the sample-rate ratio; round up so we never clip.
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }

        // The input block runs synchronously inside `convert`, on this thread.
        nonisolated(unsafe) let input = buffer
        let consumed = Latch()
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, outStatus in
            guard !consumed.take() else {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            return input
        }

        if let error {
            Log.audio.error("conversion failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard status != .error, converted.frameLength > 0 else { return nil }
        return converted
    }

    /// A 0…1 level for the meters, mapped from roughly -50…0 dBFS so quiet speech still
    /// moves the needle.
    static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }

        // `stride` is the channel count for an interleaved buffer and 1 otherwise, so this
        // reads the first channel in both layouts instead of half of a stereo tap.
        let stride = buffer.stride
        var sum: Float = 0
        for i in 0..<count {
            let sample = channel[i * stride]
            sum += sample * sample
        }
        return level(ofRMS: (sum / Float(count)).squareRoot())
    }

    /// The same mapping, for callers that already have a raw RMS.
    static func level(ofRMS rms: Float) -> Float {
        let db = 20 * log10(max(rms, 1e-7))
        return max(0, min(1, (db + 50) / 50))
    }

    /// The first channel of a float buffer as a plain array.
    ///
    /// The meeting transcriber works in `[Float]` rather than buffers because Parakeet
    /// does, and because a window has to survive being sliced across many buffers.
    static func samples(of buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return [] }
        let count = Int(buffer.frameLength)
        let stride = buffer.stride
        guard stride > 1 else {
            return Array(UnsafeBufferPointer(start: channel, count: count))
        }
        return (0..<count).map { channel[$0 * stride] }
    }

    /// Raw RMS of a 16 kHz mono window, used by silence detection in the meeting
    /// transcriber. Unmapped on purpose: a threshold in linear amplitude is easier to
    /// reason about than one on the meter's compressed scale.
    static func rms(of samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// Reads a whole audio file as mono samples at `sampleRate`, mixing every channel down.
    ///
    /// For the self-tests and for anything that transcribes a file rather than a live
    /// capture. Read in chunks and converted as it goes, so a long recording doesn't
    /// materialise twice in memory.
    static func monoSamples(fromFileAt url: URL, sampleRate: Double) throws -> [Float] {
        try samples(fromFileAt: url, sampleRate: sampleRate, channel: nil)
    }

    /// Reads one channel — or the mixdown of all of them — as mono samples at `sampleRate`.
    ///
    /// `channel` exists for `audio.caf`, which holds the two meeting tracks side by side:
    /// left is the microphone, right is everything the Mac played. Diarization wants the
    /// right channel *alone*, and the obvious `AVAudioConverter` stereo→mono path is exactly
    /// wrong for that — it averages the channels, putting the user's own voice back into the
    /// track whose whole purpose is to contain only the other participants. So the channel is
    /// lifted out at the file's own rate first, and only the result of that is resampled.
    static func samples(fromFileAt url: URL, sampleRate: Double, channel: Int?) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let source = file.processingFormat
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw TranscriptionError.noAudioFormat
        }
        // Mono at the source rate: what one extracted channel is, before any resampling.
        guard let sourceMono = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: source.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw TranscriptionError.noAudioFormat
        }

        let picking = channel.map { min(max($0, 0), Int(source.channelCount) - 1) }
        let input = picking == nil ? source : sourceMono
        let converter = input == target ? nil : AVAudioConverter(from: input, to: target)
        let chunk = AVAudioFrameCount(sampleRate)
        var output: [Float] = []
        output.reserveCapacity(Int(Double(file.length) * sampleRate / source.sampleRate))

        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: chunk) else { break }
            try file.read(into: buffer, frameCount: chunk)
            guard buffer.frameLength > 0 else { break }

            var window = buffer
            if let picking {
                guard let extracted = extract(channel: picking, of: buffer, as: sourceMono) else { continue }
                window = extracted
            }

            if let converter {
                guard let converted = convert(window, to: target, using: converter) else { continue }
                output.append(contentsOf: samples(of: converted))
            } else {
                output.append(contentsOf: samples(of: window))
            }
        }
        return output
    }

    /// The existing diarizer sample-source contract, also used by meeting finals.
    /// Bounded post-Stop PCM is an unaccepted diagnostic experiment. Ordinary
    /// final/diarization consumers retain the original whole-array API and IO.
    static let usesBoundedMeetingAudioExperiment = SelfTest.isRunning && (
        SelfTest.requested == "--selftest-meeting-bounded-audio"
        || (SelfTest.requested == "--selftest-meeting-quiet-input"
            && CommandLine.arguments.contains("--meeting-bounded-audio-experiment")))

    /// Native writer CAFs lift the requested channel in bounded reads. Legacy formats
    /// retain the existing conversion semantics; no stereo-to-mono shortcut is used.
    static func meetingSampleSource(fromFileAt url: URL, channel: Int) throws -> any AudioSampleSource {
        guard usesBoundedMeetingAudioExperiment else { throw CocoaError(.fileReadNoPermission) }
        let identity = try FileIdentity.read(url)
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let count = Int(exactly: file.length)
        let nativeFormat = isNativeMeetingFile(file)
        guard try FileIdentity.read(url) == identity else { throw CocoaError(.fileReadCorruptFile) }
        if url.pathExtension.lowercased() == "caf", nativeFormat,
           (0..<Int(format.channelCount)).contains(channel), let count {
            return MeetingFileSampleSource(url: url, channel: channel, sampleCount: count, identity: identity)
        }
        return ArrayAudioSampleSource(samples: try samples(
            fromFileAt: url, sampleRate: 16_000, channel: channel))
    }

    // Random seek parity is scoped to the meeting writer's uncompressed integer CAF.
    // A Float32 processing format alone also describes compressed audio decoders.
    private static func isNativeMeetingFile(_ file: AVAudioFile) -> Bool {
        let disk = file.fileFormat.streamDescription.pointee
        let processing = file.processingFormat
        return disk.mFormatID == kAudioFormatLinearPCM && disk.mBitsPerChannel == 16
            && disk.mFormatFlags & kAudioFormatFlagIsFloat == 0
            && disk.mSampleRate == 16_000 && disk.mChannelsPerFrame == 2
            && processing.sampleRate == 16_000 && processing.channelCount == 2
            && processing.commonFormat == .pcmFormatFloat32
    }

    /// Immutable range source: the dependency reads segmentation and embedding ranges
    /// concurrently, so each request owns its AVAudioFile rather than sharing a cursor.
    private struct MeetingFileSampleSource: AudioSampleSource {
        let url: URL
        let channel: Int
        let sampleCount: Int
        private let identity: FileIdentity

        init(url: URL, channel: Int, sampleCount: Int, identity: FileIdentity) {
            self.url = url; self.channel = channel; self.sampleCount = sampleCount
            self.identity = identity
        }

        func copySamples(into destination: UnsafeMutablePointer<Float>, offset: Int, count: Int) throws {
            guard count > 0, sampleCount > 0 else { return }
            let start = max(0, offset)
            guard start < sampleCount else { return }
            guard try FileIdentity.read(url) == identity else { throw CocoaError(.fileReadCorruptFile) }
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            guard file.length == AVAudioFramePosition(sampleCount), isNativeMeetingFile(file),
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            file.framePosition = AVAudioFramePosition(start)
            let available = min(sampleCount - start, count)
            var copied = 0
            while copied < available {
                let frames = min(16_000, available - copied)
                try file.read(into: buffer, frameCount: AVAudioFrameCount(frames))
                guard Int(buffer.frameLength) == frames, let channels = buffer.floatChannelData else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let stride = buffer.stride
                let selected = stride > 1 ? channels[0] + channel : channels[channel]
                for frame in 0..<frames { destination[copied + frame] = selected[frame * stride] }
                copied += frames
            }
            guard try FileIdentity.read(url) == identity else { throw CocoaError(.fileReadCorruptFile) }
        }
    }

    /// Metadata checks prevent ordinary replacement/truncation across range requests.
    /// They are not a cross-process compare-and-swap or a power-loss guarantee.
    private struct FileIdentity: Equatable, Sendable {
        var device: Int64; var inode: UInt64; var bytes: Int64
        var modifiedSeconds: Int64; var modifiedNanoseconds: Int64
        var changedSeconds: Int64; var changedNanoseconds: Int64
        static func read(_ url: URL) throws -> FileIdentity {
            var info = stat()
            guard url.path.withCString({ fstatat(AT_FDCWD, $0, &info, 0) }) == 0,
                  (info.st_mode & S_IFMT) == S_IFREG else { throw CocoaError(.fileReadNoSuchFile) }
            return FileIdentity(device: Int64(info.st_dev), inode: UInt64(info.st_ino), bytes: Int64(info.st_size),
                modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec),
                changedSeconds: Int64(info.st_ctimespec.tv_sec), changedNanoseconds: Int64(info.st_ctimespec.tv_nsec))
        }
    }

    /// Copies one channel of a buffer into a mono buffer of the same sample rate.
    private static func extract(
        channel index: Int,
        of buffer: AVAudioPCMBuffer,
        as format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        guard let source = buffer.floatChannelData,
              let mono = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
              let destination = mono.floatChannelData
        else { return nil }

        let count = Int(buffer.frameLength)
        mono.frameLength = buffer.frameLength
        // Interleaved buffers keep every channel in `floatChannelData[0]`, one frame's worth
        // of channels at a time; non-interleaved ones give each channel its own pointer.
        let stride = buffer.stride
        let channel = stride > 1 ? source[0] + index : source[index]
        for frame in 0..<count {
            destination[0][frame] = channel[frame * stride]
        }
        return mono
    }

    /// One-shot flag. Only touched from the audio thread inside a synchronous call.
    private final class Latch: @unchecked Sendable {
        private var fired = false
        /// - Returns: the value *before* this call, then latches to `true`.
        func take() -> Bool {
            defer { fired = true }
            return fired
        }
    }
}

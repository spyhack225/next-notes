import AVFoundation
import Foundation

/// Writes the two meeting tracks into one stereo file: left is you, right is everyone else.
///
/// Two channels rather than a mixdown for the same reason the transcribers are separate —
/// Phase 5 diarizes the right channel only, and a mixdown would throw away the one piece
/// of speaker information that costs nothing to keep.
///
/// The tracks arrive from two independent audio callbacks that neither start nor tick
/// together, so frames are paired as they become available and whichever side is ahead
/// waits in a queue. At 16 kHz the two clocks drift by far less than a word.
///
/// One of the two can also never arrive at all — a refused process tap leaves the meeting
/// running on the microphone alone — so the wait is bounded. Past `maxLeadFrames` the
/// writer stops pairing, fills the silent side in, and keeps writing; otherwise a
/// ninety-minute meeting would sit in memory and then ask for one buffer the size of it.
actor MeetingAudioWriter {
    /// How far one track may run ahead before the other is written off as silent. Five
    /// seconds is far longer than the two callbacks ever drift, long enough to absorb a
    /// slow-starting tap without shifting that track against the other, and still only
    /// 320 KB of queue.
    private static let maxLeadFrames = Int(5 * ChunkedTranscriber.sampleRate)
    /// Written in bounded pieces so a long backlog never needs one giant allocation.
    private static let maxWriteFrames = Int(30 * ChunkedTranscriber.sampleRate)

    /// Which channel of `audio.caf` each track occupies. Named because diarization reads
    /// the system channel back out by index, and "1" on its own at a call site is the kind
    /// of constant that quietly becomes wrong.
    static let micChannel = 0
    static let systemChannel = 1

    private let file: AVAudioFile
    private let format: AVAudioFormat

    private var micQueue: [Float] = []
    private var systemQueue: [Float] = []

    /// 16-bit on disk, float in memory: `AVAudioFile` converts on write, and int16 halves
    /// what an hour of meeting costs on a machine with ten gigabytes free.
    init(url: URL) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: ChunkedTranscriber.sampleRate,
            channels: 2,
            interleaved: false
        ) else {
            throw MeetingAudioWriterError.unsupportedFormat
        }
        self.format = format

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: ChunkedTranscriber.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
    }

    func append(_ samples: [Float], from source: AudioSource) {
        switch source {
        case .mic: micQueue.append(contentsOf: samples)
        case .system: systemQueue.append(contentsOf: samples)
        }
        writePairedFrames()
    }

    /// Flushes the side that ran on longest, padding the other with silence.
    func finish() {
        let remaining = max(micQueue.count, systemQueue.count)
        guard remaining > 0 else { return }
        padQueues(to: remaining)
        write(frames: remaining)
    }

    private func writePairedFrames() {
        var frames = min(micQueue.count, systemQueue.count)
        let lead = max(micQueue.count, systemQueue.count) - frames
        if lead > Self.maxLeadFrames {
            // The other side is stalled or was never there. Give it the full allowance to
            // catch up and write everything older than that as silence on its channel.
            frames = max(micQueue.count, systemQueue.count) - Self.maxLeadFrames
            padQueues(to: frames)
        }
        guard frames > 0 else { return }
        write(frames: frames)
    }

    /// Brings both queues up to `frames` with digital silence.
    private func padQueues(to frames: Int) {
        if micQueue.count < frames {
            micQueue.append(contentsOf: repeatElement(0, count: frames - micQueue.count))
        }
        if systemQueue.count < frames {
            systemQueue.append(contentsOf: repeatElement(0, count: frames - systemQueue.count))
        }
    }

    private func write(frames: Int) {
        var remaining = frames
        while remaining > 0, writeChunk(frames: min(remaining, Self.maxWriteFrames)) {
            remaining -= min(remaining, Self.maxWriteFrames)
        }
    }

    /// - Returns: `false` when the buffer couldn't be allocated, which stops the caller
    ///   rather than letting it spin on a chunk that will never be consumed.
    private func writeChunk(frames: Int) -> Bool {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData
        else {
            Log.meeting.error("audio write failed: couldn't allocate \(frames, privacy: .public) frames")
            return false
        }

        buffer.frameLength = AVAudioFrameCount(frames)
        micQueue.withUnsafeBufferPointer {
            channels[Self.micChannel].update(from: $0.baseAddress!, count: frames)
        }
        systemQueue.withUnsafeBufferPointer {
            channels[Self.systemChannel].update(from: $0.baseAddress!, count: frames)
        }
        micQueue.removeFirst(frames)
        systemQueue.removeFirst(frames)

        do {
            try file.write(from: buffer)
        } catch {
            Log.meeting.error("audio write failed: \(error.localizedDescription, privacy: .public)")
        }
        return true
    }
}

enum MeetingAudioWriterError: LocalizedError {
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat: "Couldn't create the meeting audio file format."
        }
    }
}

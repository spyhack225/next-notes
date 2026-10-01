import AVFoundation
import Foundation

/// Writes the two meeting tracks into one stereo file: left is you, right is everyone else.
///
/// Two channels rather than a mixdown for the same reason the transcribers are separate —
/// Phase 5 diarizes the right channel only, and a mixdown would throw away the one piece
/// of speaker information that costs nothing to keep.
///
/// The tracks arrive from two independent audio callbacks that neither start nor tick
/// together. The first buffer on each track is placed on the recording clock, then frames
/// are paired in order. In particular, a system tap that joins late must begin after
/// silence on its channel, not beside the last five seconds of microphone audio.
///
/// One of the two can also never arrive at all — a refused process tap leaves the meeting
/// running on the microphone alone — so the wait is bounded. Past `maxLeadFrames` the
/// writer stops pairing, fills the silent side in, and keeps writing; otherwise a
/// ninety-minute meeting would sit in memory and then ask for one buffer the size of it.
actor MeetingAudioWriter {
    /// Synchronous file boundary. Fixtures may reject an actual write without filling
    /// the volume; production always uses AVAudioFile's write.
    typealias Write = @Sendable (AVAudioFile, AVAudioPCMBuffer) throws -> Void

    struct ResourceSnapshot: Sendable {
        let queuedBytes: Int
        let queueCapacityBytes: Int
        let writtenFrames: Int
        let writeFailed: Bool
        let writeInFlight: Bool
        let writeStartedAt: Date?
        let missingSavedMicFrames: Int
        let missingSavedSystemFrames: Int
    }

    /// How far one track may run ahead before the other is written off as silent. Five
    /// seconds is far longer than the two callbacks ever drift, and still only 320 KB of
    /// queue. A late-starting tap is aligned by its recording-clock offset, not this bound.
    private static let maxLeadFrames = Int(5 * ChunkedTranscriber.sampleRate)
    /// Written in bounded pieces so a long backlog never needs one giant allocation.
    private static let maxWriteFrames = Int(30 * ChunkedTranscriber.sampleRate)

    /// Which channel of `audio.caf` each track occupies. Named because diarization reads
    /// the system channel back out by index, and "1" on its own at a call site is the kind
    /// of constant that quietly becomes wrong.
    static let micChannel = 0
    static let systemChannel = 1

    private var file: AVAudioFile?
    private let format: AVAudioFormat
    private let writeBuffer: Write

    private var micQueue: [Float] = []
    private var systemQueue: [Float] = []
    /// Number of stereo frames already written. Together with each queue length this
    /// gives that track's next absolute frame on the recording clock.
    private var writtenFrames = 0
    /// Once the first timed packet arrives, advance by actual sample counts. This
    /// also lets a packet that is wholly behind an already written cursor be trimmed
    /// across subsequent packets, rather than moving the second packet forward.
    private var micNextCaptureFrame: Int?
    private var systemNextCaptureFrame: Int?
    /// A frame trimmed behind the paired cursor never reached disk. Live ASR may
    /// still hold that original, so later successful writes cannot restore recovery
    /// authority for this track. Two bounded facts, not a per-packet history.
    private var missingSavedMicFrames = 0
    private var missingSavedSystemFrames = 0

    /// Called once, on the first write failure (M-10). The session surfaces the
    /// message; the writer stops trying after it.
    private let onWriteError: (@Sendable (String) -> Void)?
    /// The first write error's message, or nil while every chunk has landed.
    /// Once set, incoming samples are dropped rather than queued — a two-hour
    /// meeting must not grow memory behind a file that can no longer take bytes.
    private var writeError: String?
    private var writeInFlight = false
    private var writeStartedAt: Date?
    /// Native AVAudioFile.write is synchronous and can occupy this actor while
    /// storage stalls. Its health reader must not queue behind that same write.
    /// This is one bounded projection of the producer's existing counters; it
    /// owns no samples, history, timer or persistence.
    private nonisolated let progress = WriterProgress()

    /// A file that failed after being created cannot recover shed live ASR windows.
    var didFail: Bool { writeError != nil }

    /// Content-free retained audio and successful file progress. Sample off the
    /// callback path; capacity also reports empty arrays retaining their allocation.
    nonisolated func resourceSnapshot() -> ResourceSnapshot { progress.read() }

    private func publishSnapshot() {
        progress.publish(ResourceSnapshot(
            queuedBytes: (micQueue.count + systemQueue.count) * MemoryLayout<Float>.stride,
            queueCapacityBytes: (micQueue.capacity + systemQueue.capacity) * MemoryLayout<Float>.stride,
            writtenFrames: writtenFrames,
            writeFailed: writeError != nil,
            writeInFlight: writeInFlight,
            writeStartedAt: writeStartedAt,
            missingSavedMicFrames: missingSavedMicFrames,
            missingSavedSystemFrames: missingSavedSystemFrames
        ))
    }

    /// 16-bit on disk, float in memory: `AVAudioFile` converts on write, and int16 halves
    /// what an hour of meeting costs on a machine with ten gigabytes free.
    ///
    /// - Parameters:
    ///   - onWriteError: the one-shot callback for the first write failure. Set at
    ///     creation because the writer is an actor: its state cannot be mutated
    ///     from outside after construction.
    ///   - url: where the stereo file is written.
    init(
        url: URL,
        onWriteError: (@Sendable (String) -> Void)? = nil,
        write: @escaping Write = { file, buffer in try file.write(from: buffer) }
    ) throws {
        self.onWriteError = onWriteError
        self.writeBuffer = write
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

    /// `startFrame` locates the first captured buffer on the meeting clock. Later
    /// buffers advance from that origin by their sample counts, so callback scheduling
    /// jitter cannot repeatedly insert or remove frames. Existing fixture callers may
    /// omit it and start both tracks at frame zero.
    @discardableResult
    func append(
        _ samples: [Float], from source: AudioSource, startFrame: Int? = nil,
        requireWritten: Bool = false
    ) -> Bool {
        defer { publishSnapshot() }
        // The file failed once; nothing after that lands anywhere, and saying so
        // again would be noise. The transcript keeps running without the file.
        guard writeError == nil, file != nil else { return false }
        guard !samples.isEmpty else {
            guard requireWritten else { return true }
            return source == .mic
                ? missingSavedMicFrames == 0 && micQueue.isEmpty
                : missingSavedSystemFrames == 0 && systemQueue.isEmpty
        }
        let packetEnd: Int
        switch source {
        case .mic:
            let packetStart = micNextCaptureFrame ?? startFrame
            packetEnd = max(0, packetStart ?? (writtenFrames + micQueue.count)) + samples.count
            micNextCaptureFrame = packetStart.map { $0 + samples.count }
            let aligned = alignedSamples(samples, from: .mic, startFrame: packetStart)
            micQueue.append(contentsOf: aligned)
        case .system:
            let packetStart = systemNextCaptureFrame ?? startFrame
            packetEnd = max(0, packetStart ?? (writtenFrames + systemQueue.count)) + samples.count
            systemNextCaptureFrame = packetStart.map { $0 + samples.count }
            let aligned = alignedSamples(samples, from: .system, startFrame: packetStart)
            systemQueue.append(contentsOf: aligned)
        }
        guard writeError == nil else { return false }
        writePairedFrames()
        guard writeError == nil else { return false }
        guard requireWritten else { return true }
        let complete = source == .mic ? missingSavedMicFrames == 0 : missingSavedSystemFrames == 0
        return complete && writtenFrames >= packetEnd
    }

    /// Silence spans a late track's missing beginning. If the other track has already
    /// forced the file cursor past this buffer, trim the overlap instead of moving the
    /// remaining speech to a later time. The normal path allocates no padding.
    private func alignedSamples(
        _ samples: [Float], from source: AudioSource, startFrame: Int?
    ) -> [Float] {
        guard let startFrame else { return samples }
        let cursor = writtenFrames + (source == .mic ? micQueue.count : systemQueue.count)
        let target = max(0, startFrame)
        if target > cursor {
            // A tap can join minutes into a recording. Pad in bounded pieces and
            // flush the older ones as we go, rather than allocate minutes of zeroes.
            var gap = target - cursor
            while gap > 0, writeError == nil {
                let count = min(gap, Self.maxWriteFrames)
                switch source {
                case .mic: micQueue.append(contentsOf: repeatElement(0, count: count))
                case .system: systemQueue.append(contentsOf: repeatElement(0, count: count))
                }
                writePairedFrames()
                gap -= count
            }
            return writeError == nil ? samples : []
        }
        let overlap = cursor - target
        if overlap > 0 {
            // Count originals actually omitted, not the cursor's full lead: the
            // same delayed source can remain behind over several packets.
            let omitted = min(overlap, samples.count)
            switch source {
            case .mic:
                let sum = missingSavedMicFrames.addingReportingOverflow(omitted)
                missingSavedMicFrames = sum.overflow ? .max : sum.partialValue
            case .system:
                let sum = missingSavedSystemFrames.addingReportingOverflow(omitted)
                missingSavedSystemFrames = sum.overflow ? .max : sum.partialValue
            }
        }
        if overlap >= samples.count { return [] }
        return Array(samples.dropFirst(overlap))
    }

    /// Flushes the side that ran on longest, padding the other with silence.
    func finish() {
        defer {
            // AVAudioFile finalizes its converted tail on close. Accepted frame
            // counts alone were not proof that a fresh final-pass reader could
            // see those samples while this actor retained the still-open file.
            file = nil
            micQueue.removeAll(keepingCapacity: false)
            systemQueue.removeAll(keepingCapacity: false)
            publishSnapshot()
        }
        guard writeError == nil, file != nil else { return }
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

    /// - Returns: `false` when the buffer couldn't be allocated or the file refused
    ///   the write (M-10: the first refusal stops the caller), rather than letting
    ///   it spin on a chunk that will never be consumed.
    private func writeChunk(frames: Int) -> Bool {
        publishSnapshot()
        guard let file else { return false }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData
        else {
            recordWriteFailure("The recording could not be saved.")
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

        writeInFlight = true
        writeStartedAt = Date()
        publishSnapshot()
        defer {
            writeInFlight = false
            publishSnapshot()
        }
        do {
            try writeBuffer(file, buffer)
            writtenFrames += frames
        } catch {
            // The samples were consumed above; no later chunk may queue behind this.
            recordWriteFailure(error.localizedDescription)
            return false
        }
        return true
    }

    private func recordWriteFailure(_ message: String) {
        guard writeError == nil else { return }
        writeError = message
        writeInFlight = false
        file = nil
        // The first refusal permanently closes this writer. Retaining an unmatched
        // track's five-second lead (or a larger currently consumed packet) serves no
        // recovery purpose and keeps allocation alive during the very pressure that
        // stopped saving. Incoming audio is already rejected above.
        micQueue.removeAll(keepingCapacity: false)
        systemQueue.removeAll(keepingCapacity: false)
        publishSnapshot()
        Log.meeting.error("audio write failed; stopping the recording file: \(message, privacy: .public)")
        onWriteError?(message)
    }

    private final class WriterProgress: @unchecked Sendable {
        private let lock = NSLock()
        private var value = ResourceSnapshot(
            queuedBytes: 0, queueCapacityBytes: 0, writtenFrames: 0,
            writeFailed: false, writeInFlight: false, writeStartedAt: nil,
            missingSavedMicFrames: 0, missingSavedSystemFrames: 0)

        func read() -> ResourceSnapshot {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func publish(_ snapshot: ResourceSnapshot) {
            lock.lock()
            value = snapshot
            lock.unlock()
        }
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

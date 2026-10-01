// Standalone compiler fixture; compiled alongside MeetingAudioWriter.swift.
import AVFoundation
import Foundation
import OSLog

enum AudioSource { case mic, system }
enum ChunkedTranscriber { static let sampleRate: Double = 16_000 }
enum Log { static let meeting = Logger(subsystem: "meeting-resource-fixture", category: "writer") }

@main
struct WriterAllocationProbe {
    static func main() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("writer-allocation-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        if CommandLine.arguments.contains("--expect-close") {
            try await proveClose(in: dir)
            return
        }
        if CommandLine.arguments.contains("--expect-trimmed") {
            try await proveTrimmed(in: dir)
            return
        }
        let writer = try MeetingAudioWriter(url: dir.appendingPathComponent("rejected.caf"),
            write: { _, _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)) })
        let accepted = await writer.append([Float](repeating: 0.1, count: 96_000), from: .mic, startFrame: 0)
        let state = await writer.resourceSnapshot()
        print("FAILED_WRITER accepted=\(accepted) retained_logical_bytes=\(state.queuedBytes) retained_capacity_bytes=\(state.queueCapacityBytes) written_frames=\(state.writtenFrames) failed=\(state.writeFailed)")
        if CommandLine.arguments.contains("--expect-release") &&
            (state.queuedBytes != 0 || state.queueCapacityBytes != 0 || !state.writeFailed || accepted) {
            print("FAILED_WRITER_RELEASE_FAILED")
            exit(1)
        }
        print("FAILED_WRITER_RELEASE_OK")
    }

    private static func proveClose(in dir: URL) async throws {
        let gate = HeldWrite()
        let url = dir.appendingPathComponent("held.caf")
        let writer = try MeetingAudioWriter(url: url, write: { file, buffer in
            guard gate.holdFirst() else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT)) }
            try file.write(from: buffer)
        })
        let pending = Task.detached {
            await writer.append([Float](repeating: 0.1, count: 96_000), from: .mic, startFrame: 0)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !gate.entered && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        gate.release()
        let accepted = await pending.value
        await writer.finish()
        let state = writer.resourceSnapshot()
        let samples = try read(url, channel: 0)
        print("WRITER_CLOSE accepted=\(accepted) saved_frames=\(state.writtenFrames) reader_frames=\(samples.count)")
        guard accepted && state.writtenFrames == 96_000 && samples.count == 96_000
                && samples.allSatisfy({ abs($0 - 0.1) < 0.0001 }) else {
            print("WRITER_CLOSE_FAILED")
            exit(1)
        }
        print("WRITER_CLOSE_OK")
    }

    private static func proveTrimmed(in dir: URL) async throws {
        let url = dir.appendingPathComponent("trimmed.caf")
        let writer = try MeetingAudioWriter(url: url)
        let one = [Float](repeating: 0.1, count: 16_000)
        await writer.append(one, from: .mic, startFrame: 0)
        await writer.append(one, from: .system, startFrame: 0)
        await writer.append([Float](repeating: 0.1, count: 128_000), from: .mic)
        let whollyTrimmed = await writer.append(one, from: .system, requireWritten: true)
        let partiallyTrimmed = await writer.append([Float](repeating: 0.2, count: 112_000), from: .system, requireWritten: true)
        await writer.append(one, from: .mic)
        let later = await writer.append(one, from: .system, requireWritten: true)
        await writer.finish()
        let state = writer.resourceSnapshot()
        let mic = try read(url, channel: 0)
        let system = try read(url, channel: 1)
        print("WRITER_TRIM saved_frames=\(state.writtenFrames) reader_frames=\(system.count) missing_mic_frames=\(state.missingSavedMicFrames) missing_system_frames=\(state.missingSavedSystemFrames) wholly_trimmed_authorized=\(whollyTrimmed) partially_trimmed_authorized=\(partiallyTrimmed) later_authorized=\(later)")
        guard state.writtenFrames == 160_000 && mic.count == 160_000 && system.count == 160_000
                && state.missingSavedMicFrames == 0 && state.missingSavedSystemFrames == 48_000
                && !whollyTrimmed && !partiallyTrimmed && !later
                && mic.allSatisfy({ abs($0 - 0.1) < 0.0001 })
                && system[16_000..<64_000].allSatisfy({ $0 == 0 })
                && system[64_000..<144_000].allSatisfy({ abs($0 - 0.2) < 0.0001 })
                && system[144_000..<160_000].allSatisfy({ abs($0 - 0.1) < 0.0001 }) else {
            print("WRITER_TRIM_FAILED")
            exit(1)
        }
        print("WRITER_TRIM_OK")
    }

    private static func read(_ url: URL, channel: Int) throws -> [Float] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![channel], count: Int(buffer.frameLength)))
    }

    private final class HeldWrite: @unchecked Sendable {
        private let lock = NSLock()
        private let semaphore = DispatchSemaphore(value: 0)
        private var hasEntered = false
        var entered: Bool {
            lock.lock()
            defer { lock.unlock() }
            return hasEntered
        }
        func holdFirst() -> Bool {
            lock.lock()
            let hold = !hasEntered
            hasEntered = true
            lock.unlock()
            return !hold || semaphore.wait(timeout: .now() + 10) == .success
        }
        func release() { semaphore.signal() }
    }
}

import AVFoundation
import Foundation
import Synchronization

/// Bounded transfer from AVAudioSinkNode's hardware callback to the ordinary
/// AudioCaptureHub fan-out lane. Every slot owns its PCM storage and timestamp.
/// A busy ring drops a whole hardware buffer instead of delaying Core Audio.
final class AudioSinkCaptureRing: @unchecked Sendable {
    private struct Slot {
        let buffer: AVAudioPCMBuffer
        var hostTime: UInt64?
        var state: UInt8 = 0 // 0 free, 1 ready, 2 being delivered
    }

    private let lock = NSLock()
    /// stop() waits for a delivery already in progress before route rebuild.
    /// The hardware callback never touches this lock.
    private let deliveryLock = NSLock()
    private var slots: [Slot]
    private var writeIndex = 0
    private var readIndex = 0
    private var dropped = 0
    private let lockMisses = Atomic<Int>(0)
    private var active = true
    private let source: DispatchSourceUserDataAdd
    private let deliver: @Sendable (AVAudioPCMBuffer, UInt64?) -> Void
    private let overflow: @Sendable (Int) -> Void

    init?(format: AVAudioFormat, capacity: AVAudioFrameCount = 4_096,
          slotCount: Int = 32,
          deliver: @escaping @Sendable (AVAudioPCMBuffer, UInt64?) -> Void,
          overflow: @escaping @Sendable (Int) -> Void) {
        guard slotCount > 0 else { return nil }
        var storage: [Slot] = []
        storage.reserveCapacity(slotCount)
        for _ in 0..<slotCount {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
                return nil
            }
            storage.append(Slot(buffer: buffer))
        }
        slots = storage
        self.deliver = deliver
        self.overflow = overflow
        source = DispatchSource.makeUserDataAddSource(queue: DispatchQueue(
            label: "ai.pivotstudio.nextnotes.audio-sink-drain", qos: .userInitiated))
        source.setEventHandler { [weak self] in self?.drain() }
        source.resume()
    }

    /// Never waits for the drain lane. The only per-callback work is a bounded
    /// PCM copy into preallocated memory; no Swift Task or buffer allocation.
    func receive(_ timestamp: UnsafePointer<AudioTimeStamp>,
                 frames: AVAudioFrameCount,
                 input: UnsafePointer<AudioBufferList>) {
        guard lock.try() else {
            lockMisses.wrappingAdd(1, ordering: .relaxed)
            source.add(data: 1)
            return
        }
        guard active, frames > 0,
              frames <= slots[writeIndex].buffer.frameCapacity,
              slots[writeIndex].state == 0 else {
            dropped &+= 1
            lock.unlock()
            source.add(data: 1)
            return
        }
        let index = writeIndex
        slots[index].buffer.frameLength = frames
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: input))
        let targetBuffers = UnsafeMutableAudioBufferListPointer(
            slots[index].buffer.mutableAudioBufferList)
        guard sourceBuffers.count == targetBuffers.count else {
            dropped &+= 1
            lock.unlock()
            source.add(data: 1)
            return
        }
        for channel in 0..<sourceBuffers.count {
            guard let sourceData = sourceBuffers[channel].mData,
                  let targetData = targetBuffers[channel].mData,
                  sourceBuffers[channel].mDataByteSize <= targetBuffers[channel].mDataByteSize else {
                dropped &+= 1
                lock.unlock()
                source.add(data: 1)
                return
            }
            memcpy(targetData, sourceData, Int(sourceBuffers[channel].mDataByteSize))
        }
        let stamp = timestamp.pointee
        slots[index].hostTime = stamp.mFlags.contains(.hostTimeValid) ? stamp.mHostTime : nil
        slots[index].state = 1
        writeIndex = (index + 1) % slots.count
        lock.unlock()
        source.add(data: 1)
    }

    func stop() {
        deliveryLock.lock()
        lock.lock()
        active = false
        for index in slots.indices {
            slots[index].state = 0
            slots[index].hostTime = nil
        }
        lock.unlock()
        deliveryLock.unlock()
    }

    private func drain() {
        while true {
            lock.lock()
            let overflowCount = dropped + lockMisses.exchange(0, ordering: .relaxed)
            dropped = 0
            let index = readIndex
            guard slots[index].state == 1 else {
                lock.unlock()
                if overflowCount > 0 { overflow(overflowCount) }
                return
            }
            slots[index].state = 2
            let buffer = slots[index].buffer
            let hostTime = slots[index].hostTime
            lock.unlock()
            if overflowCount > 0 { overflow(overflowCount) }
            deliveryLock.lock()
            lock.lock()
            let shouldDeliver = active
            lock.unlock()
            if shouldDeliver { deliver(buffer, hostTime) }
            deliveryLock.unlock()
            lock.lock()
            slots[index].state = 0
            slots[index].hostTime = nil
            readIndex = (index + 1) % slots.count
            lock.unlock()
        }
    }

    /// Deterministic callback-boundary checks. The ordinary microphone probe
    /// covers the AVAudioEngine graph and converted subscriber delivery.
    static func selfTestFailures() -> [String] {
        var failures: [String] = []
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000, channels: 1, interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160) else {
            return ["sink ring fixture format unavailable"]
        }
        input.frameLength = 160
        input.floatChannelData?[0].initialize(repeating: 0.125, count: 160)
        let observation = SinkRingSelfTestObservation()
        guard let ring = AudioSinkCaptureRing(format: format, capacity: 160,
            slotCount: 2, deliver: { buffer, time in
                observation.delivered(buffer.frameLength, hostTime: time)
            }, overflow: { count in observation.overflow(count) }) else {
            return ["sink ring allocation failed"]
        }
        var stamp = AudioTimeStamp()
        stamp.mFlags = .hostTimeValid
        stamp.mHostTime = 123_456
        withUnsafePointer(to: &stamp) { time in
            ring.receive(time, frames: 160, input: input.audioBufferList)
        }
        Thread.sleep(forTimeInterval: 0.1)
        let first = observation.snapshot()
        if first.frames != [160] || first.hostTimes != [123_456] {
            failures.append("sink delivery lost frame/time: frames=\(first.frames), host=\(first.hostTimes), drops=\(first.overflows)")
        }
        // Force the callback's try-lock failure without racing queue timing.
        ring.lock.lock()
        withUnsafePointer(to: &stamp) { time in
            ring.receive(time, frames: 160, input: input.audioBufferList)
        }
        ring.lock.unlock()
        Thread.sleep(forTimeInterval: 0.1)
        if observation.snapshot().overflows < 1 {
            failures.append("sink try-lock drop was silent")
        }
        ring.stop()
        withUnsafePointer(to: &stamp) { time in
            ring.receive(time, frames: 160, input: input.audioBufferList)
        }
        Thread.sleep(forTimeInterval: 0.1)
        if observation.snapshot().frames != first.frames {
            failures.append("stopped sink delivered a stale hardware callback")
        }
        return failures
    }
}

private final class SinkRingSelfTestObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [AVAudioFrameCount] = []
    private var hostTimes: [UInt64?] = []
    private var overflows = 0

    func delivered(_ frames: AVAudioFrameCount, hostTime: UInt64?) {
        lock.lock()
        self.frames.append(frames)
        hostTimes.append(hostTime)
        lock.unlock()
    }

    func overflow(_ count: Int) {
        lock.lock()
        overflows += count
        lock.unlock()
    }

    func snapshot() -> (frames: [AVAudioFrameCount], hostTimes: [UInt64?], overflows: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (frames, hostTimes, overflows)
    }
}

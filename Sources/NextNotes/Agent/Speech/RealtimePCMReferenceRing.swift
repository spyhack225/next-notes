import Synchronization

/// Render callback → AEC worker SPSC FIFO. Each PCM sample carries the hardware
/// host clock of that *same* sample; the worker cannot detach timestamps from
/// audio even when source callbacks have variable frame lengths.
final class RealtimePCMReferenceRing: @unchecked Sendable {
    private struct Sample {
        var pcm: Float
        var hostTime: UInt64
    }
    let capacity: Int
    private let slots: UnsafeMutablePointer<Sample>
    private let written = Atomic<Int>(0)
    private let consumed = Atomic<Int>(0)

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        slots = .allocate(capacity: capacity)
        slots.initialize(repeating: Sample(pcm: 0, hostTime: 0), count: capacity)
    }

    deinit {
        slots.deinitialize(count: capacity)
        slots.deallocate()
    }

    var availableToRead: Int {
        written.load(ordering: .acquiring) - consumed.load(ordering: .acquiring)
    }

    func write(_ pcm: UnsafePointer<Float>, count: Int,
               firstHostTime: UInt64, ticksPerSample: Double) -> Int {
        let start = written.load(ordering: .relaxed)
        let tail = consumed.load(ordering: .acquiring)
        let accepted = min(count, max(0, capacity - (start - tail)))
        for i in 0..<accepted {
            slots[(start + i) % capacity] = Sample(pcm: pcm[i],
                hostTime: firstHostTime == 0 ? 0
                    : firstHostTime &+ UInt64(Double(i) * ticksPerSample))
        }
        written.store(start + accepted, ordering: .releasing)
        return accepted
    }

    func read(into destination: UnsafeMutablePointer<Float>, count: Int)
        -> (frames: Int, firstHostTime: UInt64) {
        let start = consumed.load(ordering: .relaxed)
        let end = written.load(ordering: .acquiring)
        let available = min(count, max(0, end - start))
        let first = available > 0 ? slots[start % capacity].hostTime : 0
        for i in 0..<available { destination[i] = slots[(start + i) % capacity].pcm }
        consumed.store(start + available, ordering: .releasing)
        return (available, first)
    }
}

import Synchronization

/// Fixed-memory single-producer/single-consumer Float32 FIFO. The audio render
/// callback only reads preallocated memory and atomic indices. Neither side
/// allocates, blocks, or calls a model while touching this ring.
final class RealtimePCMFloatRing: @unchecked Sendable {
    let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    private let written = Atomic<Int>(0)
    private let consumed = Atomic<Int>(0)

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }

    var availableToRead: Int {
        written.load(ordering: .acquiring) - consumed.load(ordering: .acquiring)
    }

    var availableToWrite: Int {
        capacity - availableToRead
    }

    /// Producer only. Returns the number accepted without overwriting unread PCM.
    func write(_ source: UnsafePointer<Float>, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let start = written.load(ordering: .relaxed)
        let tail = consumed.load(ordering: .acquiring)
        let accepted = min(count, max(0, capacity - (start - tail)))
        let first = min(accepted, capacity - start % capacity)
        if first > 0 { storage.advanced(by: start % capacity).update(from: source, count: first) }
        if accepted > first { storage.update(from: source.advanced(by: first), count: accepted - first) }
        written.store(start + accepted, ordering: .releasing)
        return accepted
    }

    /// Consumer only. Never waits for the producer and never returns invented audio.
    func read(into destination: UnsafeMutablePointer<Float>, maxCount: Int) -> Int {
        guard maxCount > 0 else { return 0 }
        let start = consumed.load(ordering: .relaxed)
        let end = written.load(ordering: .acquiring)
        let accepted = min(maxCount, max(0, end - start))
        let first = min(accepted, capacity - start % capacity)
        if first > 0 { destination.update(from: storage.advanced(by: start % capacity), count: first) }
        if accepted > first { destination.advanced(by: first).update(from: storage, count: accepted - first) }
        consumed.store(start + accepted, ordering: .releasing)
        return accepted
    }

    /// Consumer only. Use on a stopped-token render callback, never from the
    /// producer while a render callback may be reading.
    func discardUnreadFromConsumer() {
        consumed.store(written.load(ordering: .acquiring), ordering: .releasing)
    }
}

import Darwin
import Foundation
import os

/// The main actor's own account of how long it was unavailable, in nanoseconds.
///
/// Every one of the boundaries a voice turn waits on — the endpoint, the clause enqueue,
/// the frame schedule — is a hop through the main queue, so a stall there is a stall in the
/// whole turn. This probe measures it without Instruments: a timer on a user-interactive
/// queue posts an empty block to the main queue every 10 ms and records how late it landed.
///
/// It is deliberately **not** `Task { @MainActor }`. A task has to be scheduled, can be
/// batched behind cooperative work and reports its own priority, so a task-based ping
/// measures the runtime as much as the main actor. A plain `DispatchQueue.main.async`
/// block is a FIFO position, which is the thing being measured.
///
/// It runs only while a voice session is open. Outside one, a labelled section costs one
/// predictable branch and nothing else.
final class MainActorStallProbe: @unchecked Sendable {
    static let shared = MainActorStallProbe()

    /// A hop that lands within one 10 ms tick of a 16 ms frame is not a stall anybody felt.
    static let latenessFloor: UInt64 = 16_000_000

    private struct Lateness: Sendable {
        let atNanos: UInt64
        let latenessNanos: UInt64
        let site: String?
    }

    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var queue: DispatchQueue?
    private var sentAt: UInt64?
    private var samples: [Lateness] = []
    private var running = false
    /// The label of the main-actor section that was running when the ping went out. A
    /// `StaticString` is a pointer and a length, so this is a trivial store and a nil check
    /// is a nil check — no allocation on the measured path.
    private var currentSite: StaticString?

    /// True while the timer is live. `MainActorSection` reads it to decide whether
    /// labelling is worth anything at all.
    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    /// Arms a repeating 10 ms ping. Idempotent.
    func start(milliseconds interval: Int = 10) {
        lock.lock()
        if running {
            lock.unlock()
            return
        }
        let queue = DispatchQueue(label: "ai.pivotstudio.nextnotes.main-stall",
            qos: .userInteractive)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(),
            repeating: .milliseconds(max(1, interval)))
        timer.setEventHandler { [weak self] in self?.ping() }
        self.queue = queue
        self.timer = timer
        running = true
        lock.unlock()
        timer.resume()
    }

    func stop() {
        lock.lock()
        let timer = self.timer
        let queue = self.queue
        self.timer = nil
        self.queue = nil
        running = false
        currentSite = nil
        sentAt = nil
        lock.unlock()
        timer?.cancel()
        queue?.async {}
    }

    /// One probe. Only one is ever outstanding: a second ping would measure the queue, not
    /// the main actor.
    private func ping() {
        lock.lock()
        guard sentAt == nil else {
            lock.unlock()
            return
        }
        let sent = VoiceLatencyTimeline.nowNanos()
        let site = currentSite
        sentAt = sent
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let landed = VoiceLatencyTimeline.nowNanos()
            self.lock.lock()
            self.sentAt = nil
            let lateness = landed &- sent
            guard lateness > Self.latenessFloor else {
                self.lock.unlock()
                return
            }
            if self.samples.count >= 64 { self.samples.removeFirst() }
            self.samples.append(Lateness(atNanos: landed, latenessNanos: lateness,
                site: site.map { "\($0)" }))
            self.lock.unlock()
            VoiceLatencyTimeline.shared.noteStall(
                nanos: lateness, site: site.map { "\($0)" })
        }
    }

    /// The worst lateness seen since `nanos`, and the site that was running when the worst
    /// ping was sent. Nil means nothing landed late in that window.
    func maxLatenessSeconds(since nanos: UInt64) -> (seconds: Double, site: String?, atNanos: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        var worst: Lateness?
        for sample in samples where sample.atNanos >= nanos {
            if worst == nil || sample.latenessNanos > worst!.latenessNanos { worst = sample }
        }
        guard let worst else { return (0, nil, 0) }
        return (Double(worst.latenessNanos) / 1_000_000_000, worst.site, worst.atNanos)
    }

    // MARK: - Labelling

    func enter(site: StaticString) {
        lock.lock()
        currentSite = site
        lock.unlock()
    }

    func leave() {
        lock.lock()
        currentSite = nil
        lock.unlock()
    }

    func clearSamples() {
        lock.lock()
        samples.removeAll()
        lock.unlock()
    }
}

/// Labels main-actor work so a stall can be attributed without Instruments, and gives
/// Instruments the same labels through `os_signpost`.
///
/// One wrapper, no behaviour change. Outside a voice session the whole thing is one
/// predictable branch on a locked flag — which is the price of measuring, and the reason
/// the flag exists at all.
enum MainActorSection {
    private static let signposter = OSSignposter(
        subsystem: "ai.pivotstudio.nextnotes", category: "voice")

    @inline(__always)
    @MainActor
    static func run<T>(_ site: StaticString, _ body: () throws -> T) rethrows -> T {
        guard MainActorStallProbe.shared.isRunning else { return try body() }
        MainActorStallProbe.shared.enter(site: site)
        let signpost = signposter.beginInterval(site)
        defer {
            signposter.endInterval(site, signpost)
            MainActorStallProbe.shared.leave()
        }
        return try body()
    }
}

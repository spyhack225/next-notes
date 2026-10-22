import Foundation
import Dispatch

/// Samples host load for `CleanupRouter` without private GPU / ANE APIs.
///
/// Sources:
/// - `DispatchSource` memory-pressure warning / critical (sticky until `.normal`)
/// - `ProcessInfo.thermalState` (serious / critical)
/// - `ProcessInfo.isLowPowerModeEnabled`
/// - `ComputeScheduler.shared` occupancy — `.realtimeASR` (live ASR) and
///   `.background` (notes load / generation, and other background work)
///
/// Optional overlays still OR into the live bits so a self-test can force
/// pressure without driving the shared scheduler.
enum CleanupPressureProbe {
    /// Live host signals, plus any occupancy overlays the caller already knows.
    ///
    /// Reads `ComputeScheduler.shared.occupancy()` for ASR / notes busy. That
    /// snapshot is approximate and race-tolerant — fine for routing, not a lock.
    ///
    /// A hold's own pre-clean never appears here: MiniCPM cleanup takes the lane with
    /// `tryAcquire(.realtimeAgent)` or not at all, so it is never a queued `.background`
    /// job (it used to be, behind the hold's own ASR, and read as `notesBusy` — the hold
    /// deferring its own tail to rules). Apple pre-cleans are not on the scheduler.
    static func sample(
        realtimeASRBusy: Bool = false,
        notesBusy: Bool = false,
        scheduler: ComputeScheduler = .shared
    ) async -> CleanupComputePressure {
        MemoryPressureFlag.shared.startIfNeeded()
        let info = ProcessInfo.processInfo
        let thermal = info.thermalState
        let occupancy = await scheduler.occupancy()
        return CleanupComputePressure(
            memoryWarning: MemoryPressureFlag.shared.isElevated,
            thermalElevated: thermal == .serious || thermal == .critical,
            lowPower: info.isLowPowerModeEnabled,
            realtimeASRBusy: realtimeASRBusy || occupancy.realtimeASRBusy,
            notesBusy: notesBusy || occupancy.notesBusy
        )
    }
}

/// Process-wide sticky memory-pressure bit for cleanup routing.
///
/// Distinct from `ModelResidencyGuardian`: that one unloads weights; this one
/// only answers "is the kernel still telling us memory is tight?" so Stage B
/// can stay off the GPU while the machine recovers. Warning and critical set
/// the flag; normal clears it.
final class MemoryPressureFlag: @unchecked Sendable {
    static let shared = MemoryPressureFlag()

    private let lock = NSLock()
    private var source: DispatchSourceMemoryPressure?
    private var started = false
    private var elevated = false

    var isElevated: Bool {
        lock.lock()
        defer { lock.unlock() }
        return elevated
    }

    func startIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        started = true

        let src = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical, .normal],
            queue: DispatchQueue.global(qos: .utility)
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let data = src.data
            self.lock.lock()
            if data.contains(.warning) || data.contains(.critical) {
                self.elevated = true
            } else if data.contains(.normal) {
                self.elevated = false
            }
            self.lock.unlock()
        }
        src.resume()
        source = src
    }

    /// Self-test only. Does not talk to the kernel.
    func setElevatedForTesting(_ value: Bool) {
        lock.lock()
        elevated = value
        lock.unlock()
    }
}

/// Whether a model file's pages are in memory — not whether a runtime holds a pointer to them.
///
/// The local model is opened with `LLAMA_LOAD_MODE_MMAP` on purpose, so under pressure the
/// kernel drops its clean, file-backed weight pages instead of killing the app. The cost is
/// that "loaded" stops meaning "in memory": on 2026-10-08 the owner's running app held
/// MiniCPM5-2B loaded with a process RSS of 72 MB and 0 of 95,296 file pages resident, and
/// 14 of the 15 pressure releases in `metrics.jsonl` recorded `rssBefore` of 60–125 MB for a
/// 1.56 GB model. A pass on such weights faults them back in from the SSD a page at a time
/// under the GPU — a fully cached 20-token prompt took 4.0 s instead of 0.3 s, and a 5-word
/// hold ran out its 8 s budget.
///
/// `mincore` on a fresh read-only mapping reports the shared page cache for the file (checked:
/// 0 → 1.0 after a `cat`, and back to 0 within two minutes under the owner's pressure).
/// Sampling keeps it off the clock: 512 single-page calls measured 0.49 ms on the 1.56 GB file,
/// against 34 ms for every page.
enum WeightPageResidency {
    static let defaultSamples = 512

    /// Fraction of sampled pages resident, 0...1, or nil when the file cannot be mapped.
    static func fraction(of file: URL, samples: Int = defaultSamples) -> Double? {
        let descriptor = open(file.path, O_RDONLY)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_size > 0 else { return nil }
        let length = Int(info.st_size)
        guard let base = mmap(nil, length, PROT_READ, MAP_SHARED, descriptor, 0),
              base != UnsafeMutableRawPointer(bitPattern: -1) else { return nil }
        defer { munmap(base, length) }
        let page = Int(getpagesize())
        let pages = (length + page - 1) / page
        let count = max(1, min(samples, pages))
        var resident = 0
        var vector: CChar = 0
        for index in 0..<count {
            let offset = (index * pages / count) * page
            if mincore(base.advanced(by: offset), page, &vector) == 0,
               Int32(vector) & MINCORE_INCORE != 0 {
                resident += 1
            }
        }
        return Double(resident) / Double(count)
    }

    private static let reading = LockedBox(false)

    /// Reads the file once, sequentially, into the page cache — off every clock, coalesced,
    /// and only while the kernel reports no memory pressure (bringing 1.5 GB back during a
    /// pressure episode is how the next eviction starts). A sequential read is what a GPU
    /// fault storm is not: one pass at SSD speed instead of thousands of 16 KB faults inside
    /// a dictation's budget. Returns whether a read was started.
    @discardableResult
    static func pageInInBackground(_ file: URL) -> Bool {
        guard !SelfTest.isRunning,
              ModelResidencyGuardian.shared.snapshot.level == .normal,
              !MemoryPressureFlag.shared.isElevated else { return false }
        guard !reading.value else { return false }
        reading.value = true
        DispatchQueue.global(qos: .utility).async {
            defer { reading.value = false }
            let began = Date()
            let descriptor = open(file.path, O_RDONLY)
            guard descriptor >= 0 else { return }
            defer { close(descriptor) }
            let chunk = 4 << 20
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 16)
            defer { buffer.deallocate() }
            var total = 0
            while true {
                // Pressure arriving mid-read stops it; what was read stays cached.
                if MemoryPressureFlag.shared.isElevated { break }
                let got = read(descriptor, buffer, chunk)
                if got <= 0 { break }
                total += got
            }
            Log.llm.info(
                "cleanup model weights paged in: \(total / (1 << 20)) MB in \(Date().timeIntervalSince(began), format: .fixed(precision: 2))s"
            )
        }
        return true
    }
}

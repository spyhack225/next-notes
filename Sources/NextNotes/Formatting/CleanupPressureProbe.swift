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
    static func sample(
        realtimeASRBusy: Bool = false,
        notesBusy: Bool = false
    ) async -> CleanupComputePressure {
        MemoryPressureFlag.shared.startIfNeeded()
        let info = ProcessInfo.processInfo
        let thermal = info.thermalState
        let occupancy = await ComputeScheduler.shared.occupancy()
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

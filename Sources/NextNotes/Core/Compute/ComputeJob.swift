import Foundation

/// Which lane a unit of work belongs to. The names and the four-rung priority
/// they imply are the ones in the v3 roadmap (§3, §5), not a measurement of
/// this machine.
///
/// Work that the product talks about by another name maps onto these cases
/// rather than growing a tenth class:
///
/// - wake-word spotting, VAD, microphone and system-audio callbacks → `realtimeAudio`
/// - dictation / meeting / agent ASR (Parakeet or Apple) → `realtimeASR`
/// - S1 / Foundation dictation cleanup → `realtimeAgent` when it is the
///   user-facing tail, `background` when it is an expensive second pass
/// - Local model meeting notes → `background`
/// - diarization → `background`
/// - immediate agent tools (inspect, route, a short read) → `realtimeAgent`
/// - delegated / long agent tools (coding, large search) → `background`
///
/// Priority 4 (`background`) must yield to Priorities 0–3. The in-memory
/// scheduler records that yield; it does not load a model to prove it.
enum WorkClass: String, Sendable, CaseIterable, Equatable {
    /// Priority 0 — audio continuity. Capture, VAD, wake. Reserved CPU.
    case realtimeAudio
    /// Priority 1 — user-facing ASR. Prefer the Neural Engine; do not assume it is faster.
    case realtimeASR
    /// Priority 2 — interactive agent: intent, immediate tools, TTS start.
    case realtimeAgent
    /// Priority 3 — live meeting intelligence. Opportunistic accelerator.
    case meetingLive
    /// Priority 4 — notes, diarization, coding agents, large searches. Throttled GPU.
    case background

    /// Lower is more urgent. Matches the roadmap's "Priority 0 … 4" numbering.
    var priority: Int {
        switch self {
        case .realtimeAudio: 0
        case .realtimeASR: 1
        case .realtimeAgent: 2
        case .meetingLive: 3
        case .background: 4
        }
    }

    /// Whether a newly queued job of this class should displace `other`.
    func preempts(_ other: WorkClass) -> Bool {
        priority < other.priority
    }

    /// Policy intent only. Not a benchmark, and not read by any production runtime.
    ///
    /// - `realtimeAudio` stays on CPU so capture threads are never competing
    ///   for ANE or Metal.
    /// - `realtimeASR` prefers the Neural Engine because that is where
    ///   Parakeet already asks Core ML to run (`.cpuAndNeuralEngine`). ANE
    ///   is not assumed to be faster than CPU — FluidAudio's first compile
    ///   can stall, and CPU remains the fallback when ANE refuses.
    /// - `realtimeAgent` prefers GPU / Apple Foundation Models.
    /// - `meetingLive` takes whatever accelerator is free.
    /// - `background` prefers GPU but is the class that must throttle and
    ///   yield. Notes generation on the local model is the example the scheduler exists
    ///   to stop: loading 2.7 GB of weights must not make dictation ASR lag.
    var preferredDevice: ComputeDevice {
        switch self {
        case .realtimeAudio: .cpu
        case .realtimeASR: .neuralEngine
        case .realtimeAgent: .gpu
        case .meetingLive: .neuralEngine
        case .background: .gpu
        }
    }
}

/// Where a job would *like* to run. Hint only — the scheduler does not bind
/// a real model to a device. Notes take `.background` via
/// `ComputeScheduler.acquire`; the cleanup gate stays one-directional
/// (`awaitCleanupIdle` only — never `beginCleanup` from notes).
enum ComputeDevice: String, Sendable, CaseIterable, Equatable {
    case cpu
    case gpu
    case neuralEngine
}

/// One unit of scheduled work. Value type for the in-memory queue; later
/// slices can adopt the same shape without this type knowing about llama.cpp
/// or Core ML.
///
/// Do not close the `LlamaBackend` cleanup cycle through a job: notes wait
/// for cleanup (`awaitCleanupIdle`), cleanup must never wait for notes.
struct ComputeJob: Sendable, Equatable, Identifiable {
    let id: UUID
    let workClass: WorkClass
    let preferredDevice: ComputeDevice

    init(
        id: UUID = UUID(),
        workClass: WorkClass,
        preferredDevice: ComputeDevice? = nil
    ) {
        self.id = id
        self.workClass = workClass
        self.preferredDevice = preferredDevice ?? workClass.preferredDevice
    }
}

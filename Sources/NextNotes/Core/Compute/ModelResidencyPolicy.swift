import Foundation
import Dispatch

/// Which large models this process may keep resident, and what to drop first
/// when the kernel says memory is tight.
///
/// ## Enforced (this slice)
///
/// - **Unload order under pressure** is a pure function: notes, then
///   diarization. Wake/KWS and Parakeet ASR are never in that list while
///   sessions still need them (`alwaysWarm`).
/// - **Background compute yields to `realtimeASR`** via `ComputeScheduler`
///   (`acquire` / `checkpoint` / `release`). `NotesModelRuntime` takes that
///   path around load and generation.
/// - **Idle notes unload** stays at ten minutes (`NotesModelRuntime.idleUnload`).
/// - **Cleanup gate stays one-directional.** Notes still call
///   `LlamaBackend.awaitCleanupIdle()` before loading. Nothing here calls
///   `beginCleanup()`. Closing that cycle deadlocks Qwen cleanup
///   (`QwenCleanupFormatter`).
///
/// ## Wired, soft
///
/// - A `DispatchSource` memory-pressure observer calls `shutdown()` on the
///   notes runtime and `unload()` on the diarizer, in that order. It does
///   not unload Parakeet or the wake spotter.
///
/// ## Aspirational (not claimed, not enforced)
///
/// - Preferring ANE vs GPU for a given `WorkClass` (see `preferredDevice`).
/// - Unloading Parakeet under extreme pressure once no dictation / meeting
///   ASR session needs it.
/// - Measuring freed bytes after an unload.
///
/// Windows is out of scope.
enum ModelResidencyPolicy: Sendable {

    /// Models the product treats as always-warm while the feature is on.
    /// Pressure unload must not touch these when sessions still need them.
    enum ResidentModel: String, Sendable, CaseIterable, Equatable {
        /// Qwen / notes GGUF behind `NotesModelRuntime`.
        case notes
        /// FluidAudio offline diarizer behind `MeetingDiarizer`.
        case diarization
        /// Parakeet ASR behind `ParakeetModels`.
        case asr
        /// Sherpa zipformer KWS / wake-word spotter.
        case wake
    }

    /// Kept warm by policy. Unloading them mid-session would reintroduce the
    /// cold-start tax the warm path exists to remove.
    static let alwaysWarm: Set<ResidentModel> = [.wake, .asr]

    /// First unloaded first. ASR and wake are omitted on purpose — see
    /// `unloadOrder(resident:wakeNeeded:asrNeeded:)`.
    static let pressureUnloadPriority: [ResidentModel] = [.notes, .diarization]

    /// Pure unload plan for a pressure event.
    ///
    /// - Notes before diarization before anything else.
    /// - Wake stays if `wakeNeeded`; ASR stays if `asrNeeded`.
    /// - Members of `alwaysWarm` that are still needed never appear.
    static func unloadOrder(
        resident: Set<ResidentModel>,
        wakeNeeded: Bool = true,
        asrNeeded: Bool = true
    ) -> [ResidentModel] {
        var protected = Set<ResidentModel>()
        if wakeNeeded { protected.insert(.wake) }
        if asrNeeded { protected.insert(.asr) }

        return pressureUnloadPriority.filter { resident.contains($0) && !protected.contains($0) }
    }

    /// Applies `unload` once per model in `unloadOrder`. Used by the live
    /// guardian and by the self-test with a mock.
    static func applyPressure(
        resident: Set<ResidentModel>,
        wakeNeeded: Bool = true,
        asrNeeded: Bool = true,
        unload: (ResidentModel) -> Void
    ) {
        for model in unloadOrder(resident: resident, wakeNeeded: wakeNeeded, asrNeeded: asrNeeded) {
            unload(model)
        }
    }

    /// Starts the process-wide memory-pressure observer once. Safe to call
    /// from a notes load; does not touch `LlamaBackend`'s cleanup gate.
    static func installPressureObserver() {
        ModelResidencyGuardian.shared.startIfNeeded()
    }
}

// MARK: - Live pressure → real unloads

/// Owns the `DispatchSource` memory-pressure handle. A class rather than an
/// actor so the source's event handler can hop into a `Task` without nesting
/// actor re-entrancy around Dispatch.
final class ModelResidencyGuardian: @unchecked Sendable {
    static let shared = ModelResidencyGuardian()

    private let lock = NSLock()
    private var source: DispatchSourceMemoryPressure?
    private var started = false

    /// Idempotent. Warning and critical both run the same unload plan;
    /// normal is ignored (the kernel already recovered).
    func startIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        started = true

        let src = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: DispatchQueue.global(qos: .utility)
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let data = src.data
            guard data.contains(.warning) || data.contains(.critical) else { return }
            Task { await self.applyLivePressure() }
        }
        src.resume()
        source = src
        Log.llm.info("residency: memory-pressure observer installed")
    }

    /// Live path: notes, then diarization. Never wake, never Parakeet.
    ///
    /// Wake and ASR stay warm by policy (`ModelResidencyPolicy.alwaysWarm`).
    /// Whether a session "needs" them is not queried here — under pressure we
    /// still refuse to unload them; cold-starting KWS mid-meeting is worse
    /// than keeping ~tens of MB.
    func applyLivePressure() async {
        let plan = ModelResidencyPolicy.unloadOrder(
            resident: [.notes, .diarization, .asr, .wake],
            wakeNeeded: true,
            asrNeeded: true
        )
        for model in plan {
            switch model {
            case .notes:
                await NotesModelRuntime.shared.shutdown()
                // `shutdown()` records the unload with the runtime generation it
                // actually released. Do not follow it with an unguarded registry
                // write: a replacement load may begin while the actor is suspended,
                // and a nil-generation mark would incorrectly turn that newer
                // `.loading`/`.ready` entry back into `.unloaded`.
                Log.llm.info("residency: unloaded notes under memory pressure")
            case .diarization:
                await MeetingDiarizer.shared.unload()
                _ = await ModelRuntimeManager.shared.markUnloaded(.diarization)
                Log.meeting.info("residency: unloaded diarizer under memory pressure")
            case .asr, .wake:
                // Unreachable while wakeNeeded/asrNeeded stay true; kept for exhaustiveness.
                break
            }
        }
    }
}

// MARK: - Self-test

extension ModelResidencyPolicy {
    /// Isolated residency + scheduler probe. Not wired to a `--selftest-…`
    /// flag (leave that for the harness). Never calls `RunLog.record`.
    ///
    /// Fails unless:
    /// 1. A background job yields when `realtimeASR` is queued.
    /// 2. Pressure unload order is notes → diarization, and never wake/ASR
    ///    while those sessions are marked needed.
    @discardableResult
    static func runSelfTest() async -> Bool {
        var failures: [String] = []

        // Model lifecycle is part of residency correctness: a late Parakeet
        // load must not resurrect a runtime that a newer recovery replaced.
        if !(await ModelRuntimeManager.runSelfTest()) {
            failures.append("model runtime lifecycle probe failed")
        }

        // 1. Scheduler yield (same contract as ComputeScheduler.runSelfTest).
        let scheduler = ComputeScheduler()
        await scheduler.submit(ComputeJob(workClass: .background))
        await scheduler.submit(ComputeJob(workClass: .realtimeASR))
        if !(await scheduler.didYield(.background, to: .realtimeASR)) {
            failures.append("background job did not yield when realtimeASR was queued")
        }

        // Cooperative acquire: ASR running must make a background acquire wait
        // until release — exercised without loading a model.
        let coop = ComputeScheduler()
        let asrID = await coop.acquire(.realtimeASR)
        let gate = ResidencyTestGate()
        let background = Task {
            let bgID = await coop.acquire(.background)
            await gate.markStarted()
            await coop.release(bgID)
        }
        try? await Task.sleep(for: .milliseconds(40))
        if await gate.hasStarted {
            failures.append("background acquire started while realtimeASR still held the lane")
        }
        await coop.release(asrID)
        _ = await background.result
        if !(await gate.hasStarted) {
            failures.append("background acquire never resumed after realtimeASR released")
        }

        // 2. Pressure unload order (mock — no real model free).
        let order = unloadOrder(
            resident: [.notes, .diarization, .asr, .wake],
            wakeNeeded: true,
            asrNeeded: true
        )
        if order != [.notes, .diarization] {
            failures.append("pressure unload order was \(order.map(\.rawValue)), want notes → diarization")
        }

        var unloaded: [ResidentModel] = []
        applyPressure(
            resident: [.notes, .diarization, .asr, .wake],
            wakeNeeded: true,
            asrNeeded: true,
            unload: { unloaded.append($0) }
        )
        if unloaded != [.notes, .diarization] {
            failures.append("applyPressure unloaded \(unloaded.map(\.rawValue)), want notes → diarization")
        }
        if unloaded.contains(.wake) || unloaded.contains(.asr) {
            failures.append("pressure unload touched always-warm wake/ASR")
        }

        // Control: with ASR not needed, it may be planned after notes/diarization
        // only if we ever add it to pressureUnloadPriority — today it must stay out.
        let withoutASR = unloadOrder(
            resident: [.notes, .diarization, .asr],
            wakeNeeded: true,
            asrNeeded: false
        )
        if withoutASR.contains(.asr) {
            failures.append("ASR appeared in unload plan without being in pressureUnloadPriority")
        }

        for failure in failures {
            print("RESIDENCY_WRONG: \(failure)")
        }
        print(failures.isEmpty ? "RESIDENCY_OK" : "RESIDENCY_FAILED")
        return failures.isEmpty
    }
}

/// Tiny async flag for the cooperative half of `runSelfTest`.
private actor ResidencyTestGate {
    private(set) var hasStarted = false
    func markStarted() { hasStarted = true }
}

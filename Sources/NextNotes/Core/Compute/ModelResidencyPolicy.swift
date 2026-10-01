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
///   `beginCleanup()`. Closing that cycle deadlocks the local model cleanup
///   (`AppLLMCleanupFormatter`).
///
/// ## Wired, soft
///
/// - A `DispatchSource` pressure observer maintains synchronous admission state,
///   releases idle notes allocations and drops the diarizer owner's references.
///   Native work, queued requests and voice leases defer notes release.
/// - Speculative loads recheck admission after waits and before native allocation.
///
/// ## Aspirational (not claimed, not enforced)
///
/// - Preferring ANE vs GPU for a given `WorkClass` (see `preferredDevice`).
/// - Unloading Parakeet under extreme pressure once no dictation / meeting
///   ASR session needs it.
/// - Attributing freed native/Metal bytes after an unload (two RSS observations
///   and synchronous pointer teardown are narrower evidence).
///
/// Windows is out of scope.
enum ModelResidencyPolicy: Sendable {

    enum PressureLevel: String, Sendable { case normal, warning, critical }

    struct PressureSnapshot: Sendable, Equatable {
        let level: PressureLevel
        let generation: UInt64
        let changedAt: Date
        var allowsOptionalWork: Bool { level == .normal }
    }

    /// A cheap observation, never a gate on an interactive turn or audio callback.
    static var pressureSnapshot: PressureSnapshot { ModelResidencyGuardian.shared.snapshot }

    /// Models the product treats as always-warm while the feature is on.
    /// Pressure unload must not touch these when sessions still need them.
    enum ResidentModel: String, Sendable, CaseIterable, Equatable {
        /// Local model GGUF behind `NotesModelRuntime`.
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
    private var pressure = ModelResidencyPolicy.PressureSnapshot(
        level: .normal, generation: 0, changedAt: Date())
    private var releaseInFlight = false
    private let releaseForTesting: (@Sendable () async -> Void)?

    init(releaseForTesting: (@Sendable () async -> Void)? = nil) {
        self.releaseForTesting = releaseForTesting
    }

    var snapshot: ModelResidencyPolicy.PressureSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return pressure
    }

    /// Install before optional loads, not only after the first model is opened.
    /// Normal events reopen admission; no timer guesses that pressure has ended.
    func startIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        started = true

        let src = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: DispatchQueue.global(qos: .utility)
        )
        src.setEventHandler { [weak self] in
            guard let self else { return }
            let data = src.data
            let level: ModelResidencyPolicy.PressureLevel = data.contains(.critical)
                ? .critical : data.contains(.warning) ? .warning : .normal
            self.receive(level)
        }
        src.resume()
        source = src
        Log.llm.info("residency: memory-pressure observer installed")
    }

    /// The source and isolated fixtures use the same transition/admission producer.
    /// Update synchronously before the unload task gets a chance to suspend.
    func receive(_ level: ModelResidencyPolicy.PressureLevel) {
        let shouldRelease = updatePressure(level)
        guard shouldRelease else { return }
        Task {
            if let releaseForTesting { await releaseForTesting() }
            else { await applyLivePressure() }
            finishRelease()
        }
    }

    private func updatePressure(_ level: ModelResidencyPolicy.PressureLevel) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if pressure.level != level {
            pressure = .init(level: level, generation: pressure.generation &+ 1, changedAt: Date())
            Log.llm.info("residency: pressure=\(level.rawValue, privacy: .public)")
        }
        guard level != .normal, !releaseInFlight else { return false }
        releaseInFlight = true
        return true
    }

    private func finishRelease() {
        lock.lock()
        releaseInFlight = false
        lock.unlock()
    }

    /// Live path: notes, then diarization. Never wake, never Parakeet.
    ///
    /// Wake and ASR stay warm by policy (`ModelResidencyPolicy.alwaysWarm`).
    /// Whether a session "needs" them is not queried here — under pressure we
    /// still refuse to unload them; cold-starting KWS mid-meeting is worse
    /// than keeping ~tens of MB.
    func applyLivePressure() async {
        guard !snapshot.allowsOptionalWork else { return }
        let pressureObservedAt = snapshot.changedAt
        // The embedders are a batch backfill's, never a live path's: they go first.
        await EmbeddingRuntime.shared.stopNow()
        StaticEmbedder.shared.unload()
        let plan = ModelResidencyPolicy.unloadOrder(
            resident: [.notes, .diarization, .asr, .wake],
            wakeNeeded: true,
            asrNeeded: true
        )
        for model in plan {
            guard !snapshot.allowsOptionalWork else { return }
            switch model {
            case .notes:
                // P1-28: the reason, on the unload row. Memory pressure was the one cause
                // with no trace at all before, and it is the one whose cost is arguable —
                // §12 keeps the order notes → diarization, never wake/ASR, and a plan nobody
                // can check is a plan nobody can keep.
                // `noteUnload` is actor-isolated with the rest of the runtime, so it is awaited
                // rather than called: an unawaited call is a compile error here, which is the
                // right outcome for a fire-and-forget write to the latency log.
                let outcome = await NotesModelRuntime.shared.releaseUnderPressure()
                // `shutdown()` records the unload with the runtime generation it
                // actually released. Do not follow it with an unguarded registry
                // write: a replacement load may begin while the actor is suspended,
                // and a nil-generation mark would incorrectly turn that newer
                // `.loading`/`.ready` entry back into `.unloaded`.
                let actionMilliseconds = Int(Date().timeIntervalSince(pressureObservedAt) * 1_000)
                Log.llm.info("residency: notes pressure release=\(outcome.rawValue, privacy: .public) action_ms=\(actionMilliseconds)")
            case .diarization:
                await MeetingDiarizer.shared.unload()
                _ = await ModelRuntimeManager.shared.markUnloaded(.diarization)
                // An active pass can retain its own CoreML references. Dropping this
                // owner's references does not prove native allocations were reclaimed.
                Log.meeting.info("residency: diarizer owner release requested under memory pressure")
            case .asr, .wake:
                // Unreachable while wakeNeeded/asrNeeded stay true; kept for exhaustiveness.
                break
            }
        }
        // UI scheduling can be delayed under load. It must not postpone releasing
        // the native model owners above just to purge this derived search cache.
        await MainActor.run { KnowledgeIndexer.shared.vectorIndex.purge() }
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
        if !(await NotesModelRuntime.shutdownDeferralSelfTest()) {
            failures.append("notes shutdown was not deferred across an active background operation")
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

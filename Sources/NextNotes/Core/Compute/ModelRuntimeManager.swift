import Foundation

/// Runtime lifecycle for models that participate in a realtime path.
///
/// The model implementations own their actual weights. This actor owns the small,
/// shared piece of state that callers need to coordinate prewarming, cancellation,
/// recovery and residency decisions. A generation token prevents a late load or
/// failure from overwriting the state of a newer attempt after an actor suspension.
enum ManagedModel: String, CaseIterable, Sendable, Codable {
    case parakeetASR = "parakeet-asr"
    case appleSpeech = "apple-speech"
    case wakeKWS = "wake-kws"
    case tts
    case notes
    case diarization
}

enum ModelRuntimeState: String, Sendable, Codable, Equatable {
    case unloaded
    case loading
    case warming
    case ready
    case busy
    case wedged
    case recovering
}

struct ModelRuntimeSnapshot: Sendable, Codable, Equatable {
    let model: ManagedModel
    let state: ModelRuntimeState
    let generation: UInt64
    let changedAt: Date
    let lastError: String?
}

/// Process-wide lifecycle registry for local model runtimes.
///
/// It is deliberately independent from `NotesModelRuntime`, `ParakeetModels`, and
/// the wake-word C bridge: those owners can continue to use their native APIs while
/// this actor prevents stale lifecycle writes and makes recovery observable.
actor ModelRuntimeManager {
    static let shared = ModelRuntimeManager()

    private struct Entry: Sendable {
        var state: ModelRuntimeState = .unloaded
        var generation: UInt64 = 0
        var changedAt = Date()
        var lastError: String?
    }

    private var entries = Dictionary(
        uniqueKeysWithValues: ManagedModel.allCases.map { ($0, Entry()) }
    )

    /// Starts a new lifecycle attempt and returns its token. Every subsequent
    /// transition must supply this token, so a cancelled load cannot mark a newer
    /// load ready when it eventually unwinds.
    func beginLoading(_ model: ManagedModel) -> UInt64 {
        var entry = entries[model] ?? Entry()
        entry.generation &+= 1
        entry.state = .loading
        entry.lastError = nil
        entry.changedAt = Date()
        entries[model] = entry
        return entry.generation
    }

    /// Marks a successful load. Returns false for a stale token.
    @discardableResult
    func markReady(_ model: ManagedModel, generation: UInt64) -> Bool {
        transition(model, generation: generation, state: .ready, error: nil)
    }

    /// Marks a runtime as warming before its first inference. Warming is distinct
    /// from loading because a model can be resident while its first graph compile
    /// is still in progress.
    @discardableResult
    func markWarming(_ model: ManagedModel, generation: UInt64) -> Bool {
        transition(model, generation: generation, state: .warming, error: nil)
    }

    @discardableResult
    func markBusy(_ model: ManagedModel, generation: UInt64) -> Bool {
        transition(model, generation: generation, state: .busy, error: nil)
    }

    /// Records an inference/runtime failure. A later `beginRecovery` starts a new
    /// generation, so the failed instance can never overwrite the replacement.
    @discardableResult
    func markWedged(
        _ model: ManagedModel,
        generation: UInt64,
        error: String
    ) -> Bool {
        transition(model, generation: generation, state: .wedged, error: error)
    }

    func beginRecovery(_ model: ManagedModel) -> UInt64 {
        var entry = entries[model] ?? Entry()
        entry.generation &+= 1
        entry.state = .recovering
        entry.lastError = nil
        entry.changedAt = Date()
        entries[model] = entry
        return entry.generation
    }

    /// Run one owner-supplied recovery operation. The unload and load closures
    /// perform the real resource work; this actor only records their lifecycle.
    /// A failed reload remains wedged so callers do not mistake a half-recovered
    /// runtime for a usable one.
    @discardableResult
    func recover(
        _ model: ManagedModel,
        unload: @escaping @Sendable () async -> Void,
        load: @escaping @Sendable () async throws -> Void
    ) async -> Bool {
        let generation = beginRecovery(model)
        await unload()
        do {
            try await load()
            return markReady(model, generation: generation)
        } catch {
            _ = markWedged(model, generation: generation, error: error.localizedDescription)
            return false
        }
    }

    /// Records that an owner released its resident weights.
    @discardableResult
    func markUnloaded(_ model: ManagedModel, generation: UInt64? = nil) -> Bool {
        guard var entry = entries[model] else { return false }
        if let generation, generation != entry.generation { return false }
        entry.state = .unloaded
        entry.lastError = nil
        entry.changedAt = Date()
        entries[model] = entry
        return true
    }

    func snapshot(_ model: ManagedModel) -> ModelRuntimeSnapshot {
        let entry = entries[model] ?? Entry()
        return ModelRuntimeSnapshot(
            model: model,
            state: entry.state,
            generation: entry.generation,
            changedAt: entry.changedAt,
            lastError: entry.lastError
        )
    }

    func snapshots() -> [ModelRuntimeSnapshot] {
        ManagedModel.allCases.map { snapshot($0) }
    }

    private func transition(
        _ model: ManagedModel,
        generation: UInt64,
        state: ModelRuntimeState,
        error: String?
    ) -> Bool {
        guard var entry = entries[model], entry.generation == generation else { return false }
        entry.state = state
        entry.lastError = error
        entry.changedAt = Date()
        entries[model] = entry
        return true
    }
}

extension ModelRuntimeManager {
    private actor RecoveryProbe {
        private(set) var unloadCount = 0
        private(set) var loadCount = 0

        func unload() { unloadCount += 1 }
        func load() { loadCount += 1 }
    }

    /// Lifecycle and stale-generation probe. No model files, permissions, or
    /// `RunLog` are touched; a passing result means the state machine actually
    /// rejected a late transition and accepted the current recovery.
    @discardableResult
    static func runSelfTest() async -> Bool {
        let manager = ModelRuntimeManager()
        let first = await manager.beginLoading(.parakeetASR)
        _ = await manager.beginRecovery(.parakeetASR)
        let probe = RecoveryProbe()

        var failures: [String] = []
        if await manager.markReady(.parakeetASR, generation: first) {
            failures.append("stale load marked the replacement runtime ready")
        }
        if !(await manager.recover(
            .parakeetASR,
            unload: { await probe.unload() },
            load: { await probe.load() }
        )) {
            failures.append("owner recovery did not complete")
        }
        let unloadCount = await probe.unloadCount
        let loadCount = await probe.loadCount
        if unloadCount != 1 || loadCount != 1 {
            failures.append("owner recovery ran unload/load more than once")
        }
        if (await manager.snapshot(.parakeetASR)).state != .ready {
            failures.append("runtime state was not ready after recovery")
        }
        let recoveredGeneration = (await manager.snapshot(.parakeetASR)).generation
        if !(await manager.markBusy(.parakeetASR, generation: recoveredGeneration)) {
            failures.append("ready runtime could not enter busy state")
        }
        if !(await manager.markUnloaded(.parakeetASR, generation: recoveredGeneration)) {
            failures.append("current runtime could not be unloaded")
        }
        if (await manager.snapshot(.parakeetASR)).state != .unloaded {
            failures.append("runtime state was not unloaded")
        }

        for failure in failures {
            print("MODEL_RUNTIME_WRONG: \(failure)")
        }
        print(failures.isEmpty ? "MODEL_RUNTIME_OK" : "MODEL_RUNTIME_FAILED")
        return failures.isEmpty
    }
}

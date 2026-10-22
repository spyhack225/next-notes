import Foundation
import llama

/// The single owner of llama.cpp's process-wide backend state.
///
/// Two runtimes share llama.cpp in this process — S1-mini for dictation cleanup and the
/// notes model for meetings — and `llama_backend_init` plus the `GGML_*` environment
/// variables are global to the process, not to a model. Whichever runtime initialized
/// first used to decide, for everyone, whether Metal existed at all. This actor decides
/// once, and per-model choices (CPU vs GPU) are made through `n_gpu_layers` instead.
actor LlamaBackend {
    static let shared = LlamaBackend()

    /// Who started the one process-wide initialization. Launch warm-up starts it after
    /// Parakeet has settled; anything else is the first native caller paying for it.
    enum InitializationOrigin: String, Sendable { case launchWarmup = "launch", firstUse = "first_use" }

    /// What the one initialization cost. `llama_backend_init` is where ggml-metal compiles
    /// its embedded shader sources (twenty libraries in b10621, `newLibraryWithSource`), so
    /// this number is the Metal compile: ~50 s with no shader cache, under a second with
    /// one. It is recorded apart from the model open so a cold load says which half was slow.
    struct InitializationRecord: Sendable, Equatable {
        let seconds: Double
        let metal: Bool
        let origin: InitializationOrigin
    }

    /// The native call, injectable so `--selftest-llama-backend-warmup` can hold it open
    /// without compiling shaders. Runs on a GCD thread, never on this actor's executor.
    typealias NativeInitializer = @Sendable (_ metalEnabled: Bool) -> Void

    private let nativeInitializer: NativeInitializer
    private let metalSetting: @Sendable () async -> Bool
    private let recordsMetrics: Bool

    init(
        nativeInitializer: @escaping NativeInitializer = LlamaBackend.nativeInitialize,
        metalSetting: @escaping @Sendable () async -> Bool = {
            await MainActor.run { Settings.shared.llmMetalEnabled }
        },
        recordsMetrics: Bool = true
    ) {
        self.nativeInitializer = nativeInitializer
        self.metalSetting = metalSetting
        self.recordsMetrics = recordsMetrics
    }

    private var isInitialized = false
    /// The in-flight initialization every concurrent caller joins, so the shader compile
    /// runs once and the actor stays free for `beginCleanup`/`endCleanup` meanwhile.
    private var initialization: Task<Void, Never>?
    private(set) var lastInitialization: InitializationRecord?
    private(set) var nativeProbeAllowed = true
    private(set) var terminationProbeTraceForTesting: OtherLlamaTerminationTrace?

    func configureProbeTerminationFixture(trace: OtherLlamaTerminationTrace) throws {
        guard NativeOtherLlamaQuitSelfTest.isRequested, terminationProbeTraceForTesting == nil else { throw CocoaError(.fileReadNoPermission) }
        terminationProbeTraceForTesting = trace
    }
    nonisolated func beginTermination() async { await closeNativeProbesForTermination() }
    /// Refuses new native work, then joins an initialization already in flight. The native
    /// call no longer runs on this actor's executor, so actor serialization alone would not
    /// join it; awaiting the same task keeps "native work finishes before quit admits exit".
    private func closeNativeProbesForTermination() async {
        nativeProbeAllowed = false
        if let initialization { await initialization.value }
        terminationProbeTraceForTesting?.ownerClosed()
    }
    private(set) var isMetalAvailable = false

    /// Idempotent. Safe to call from every runtime before its first model load, and from
    /// launch warm-up ahead of it. Concurrent callers join one in-flight initialization.
    func initialize(origin: InitializationOrigin = .firstUse) async {
        guard nativeProbeAllowed else { return }
        if isInitialized { return }
        if let initialization { await initialization.value; return }

        // The slot is claimed synchronously — no suspension between the checks above and
        // this assignment — so the record's origin is the caller that actually started the
        // initialization. Reading the Metal setting before the claim let every concurrent
        // caller suspend there, and whichever resumed first (often not the first to ask)
        // stamped its own origin on the one shared compile.
        let native = nativeInitializer
        let metalSetting = self.metalSetting
        let qos: DispatchQoS.QoSClass = origin == .launchWarmup ? .utility : .userInitiated
        let task = Task<Void, Never> {
            let metalEnabled = await metalSetting()
            // Re-checked after the suspension: termination may have closed native work.
            guard self.nativeProbeAllowed else { return }
            let seconds = await Self.runOffExecutor(qos: qos) { native(metalEnabled) }
            self.finishInitialization(seconds: seconds, metal: metalEnabled, origin: origin)
        }
        initialization = task
        await task.value
    }

    /// The production native call. llama.cpp keeps Metal residency sets alive for three
    /// minutes by default and can assert while a GUI app is quitting; neither model here
    /// needs that, and disabling it makes context teardown immediate and deterministic.
    /// The escape hatch: the Metal backend has wedged MTLCompilerService on some macOS 26
    /// builds; when the user turns Metal off, hide the device from ggml entirely so the
    /// process behaves exactly as it did before the notes model existed.
    static let nativeInitialize: NativeInitializer = { metalEnabled in
        setenv("GGML_METAL_NO_RESIDENCY", "1", 1)
        if !metalEnabled {
            setenv("GGML_METAL_DEVICES", "0", 1)
        }
        llama_log_set({ _, _, _ in }, nil)
        llama_backend_init()
    }

    /// A blocking native call that can take tens of seconds must not hold a Swift
    /// cooperative-pool thread or this actor; it runs on a GCD thread and is awaited.
    private nonisolated static func runOffExecutor(
        qos: DispatchQoS.QoSClass,
        _ work: @escaping @Sendable () -> Void
    ) async -> Double {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: qos).async {
                let start = DispatchTime.now().uptimeNanoseconds
                work()
                let elapsed = DispatchTime.now().uptimeNanoseconds &- start
                continuation.resume(returning: Double(elapsed) / 1_000_000_000)
            }
        }
    }

    private func finishInitialization(seconds: Double, metal: Bool, origin: InitializationOrigin) {
        isInitialized = true
        isMetalAvailable = metal
        lastInitialization = InitializationRecord(seconds: seconds, metal: metal, origin: origin)
        Log.llm.info("""
            llama.cpp backend initialized — metal \(metal ? "on" : "off", privacy: .public) — \
            \(seconds, format: .fixed(precision: 3), privacy: .public)s \
            (\(origin.rawValue, privacy: .public))
            """)
        // Its own `model.load` span, beside the runtime's `app_llm` one: a load that found
        // the backend already initialized no longer carries the shader compile, and one that
        // did can be split by subtracting this row.
        if recordsMetrics {
            LatencyTrace.record(
                .modelLoad, seconds: seconds,
                note: "llama_backend_init origin=\(origin.rawValue) metal=\(metal ? "on" : "off")")
        }
    }

    /// Runtimes must have released their models and contexts before this runs; the Metal
    /// backend asserts at process exit if a live context outlives the backend.
    func shutdown() {
        guard isInitialized else { return }
        llama_backend_free()
        isInitialized = false
        initialization = nil
    }

    /// Whether this build of llama.cpp can offload layers to a GPU at all.
    ///
    /// Distinct from `isMetalAvailable`, which only reports the user's setting: this asks
    /// the library. `--selftest-llm-metal` prints both, because "Metal is on" and "Metal is
    /// there" failing apart is exactly the R1 failure the gate exists to catch.
    var supportsGPUOffload: Bool { llama_supports_gpu_offload() }

    /// The backends llama.cpp actually loaded, as it reports them.
    var systemInfo: String { String(cString: llama_print_system_info()) }

    // MARK: - Cleanup gate

    /// How many dictation cleanup passes are running right now.
    private var cleanupsInFlight = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    /// Marks a dictation cleanup as started. Paired with `endCleanup()`.
    ///
    /// This exists for one reason: on a 16 GB Mac the notes model's gigabytes of weights and
    /// S1-mini's context must not be *loaded* at the same instant. Both models running is
    /// fine; both loading is where the machine starts swapping, and the dictation pass is
    /// the one with a person waiting on it.
    ///
    /// **One-directional.** Notes (`NotesModelRuntime`) and the compute scheduler call
    /// `awaitCleanupIdle()` so a load waits for cleanup. They must never call
    /// `beginCleanup()`. Closing the cycle — beginCleanup from a path that then awaits
    /// this same runtime — deadlocks on-device cleanup (`AppLLMCleanupFormatter`).
    /// `ComputeScheduler` and `ModelResidencyPolicy` cooperate by yielding / unloading;
    /// they do not reverse this gate.
    func beginCleanup() {
        cleanupsInFlight += 1
    }

    func endCleanup() {
        cleanupsInFlight = max(0, cleanupsInFlight - 1)
        guard cleanupsInFlight == 0 else { return }
        let waiters = idleWaiters
        idleWaiters = []
        for waiter in waiters { waiter.resume() }
    }

    /// Suspends until no dictation cleanup is in flight. Returns immediately when none is.
    ///
    /// The only notes → cleanup wait. Scheduler preemption of notes for ASR is a
    /// separate, parallel mechanism (`ComputeScheduler`); do not merge them into a
    /// bidirectional lock.
    func awaitCleanupIdle() async {
        guard cleanupsInFlight > 0 else { return }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }
}

/// The launch order for the cleanup model, as data so `--selftest-llama-backend-warmup`
/// pins the order the app actually runs.
///
/// Parakeet first: the Neural Engine compile of its encoder (21–36 s on a cache miss) and
/// ggml-metal's shader compile are both CPU-heavy, and a dictation needs its recognizer
/// before its cleanup model. Then the backend on its own — the shader compile, timed apart
/// from the weights — and only then the 1.5 GB preload, so the model open never pays for
/// the compile. A self-test never warms anything, and a plan without the cleanup model
/// warms nothing here.
enum LlamaLaunchWarmup {
    enum Step: Equatable, Sendable { case awaitParakeetSettled, initializeBackend, preloadCleanupModel }

    static func steps(
        plan: Set<LaunchWarmup.Action>,
        parakeetPlanned: Bool,
        selfTestRunning: Bool
    ) -> [Step] {
        guard !selfTestRunning, plan.contains(.loadCleanupModel) else { return [] }
        return (parakeetPlanned ? [.awaitParakeetSettled] : []) + [.initializeBackend, .preloadCleanupModel]
    }
}

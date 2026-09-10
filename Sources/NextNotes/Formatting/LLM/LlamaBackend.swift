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

    private var isInitialized = false
    private(set) var isMetalAvailable = false

    /// Idempotent. Safe to call from every runtime before its first model load.
    func initialize() async {
        if isInitialized { return }

        let metalEnabled = await MainActor.run { Settings.shared.llmMetalEnabled }

        // llama.cpp keeps Metal residency sets alive for three minutes by default and can
        // assert while a GUI app is quitting. Neither model here needs that optimization;
        // disabling it makes context teardown immediate and deterministic.
        setenv("GGML_METAL_NO_RESIDENCY", "1", 1)

        // The escape hatch. The Metal backend has wedged MTLCompilerService on some macOS 26
        // builds; when the user turns Metal off, hide the device from ggml entirely so the
        // process behaves exactly as it did before the notes model existed.
        if !metalEnabled {
            setenv("GGML_METAL_DEVICES", "0", 1)
        }

        llama_log_set({ _, _, _ in }, nil)
        llama_backend_init()

        isInitialized = true
        isMetalAvailable = metalEnabled
        Log.llm.info("llama.cpp backend initialized — metal \(metalEnabled ? "on" : "off")")
    }

    /// Runtimes must have released their models and contexts before this runs; the Metal
    /// backend asserts at process exit if a live context outlives the backend.
    func shutdown() {
        guard isInitialized else { return }
        llama_backend_free()
        isInitialized = false
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
    /// This exists for one reason: on a 16 GB Mac the notes model's 2.7 GB of weights and
    /// S1-mini's context must not be *loaded* at the same instant. Both models running is
    /// fine; both loading is where the machine starts swapping, and the dictation pass is
    /// the one with a person waiting on it.
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
    func awaitCleanupIdle() async {
        guard cleanupsInFlight > 0 else { return }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }
}

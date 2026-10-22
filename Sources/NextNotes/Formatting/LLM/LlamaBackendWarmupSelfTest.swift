import Foundation

/// `--selftest-llama-backend-warmup`: the llama backend initializes once, off its actor,
/// in launch order, and is timed apart from the model open.
///
/// `llama_backend_init` is where ggml-metal (b10621, embedded library) compiles its twenty
/// shader sources with `newLibraryWithSource` — ~50 s with no Metal shader cache, under a
/// second with one. Before this change the call ran synchronously on `LlamaBackend`'s own
/// executor inside the first model load, so for the whole compile every other hop to the
/// actor (`beginCleanup`, `endCleanup`, `awaitCleanupIdle`) waited too, and the compile
/// was counted as model-open time.
///
/// Cases 1–4 hold the native call open with an injected initializer on an isolated
/// `LlamaBackend` (no shaders, no metrics row, no owner store):
/// 1. four concurrent callers run the native initializer exactly once and all return
///    after it finished — three of them arriving while the first is still suspended
///    reading the Metal setting;
/// 2. while it is in flight the actor answers `beginCleanup`/`endCleanup`/
///    `awaitCleanupIdle` promptly — the original executor-blocking shape fails this;
/// 3. the one initialization is recorded with its duration and the origin of the caller
///    that started it (not whichever caller resumed first from that suspension);
/// 4. `beginTermination` joins an initialization in flight and refuses a new one.
/// Case 5 pins `LlamaLaunchWarmup.steps`, the order the launch path executes.
/// Case 6 runs the real shared backend once and prints its measured init time
/// (`LLAMA_BACKEND_INIT_SECONDS`) — a diagnostic, failing only if nothing was recorded.
@MainActor
enum LlamaBackendWarmupSelfTest {
    static let hold: Duration = .milliseconds(600)
    /// Generous against scheduler noise and far below `hold`.
    static let promptBound: Double = 0.2

    static func runSelfTest() async -> Bool {
        var failures: [String] = []
        failures += await sharedInitializationFailures()
        failures += await responsivenessFailures()
        failures += await terminationFailures()
        failures += launchOrderFailures()
        failures += await realBackendFailures()
        for failure in failures { SelfTest.diagnostic("LLAMA_BACKEND_WARMUP_WRONG: \(failure)") }
        SelfTest.diagnostic(failures.isEmpty
            ? "LLAMA_BACKEND_WARMUP_OK: one off-actor initialization, joined by callers and termination, launch order pinned"
            : "LLAMA_BACKEND_WARMUP_FAILED: \(failures.count) assertion(s)")
        return failures.isEmpty
    }

    /// Counts native calls and lets a case know the call has started.
    final class NativeProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        private var finished = 0
        let started = DispatchSemaphore(value: 0)
        let holdSeconds: Double

        init(holdSeconds: Double) { self.holdSeconds = holdSeconds }

        var initializer: LlamaBackend.NativeInitializer {
            { [self] _ in
                lock.withLock { calls += 1 }
                started.signal()
                Thread.sleep(forTimeInterval: holdSeconds)
                lock.withLock { finished += 1 }
            }
        }
        var callCount: Int { lock.withLock { calls } }
        var finishedCount: Int { lock.withLock { finished } }

        /// Waits off the main actor for the native call to begin.
        func waitStarted() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    _ = self.started.wait(timeout: .now() + 5)
                    continuation.resume()
                }
            }
        }
    }

    private static func isolated(
        _ probe: NativeProbe,
        metalSetting: @escaping @Sendable () async -> Bool = { true }
    ) -> LlamaBackend {
        LlamaBackend(nativeInitializer: probe.initializer, metalSetting: metalSetting, recordsMetrics: false)
    }

    /// Counts reads of the Metal setting and holds the first one open, the way the
    /// production `MainActor.run` hop can stay suspended while later callers arrive.
    final class MetalSettingProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        let firstEntered = DispatchSemaphore(value: 0)
        var callCount: Int { lock.withLock { calls } }

        var setting: @Sendable () async -> Bool {
            { [self] in
                let call = lock.withLock { () -> Int in calls += 1; return calls }
                if call == 1 {
                    firstEntered.signal()
                    try? await Task.sleep(for: .milliseconds(150))
                }
                return true
            }
        }

        func waitFirstEntered() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    _ = self.firstEntered.wait(timeout: .now() + 5)
                    continuation.resume()
                }
            }
        }
    }

    private static var holdSeconds: Double {
        Double(hold.components.seconds) + Double(hold.components.attoseconds) / 1e18
    }

    // MARK: 1 + 3

    private static func sharedInitializationFailures() async -> [String] {
        let probe = NativeProbe(holdSeconds: holdSeconds)
        let metal = MetalSettingProbe()
        let backend = isolated(probe, metalSetting: metal.setting)
        // The launch caller asks first and is still suspended reading the Metal setting when
        // three first-use callers arrive. The one that asked first started the compile, so
        // the record must say launch; the setting is read once, by the one initialization.
        let launch = Task { await backend.initialize(origin: .launchWarmup) }
        await metal.waitFirstEntered()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<3 { group.addTask { await backend.initialize() } }
        }
        await launch.value
        var failures: [String] = []
        if metal.callCount != 1 {
            failures.append("the Metal setting was read \(metal.callCount) time(s) for one initialization")
        }
        if probe.callCount != 1 {
            failures.append("concurrent callers ran the native initializer \(probe.callCount) time(s), not once")
        }
        if probe.finishedCount != 1 {
            failures.append("a caller returned before the native initializer finished")
        }
        let record = await backend.lastInitialization
        if record == nil {
            failures.append("no initialization record")
        } else if let record {
            if record.origin != .launchWarmup {
                failures.append("record origin \(record.origin.rawValue), not the launch caller that started it")
            }
            if record.seconds < holdSeconds * 0.9 {
                failures.append("recorded \(record.seconds)s for a \(holdSeconds)s native call")
            }
            if !record.metal { failures.append("record lost the Metal setting") }
        }
        if !(await backend.isMetalAvailable) { failures.append("isMetalAvailable not set after init") }
        await backend.initialize()
        if probe.callCount != 1 { failures.append("a later caller initialized again") }
        return failures
    }

    // MARK: 2

    private static func responsivenessFailures() async -> [String] {
        let probe = NativeProbe(holdSeconds: holdSeconds)
        let backend = isolated(probe)
        let initializing = Task { await backend.initialize(origin: .launchWarmup) }
        await probe.waitStarted()
        let clock = ContinuousClock()
        let start = clock.now
        await backend.beginCleanup()
        await backend.endCleanup()
        await backend.awaitCleanupIdle()
        let elapsed = clock.now - start
        let stillRunning = probe.finishedCount == 0
        await initializing.value
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        var failures: [String] = []
        if seconds > promptBound {
            failures.append(String(format: "cleanup gate waited %.3fs behind the in-flight initialization", seconds))
        }
        if !stillRunning { failures.append("the native call finished before the gate was probed; case proved nothing") }
        return failures
    }

    // MARK: 4

    private static func terminationFailures() async -> [String] {
        var failures: [String] = []
        let probe = NativeProbe(holdSeconds: holdSeconds)
        let backend = isolated(probe)
        let initializing = Task { await backend.initialize(origin: .launchWarmup) }
        await probe.waitStarted()
        await backend.beginTermination()
        if probe.finishedCount != 1 {
            failures.append("beginTermination returned while the native initialization was still running")
        }
        await initializing.value

        let refused = NativeProbe(holdSeconds: 0)
        let closed = isolated(refused)
        await closed.beginTermination()
        await closed.initialize()
        if refused.callCount != 0 { failures.append("initialization ran after termination closed native work") }
        return failures
    }

    // MARK: 5

    private static func launchOrderFailures() -> [String] {
        typealias Step = LlamaLaunchWarmup.Step
        let cases: [(Set<LaunchWarmup.Action>, Bool, Bool, [Step], String)] = [
            ([.loadCleanupModel, .warmApple], true, false,
             [.awaitParakeetSettled, .initializeBackend, .preloadCleanupModel], "Parakeet planned"),
            ([.loadCleanupModel], false, false, [.initializeBackend, .preloadCleanupModel], "no Parakeet"),
            ([.loadCleanupModel], true, true, [], "under a self-test"),
            ([.warmApple], true, false, [], "Apple cleanup"),
            ([], true, false, [], "cleanup off"),
            ([.loadS1Mini], false, false, [], "S1-mini (its own prepare path)"),
        ]
        return cases.compactMap { plan, parakeet, selfTest, expected, name in
            let steps = LlamaLaunchWarmup.steps(plan: plan, parakeetPlanned: parakeet, selfTestRunning: selfTest)
            return steps == expected ? nil : "launch order for \(name) is \(steps), expected \(expected)"
        }
    }

    // MARK: 6

    private static func realBackendFailures() async -> [String] {
        let clock = ContinuousClock()
        let start = clock.now
        await LlamaBackend.shared.initialize(origin: .launchWarmup)
        let elapsed = clock.now - start
        guard let record = await LlamaBackend.shared.lastInitialization else {
            return ["the real backend initialized without a record"]
        }
        SelfTest.diagnostic(String(
            format: "LLAMA_BACKEND_INIT_SECONDS: %.3f (metal %@, wall %.3f) — >5 s means the Metal shader cache missed",
            record.seconds, record.metal ? "on" : "off",
            Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18))
        return []
    }
}

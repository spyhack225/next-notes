import AppKit
import FluidAudio
import Foundation

/// OFF-SOURCE COMMON. Requires the root's corrected startup asset preflight and
/// exact same default-nil concrete delegate queue injection before BOTH runs.
@MainActor
enum ASRQueueTerminationSelfTest {
    private static var activeCaller: Task<Void, Never>?
    private static var queuedCaller: Task<Void, Never>?

    static func armIfRequested() async throws -> Bool {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--native-startup-case"),
              args.indices.contains(index + 1) else { return false }
        let mode = args[index + 1]
        guard mode.hasPrefix("asr-queue-") else { return false }
        guard SelfTest.requested == "--selftest-native-termination",
              ["asr-queue-active", "asr-queue-queued", "asr-queue-closed"].contains(mode),
              let assets = args.firstIndex(of: "--native-startup-assets"), args.indices.contains(assets + 1),
              let delegate = AppDelegate.current else { throw CocoaError(.fileReadNoPermission) }
        let root = try NativeStartupTerminationSelfTest.validateAssets(
            URL(fileURLWithPath: args[assets + 1]), pocket: false)
        ModelHub.offlineMode = true
        // Actual public copied models. This quiet loader trace cannot itself quit.
        let models = try ParakeetModels(terminationFixtureRoot: root,
                                       trace: StartupTerminationTrace(autoQuit: false))
        let queue = TranscriptionQueue.shared
        let trace = ASRQueueTerminationTrace(mode: mode)
        try await queue.configureTerminationFixture(models: models, trace: trace)
        // Deterministic numeric PCM at the actual 16 kHz model input. No microphone,
        // owner recording, synthesized fake ASR result, text scorer, or speaker.
        let samples = (0..<64_000).map { Float(0.05 * sin(2 * Double.pi * 200 * Double($0) / 16_000)) }
        func check(_ label: String, _ accepted: Bool) {
            trace.check(accepted)
            if !accepted {
                SelfTest.failed = true
                SelfTest.diagnostic("ASR_QUEUE_TERMINATION_ASSERT_FAILED: \(label)")
            }
        }
        // Qualification pass really returns from the native ASR API, not an override.
        try await queue.warmUp()
        _ = try await queue.transcribe(samples)
        let qualified = trace.snapshot()
        guard qualified.successfulReturns == 1 && qualified.nativeActive == 0
                && qualified.workAssigned == 1 && qualified.workEnded == 1 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        check("C01 actual native qualification returned once", true)
        check("C02 offline input policy", ModelHub.offlineMode)
        try delegate.configureStartupTerminationFixture(
            parakeet: nil, pocket: nil, queue: queue,
            reply: { reply in
                let observed = trace.snapshot()
                check("C03 actual Cocoa quit returns later", reply == .terminateLater)
                if mode != "asr-queue-closed" {
                    let expectedPending = mode == "asr-queue-queued" ? 2 : 1
                    let overlap = observed.nativeActive == 1 && observed.successfulReturns == 1
                        && observed.workAssigned - observed.workEnded == expectedPending
                    check("C04 SAME owned work is pending at quit", overlap)
                    if !overlap { trace.invalidate() }
                    if mode == "asr-queue-queued" {
                        check("C05 caller cancellation leaves native owned work pending", activeCaller?.isCancelled == true)
                    }
                }
                SelfTest.diagnostic("ASR_QUEUE_TERMINATION_REPLY_TRACE mode=\(mode) active=\(observed.nativeActive) assigned=\(observed.workAssigned) ended=\(observed.workEnded) success=\(observed.successfulReturns)")
            },
            willExit: {
                let observed = trace.snapshot()
                check("F01 actual owned tail is drained", observed.nativeActive == 0
                      && observed.workAssigned == observed.workEnded)
                if mode == "asr-queue-queued" {
                    check("F02 closed previous-await successor starts no native call", observed.nativeStarts == 2)
                }
                check("C06 actual native counts remain balanced", observed.nativeStarts == observed.nativeEnds + observed.nativeActive)
                check("C07 offline policy survives quit", ModelHub.offlineMode)
                let final = trace.snapshot()
                SelfTest.diagnostic("ASR_QUEUE_TERMINATION_EXIT_TRACE mode=\(mode) assigned=\(final.workAssigned) ended=\(final.workEnded) starts=\(final.nativeStarts) ends=\(final.nativeEnds) active=\(final.nativeActive) success=\(final.successfulReturns) checks=\(final.checks) failures=\(final.failures) invalid=\(final.invalid)")
                if final.invalid {
                    SelfTest.failed = true
                    SelfTest.diagnostic("ASR_QUEUE_TERMINATION_INVALID: actual pending overlap unavailable")
                } else {
                    SelfTest.diagnostic(final.failures == 0
                        ? "ASR_QUEUE_TERMINATION_OK: \(final.checks) checks"
                        : "ASR_QUEUE_TERMINATION_FAILED: \(final.failures)/\(final.checks)")
                }
            }
        )
        trace.onBoundary = { boundary in
            if boundary == .activeNative {
                if mode == "asr-queue-queued" {
                    // This caller admits behind the actual existing tail. Its assignment
                    // callback, not a yield/sleep, schedules Cocoa quit after admission.
                    activeCaller?.cancel()
                    queuedCaller = Task {
                        do { _ = try await queue.transcribe(samples) }
                        catch { /* real refusal/result is traced without payload */ }
                    }
                } else { SelfTest.requestTermination() }
            } else if boundary == .queuedAssigned {
                SelfTest.requestTermination()
            }
        }
        SelfTest.diagnostic("ASR_QUEUE_TERMINATION_INPUT_OK: same shared queue and confined real public model")
        if mode == "asr-queue-closed" {
            await queue.beginTermination()
            let before = trace.snapshot()
            var refused = false
            do { _ = try await queue.transcribe(samples) }
            catch is CancellationError { refused = true }
            let after = trace.snapshot()
            check("F03 closed queue rejects actual new submission", refused)
            check("F04 closed queue adds no work or native call", after.workAssigned == before.workAssigned
                  && after.nativeStarts == before.nativeStarts)
            SelfTest.requestTermination()
        } else {
            activeCaller = Task {
                do { _ = try await queue.transcribe(samples) }
                catch { /* real failure has no payload publication here */ }
            }
        }
        return true
    }
}

/// Bounded scalar observer only. No second audio queue, decoder override or native
/// wait. Cocoa boundary publication is explicitly outside any Swift MainActor Task.
final class ASRQueueTerminationTrace: @unchecked Sendable {
    enum Boundary: Equatable, Sendable { case activeNative, queuedAssigned }
    struct Snapshot: Sendable {
        var workAssigned = 0
        var workEnded = 0
        var nativeStarts = 0
        var nativeEnds = 0
        var nativeActive = 0
        var successfulReturns = 0
        var checks = 0
        var failures = 0
        var invalid = false
    }
    private let lock = NSLock()
    private let mode: String
    private var value = Snapshot()
    // Configured once on MainActor after real qualification, before further work.
    // Locked to prevent a callback/data race during native Task boundary reporting.
    private var callback: (@MainActor @Sendable (Boundary) -> Void)?
    var onBoundary: (@MainActor @Sendable (Boundary) -> Void)? {
        get { lock.withLock { callback } }
        set { lock.withLock { callback = newValue } }
    }
    init(mode: String) { self.mode = mode }
    func workAssigned() {
        let fire = lock.withLock { () -> Bool in
            value.workAssigned += 1
            return mode == "asr-queue-queued" && value.workAssigned == 3
        }
        if fire { publish(.queuedAssigned) }
    }
    func workEnded() { lock.withLock { value.workEnded += 1 } }
    func nativeEntered() {
        let fire = lock.withLock { () -> Bool in
            value.nativeStarts += 1; value.nativeActive += 1
            return mode != "asr-queue-closed" && value.nativeStarts == 2
        }
        if fire { publish(.activeNative) }
    }
    func nativeReturned(succeeded: Bool) {
        lock.withLock {
            value.nativeEnds += 1; value.nativeActive -= 1
            if succeeded { value.successfulReturns += 1 }
        }
    }
    func check(_ accepted: Bool) { lock.withLock { value.checks += 1; if !accepted { value.failures += 1 } } }
    func invalidate() { lock.withLock { value.invalid = true } }
    func snapshot() -> Snapshot { lock.withLock { value } }
    private func publish(_ boundary: Boundary) {
        guard let callback = lock.withLock({ callback }) else { return }
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated { callback(boundary) }
        }
    }
}

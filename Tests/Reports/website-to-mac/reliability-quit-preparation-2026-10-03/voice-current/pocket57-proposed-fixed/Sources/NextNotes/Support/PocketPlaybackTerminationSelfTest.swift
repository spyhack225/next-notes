import AppKit
import FluidAudio
import Foundation

/// COMMON real Pocket backing/Cocoa producer fixture. Source-only, uncompiled.
/// The exact existing startup assets validator and offline preparation are reused.
@MainActor
enum PocketPlaybackTerminationSelfTest {
    static func armIfRequested() async throws -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--native-startup-case"), args.indices.contains(i + 1),
              args[i + 1].hasPrefix("pocket-playback-") else { return false }
        guard SelfTest.requested == "--selftest-native-termination",
              let a = args.firstIndex(of: "--native-startup-assets"), args.indices.contains(a + 1),
              let delegate = AppDelegate.current else { throw CocoaError(.fileReadNoPermission) }
        let mode = args[i + 1]
        guard ["pocket-playback-active", "pocket-playback-predecessor",
               "pocket-playback-factory", "pocket-playback-closed"].contains(mode) else {
            throw CocoaError(.fileReadNoPermission)
        }
        #if NEXTNOTES_POCKET_OBSERVATION
        let root = try NativeStartupTerminationSelfTest.validateAssets(
            URL(fileURLWithPath: args[a + 1]), pocket: true)
        ModelHub.offlineMode = true
        let voice = try PocketAgentVoice(terminationFixtureRoot: root,
                                       trace: StartupTerminationTrace(autoQuit: false))
        await voice.prepare()
        guard voice.isReady, !voice.isPreparing else { throw CocoaError(.fileReadCorruptFile) }
        let backing = PocketSpeechBacking()
        // Below the existing 280-character clause policy; synthetic public text only.
        let text = "This is a synthetic playback shutdown check. The test team is checking that a cancelled voice generation remains owned until it finishes, while the next reply can begin promptly. No private messages, meeting notes, or user speech are used for this check."
        var finalCaptured = false
        var checks = 0
        var failures = 0
        var invalid = false
        var firstReplyCaptured = false
        let trace = PocketPlaybackTerminationTrace { action in
            // No I/O or blocking in a native observer. Actual Cocoa quit runs in
            // its run loop, never within an occupied MainActor executor job.
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated {
                    switch action {
                    case .firstPCM(let token):
                        if mode == "pocket-playback-predecessor", token == 1 {
                            backing.stop()
                            backing.speak(text, volume: 0, token: 2)
                        } else if mode != "pocket-playback-factory", mode != "pocket-playback-closed" {
                            NSApp.terminate(nil)
                        }
                    case .factoryEntered:
                        if mode == "pocket-playback-factory" { NSApp.terminate(nil) }
                    case .safeCleanup:
                        SelfTest.requestTermination()
                    }
                }
            }
        }
        try backing.configureTerminationPlaybackFixture(voice: voice, trace: trace)
        func check(_ label: String, _ passed: Bool) {
            checks += 1
            if !passed {
                failures += 1
                if label.hasPrefix("C") { invalid = true }
                SelfTest.failed = true
                SelfTest.diagnostic("POCKET_PLAYBACK_TERMINATION_ASSERT_FAILED: \(label)")
            }
        }
        try delegate.configureStartupTerminationFixture(
            parakeet: nil, pocket: voice, playback: backing,
            finalReply: { proposed in
                if finalCaptured { return proposed }
                finalCaptured = true
                let s = trace.snapshot()
                check("C03 actual delegate proposed a positive native quit reply", proposed)
                if mode == "pocket-playback-active" || mode == "pocket-playback-predecessor" {
                    // An original that happened to finish naturally supplies no
                    // measured exit-before-return case. It must remain INVALID.
                    if !backing.terminationOwnerForTesting.closed && s.nativePending == 0 { invalid = true }
                }
                check("F01 quit permanently closes the actual playback owner", backing.terminationOwnerForTesting.closed)
                check("F02 quit joins every entered native generation body", s.nativePending == 0 && s.nativeStarts == s.nativeReturns)
                check("F03 quit releases the same active consumer chain", s.consumerPending == 0 && !backing.terminationOwnerForTesting.pending)
                check("F04 every returned session was explicitly cancelled and joined", s.sessionReturns == s.sessionJoins && (mode == "pocket-playback-closed" || s.sessionReturns > 0))
                if mode == "pocket-playback-factory" {
                    check("F05 closed factory result enqueues no text", s.enqueues == 0)
                }
                let before = trace.snapshot()
                backing.speak(text, volume: 0, token: 3)
                check("F06 late speak admits no new consumer task", !backing.terminationOwnerForTesting.pending)
                check("F07 late speak starts no playback engine", !backing.isPlaybackEngineRunning)
                check("C04 closed probe does not fabricate native observations", trace.snapshot().nativeStarts == before.nativeStarts)
                SelfTest.diagnostic("POCKET_PLAYBACK_TERMINATION_FINAL_TRACE mode=\(mode) proposed=\(proposed) nativeStarts=\(s.nativeStarts) nativeReturns=\(s.nativeReturns) nativePending=\(s.nativePending) consumers=\(s.consumerPending) sessions=\(s.sessionReturns) joins=\(s.sessionJoins) nativeFactoryPending=\(s.nativeFactoryPending) factorySuccesses=\(s.nativeFactorySuccesses) enqueues=\(s.enqueues) invalid=\(invalid)")
                // COMMON diagnostic veto: preserve the REAL proposed verdict,
                // then prevent deliberately exiting while original CoreML owns work.
                backing.stop()
                trace.beginSafeCleanup()
                return false
            },
            reply: { reply in
                guard !firstReplyCaptured else { return }
                firstReplyCaptured = true
                let s = trace.snapshot()
                check("C01 Cocoa quit returns later", reply == .terminateLater)
                let qualified: Bool
                if mode == "pocket-playback-closed" { qualified = true }
                else if mode == "pocket-playback-factory" { qualified = s.nativeFactoryPending > 0 }
                else { qualified = s.nonzeroFirstPCM > 0 && s.nativePending > 0 && s.consumerPending > 0 }
                check("C02 actual input boundary is outstanding at Cocoa quit", qualified)
                if !qualified { invalid = true }
                if mode == "pocket-playback-predecessor" {
                    check("C07 successor entered before predecessor native return", s.successorBeforePredecessorReturn)
                    if !s.successorBeforePredecessorReturn { invalid = true }
                    check("C10 actual successor PCM arrived before predecessor native return", s.successorPCMBeforePredecessorReturn)
                    if !s.successorPCMBeforePredecessorReturn { invalid = true }
                }
                SelfTest.diagnostic("POCKET_PLAYBACK_TERMINATION_REPLY_TRACE mode=\(mode) pcm=\(s.nonzeroFirstPCM) nativePending=\(s.nativePending) factoryPending=\(s.factoryPending) nativeFactoryPending=\(s.nativeFactoryPending) consumers=\(s.consumerPending) successorBeforePriorReturn=\(s.successorBeforePredecessorReturn) successorPCMBeforePriorReturn=\(s.successorPCMBeforePredecessorReturn) firstPCM1ms=\(s.firstPCM1ms) firstPCM2ms=\(s.firstPCM2ms) invalid=\(invalid)")
            },
            willExit: {
                let s = trace.snapshot()
                check("C05 safe cleanup has no entered native body or caller left", s.nativePending == 0 && s.consumerPending == 0 && s.factoryPending == 0 && s.nativeFactoryPending == 0)
                check("C06 offline mode and the same prepared owner remain", ModelHub.offlineMode && voice.isReady)
                check("C08 serial Pocket path was used", !s.pipelined)
                if mode == "pocket-playback-factory" {
                    check("C09 actual native factory successfully returned its real owner", s.nativeFactorySuccesses > 0)
                    if s.nativeFactorySuccesses == 0 { invalid = true }
                }
                SelfTest.diagnostic("POCKET_PLAYBACK_TERMINATION_EXIT_TRACE mode=\(mode) checks=\(checks) failures=\(failures) invalid=\(invalid) nativeStarts=\(s.nativeStarts) nativeReturns=\(s.nativeReturns) consumers=\(s.consumerPending)")
                if invalid {
                    SelfTest.failed = true
                    SelfTest.diagnostic("POCKET_PLAYBACK_TERMINATION_INVALID: actual overlap unavailable")
                } else {
                    SelfTest.diagnostic(failures == 0
                        ? "POCKET_PLAYBACK_TERMINATION_OK: \(checks) checks"
                        : "POCKET_PLAYBACK_TERMINATION_FAILED: \(failures)/\(checks)")
                }
            }
        )
        SelfTest.diagnostic("POCKET_PLAYBACK_TERMINATION_INPUT_OK: actual prepared offline Pocket; synthetic muted clause")
        if mode == "pocket-playback-closed" {
            backing.beginTermination()
            backing.speak(text, volume: 0, token: 1)
            check("F08 explicitly closed backing admits no new task", !backing.terminationOwnerForTesting.pending)
            SelfTest.requestTermination()
        } else {
            backing.speak(text, volume: 0, token: 1)
        }
        return true
        #else
        // No substitute observations and no model/graph/delegate work here.
        print("POCKET_PLAYBACK_TERMINATION_UNAVAILABLE: reviewed package observation is not compiled")
        throw CocoaError(.fileReadNoPermission)
        #endif
    }
}

/// Bounded synthetic per-generation metadata only. This is not a work registry.
final class PocketPlaybackTerminationTrace: @unchecked Sendable {
    enum Action: Sendable { case firstPCM(UInt64), factoryEntered, safeCleanup }
    struct Snapshot: Sendable {
        var nativeStarts = 0; var nativeReturns = 0; var nativePending = 0
        var consumerPending = 0; var factoryPending = 0
        var nativeFactoryPending = 0; var nativeFactorySuccesses = 0
        var nonzeroFirstPCM = 0; var sessionReturns = 0; var sessionJoins = 0; var enqueues = 0
        var successorBeforePredecessorReturn = false
        var successorPCMBeforePredecessorReturn = false
        var firstPCM1ms = -1.0; var firstPCM2ms = -1.0
        var pipelined = false
    }
    private let lock = NSLock()
    private var value = Snapshot()
    private var priorNativePending = 0
    private var firstPCMSeen = Set<UInt64>()
    private var starts: [UInt64: ContinuousClock.Instant] = [:]
    private var cleanup = false
    private var cleanupScheduled = false
    private let action: @Sendable (Action) -> Void
    init(action: @escaping @Sendable (Action) -> Void) { self.action = action }
    func snapshot() -> Snapshot { lock.withLock { value } }
    func consumerEntered(token: UInt64) {
        lock.withLock {
            value.consumerPending += 1
            if token <= 3 { starts[token] = ContinuousClock.now }
            if token == 2 { value.successorBeforePredecessorReturn = priorNativePending > 0 }
        }
    }
    func consumerReturned(token: UInt64) { lock.withLock { value.consumerPending -= 1 }; notifyCleanup() }
    func factoryEntered(token: UInt64) {
        lock.withLock { value.factoryPending += 1 }
    }
    func factoryReturned(token: UInt64) { lock.withLock { value.factoryPending -= 1 }; notifyCleanup() }
    func sessionReturned(token: UInt64) { lock.withLock { value.sessionReturns += 1 } }
    func sessionJoined(token: UInt64) { lock.withLock { value.sessionJoins += 1 } }
    func enqueued(token: UInt64) { lock.withLock { value.enqueues += 1 } }
    func firstPCM(token: UInt64, nonzero: Bool) {
        let first = lock.withLock { () -> Bool in
            guard token <= 3, nonzero, firstPCMSeen.insert(token).inserted else { return false }
            if nonzero { value.nonzeroFirstPCM += 1 }
            if token == 2 { value.successorPCMBeforePredecessorReturn = priorNativePending > 0 }
            if let start = starts[token] {
                let components = start.duration(to: .now).components
                let ms = Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
                if token == 1 { value.firstPCM1ms = ms }
                if token == 2 { value.firstPCM2ms = ms }
            }
            return true
        }
        if first { action(.firstPCM(token)) }
    }
    #if NEXTNOTES_POCKET_OBSERVATION
    func nativeObserver(token: UInt64) -> @Sendable (PocketTtsSynthesizer.StreamLifecycleEvent) -> Void {
        { [self] event in
            var requestFactoryQuit = false
            lock.withLock {
                switch event {
                case .factoryEntered:
                    value.nativeFactoryPending += 1
                    requestFactoryQuit = token == 1
                case .factoryReturned(let succeeded):
                    value.nativeFactoryPending -= 1
                    if succeeded { value.nativeFactorySuccesses += 1 }
                case .bodyEntered(let pipelined):
                    value.nativeStarts += 1; value.nativePending += 1
                    value.pipelined = value.pipelined || pipelined
                    if token == 1 { priorNativePending += 1 }
                case .bodyReturned:
                    value.nativeReturns += 1; value.nativePending -= 1
                    if token == 1 { priorNativePending -= 1 }
                case .streamTerminated:
                    break // termination is not native completion
                }
            }
            if requestFactoryQuit { action(.factoryEntered) }
            notifyCleanup()
        }
    }
    #endif
    func beginSafeCleanup() { lock.withLock { cleanup = true }; notifyCleanup() }
    private func notifyCleanup() {
        let schedule = lock.withLock { () -> Bool in
            guard cleanup, !cleanupScheduled, value.nativePending == 0,
                  value.consumerPending == 0, value.factoryPending == 0,
                  value.nativeFactoryPending == 0 else { return false }
            cleanupScheduled = true
            return true
        }
        if schedule { action(.safeCleanup) }
    }
}

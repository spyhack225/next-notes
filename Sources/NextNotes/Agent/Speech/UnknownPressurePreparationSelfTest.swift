import Foundation

@MainActor enum UnknownPressurePreparationSelfTest {
    /// The pressure reader alone is substituted; timer/admission notifications,
    /// actual optional preparation owner and compute scheduler are production code.
    static func run() async -> [String] {
        let reader = Reader()
        let guardian = ModelResidencyGuardian(releaseForTesting: {}, readPressureForTesting: { reader.read() })
        guardian.startIfNeeded()
        let owner = PocketAgentVoice()
        owner.schedulerForTesting = ComputeScheduler()
        owner.pressureForTesting = { guardian.snapshot }
        let kokoro = KokoroAgentVoice()
        kokoro.schedulerForTesting = ComputeScheduler()
        kokoro.pressureForTesting = { guardian.snapshot }
        var kokoroLoads = 0
        kokoro.initializeForTesting = { kokoroLoads += 1 }
        var loads = 0, warms = 0
        owner.initializeForTesting = { loads += 1 }
        owner.warmForTesting = { warms += 1 }
        var failures: [String] = []
        await owner.prepareAutomatically()
        await kokoro.prepare(automatic: true)
        if owner.isReady || !owner.isPreparing || loads != 0 || warms != 0 || reader.count != 1 {
            failures.append("R4: unreadable cold seed did not defer actual owner")
        }
        // No injected normal event. The real bounded re-observation must retry
        // unreadable reads and notify the existing deferred owner itself.
        for _ in 0..<700 where !owner.isReady || (KokoroAgentVoice.isSupportedOS && !kokoro.isReady) { try? await Task.sleep(for: .milliseconds(10)) }
        if KokoroAgentVoice.isSupportedOS && (!kokoro.isReady || kokoroLoads != 1 || kokoro.isPreparing) {
            failures.append("R4: unreadable seed stranded Kokoro automatic preparation without kernel event")
        }
        if reader.count < 3 || loads != 1 || warms != 1 || !owner.isReady || owner.isPreparing {
            failures.append("R4: unreadable seed stranded automatic preparation without kernel event")
        }
        if owner.errorMessage != nil { failures.append("R4: unknown pressure became a model failure") }
        let resolvedReads = reader.count
        try? await Task.sleep(for: .milliseconds(2300))
        if reader.count != resolvedReads { failures.append("R4: resolved pressure kept polling") }
        owner.beginTermination(); await owner.finishTermination()
        // A real event resolves unknown immediately and retires its retry;
        // the guardian must neither overrule that event nor infer normal.
        let eventReader = Reader()
        let eventGuardian = ModelResidencyGuardian(releaseForTesting: {}, readPressureForTesting: { eventReader.read() })
        eventGuardian.startIfNeeded()
        eventGuardian.receive(.critical)
        try? await Task.sleep(for: .milliseconds(2300))
        if eventReader.count != 1 || eventGuardian.snapshot.allowsOptionalWork {
            failures.append("R4: kernel critical event did not retire unknown retry")
        }
        return failures
    }
    private final class Reader: @unchecked Sendable {
        private let lock = NSLock()
        private var reads = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return reads }
        func read() -> ModelResidencyPolicy.PressureLevel? {
            lock.lock(); defer { lock.unlock() }
            reads += 1
            return reads < 3 ? nil : .normal
        }
    }
}

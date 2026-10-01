import Foundation

/// Scripted pressure proves production policy wiring, not physical memory savings.
/// Every runtime/guardian is private; no owner selection, model load or store changes.
enum MeetingResourcePolicySelfTest {
    static func run() async -> Bool {
        var failures: [String] = []
        func expect(_ value: Bool, _ message: String) {
            if !value { failures.append(message) }
        }
        let guardian = ModelResidencyGuardian(releaseForTesting: {})
        let runtime = NotesModelRuntime(
            spec: NotesModels.spec, gpuLayers: 0, pressureSnapshot: { guardian.snapshot })
        let admitted = ResourcePolicyCounter()
        await runtime.setOptionalLoadProbeForTesting { await admitted.increment() }

        // The original reload producer: an optional prepare after pressure release.
        guardian.receive(.warning)
        expect(!guardian.snapshot.allowsOptionalWork, "warning not visible synchronously")
        let warningAdmitted = await runtime.prepareForOptionalUse()
        expect(!warningAdmitted, "warning admitted optional weights")
        guardian.receive(.critical)
        let criticalAdmitted = await runtime.prepareForOptionalUse()
        expect(!criticalAdmitted, "critical admitted optional weights")
        expect(await admitted.count == 0, "pressure reached heavy optional load")
        guardian.receive(.normal)
        expect(guardian.snapshot.allowsOptionalWork, "normal did not reopen admission")
        expect(await runtime.prepareForOptionalUse(), "normal suppressed optional prepare")
        expect(await admitted.count == 1, "normal did not reach production load seam")

        // A load admitted before scheduler waiting must recheck when its lane resumes.
        let asrID = await ComputeScheduler.shared.acquire(.realtimeASR)
        let delayed = Task { await runtime.prepareForOptionalUse() }
        for _ in 0..<100 {
            if await runtime.isResidentOrBusy { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let reserved = await runtime.isResidentOrBusy
        guardian.receive(.warning)
        await ComputeScheduler.shared.release(asrID)
        expect(reserved, "delayed optional fixture never reserved native owner")
        expect(!(await delayed.value), "delayed prepare ignored pressure after scheduler wait")
        expect(await admitted.count == 1, "delayed prepare reached load while pressure persisted")

        // Speculative Agent intent uses the same state and rechecks after route await.
        guardian.receive(.normal)
        let gate = ResourcePolicyGate()
        let warmed = ResourcePolicyCounter()
        await runtime.setPrewarmProbeForTesting(.init(
            isModelAvailable: { true },
            isLocalRoute: { _ in await gate.park(); return true },
            onPrewarm: { await warmed.increment() }))
        let warm = runtime.prewarm()
        for _ in 0..<100 {
            if await gate.started { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        expect(await gate.started, "prewarm route fixture never started")
        guardian.receive(.critical)
        await gate.release()
        await warm.value
        expect(await warmed.count == 0, "pressure during route await admitted prewarm")
        await runtime.prewarm().value
        expect(await warmed.count == 0, "pressure immediately reloaded evicted prewarm")
        guardian.receive(.normal)
        await runtime.prewarm().value
        expect(await warmed.count == 1, "normal did not restore intent prewarm")

        // Pressure that arrives after admission makes the speculative operation
        // unwind before claiming successful preparation.
        await runtime.setOptionalLoadProbeForTesting {
            guardian.receive(.warning)
            await admitted.increment()
        }
        expect(!(await runtime.prepareForOptionalUse()), "late pressure reported optional preparation success")
        expect(await admitted.count == 2, "late-pressure fixture missed load seam")

        // Repeated kernel events share one release pass while native/actor teardown
        // is waiting. Snapshot changes remain visible without waiting for that pass.
        let releaseGate = ResourcePolicyGate()
        let releases = ResourcePolicyCounter()
        let coalesced = ModelResidencyGuardian(releaseForTesting: {
            await releases.increment()
            await releaseGate.park()
        })
        coalesced.receive(.warning)
        for _ in 0..<100 {
            if await releaseGate.started { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        expect(await releaseGate.started, "pressure release task never started")
        coalesced.receive(.critical)
        coalesced.receive(.warning)
        expect(coalesced.snapshot.level == .warning, "coalescing lost latest pressure")
        expect(await releases.count == 1, "concurrent pressure spawned duplicate release pass")
        coalesced.receive(.normal)
        expect(coalesced.snapshot.allowsOptionalWork, "release wait blocked normal admission")
        await releaseGate.release()

        // Required work still reaches its real loader; use an absent file so no native
        // model can load even if this machine has the built-in model installed.
        let missing = ModelSpec(
            displayName: "Pressure fixture", fileName: "missing-\(UUID().uuidString).gguf",
            url: URL(fileURLWithPath: "/nonexistent"), expectedBytes: 1, expectedSHA256: nil)
        let required = NotesModelRuntime(
            spec: missing, gpuLayers: 0, pressureSnapshot: { guardian.snapshot })
        guardian.receive(.critical)
        do { try await required.prepare() } catch { }
        expect(await required.loadAttemptCount == 1, "pressure policy gated required work")
        expect(await NotesModelRuntime.pressureOwnershipSelfTest(),
               "pressure did not protect active operation/lease or preserve deferred reason")

        for failure in failures { print("MEETING_RESOURCE_POLICY_WRONG: \(failure)") }
        print(failures.isEmpty ? "MEETING_RESOURCE_POLICY_OK" : "MEETING_RESOURCE_POLICY_FAILED")
        return failures.isEmpty
    }
}

private actor ResourcePolicyCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

private actor ResourcePolicyGate {
    private(set) var started = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func park() async {
        started = true
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

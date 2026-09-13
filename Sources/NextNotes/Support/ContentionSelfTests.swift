import AVFoundation
import Foundation

/// Wave 2-Stress S5 — resource-contention probes that need no microphone.
///
/// Roadmap §38 tests A–D, exercised against the seams that already exist
/// without hardware: `AudioCaptureHub` (probe mode), `ComputeScheduler`,
/// `RealtimeAudioSession` + a recording TTS backing, and `ACPConfirmation`.
///
/// What this deliberately does **not** claim:
///
/// - Real meeting ASR latency under notes load (needs Parakeet + Qwen).
/// - Lost microphone frames during barge-in (needs a live tap).
/// - Dictation e2e latency while an ACP coding task runs (needs both paths live).
///
/// Never calls `RunLog.record`.
///
/// Wire with `--selftest-contention` in `NextNotesApp.runRequestedSelfTest`
/// when that file is free:
/// ```
/// if arguments.contains("--selftest-contention") {
///     Task { @MainActor in
///         await ContentionSelfTests.runSelfTest()
///         NSApp.terminate(nil)
///     }
///     return true
/// }
/// ```
enum ContentionSelfTests {
    /// Prints `CONTENTION_WRONG:` lines, then `CONTENTION_OK` / `CONTENTION_FAILED` last.
    @MainActor
    static func runSelfTest() async {
        var failures: [String] = []

        failures += meetingAndWakeHubFailures()
        failures += await backgroundYieldsToASRFailures()
        failures += bargeInStopsSpeechFailures()
        failures += missingHarnessRequiresConfirmFailures()

        for failure in failures {
            print("CONTENTION_WRONG: \(failure)")
        }
        print(failures.isEmpty ? "CONTENTION_OK" : "CONTENTION_FAILED")
    }

    // MARK: - A · Meeting + wake share one hub seat

    /// Meeting and wake can both be subscribed; the input engine starts once.
    /// A dictation seat joining them must not start a second engine.
    @MainActor
    private static func meetingAndWakeHubFailures() -> [String] {
        var failures: [String] = []
        guard let format = pcm16kMono() else {
            return ["A: no 16 kHz format for hub probe"]
        }

        let hub = AudioCaptureHub(probe: true)
        let sink: @Sendable (AudioChunk) -> Void = { _ in }
        let level: @Sendable (Float) -> Void = { _ in }

        do {
            try hub.subscribe(.wake, outputFormat: format, onBuffer: sink, onLevel: level)
            try hub.subscribe(.meeting, outputFormat: format, onBuffer: sink, onLevel: level)
        } catch {
            failures.append("A: subscribe failed: \(error.localizedDescription)")
            return failures
        }

        if !hub.isSubscribed(.wake) || !hub.isSubscribed(.meeting) {
            failures.append("A: meeting + wake were not both on the hub")
        }
        if hub.inputEngineStarts != 1 {
            failures.append(
                "A: overlapping consumers started \(hub.inputEngineStarts) input engines (want 1)"
            )
        }
        if !hub.isRunning {
            failures.append("A: hub not running while meeting + wake are subscribed")
        }

        // Cross-check: a dictation attempt must share the same engine, not steal it.
        do {
            try hub.subscribe(.dictation, outputFormat: format, onBuffer: sink, onLevel: level)
        } catch {
            failures.append("A: dictation subscribe failed: \(error.localizedDescription)")
        }
        if hub.inputEngineStarts != 1 {
            failures.append(
                "A: dictation join started a second input engine (starts=\(hub.inputEngineStarts))"
            )
        }
        if !hub.isSubscribed(.wake) || !hub.isSubscribed(.meeting) {
            failures.append("A: dictation join dropped meeting or wake")
        }

        hub.unsubscribe(.dictation)
        hub.unsubscribe(.meeting)
        hub.unsubscribe(.wake)
        return failures
    }

    // MARK: - B · Notes / background yields to realtime ASR

    /// A notes-class job already running must yield when `realtimeASR` is queued.
    private static func backgroundYieldsToASRFailures() async -> [String] {
        var failures: [String] = []

        let scheduler = ComputeScheduler()
        await scheduler.submit(ComputeJob(workClass: .background))
        await scheduler.submit(ComputeJob(workClass: .realtimeASR))

        if await !scheduler.didYield(.background, to: .realtimeASR) {
            failures.append("B: background job did not yield when realtimeASR was queued")
        }
        let order = await scheduler.recordedOrder
        if order.first != .background {
            failures.append("B: background job did not start before realtimeASR arrived")
        }
        if !order.contains(.realtimeASR) {
            failures.append("B: realtimeASR never started after being queued")
        }

        // Control: ASR must not yield to notes.
        let reverse = ComputeScheduler()
        await reverse.submit(ComputeJob(workClass: .realtimeASR))
        await reverse.submit(ComputeJob(workClass: .background))
        if await reverse.didYield(.realtimeASR, to: .background) {
            failures.append("B: realtimeASR yielded to a background notes job")
        }

        return failures
    }

    // MARK: - C · TTS barge-in stops speech

    /// User speech / interrupt must stop the synthesizer without awaiting the
    /// utterance. Uses a recording backing — no speaker, no microphone.
    @MainActor
    private static func bargeInStopsSpeechFailures() -> [String] {
        var failures: [String] = []
        let session = RealtimeAudioSession.shared
        let recorder = RecordingSpeechBacking()
        let synth = AgentSpeechSynthesizer.shared
        synth.useTestingBacking(recorder)
        defer {
            synth.restoreSystemBacking()
            session.end()
        }

        session.begin()
        session.speak("I found three files.")
        if !session.isSpeaking || session.phase != .speaking {
            failures.append("C: speak did not enter speaking phase")
        }
        if recorder.spoken.isEmpty {
            failures.append("C: speak did not enqueue TTS")
        }

        let before = ContinuousClock.now
        session.noteUserSpeech()
        let elapsed = before.duration(to: .now)
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18

        if !synth.didStop || recorder.stopCount == 0 {
            failures.append("C: barge-in did not stop synthesizer")
        }
        if session.isSpeaking {
            failures.append("C: speaking flag still set after barge-in")
        }
        if session.phase != .listening {
            failures.append(
                "C: phase was \(session.phase.rawValue) after barge-in, expected listening"
            )
        }
        if seconds > 0.1 {
            failures.append(
                String(format: "C: barge-in stop took %.3fs (budget 0.100s)", seconds)
            )
        }

        recorder.reset()
        session.speak("Still listening.")
        RealtimeAgent.shared.interrupt()
        if !synth.didStop || recorder.stopCount == 0 {
            failures.append("C: RealtimeAgent.interrupt did not stop synthesizer")
        }

        return failures
    }

    // MARK: - D · Missing ACP harness requires confirm before local tools

    /// An unavailable named CLI must not run local tools until [Run once].
    @MainActor
    private static func missingHarnessRequiresConfirmFailures() -> [String] {
        var failures: [String] = []

        AgentHarnessRouter.shared.resetForTesting()
        AgentHarnessRouter.shared.availabilityProbe = { _ in false }
        ACPConfirmationGate.shared.resetForTesting()
        defer {
            AgentHarnessRouter.shared.restorePersistence()
            ACPConfirmationGate.shared.resetForTesting()
        }

        let utterance = "use claude code to investigate this repo"
        let named = AgentHarnessRouter.shared.choose(for: utterance)

        if named.id != .claude {
            failures.append("D: unavailable Claude pick did not stay on the ACP harness")
        }
        if !named.needsACPConfirmation {
            failures.append("D: missing CLI did not ask for confirmation")
        }
        if ACPConfirmation.allowsLocalTools(named, outcome: .pending)
            || ACPConfirmation.allowsLocalTools(named, outcome: .notRequired)
            || ACPConfirmation.allowsLocalTools(named, outcome: .cancelled) {
            failures.append(
                "D: unavailable CLI ran local tools without a confirmation outcome"
            )
        }
        if !ACPConfirmation.allowsLocalTools(named, outcome: .confirmedOnce) {
            failures.append("D: confirming once still refused local tools")
        }
        if ACPConfirmationGate.shared.pending == nil
            || ACPConfirmationGate.shared.lastOutcome != .pending {
            failures.append("D: confirm card was not parked for a missing CLI")
        }
        if ACPConfirmation.voiceEntryAction(named) != .awaitConfirmation {
            failures.append(
                "D: voice entry ran local or started ACP without a confirmation outcome"
            )
        }
        if ACPConfirmation.entryAction(named, outcome: .confirmedOnce) != .runLocalOnce {
            failures.append("D: [Run once] did not become runLocalOnce")
        }

        return failures
    }

    // MARK: - Helpers

    private static func pcm16kMono() -> AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )
    }
}

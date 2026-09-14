import AVFoundation
import Foundation

/// Agent duplex I/O façade: capture stays on `AudioCaptureHub`, TTS plays out,
/// and user speech interrupts playback without waiting for the utterance to end.
///
/// ## Echo / AEC
/// Full acoustic echo cancellation needs voice processing on a shared
/// `AVAudioEngine` that both captures and plays. Agent TTS uses
/// `AVSpeechSynthesizer` or an output-only Pocket player, so true AEC is
/// out of reach without private APIs or routing every utterance through the
/// hub engine (Kokoro/Piper later). This session therefore does:
///
/// 1. **Interrupt-on-VAD** — user speech stops TTS immediately (`.immediate`)
///    and clears every pending clause in the speak queue.
/// 2. **Optional output ducking** — while speaking, utterance volume is lowered
///    so speaker→mic bleed is less likely to false-trigger VAD.
///
/// ## Streaming spoken replies
/// Prefer `beginSpokenReply` / `appendSpokenReply` / `finalizeSpokenReply` when
/// tokens arrive while generation is in flight. `speak(_:)` is the convenience
/// for a finished string: one append + finalize through the same buffer.
/// Producers with no token stream yet must still go through that path so the
/// seam is exercised; when a real stream exists, call `append` per chunk.
///
/// Dictation never opens this session and never speaks. The agent tool loop
/// does not await utterance completion — `speak` / first `append` that yields
/// a clause returns at once after enqueueing.
///
/// Turn boundaries, tools and harness stay on `RealtimeAgent` /
/// `AgentCaptureController`. A fuller `RealtimeRuntime` can absorb those later;
/// this type is the duplex audio start (roadmap §24).
@MainActor
final class RealtimeAudioSession {
    static let shared = RealtimeAudioSession()

    enum Phase: String, Sendable {
        case idle
        case listening
        case speaking
    }

    /// Lowered playback while the agent is speaking. Best-effort ducking only.
    static let duckedVolume: Float = 0.65
    static let fullVolume: Float = 1.0

    private(set) var phase: Phase = .idle
    private(set) var isActive = false
    /// True between first spoken clause and the next `stop` / barge-in / natural
    /// end of the last clause.
    private(set) var isSpeaking = false
    /// When false, speak uses full volume (tests / Settings later).
    var duckingEnabled = true

    /// Last barge-in → TTS stopped interval, for metrics / self-test.
    private(set) var lastBargeInStopSeconds: TimeInterval?

    /// Clause-by-clause flush while reply text is still growing.
    private let speechBuffer = StreamingSpeechBuffer()

    private init() {}

    // MARK: - Session lifecycle

    /// Agent listen opened. Capture still starts on the hub via
    /// `AgentCaptureController` — this only tracks duplex phase.
    func begin() {
        isActive = true
        isSpeaking = false
        phase = .listening
        speechBuffer.cancel()
        AgentSpeechSynthesizer.shared.utteranceVolume = Self.fullVolume
        lastBargeInStopSeconds = nil
        Log.agent.info("duplex · begin")
    }

    /// Session closed. Stops any in-flight utterance and clears pending clauses.
    func end() {
        stopOutput()
        isActive = false
        phase = .idle
        AgentSpeechSynthesizer.shared.utteranceVolume = Self.fullVolume
        Log.agent.info("duplex · end")
    }

    // MARK: - Output

    /// Start a streamed spoken reply. Clears any prior utterance.
    /// Call `appendSpokenReply` as text grows, then `finalizeSpokenReply`.
    func beginSpokenReply() {
        speechBuffer.begin()
        applySpeakingVolumeIfActive()
    }

    /// Feed partial reply text. Completed clauses enqueue immediately when
    /// policy allows; silent forms (URL / listing / …) enqueue nothing.
    func appendSpokenReply(_ chunk: String) {
        speechBuffer.append(chunk)
        noteEnqueueIfNeeded()
    }

    /// Flush any trailing incomplete clause. Safe to call after a single
    /// full-string `appendSpokenReply`.
    func finalizeSpokenReply() {
        speechBuffer.finalize()
        noteEnqueueIfNeeded()
    }

    /// Speak a finished reply without blocking. Routes through the streaming
    /// buffer (begin → append → finalize) so one-shot and token-stream paths
    /// share the same queue. Empty spoken forms are a no-op and do not
    /// interrupt whatever is already playing.
    func speak(_ reply: String) {
        guard !AgentSpeechPolicy.spokenClauses(reply).isEmpty else { return }
        beginSpokenReply()
        appendSpokenReply(reply)
        finalizeSpokenReply()
    }

    /// Last clause finished — keep phase honest when idle.
    func noteOutputFinished() {
        guard isSpeaking else { return }
        isSpeaking = false
        if isActive { phase = .listening }
        AgentSpeechSynthesizer.shared.utteranceVolume = Self.fullVolume
    }

    // MARK: - Barge-in

    /// User speech / `RealtimeAgent.interrupt`: stop TTS immediately and clear
    /// every pending clause. Does not cancel an in-flight tool —
    /// `AgentCaptureController` still calls `RealtimeAgent.interrupt()` when
    /// the mode is `.agentWorking`.
    func noteUserSpeech() {
        let wasSpeaking = isSpeaking || AgentSpeechSynthesizer.shared.isSpeaking
        let started = ContinuousClock.now
        stopOutput()
        if wasSpeaking {
            let elapsed = started.duration(to: .now)
            lastBargeInStopSeconds = Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18
            Log.agent.info(
                "duplex · barge-in stop \(self.lastBargeInStopSeconds ?? -1, format: .fixed(precision: 4))s"
            )
        }
        if isActive {
            phase = .listening
        }
    }

    private func stopOutput() {
        speechBuffer.cancel()
        AgentSpeechSynthesizer.shared.stop()
        isSpeaking = false
        AgentSpeechSynthesizer.shared.utteranceVolume = Self.fullVolume
    }

    private func applySpeakingVolumeIfActive() {
        guard isActive else { return }
        AgentSpeechSynthesizer.shared.utteranceVolume =
            duckingEnabled ? Self.duckedVolume : Self.fullVolume
    }

    private func noteEnqueueIfNeeded() {
        guard speechBuffer.didEnqueue else { return }
        if isActive {
            isSpeaking = true
            phase = .speaking
            applySpeakingVolumeIfActive()
        } else {
            // Test / closed session: still allow one-shot speak for island Stop,
            // but do not claim duplex speaking state.
            isSpeaking = false
        }
    }
}

// MARK: - Self-test

extension RealtimeAudioSession {
    /// Duplex invariants. Never calls `RunLog.record`. Not wired into
    /// `NextNotesApp` — invoke directly or park `--selftest-duplex` later:
    /// ```
    /// if arguments.contains("--selftest-duplex") {
    ///     Task { @MainActor in
    ///         await RealtimeAudioSession.runSelfTest()
    ///         NSApp.terminate(nil)
    ///     }
    ///     return true
    /// }
    /// ```
    @discardableResult
    static func runSelfTest() async -> Bool {
        var failures: [String] = []

        failures += bargeInFailures()
        failures += firstAudioCallbackFailures()
        failures += await singleInputEngineFailures()
        failures += speakingStateFailures()
        failures += dictationStaysSilentFailures()

        for failure in failures {
            print("DUPLEX_WRONG: \(failure)")
        }
        print(failures.isEmpty ? "DUPLEX_OK" : "DUPLEX_FAILED")
        return failures.isEmpty
    }

    /// Interrupt must stop the synthesizer backing without awaiting utterance end,
    /// and clear any remaining clause queue mid-reply.
    private static func bargeInFailures() -> [String] {
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
            failures.append("speak did not enter speaking phase")
        }
        if recorder.spoken.isEmpty {
            failures.append("speak did not enqueue TTS")
        }

        let before = ContinuousClock.now
        session.noteUserSpeech()
        let elapsed = before.duration(to: .now)
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18

        if !synth.didStop || recorder.stopCount == 0 {
            failures.append("interrupt did not stop synthesizer")
        }
        if session.isSpeaking {
            failures.append("speaking flag still set after barge-in")
        }
        if session.phase != .listening {
            failures.append("phase was \(session.phase.rawValue) after barge-in, expected listening")
        }
        if seconds > 0.1 {
            failures.append(
                String(format: "barge-in stop took %.3fs (budget 0.100s)", seconds)
            )
        }

        // Agent interrupt hook must still stop TTS (Wave 1 path).
        recorder.reset()
        session.speak("Still listening.")
        RealtimeAgent.shared.interrupt()
        if !synth.didStop || recorder.stopCount == 0 {
            failures.append("RealtimeAgent.interrupt did not stop synthesizer")
        }

        // Clause queue: multi-sentence reply leaves pending clauses; barge-in clears them.
        recorder.reset()
        session.begin()
        session.speak("I found three files. The latest is enclosure version seventeen.")
        if recorder.spoken != ["I found three files."] {
            failures.append(
                "clause stream should speak first clause only, got \(recorder.spoken)"
            )
        }
        if synth.pendingClauseCount < 1 {
            failures.append(
                "clause stream should leave pending clauses, got \(synth.pendingClauseCount)"
            )
        }
        session.noteUserSpeech()
        if synth.pendingClauseCount != 0 {
            failures.append(
                "barge-in left \(synth.pendingClauseCount) pending clauses"
            )
        }
        if recorder.spoken.count != 1 {
            failures.append(
                "barge-in must not speak remaining clauses, got \(recorder.spoken)"
            )
        }

        return failures
    }

    /// First-audio timing must stay open after enqueue, and an interrupted
    /// utterance's late delegate event must not close the next reply's span.
    /// The recorder supplies deterministic backing while explicit tokens model
    /// the AVSpeech delegate identity that production carries.
    private static func firstAudioCallbackFailures() -> [String] {
        var failures: [String] = []
        let recorder = RecordingSpeechBacking()
        let synth = AgentSpeechSynthesizer.shared
        synth.useTestingBacking(recorder)
        synth.onFirstAudio = nil
        synth.onFirstAudioCancelled = nil
        defer { synth.restoreSystemBacking() }

        var callbackCount = 0
        synth.onFirstAudio = { callbackCount += 1 }
        synth.speak("First reply.")
        let oldToken = synth.outputGeneration
        if callbackCount != 0 {
            failures.append("first-audio callback ran during enqueue")
        }

        synth.stop()
        var cancelledCount = 0
        synth.speak("Replacement reply.")
        let newToken = synth.outputGeneration
        synth.onFirstAudio = { callbackCount += 1 }
        synth.onFirstAudioCancelled = { cancelledCount += 1 }
        synth.notifyTestingFirstAudio(token: oldToken)
        if callbackCount != 0 {
            failures.append("stale first-audio callback closed the replacement reply")
        }
        synth.notifyTestingFirstAudio(token: newToken)
        synth.notifyTestingFirstAudio(token: newToken)
        if callbackCount != 1 {
            failures.append("current first-audio callback fired \(callbackCount) times, expected once")
        }

        // A pending callback is closed exactly once when barge-in cancels it.
        synth.speak("Cancelled reply.")
        synth.onFirstAudio = { callbackCount += 1 }
        synth.onFirstAudioCancelled = { cancelledCount += 1 }
        synth.stop()
        if cancelledCount != 1 {
            failures.append("first-audio cancellation callback fired \(cancelledCount) times, expected once")
        }
        return failures
    }

    /// Agent + another hub consumer must share one input engine start.
    private static func singleInputEngineFailures() async -> [String] {
        var failures: [String] = []
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        )
        guard let format else {
            return ["no 16 kHz format for hub probe"]
        }

        let hub = AudioCaptureHub(probe: true)
        let sink: @Sendable (AudioChunk) -> Void = { _ in }
        let level: @Sendable (Float) -> Void = { _ in }

        do {
            try hub.subscribe(.wake, outputFormat: format, onBuffer: sink, onLevel: level)
            try hub.subscribe(.agent, outputFormat: format, onBuffer: sink, onLevel: level)
        } catch {
            failures.append("hub subscribe failed: \(error.localizedDescription)")
            return failures
        }

        if hub.inputEngineStarts != 1 {
            failures.append(
                "agent capture would start a second input engine (starts=\(hub.inputEngineStarts))"
            )
        }
        if !hub.isSubscribed(.agent) {
            failures.append("agent consumer missing on shared hub")
        }
        if !hub.isSubscribed(.wake) {
            failures.append("wake consumer dropped when agent subscribed")
        }

        hub.unsubscribe(.agent)
        hub.unsubscribe(.wake)
        return failures
    }

    private static func speakingStateFailures() -> [String] {
        var failures: [String] = []
        let session = RealtimeAudioSession.shared
        let recorder = RecordingSpeechBacking()
        let synth = AgentSpeechSynthesizer.shared
        synth.useTestingBacking(recorder)
        defer {
            synth.restoreSystemBacking()
            session.end()
        }

        if session.isActive {
            session.end()
        }
        if session.phase != .idle {
            failures.append("inactive session phase is \(session.phase.rawValue), expected idle")
        }

        session.begin()
        if session.phase != .listening {
            failures.append("begin did not enter listening")
        }
        if session.duckingEnabled,
           abs(synth.utteranceVolume - Self.fullVolume) > 0.01 {
            failures.append("listening should restore full utterance volume")
        }

        session.speak("I found three files.")
        if session.duckingEnabled,
           abs(synth.utteranceVolume - Self.duckedVolume) > 0.01 {
            failures.append(
                "speaking should duck utterance volume to \(Self.duckedVolume), got \(synth.utteranceVolume)"
            )
        }

        session.end()
        if session.isActive || session.isSpeaking || session.phase != .idle {
            failures.append("end did not clear duplex state")
        }
        return failures
    }

    /// Dictation must never open the duplex session or speak through it.
    private static func dictationStaysSilentFailures() -> [String] {
        var failures: [String] = []
        let session = RealtimeAudioSession.shared
        if session.isActive {
            failures.append("duplex session left active after prior test")
        }
        // Policy: long listings stay silent — synthesizer must not enqueue them.
        let recorder = RecordingSpeechBacking()
        let synth = AgentSpeechSynthesizer.shared
        synth.useTestingBacking(recorder)
        defer { synth.restoreSystemBacking() }

        let listing = """
            - /Users/me/a.step
            - /Users/me/b.step
            - /Users/me/c.step
            - /Users/me/d.txt
            """
        session.begin()
        session.speak(listing)
        if session.isSpeaking || !recorder.spoken.isEmpty {
            failures.append("long listing must stay silent on duplex speak")
        }
        session.end()
        return failures
    }
}

import AVFoundation
import Foundation

/// Agent duplex I/O façade: capture stays on `AudioCaptureHub`, TTS plays out,
/// and user speech interrupts playback without waiting for the utterance to end.
///
/// ## Echo / AEC
/// Qwen routes input and output through one VoiceProcessingIO audio unit, so
/// playback is a reference for acoustic echo cancellation. Agent TTS currently
/// uses AVSpeechSynthesizer or a separate output player; this app does not yet
/// have that shared reference. This session therefore does:
///
/// 1. **Transcript-confirmed interruption** — novel ASR text stops TTS
///    immediately and clears every pending clause in the speak queue.
/// 2. **Optional output ducking** — while speaking, utterance volume is lowered
///    so speaker→mic bleed is less likely to false-trigger VAD.
/// 3. **Recent playback echo filtering** — reflected words are removed from
///    cumulative ASR, including a real interruption mixed with speaker bleed.
///
/// ## Streaming spoken replies
/// Prefer `beginSpokenReply` / `appendSpokenReply` / `finalizeSpokenReply` when
/// tokens arrive while generation is in flight. `speak(_:)` is the convenience
/// for a finished string: one append + finalize through the same buffer.
/// Producers with no token stream yet must still go through that path so the
/// seam is exercised; the normal model-led tool loop now calls `append` as
/// answer tokens arrive.
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
    private struct OutputReference {
        var text: String
        var at: Date
    }
    private struct Word {
        var value: String
        var range: Range<String.Index>
    }
    private var recentOutputs: [OutputReference] = []
    private var recordingOutput = false
    private static let echoWindow: TimeInterval = 15
    private static let maxEchoReferences = 3
    private static let wordPattern = try! NSRegularExpression(pattern: #"[\p{L}\p{N}]+"#)

    private init() {}

    // MARK: - Session lifecycle

    /// Agent listen opened. Capture still starts on the hub via
    /// `AgentCaptureController` — this only tracks duplex phase.
    func begin() {
        isActive = true
        isSpeaking = false
        phase = .listening
        speechBuffer.cancel()
        recentOutputs.removeAll()
        recordingOutput = false
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
        recordingOutput = false
        applySpeakingVolumeIfActive()
    }

    /// Feed partial reply text. Completed clauses enqueue immediately when
    /// policy allows; silent forms (URL / listing / …) enqueue nothing.
    func appendSpokenReply(_ chunk: String) {
        speechBuffer.append(chunk)
        rememberEnqueuedOutput()
        noteEnqueueIfNeeded()
    }

    private func rememberEnqueuedOutput() {
        guard speechBuffer.didEnqueue, !speechBuffer.accumulated.isEmpty else { return }
        if recordingOutput, !recentOutputs.isEmpty {
            recentOutputs[recentOutputs.count - 1] = OutputReference(
                text: speechBuffer.accumulated, at: Date()
            )
        } else {
            recentOutputs.append(OutputReference(text: speechBuffer.accumulated, at: Date()))
            recordingOutput = true
        }
        if recentOutputs.count > Self.maxEchoReferences {
            recentOutputs.removeFirst(recentOutputs.count - Self.maxEchoReferences)
        }
    }

    /// Flush any trailing incomplete clause. Safe to call after a single
    /// full-string `appendSpokenReply`.
    func finalizeSpokenReply() {
        speechBuffer.finalize()
        rememberEnqueuedOutput()
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

    /// Keep recent replies across barge-in: SpeechAnalyzer can deliver a delayed
    /// cumulative revision after the speaker stops. This is transcript-level
    /// isolation; the mic stays live so a person can interrupt the reply.
    func isLikelyPlaybackEcho(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && userSpeechExcludingPlayback(text).isEmpty
    }

    /// Remove long contiguous spans present in our own recent replies. Preserve
    /// new speech before or after a reflected span; a whole-string containment
    /// test missed exactly that mixed case in the user's 08:31 transcript.
    func userSpeechExcludingPlayback(_ text: String, now: Date = Date()) -> String {
        var remainder = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let references = recentOutputs.filter {
            isSpeaking || AgentSpeechSynthesizer.shared.isSpeaking
                || now.timeIntervalSince($0.at) < Self.echoWindow
        }
        guard !references.isEmpty else { return remainder }
        var removedEcho = false
        for _ in 0..<Self.maxEchoReferences {
            let heard = Self.words(in: remainder)
            guard !heard.isEmpty else { return "" }
            var best: (start: Int, count: Int)?
            for reference in references {
                let spoken = Self.words(in: reference.text)
                guard !spoken.isEmpty else { continue }
                for i in heard.indices {
                    for j in spoken.indices where heard[i].value == spoken[j].value {
                        var count = 0
                        while i + count < heard.count, j + count < spoken.count,
                              heard[i + count].value == spoken[j + count].value {
                            count += 1
                        }
                        // The recognizer often releases a two-word echo such as
                        // "How would...?" as a complete turn before a third word
                        // arrives. Limit short matching to turn edges so an
                        // interior common pair is less likely to erase a user.
                        let shortEdge = count == 2
                            && (heard.count == 2 || i == 0 || i + count == heard.count)
                        if (count >= 3 || shortEdge), count > (best?.count ?? 0) {
                            best = (i, count)
                        }
                    }
                }
            }
            guard let best else { break }
            let begin = heard[best.start].range.lowerBound
            let end = heard[best.start + best.count - 1].range.upperBound
            let before = String(remainder[..<begin])
            let after = String(remainder[end...])
                .replacingOccurrences(of: #"^[\s\p{P}]+"#, with: "", options: .regularExpression)
            remainder = [before, after]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            removedEcho = true
        }
        let residue = Self.words(in: remainder)
        if residue.isEmpty { return "" }
        // One-word tails of a mixed echo are often ASR revisions of the
        // preceding clause. Never let one become a fresh tool request while
        // playback or its delayed tail is still near the microphone.
        if residue.count == 1, recentOutputs.contains(where: { reference in
            let age = now.timeIntervalSince(reference.at)
            guard removedEcho || age < Self.echoWindow else { return false }
            return Self.words(in: reference.text).contains { spoken in
                spoken.value == residue[0].value
                    // SpeechAnalyzer rendered Pocket's "audio" as "Audi." in
                    // the 09:48 recording. Only tolerate a one-edit mismatch
                    // while playback is active or its fresh tail is arriving.
                    || (residue[0].value.count >= 4 && age < 3
                        && Self.oneEditApart(residue[0].value, spoken.value))
            }
        }) {
            return ""
        }
        return remainder
    }

    private static func oneEditApart(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs), b = Array(rhs)
        guard abs(a.count - b.count) <= 1, a != b else { return false }
        var i = 0, j = 0, edits = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] {
                i += 1; j += 1
                continue
            }
            edits += 1
            guard edits <= 1 else { return false }
            if a.count >= b.count { i += 1 }
            if b.count >= a.count { j += 1 }
        }
        return edits + (a.count - i) + (b.count - j) <= 1
    }

    private static func words(in text: String) -> [Word] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return wordPattern.matches(in: text, range: range).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return Word(value: String(text[range]).lowercased(), range: range)
        }
    }

    /// Last clause finished — keep phase honest when idle.
    func noteOutputFinished() {
        guard isSpeaking else { return }
        isSpeaking = false
        if !recentOutputs.isEmpty { recentOutputs[recentOutputs.count - 1].at = Date() }
        recordingOutput = false
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
        if wasSpeaking, !recentOutputs.isEmpty {
            recentOutputs[recentOutputs.count - 1].at = Date()
        }
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
        failures += echoFilterFailures()
        failures += firstAudioCallbackFailures()
        failures += await singleInputEngineFailures()
        failures += speakingStateFailures()
        failures += dictationStaysSilentFailures()
        failures += await captureEchoEndpointFailures()

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
        if !session.isLikelyPlaybackEcho("found three files") {
            failures.append("speaker playback was not recognized as an echo")
        }
        if session.isLikelyPlaybackEcho("open the calendar") {
            failures.append("new user speech was mistaken for playback echo")
        }
        if !session.isSpeaking || session.phase != .speaking {
            failures.append("speak did not enter speaking phase")
        }
        if recorder.spoken.isEmpty {
            failures.append("speak did not enqueue TTS")
        }

        let before = ContinuousClock.now
        session.noteUserSpeech()
        if !session.isLikelyPlaybackEcho("found three files") {
            failures.append("barge-in forgot the recent playback echo")
        }
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

    private static func echoFilterFailures() -> [String] {
        var failures: [String] = []
        let session = RealtimeAudioSession.shared
        let synth = AgentSpeechSynthesizer.shared
        synth.useTestingBacking(RecordingSpeechBacking())
        defer {
            session.end()
            synth.restoreSystemBacking()
        }
        session.begin()
        session.speak("I can help you manage your calendar, draft emails, and search your files.")
        if session.userSpeechExcludingPlayback("I can help you manage your") != "" {
            failures.append("partial playback became user speech")
        }
        if session.userSpeechExcludingPlayback("I can") != "" {
            failures.append("two-word playback fragment became user speech")
        }
        if session.userSpeechExcludingPlayback("Can you hear me? I can help you manage your")
            != "Can you hear me?" {
            failures.append("mixed user speech and playback were not separated")
        }
        session.noteUserSpeech()
        session.speak("Yes, I can hear you clearly. How would you like me to help you manage your calendar?")
        if session.userSpeechExcludingPlayback(
            "calendar. Yes, I can hear you clearly. How would you like me to help you manage"
        ) != "" {
            failures.append("echo tail from consecutive replies became a new request")
        }
        if session.userSpeechExcludingPlayback("Stop. Yes, I can hear you clearly") != "Stop." {
            failures.append("short novel barge-in was removed with playback")
        }
        if session.userSpeechExcludingPlayback("How would...?") != "" {
            failures.append("09:06 two-word reply tail became a user turn")
        }
        if session.userSpeechExcludingPlayback("Open the calendar") != "Open the calendar" {
            failures.append("unrelated user request was removed as playback")
        }
        session.noteUserSpeech()
        if session.userSpeechExcludingPlayback(
            "calendar.", now: Date().addingTimeInterval(10)
        ) != "" {
            failures.append("late one-word reply revision became a user turn")
        }
        session.speak("I stopped the tool plan because it took too long.")
        session.noteUserSpeech()
        if session.userSpeechExcludingPlayback(
            "long.", now: Date().addingTimeInterval(10)
        ) != "" {
            failures.append("09:07 revised reply tail became a user turn")
        }
        if session.userSpeechExcludingPlayback("Yes, I can hear you clearly") != "" {
            failures.append("late playback tail survived after output stopped")
        }
        if session.userSpeechExcludingPlayback(
            "Yes, I can hear you clearly",
            now: Date().addingTimeInterval(Self.echoWindow + 1)
        ) != "Yes, I can hear you clearly" {
            failures.append("expired playback reference suppressed a new turn")
        }
        session.speak("I don't have ears to hear audio.")
        if session.userSpeechExcludingPlayback("Audi.") != "" {
            failures.append("09:48 one-word audio echo became a user turn")
        }
        if session.userSpeechExcludingPlayback("Stop.") != "Stop." {
            failures.append("a distinct one-word interruption was suppressed")
        }
        return failures
    }

    private static func captureEchoEndpointFailures() async -> [String] {
        var failures: [String] = []
        let capture = AgentCaptureController.shared
        let session = RealtimeAudioSession.shared
        let synth = AgentSpeechSynthesizer.shared
        synth.useTestingBacking(RecordingSpeechBacking())
        defer {
            capture.turnHandlerForTesting = nil
            session.end()
            synth.restoreSystemBacking()
        }
        var forwarded: [String] = []
        capture.turnHandlerForTesting = { forwarded.append($0) }
        await capture.beginSession(captureAudio: false)
        session.speak("I can help you manage your calendar and files.")
        capture.simulateSpeech("I can help you manage your")
        capture.simulateSilence()
        _ = await capture.considerEndpoint()
        if !forwarded.isEmpty { failures.append("reflected reply reached the Agent") }

        session.speak("I can help you manage your calendar and files.")
        capture.simulateSpeech("Can you hear me? I can help you manage your")
        capture.simulateSilence()
        _ = await capture.considerEndpoint()
        await capture.waitForActiveTurnForTesting()
        if forwarded != ["Can you hear me?"] {
            failures.append("mixed turn was not forwarded as user speech only: \(forwarded)")
        }
        await capture.endSession(source: .done)
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

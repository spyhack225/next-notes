import AVFoundation
import Foundation

/// Playback backend. Production talks to `AVSpeechSynthesizer`; the self-test
/// swaps in a recorder so interrupt can be asserted without a speaker.
@MainActor
protocol AgentSpeechBacking: AnyObject {
    var isSpeaking: Bool { get }
    func speak(_ text: String, volume: Float, token: UInt64)
    func pauseForListening()
    func resumeAfterListening()
    func stop()
}

/// `AVSpeechSynthesizer` baseline. Speaks `AgentSpeechPolicy.spokenClauses`
/// one utterance at a time, never waits for the queue to drain, and is always
/// interruptible — `stop()` cancels the current clause and clears the rest.
///
/// Dictation never calls this. The optional Pocket and Kokoro backings only
/// play audio; neither backing attaches to the input node.
@MainActor
final class AgentSpeechSynthesizer {
    enum PlaybackEvent: Equatable {
        case began(UInt64)
        case enqueued(String)
        case startAcknowledged(String)
        case completed(String)
        case interrupted(String, wasRendered: Bool)
    }
    static let shared = AgentSpeechSynthesizer()

    private var backing: any AgentSpeechBacking
    private let systemBacking = AVSpeechBacking()
    private let pocketBacking = PocketSpeechBacking()
    private let pocketSourceBacking = PocketSourceSpeechBacking()
    private let kokoroBacking = KokoroSpeechBacking()
    private var testingBacking = false
    /// A probe may keep one source graph alive for several clauses. This is
    /// selected only by the explicit self-test lifecycle below.
    private var persistentPlaybackBacking: (any AgentSpeechBacking)?
    private var persistentPlaybackUsesPocketSource = false
    private(set) var persistentPlaybackFailure: String?
    /// A failed optional voice falls back only for the current reply. The
    /// saved user preference is kept for the next request.
    private var usingSystemFallbackForReply = false
    private var deferredFallbackClause = false
    private var fallbackBackingForTesting: (any AgentSpeechBacking)?
    /// Remaining clauses after the one currently speaking (or just enqueued).
    private var pendingClauses: [String] = []
    /// Set by `stop()`. The interrupt self-test fails unless this path ran.
    private(set) var didStop = false
    private(set) var isPausedForListening = false
    /// Applied to each utterance. Duplex ducking lowers this while speaking.
    var utteranceVolume: Float = 1.0
    /// Called on the backing's first output acknowledgement. Pocket reports
    /// the first completed player buffer; Apple reports its delegate start;
    /// Kokoro reports a successful `play()`. These are different strengths of
    /// evidence and none proves the sample reached a person's ears.
    var onFirstAudio: (() -> Void)?
    /// Called when a pending first-audio callback is cancelled by barge-in.
    var onFirstAudioCancelled: (() -> Void)?
    /// Reports what the output backend acknowledged. `startAcknowledged` is
    /// backend-specific, not proof that a human heard a sample.
    var onPlaybackEvent: ((PlaybackEvent) -> Void)?
    private var currentClause: String?
    private var currentClauseRendered = false
    /// Monotonic output generation. A delegate callback from an interrupted
    /// utterance carries its old token and cannot close a new reply's span.
    private(set) var outputGeneration: UInt64 = 0
    private var playbackTokenCounter: UInt64 = 0
    private(set) var currentPlaybackToken: UInt64 = 0

    /// Clauses waiting after the current utterance. Zero when idle or after stop.
    var pendingClauseCount: Int { pendingClauses.count }

    init(backing: (any AgentSpeechBacking)? = nil) {
        self.backing = backing ?? systemBacking
        systemBacking.onUtteranceFinished = { [weak self] token in
            self?.didFinishAudio(token: token)
        }
        systemBacking.onUtteranceStarted = { [weak self] token in
            self?.didBeginAudio(token: token)
        }
        pocketBacking.onUtteranceFinished = { [weak self] token in
            self?.didFinishAudio(token: token)
        }
        pocketBacking.onUtteranceStarted = { [weak self] token in
            self?.didBeginAudio(token: token)
        }
        pocketBacking.onFailure = { [weak self] text, volume, token in
            self?.fallbackCurrentClause(text: text, token: token)
        }
        pocketSourceBacking.onUtteranceFinished = { [weak self] token in
            self?.didFinishAudio(token: token)
        }
        pocketSourceBacking.onUtteranceStarted = { [weak self] token in
            self?.didBeginAudio(token: token)
        }
        pocketSourceBacking.onFailure = { [weak self] text, volume, token in
            guard let self else { return }
            guard self.persistentPlaybackUsesPocketSource else {
                self.fallbackCurrentClause(text: text, token: token)
                return
            }
            // A source backing is used as an experimental probe. Falling back
            // to Apple here would turn a failed source run into a false pass.
            guard token == self.currentPlaybackToken else { return }
            self.persistentPlaybackFailure =
                "Pocket source playback failed for token \(token)."
            Log.agent.error(
                "Pocket source playback failed token=\(token, privacy: .public)"
            )
            SelfTest.failed = true
            self.stop()
        }
        kokoroBacking.onUtteranceFinished = { [weak self] token in
            self?.didFinishAudio(token: token)
        }
        kokoroBacking.onUtteranceStarted = { [weak self] token in
            self?.didBeginAudio(token: token)
        }
        kokoroBacking.onFailure = { [weak self] text, volume, token in
            self?.fallbackCurrentClause(text: text, token: token)
        }
        if Settings.shared.agentVoiceEngine == "pocket" {
            Task { await PocketAgentVoice.shared.prepare() }
        } else if Settings.shared.agentVoiceEngine == "kokoro" {
            if KokoroAgentVoice.isSupportedOS {
                Task { await KokoroAgentVoice.shared.prepare() }
            }
        }
    }

    var isSpeaking: Bool { backing.isSpeaking || !pendingClauses.isEmpty }

    /// Enqueue speakable clauses and return immediately. An empty form is a no-op.
    /// Replaces any in-flight reply so a newer answer never stacks under an old one.
    /// Prefer `StreamingSpeechBuffer` when text arrives in chunks; this remains
    /// the one-shot path used by tests and non-streaming callers.
    func speak(_ reply: String) {
        let clauses = AgentSpeechPolicy.spokenClauses(reply)
        guard !clauses.isEmpty else { return }
        prepareForStream()
        pendingClauses = Array(clauses.dropFirst())
        currentClause = clauses[0]
        currentClauseRendered = false
        onPlaybackEvent?(.enqueued(clauses[0]))
        for clause in pendingClauses { onPlaybackEvent?(.enqueued(clause)) }
        startClause(clauses[0])
    }

    /// Clear prior playback so a streamed reply can enqueue clauses one by one.
    /// Called by `StreamingSpeechBuffer.begin` — does not set `didStop`.
    func prepareForStream() {
        usingSystemFallbackForReply = false
        deferredFallbackClause = false
        isPausedForListening = false
        interruptCurrentClause()
        currentPlaybackToken = 0
        outputGeneration &+= 1
        onPlaybackEvent?(.began(outputGeneration))
        didStop = false
        pendingClauses.removeAll()
        if backing.isSpeaking {
            backing.stop()
        }
        if !testingBacking {
            if let persistentPlaybackBacking {
                backing = persistentPlaybackBacking
                Log.agent.info(
                    "voice playback route selected=persistent \(self.persistentPlaybackUsesPocketSource ? "pocket-source" : "fixed-wav")"
                )
            } else {
                switch Settings.shared.agentVoiceEngine {
                case "pocket":
                    backing = pocketBacking
                case "kokoro" where KokoroAgentVoice.isSupportedOS:
                    backing = kokoroBacking
                default:
                    backing = systemBacking
                }
                Log.agent.info(
                    "voice playback route selected=settings \(String(describing: type(of: self.backing)))"
                )
            }
        }
    }

    /// Append one already-split clause. Starts playback when idle; otherwise
    /// queues behind the current utterance. No-op after `stop()` until
    /// `prepareForStream` / `speak` resets.
    func enqueueClause(_ clause: String) {
        let trimmed = clause.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !didStop else { return }
        if backing.isSpeaking || !pendingClauses.isEmpty {
            pendingClauses.append(trimmed)
            onPlaybackEvent?(.enqueued(trimmed))
        } else {
            currentClause = trimmed
            currentClauseRendered = false
            onPlaybackEvent?(.enqueued(trimmed))
            startClause(trimmed)
        }
    }

    /// Barge-in / VAD / Stop. Immediate, not word-boundary. Clears every
    /// pending clause so mid-reply cut-off does not keep speaking the rest.
    /// Target <100 ms.
    func stop() {
        isPausedForListening = false
        deferredFallbackClause = false
        interruptCurrentClause()
        outputGeneration &+= 1
        currentPlaybackToken = 0
        let hadPendingAudio = onFirstAudio != nil
        didStop = true
        pendingClauses.removeAll()
        onFirstAudio = nil
        if hadPendingAudio { onFirstAudioCancelled?() }
        backing.stop()
    }

    /// Suspends the rendered player without invalidating the clause token,
    /// TTS producer, pending buffers, or queued follow-up clauses. The caller
    /// must later classify input and either resume or use the hard `stop()`.
    func pauseForListening() {
        guard !didStop, currentClause != nil, !isPausedForListening else { return }
        isPausedForListening = true
        backing.pauseForListening()
    }

    func resumeAfterListening() {
        guard isPausedForListening, !didStop else { return }
        isPausedForListening = false
        backing.resumeAfterListening()
        if deferredFallbackClause, let currentClause {
            deferredFallbackClause = false
            startClause(currentClause)
            return
        }
        // A late completion can arrive while the player is paused. In that
        // case advanceQueue held the next clause; start it only now.
        if currentClause == nil { advanceQueue() }
    }

    /// Self-test only. Restored by interrupt / stream self-tests so a later
    /// turn still uses the system voice.
    func useTestingBacking(_ backing: any AgentSpeechBacking) {
        self.backing.stop()
        testingBacking = true
        self.backing = backing
    }

    /// Prepare the experimental Pocket source renderer for a probe session.
    /// A supplied fixed WAV backing wins over the source flag and is assumed to
    /// have already been prepared by its owner (`PCMProbeSpeechBacking`
    /// follows that convention). Production calls are ignored deliberately.
    func preparePersistentPocketPlayback(
        fixedWAVOverride: (any AgentSpeechBacking)? = nil
    ) throws {
        guard SelfTest.isRunning else { return }

        if let fixedWAVOverride {
            endPersistentPocketPlayback()
            persistentPlaybackBacking = fixedWAVOverride
            persistentPlaybackUsesPocketSource = false
            persistentPlaybackFailure = nil
            Log.agent.info("voice playback route selected=fixed-wav override")
            return
        }

        guard CommandLine.arguments.contains("--voice-pocket-source") else {
            return
        }
        if persistentPlaybackUsesPocketSource,
           persistentPlaybackBacking != nil {
            return
        }

        endPersistentPocketPlayback()
        try pocketSourceBacking.prepare()
        persistentPlaybackBacking = pocketSourceBacking
        persistentPlaybackUsesPocketSource = true
        persistentPlaybackFailure = nil
        Log.agent.info("voice playback route selected=pocket-source")
    }

    /// End the probe session and release the source graph. The fixed WAV
    /// owner is stopped but not otherwise dismantled; its owner retains the
    /// `prepare/endTest` lifecycle used by the acoustic probe.
    func endPersistentPocketPlayback() {
        persistentPlaybackBacking?.stop()
        if persistentPlaybackUsesPocketSource {
            pocketSourceBacking.endSession()
        }
        persistentPlaybackBacking = nil
        persistentPlaybackUsesPocketSource = false
        persistentPlaybackFailure = nil
    }

    func restoreSystemBacking() {
        if testingBacking { backing.stop() }
        usingSystemFallbackForReply = false
        deferredFallbackClause = false
        fallbackBackingForTesting = nil
        testingBacking = false
        self.backing = persistentPlaybackBacking ?? systemBacking
        utteranceVolume = 1.0
        pendingClauses.removeAll()
        onFirstAudio = nil
        onFirstAudioCancelled = nil
        onPlaybackEvent = nil
        currentClause = nil
        currentClauseRendered = false
    }

    private func didBeginAudio(token: UInt64) {
        guard token == currentPlaybackToken, currentClause != nil else { return }
        if let currentClause, !currentClauseRendered {
            currentClauseRendered = true
            onPlaybackEvent?(.startAcknowledged(currentClause))
        }
        let callback = onFirstAudio
        onFirstAudio = nil
        callback?()
    }

    private func didFinishAudio(token: UInt64) {
        guard token == currentPlaybackToken, currentClause != nil else { return }
        if let currentClause { onPlaybackEvent?(.completed(currentClause)) }
        currentClause = nil
        currentClauseRendered = false
        advanceQueue()
    }

    /// Self-test seam for a fake backing. The token is explicit so the probe
    /// can prove an old delegate callback cannot close a new span.
    func notifyTestingFirstAudio(token: UInt64) {
        didBeginAudio(token: token)
    }

    func notifyTestingAudioFinished(token: UInt64) {
        didFinishAudio(token: token)
    }

    /// Next clause after the current utterance finishes. No-op after `stop()`
    /// or when the queue is empty (then duplex phase returns to listening).
    func advanceQueue() {
        guard !didStop else { return }
        guard !isPausedForListening else { return }
        guard !pendingClauses.isEmpty else {
            RealtimeAudioSession.shared.noteOutputFinished()
            return
        }
        let next = pendingClauses.removeFirst()
        currentClause = next
        currentClauseRendered = false
        startClause(next)
    }

    private func startClause(_ clause: String) {
        playbackTokenCounter &+= 1
        currentPlaybackToken = playbackTokenCounter
        let detail = String(format: "Voice clause start %.3f token=%llu backing=%@ characters=%d",
                            Date().timeIntervalSince1970, currentPlaybackToken,
                            String(describing: type(of: self.backing)), clause.count)
        Log.agent.info("\(detail, privacy: .public)")
        if CommandLine.arguments.contains("--selftest-voice-pipeline") { SelfTest.diagnostic(detail) }
        backing.speak(clause, volume: utteranceVolume, token: currentPlaybackToken)
    }

    private func fallbackCurrentClause(text: String, token: UInt64) {
        guard token == currentPlaybackToken, !usingSystemFallbackForReply,
              let currentClause, !currentClause.isEmpty, currentClause == text else { return }
        usingSystemFallbackForReply = true
        backing = fallbackBackingForTesting ?? systemBacking
        currentClauseRendered = false
        if isPausedForListening {
            deferredFallbackClause = true
            return
        }
        startClause(currentClause)
    }

    private func interruptCurrentClause() {
        if let currentClause {
            onPlaybackEvent?(.interrupted(currentClause, wasRendered: currentClauseRendered))
        }
        currentClause = nil
        currentClauseRendered = false
        for clause in pendingClauses {
            onPlaybackEvent?(.interrupted(clause, wasRendered: false))
        }
    }

    /// Fail unless `stop()` ran and cleared remaining clauses. Uses a recording
    /// backend — no speaker required. Also drives `RealtimeAgent.interrupt()` so
    /// the barge-in hook is under test.
    static func runInterruptSelfTest() -> [String] {
        let recorder = RecordingSpeechBacking()
        let previous = AgentSpeechSynthesizer.shared
        previous.useTestingBacking(recorder)
        previous.didStop = false
        defer { previous.restoreSystemBacking() }

        previous.speak("I found three files.")
        if recorder.spoken != ["I found three files."] {
            return ["interrupt: speak did not enqueue the short answer"]
        }

        RealtimeAgent.shared.interrupt()
        if !previous.didStop || recorder.stopCount == 0 {
            return ["interrupt: stop was not called"]
        }
        return []
    }

    static func runSuspendSelfTest() -> [String] {
        let synth = AgentSpeechSynthesizer.shared
        let recorder = RecordingSpeechBacking()
        synth.useTestingBacking(recorder)
        defer { synth.restoreSystemBacking() }
        synth.speak("First sentence. The second sentence follows it.")
        let token = synth.currentPlaybackToken
        let pending = synth.pendingClauseCount
        synth.pauseForListening()
        synth.pauseForListening()
        guard synth.isPausedForListening, recorder.paused,
              recorder.pauseCount == 1, recorder.stopCount == 0,
              synth.currentPlaybackToken == token, synth.pendingClauseCount == pending else {
            return ["suspend: pause lost playback token, queue, or idempotence"]
        }
        synth.resumeAfterListening()
        synth.resumeAfterListening()
        guard !synth.isPausedForListening, !recorder.paused,
              recorder.resumeCount == 1, recorder.stopCount == 0,
              synth.currentPlaybackToken == token else {
            return ["suspend: resume changed playback or repeated"]
        }
        synth.pauseForListening()
        synth.stop()
        guard synth.didStop, !synth.isPausedForListening, !recorder.paused,
              synth.pendingClauseCount == 0, recorder.stopCount == 1 else {
            return ["suspend: hard stop did not clear held audio and clauses"]
        }

        recorder.reset()
        synth.prepareForStream()
        synth.enqueueClause("First sentence.")
        synth.enqueueClause("Second sentence.")
        let firstToken = synth.currentPlaybackToken
        synth.pauseForListening()
        synth.notifyTestingAudioFinished(token: firstToken)
        guard synth.isPausedForListening, synth.pendingClauseCount == 1,
              recorder.spoken == ["First sentence."] else {
            return ["suspend: late completion started the next clause during pause"]
        }
        synth.resumeAfterListening()
        guard !synth.isPausedForListening, synth.pendingClauseCount == 0,
              synth.currentPlaybackToken != firstToken,
              recorder.spoken == ["First sentence.", "Second sentence."] else {
            return ["suspend: held next clause did not start after resume"]
        }
        return runFallbackSelfTest()
    }

    private static func runFallbackSelfTest() -> [String] {
        let synth = AgentSpeechSynthesizer.shared
        let failedBackend = RecordingSpeechBacking()
        let safeBackend = RecordingSpeechBacking()
        let savedPreference = Settings.shared.agentVoiceEngine
        synth.useTestingBacking(failedBackend)
        synth.fallbackBackingForTesting = safeBackend
        defer { synth.restoreSystemBacking() }
        synth.speak("The first sentence.")
        let failedToken = synth.currentPlaybackToken
        synth.pauseForListening()
        synth.fallbackCurrentClause(text: "The first sentence.", token: failedToken)
        synth.fallbackCurrentClause(text: "The first sentence.", token: failedToken)
        synth.fallbackCurrentClause(text: "The first sentence.", token: failedToken &- 1)
        guard synth.isPausedForListening, safeBackend.spoken.isEmpty,
              Settings.shared.agentVoiceEngine == savedPreference else {
            return ["voice fallback: paused, duplicate, or stale failure spoke or changed preference"]
        }
        synth.resumeAfterListening()
        guard safeBackend.spoken == ["The first sentence."],
              synth.currentPlaybackToken != failedToken else {
            return ["voice fallback: resume did not speak exactly once with a new token"]
        }
        synth.stop()
        synth.fallbackCurrentClause(text: "The first sentence.", token: failedToken)
        guard safeBackend.spoken.count == 1,
              Settings.shared.agentVoiceEngine == savedPreference else {
            return ["voice fallback: stale callback replayed after stop or changed preference"]
        }
        return []
    }

    /// Signed-app selected-voice gate. Silent mixer gain still runs real PCM,
    /// dataPlayedBack receipts, and clause drain without disturbing the room.
    static func runLiveSuspendSelfTest() async -> (Bool, String) {
        let synth = AgentSpeechSynthesizer.shared
        let oldVolume = synth.utteranceVolume
        var started = 0
        var completed = 0
        synth.utteranceVolume = 0
        synth.onPlaybackEvent = { event in
            if case .startAcknowledged = event { started += 1 }
            if case .completed = event { completed += 1 }
        }
        defer {
            synth.stop()
            synth.onPlaybackEvent = nil
            synth.utteranceVolume = oldVolume
        }
        synth.speak("The first sentence has enough duration to pause after audio begins and "
            + "should resume from the same place without cancelling the reply.")
        for _ in 0..<150 where started == 0 {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard started == 1 else { return (false, "VOICE_SUSPEND_FAILED: first PCM never played") }
        let heldToken = synth.currentPlaybackToken
        synth.pauseForListening()
        let completedAtPause = completed
        try? await Task.sleep(for: .milliseconds(350))
        guard synth.isPausedForListening, completed == completedAtPause,
              synth.currentPlaybackToken == heldToken else {
            return (false, "VOICE_SUSPEND_FAILED: paused player drained or lost token")
        }
        synth.resumeAfterListening()
        for _ in 0..<600 where completed == completedAtPause {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard !synth.isPausedForListening, completed == completedAtPause + 1 else {
            return (false, "VOICE_SUSPEND_FAILED: held clause did not resume and drain")
        }
        synth.speak("A second clause should start after the first engine was drained.")
        for _ in 0..<400 where completed < completedAtPause + 2 {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard completed == completedAtPause + 2, started >= 2 else {
            return (false, "VOICE_SUSPEND_FAILED: next clause did not restart and drain")
        }
        return (true, "VOICE_SUSPEND_OK: paused PCM retained token and queue; resumed and drained; next clause restarted")
    }

    /// Multi-clause enqueue + barge-in clears the remainder. Recording backing
    /// only — no speaker. Failures are collected by `runSelfTest` / stream helper.
    static func runStreamSelfTest() -> [String] {
        var failures: [String] = []
        let recorder = RecordingSpeechBacking()
        let synth = AgentSpeechSynthesizer.shared
        synth.useTestingBacking(recorder)
        synth.didStop = false
        defer { synth.restoreSystemBacking() }

        let reply = "I found three files. The latest is enclosure version seventeen."
        synth.speak(reply)

        if recorder.spoken != ["I found three files."] {
            failures.append(
                "stream: expected first clause only, got \(recorder.spoken)"
            )
        }
        if synth.pendingClauseCount != 1 {
            failures.append(
                "stream: expected 1 pending clause, got \(synth.pendingClauseCount)"
            )
        }

        // Advance once so the second clause is “speaking” and the queue is empty
        // of pending — then speak a fresh three-clause reply and interrupt mid-way.
        synth.advanceQueue()
        if recorder.spoken.count != 2 {
            failures.append(
                "stream: advance should speak second clause, got \(recorder.spoken)"
            )
        }
        if synth.pendingClauseCount != 0 {
            failures.append("stream: queue should be empty after last advance")
        }

        recorder.reset()
        synth.didStop = false
        let longer = "That's done. I created the event. It's on your calendar."
        synth.speak(longer)
        if recorder.spoken.count != 1 {
            failures.append(
                "stream: longer reply should start with one spoken clause, got \(recorder.spoken)"
            )
        }
        if synth.pendingClauseCount < 1 {
            failures.append(
                "stream: longer reply should leave pending clauses, got \(synth.pendingClauseCount)"
            )
        }
        let pendingBefore = synth.pendingClauseCount

        RealtimeAgent.shared.interrupt()
        if !synth.didStop || recorder.stopCount == 0 {
            failures.append("stream: interrupt did not stop synthesizer")
        }
        if synth.pendingClauseCount != 0 {
            failures.append(
                "stream: interrupt left \(synth.pendingClauseCount) pending (was \(pendingBefore))"
            )
        }
        // Only the clause that had started should appear — never the cleared rest.
        if recorder.spoken.count != 1 {
            failures.append(
                "stream: interrupt must not speak remaining clauses, got \(recorder.spoken)"
            )
        }

        return failures
    }

    /// Deterministic acknowledgement contract. The fake never drives a
    /// speaker; a render event must therefore require an explicit callback.
    static func runPlaybackLedgerSelfTest() -> [String] {
        let synth = AgentSpeechSynthesizer.shared
        let recorder = RecordingSpeechBacking()
        synth.useTestingBacking(recorder)
        var events: [PlaybackEvent] = []
        synth.onPlaybackEvent = { events.append($0) }
        defer { synth.restoreSystemBacking() }

        synth.speak("First clause. Second clause.")
        let firstToken = synth.currentPlaybackToken
        guard events.contains(.began(synth.outputGeneration)),
              events.contains(.enqueued("First clause.")),
              !events.contains(.startAcknowledged("First clause.")) else {
            return ["playback ledger: enqueue claimed rendering"]
        }
        synth.notifyTestingFirstAudio(token: firstToken)
        synth.stop()
        guard events.contains(.startAcknowledged("First clause.")),
              events.contains(.interrupted("First clause.", wasRendered: true)),
              events.contains(.interrupted("Second clause.", wasRendered: false)),
              !events.contains(.completed("First clause.")) else {
            return ["playback ledger: interruption lost rendered versus queued state"]
        }
        events.removeAll()
        synth.speak("Replacement reply.")
        synth.notifyTestingFirstAudio(token: firstToken)
        guard !events.contains(.startAcknowledged("Replacement reply.")) else {
            return ["playback ledger: stale render started replacement"]
        }
        let replacementToken = synth.currentPlaybackToken
        synth.notifyTestingFirstAudio(token: replacementToken)
        synth.notifyTestingAudioFinished(token: replacementToken)
        guard events.contains(.startAcknowledged("Replacement reply.")),
              events.contains(.completed("Replacement reply.")) else {
            return ["playback ledger: completed playback lacks acknowledgements"]
        }
        events.removeAll()
        synth.speak("One clause. Two clauses.")
        let firstClauseToken = synth.currentPlaybackToken
        synth.notifyTestingAudioFinished(token: firstClauseToken)
        let secondClauseToken = synth.currentPlaybackToken
        guard firstClauseToken != secondClauseToken else {
            return ["playback ledger: clauses reused a callback identity"]
        }
        synth.notifyTestingAudioFinished(token: firstClauseToken)
        guard !events.contains(.completed("Two clauses.")) else {
            return ["playback ledger: duplicate old completion consumed next clause"]
        }
        synth.notifyTestingAudioFinished(token: secondClauseToken)
        guard events.contains(.completed("Two clauses.")) else {
            return ["playback ledger: current clause did not complete"]
        }
        return []
    }
}

// MARK: - Backends

@MainActor
final class AVSpeechBacking: NSObject, AgentSpeechBacking, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private let playbackEngine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var pendingBuffers = 0
    private var synthesisFinished = false
    private var didBegin = false
    private var delivery: PCMDelivery?
    private var speaking = false
    private var pausedForListening = false
    private var activeToken: UInt64?
    /// Wired by `AgentSpeechSynthesizer` to pump the next clause (or finish).
    var onUtteranceFinished: ((UInt64) -> Void)?
    /// Wired by `AgentSpeechSynthesizer` for truthful first-audio timing.
    var onUtteranceStarted: ((UInt64) -> Void)?
    private var tokens: [ObjectIdentifier: UInt64] = [:]

    override init() {
        super.init()
        synthesizer.delegate = self
        playbackEngine.attach(player)
        playbackEngine.connect(player, to: playbackEngine.mainMixerNode,
                               format: AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!)
        VoicePlaybackReference.install(on: playbackEngine)
    }

    var isSpeaking: Bool { speaking }

    func speak(_ text: String, volume: Float, token: UInt64) {
        // Do not clear the AVSpeech queue here — clause streaming feeds one
        // utterance at a time after `didFinish`. A replacing reply calls `stop()`
        // first from `AgentSpeechSynthesizer.speak`.
        speaking = true
        pausedForListening = false
        activeToken = token
        pendingBuffers = 0
        synthesisFinished = false
        didBegin = false
        let delivery = PCMDelivery()
        self.delivery = delivery
        let utterance = AVSpeechUtterance(string: text)
        // Output gain lives at the mixer. The render tap observes the resulting
        // PCM with the same ducking applied to the physical speaker path.
        utterance.volume = 1
        playbackEngine.mainMixerNode.outputVolume = max(0, min(1, volume))
        if !Settings.shared.agentVoiceIdentifier.isEmpty {
            utterance.voice = AVSpeechSynthesisVoice(identifier: Settings.shared.agentVoiceIdentifier)
        }
        tokens[ObjectIdentifier(utterance)] = token
        synthesizer.write(utterance, toBufferCallback: Self.makeRenderCallback(
            for: self, delivery: delivery, token: token))
    }

    /// AVSpeechSynthesizer invokes its PCM callback on a private render queue.
    /// Form it outside MainActor isolation, just like the microphone tap, or
    /// Swift's actor assertion can terminate the live app on the first buffer.
    nonisolated private static func makeRenderCallback(
        for backing: AVSpeechBacking, delivery: PCMDelivery, token: UInt64
    ) -> @Sendable (AVAudioBuffer) -> Void {
        { [weak backing] buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0,
                  let owned = AudioConversion.copy(pcm) else {
                delivery.enqueue(nil, for: backing, token: token)
                return
            }
            delivery.enqueue(owned, for: backing, token: token)
        }
    }

    /// One scheduled drain per synthesizer generation. Core Audio callback
    /// order is preserved across the MainActor hop: an EOF cannot close a
    /// clause while earlier PCM is still waiting in another Task.
    private final class PCMDelivery: @unchecked Sendable {
        private struct Item: @unchecked Sendable { let buffer: AVAudioPCMBuffer? }
        private let lock = NSLock()
        private var pending: [Item] = []
        private var draining = false

        func enqueue(_ buffer: AVAudioPCMBuffer?, for backing: AVSpeechBacking?, token: UInt64) {
            lock.lock()
            pending.append(Item(buffer: buffer))
            let schedule = !draining
            draining = true
            lock.unlock()
            if schedule {
                Task { @MainActor [weak backing] in
                    while let next = self.take() {
                        if let buffer = next.buffer { backing?.play(buffer, token: token) }
                        else { backing?.synthesisEnded(token: token) }
                    }
                }
            }
        }

        private func take() -> Item? {
            lock.lock()
            defer { lock.unlock() }
            guard !pending.isEmpty else { draining = false; return nil }
            return pending.removeFirst()
        }
    }

    private func play(_ buffer: AVAudioPCMBuffer, token: UInt64) {
        guard activeToken == token else { return }
        do {
            if !playbackEngine.isRunning {
                playbackEngine.connect(player, to: playbackEngine.mainMixerNode,
                                       format: buffer.format)
                try playbackEngine.start()
            }
            pendingBuffers += 1
            player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) {
                [weak self] _ in
                Task { @MainActor in self?.bufferPlayed(token: token) }
            }
            if !pausedForListening && !player.isPlaying { player.play() }
        } catch {
            Log.agent.error("Apple TTS PCM playback failed: \(error.localizedDescription, privacy: .public)")
            stop()
            onUtteranceFinished?(token)
        }
    }

    private func synthesisEnded(token: UInt64) {
        guard activeToken == token else { return }
        synthesisFinished = true
        finishIfDrained(token: token)
    }

    private func bufferPlayed(token: UInt64) {
        guard activeToken == token, pendingBuffers > 0 else { return }
        if !didBegin {
            didBegin = true
            onUtteranceStarted?(token)
        }
        pendingBuffers -= 1
        finishIfDrained(token: token)
    }

    private func finishIfDrained(token: UInt64) {
        guard activeToken == token, synthesisFinished, pendingBuffers == 0 else { return }
        speaking = false
        pausedForListening = false
        activeToken = nil
        delivery = nil
        player.stop()
        playbackEngine.stop()
        VoicePlaybackReference.stopped()
        onUtteranceFinished?(token)
    }

    func stop() {
        speaking = false
        pausedForListening = false
        activeToken = nil
        synthesizer.stopSpeaking(at: .immediate)
        player.stop()
        playbackEngine.stop()
        VoicePlaybackReference.stopped()
        pendingBuffers = 0
    }

    func pauseForListening() {
        guard speaking, !pausedForListening else { return }
        pausedForListening = true
        if player.isPlaying { player.pause() }
    }

    func resumeAfterListening() {
        guard speaking, pausedForListening else { return }
        pausedForListening = false
        if pendingBuffers > 0 && !player.isPlaying { player.play() }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard let token = self.tokens[utteranceID] else { return }
            self.tokens[utteranceID] = nil
            guard self.activeToken == token else { return }
            // `write` may report synthesizer completion before queued PCM has
            // reached the player; only its zero-frame sentinel and playback
            // callbacks close the clause.
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didStart utterance: AVSpeechUtterance
    ) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor in
            // The synthesis delegate marks generation, not speaker playback.
            _ = self.tokens[utteranceID]
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor in
            guard let token = self.tokens[utteranceID] else { return }
            self.tokens[utteranceID] = nil
            guard self.activeToken == token else { return }
            self.speaking = false
            self.activeToken = nil
            // Barge-in / stop already cleared pending clauses and session state.
        }
    }
}

@MainActor
final class RecordingSpeechBacking: AgentSpeechBacking {
    private(set) var spoken: [String] = []
    private(set) var volumes: [Float] = []
    private(set) var stopCount = 0
    private(set) var pauseCount = 0
    private(set) var resumeCount = 0
    private var speaking = false
    private(set) var paused = false

    var isSpeaking: Bool { speaking }

    func speak(_ text: String, volume: Float, token: UInt64) {
        spoken.append(text)
        volumes.append(volume)
        speaking = true
        paused = false
    }

    func pauseForListening() {
        guard speaking, !paused else { return }
        paused = true
        pauseCount += 1
    }

    func resumeAfterListening() {
        guard speaking, paused else { return }
        paused = false
        resumeCount += 1
    }

    func stop() {
        stopCount += 1
        speaking = false
        paused = false
    }

    func reset() {
        spoken = []
        volumes = []
        stopCount = 0
        pauseCount = 0
        resumeCount = 0
        speaking = false
        paused = false
    }
}

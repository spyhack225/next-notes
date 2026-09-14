import AVFoundation
import Foundation

/// Playback backend. Production talks to `AVSpeechSynthesizer`; the self-test
/// swaps in a recorder so interrupt can be asserted without a speaker.
@MainActor
protocol AgentSpeechBacking: AnyObject {
    var isSpeaking: Bool { get }
    func speak(_ text: String, volume: Float, token: UInt64)
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
    static let shared = AgentSpeechSynthesizer()

    private var backing: any AgentSpeechBacking
    private let systemBacking = AVSpeechBacking()
    private let pocketBacking = PocketSpeechBacking()
    private let kokoroBacking = KokoroSpeechBacking()
    private var testingBacking = false
    /// Remaining clauses after the one currently speaking (or just enqueued).
    private var pendingClauses: [String] = []
    /// Set by `stop()`. The interrupt self-test fails unless this path ran.
    private(set) var didStop = false
    /// Applied to each utterance. Duplex ducking lowers this while speaking.
    var utteranceVolume: Float = 1.0
    /// Called when the system backing actually begins the first utterance. This
    /// is intentionally separate from `enqueueClause`: enqueue latency is not
    /// audible latency.
    var onFirstAudio: (() -> Void)?
    /// Called when a pending first-audio callback is cancelled by barge-in.
    var onFirstAudioCancelled: (() -> Void)?
    /// Monotonic output generation. A delegate callback from an interrupted
    /// utterance carries its old token and cannot close a new reply's span.
    private(set) var outputGeneration: UInt64 = 0

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
            guard let self, token == self.outputGeneration else { return }
            Settings.shared.agentVoiceEngine = "apple"
            self.backing = self.systemBacking
            self.systemBacking.speak(text, volume: volume, token: token)
        }
        kokoroBacking.onUtteranceFinished = { [weak self] token in
            self?.didFinishAudio(token: token)
        }
        kokoroBacking.onUtteranceStarted = { [weak self] token in
            self?.didBeginAudio(token: token)
        }
        kokoroBacking.onFailure = { [weak self] text, volume, token in
            guard let self, token == self.outputGeneration else { return }
            Settings.shared.agentVoiceEngine = "apple"
            self.backing = self.systemBacking
            if !text.isEmpty { self.systemBacking.speak(text, volume: volume, token: token) }
        }
        if Settings.shared.agentVoiceEngine == "pocket" {
            Task { await PocketAgentVoice.shared.prepare() }
        } else if Settings.shared.agentVoiceEngine == "kokoro" {
            if KokoroAgentVoice.isSupportedOS {
                Task { await KokoroAgentVoice.shared.prepare() }
            } else {
                Settings.shared.agentVoiceEngine = "apple"
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
        backing.speak(clauses[0], volume: utteranceVolume, token: outputGeneration)
    }

    /// Clear prior playback so a streamed reply can enqueue clauses one by one.
    /// Called by `StreamingSpeechBuffer.begin` — does not set `didStop`.
    func prepareForStream() {
        outputGeneration &+= 1
        didStop = false
        pendingClauses.removeAll()
        if backing.isSpeaking {
            backing.stop()
        }
        if !testingBacking {
            switch Settings.shared.agentVoiceEngine {
            case "pocket" where PocketAgentVoice.shared.isReady:
                backing = pocketBacking
            case "kokoro" where KokoroAgentVoice.isSupportedOS:
                backing = kokoroBacking
            default:
                backing = systemBacking
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
        } else {
            backing.speak(trimmed, volume: utteranceVolume, token: outputGeneration)
        }
    }

    /// Barge-in / VAD / Stop. Immediate, not word-boundary. Clears every
    /// pending clause so mid-reply cut-off does not keep speaking the rest.
    /// Target <100 ms.
    func stop() {
        outputGeneration &+= 1
        let hadPendingAudio = onFirstAudio != nil
        didStop = true
        pendingClauses.removeAll()
        onFirstAudio = nil
        if hadPendingAudio { onFirstAudioCancelled?() }
        backing.stop()
    }

    /// Self-test only. Restored by interrupt / stream self-tests so a later
    /// turn still uses the system voice.
    func useTestingBacking(_ backing: any AgentSpeechBacking) {
        testingBacking = true
        self.backing = backing
    }

    func restoreSystemBacking() {
        testingBacking = false
        self.backing = systemBacking
        utteranceVolume = 1.0
        pendingClauses.removeAll()
        onFirstAudio = nil
        onFirstAudioCancelled = nil
    }

    private func didBeginAudio(token: UInt64) {
        guard token == outputGeneration else { return }
        let callback = onFirstAudio
        onFirstAudio = nil
        callback?()
    }

    private func didFinishAudio(token: UInt64) {
        guard token == outputGeneration else { return }
        advanceQueue()
    }

    /// Self-test seam for a fake backing. The token is explicit so the probe
    /// can prove an old delegate callback cannot close a new span.
    func notifyTestingFirstAudio(token: UInt64) {
        didBeginAudio(token: token)
    }

    /// Next clause after the current utterance finishes. No-op after `stop()`
    /// or when the queue is empty (then duplex phase returns to listening).
    func advanceQueue() {
        guard !didStop else { return }
        guard !pendingClauses.isEmpty else {
            RealtimeAudioSession.shared.noteOutputFinished()
            return
        }
        let next = pendingClauses.removeFirst()
        backing.speak(next, volume: utteranceVolume, token: outputGeneration)
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
}

// MARK: - Backends

@MainActor
final class AVSpeechBacking: NSObject, AgentSpeechBacking, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var speaking = false
    private var activeToken: UInt64?
    /// Wired by `AgentSpeechSynthesizer` to pump the next clause (or finish).
    var onUtteranceFinished: ((UInt64) -> Void)?
    /// Wired by `AgentSpeechSynthesizer` for truthful first-audio timing.
    var onUtteranceStarted: ((UInt64) -> Void)?
    private var tokens: [ObjectIdentifier: UInt64] = [:]

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var isSpeaking: Bool { speaking || synthesizer.isSpeaking }

    func speak(_ text: String, volume: Float, token: UInt64) {
        // Do not clear the AVSpeech queue here — clause streaming feeds one
        // utterance at a time after `didFinish`. A replacing reply calls `stop()`
        // first from `AgentSpeechSynthesizer.speak`.
        speaking = true
        activeToken = token
        let utterance = AVSpeechUtterance(string: text)
        utterance.volume = max(0, min(1, volume))
        if !Settings.shared.agentVoiceIdentifier.isEmpty {
            utterance.voice = AVSpeechSynthesisVoice(identifier: Settings.shared.agentVoiceIdentifier)
        }
        tokens[ObjectIdentifier(utterance)] = token
        synthesizer.speak(utterance)
    }

    func stop() {
        speaking = false
        activeToken = nil
        synthesizer.stopSpeaking(at: .immediate)
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
            self.speaking = false
            self.activeToken = nil
            self.onUtteranceFinished?(token)
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didStart utterance: AVSpeechUtterance
    ) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor in
            if let token = self.tokens[utteranceID] {
                self.onUtteranceStarted?(token)
            }
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
    private var speaking = false

    var isSpeaking: Bool { speaking }

    func speak(_ text: String, volume: Float, token: UInt64) {
        spoken.append(text)
        volumes.append(volume)
        speaking = true
    }

    func stop() {
        stopCount += 1
        speaking = false
    }

    func reset() {
        spoken = []
        volumes = []
        stopCount = 0
        speaking = false
    }
}

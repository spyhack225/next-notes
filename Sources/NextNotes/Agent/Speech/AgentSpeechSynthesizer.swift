import AVFoundation
import Foundation

/// Playback backend. Production talks to `AVSpeechSynthesizer`; the self-test
/// swaps in a recorder so interrupt can be asserted without a speaker.
@MainActor
protocol AgentSpeechBacking: AnyObject {
    var isSpeaking: Bool { get }
    func speak(_ text: String, volume: Float)
    func stop()
}

/// `AVSpeechSynthesizer` baseline. Speaks `AgentSpeechPolicy.spokenClauses`
/// one utterance at a time, never waits for the queue to drain, and is always
/// interruptible — `stop()` cancels the current clause and clears the rest.
///
/// Kokoro / Piper stay out of this wave. Dictation never calls this. A second
/// `AVAudioEngine` on the input node is forbidden — this class only plays.
@MainActor
final class AgentSpeechSynthesizer {
    static let shared = AgentSpeechSynthesizer()

    private var backing: any AgentSpeechBacking
    private let systemBacking = AVSpeechBacking()
    /// Remaining clauses after the one currently speaking (or just enqueued).
    private var pendingClauses: [String] = []
    /// Set by `stop()`. The interrupt self-test fails unless this path ran.
    private(set) var didStop = false
    /// Applied to each utterance. Duplex ducking lowers this while speaking.
    var utteranceVolume: Float = 1.0

    /// Clauses waiting after the current utterance. Zero when idle or after stop.
    var pendingClauseCount: Int { pendingClauses.count }

    init(backing: (any AgentSpeechBacking)? = nil) {
        self.backing = backing ?? systemBacking
        systemBacking.onUtteranceFinished = { [weak self] in
            self?.advanceQueue()
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
        backing.speak(clauses[0], volume: utteranceVolume)
    }

    /// Clear prior playback so a streamed reply can enqueue clauses one by one.
    /// Called by `StreamingSpeechBuffer.begin` — does not set `didStop`.
    func prepareForStream() {
        didStop = false
        pendingClauses.removeAll()
        if backing.isSpeaking {
            backing.stop()
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
            backing.speak(trimmed, volume: utteranceVolume)
        }
    }

    /// Barge-in / VAD / Stop. Immediate, not word-boundary. Clears every
    /// pending clause so mid-reply cut-off does not keep speaking the rest.
    /// Target <100 ms.
    func stop() {
        didStop = true
        pendingClauses.removeAll()
        backing.stop()
    }

    /// Self-test only. Restored by interrupt / stream self-tests so a later
    /// turn still uses the system voice.
    func useTestingBacking(_ backing: any AgentSpeechBacking) {
        self.backing = backing
    }

    func restoreSystemBacking() {
        self.backing = systemBacking
        utteranceVolume = 1.0
        pendingClauses.removeAll()
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
        backing.speak(next, volume: utteranceVolume)
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
    /// Wired by `AgentSpeechSynthesizer` to pump the next clause (or finish).
    var onUtteranceFinished: (() -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    var isSpeaking: Bool { speaking || synthesizer.isSpeaking }

    func speak(_ text: String, volume: Float) {
        // Do not clear the AVSpeech queue here — clause streaming feeds one
        // utterance at a time after `didFinish`. A replacing reply calls `stop()`
        // first from `AgentSpeechSynthesizer.speak`.
        speaking = true
        let utterance = AVSpeechUtterance(string: text)
        utterance.volume = max(0, min(1, volume))
        synthesizer.speak(utterance)
    }

    func stop() {
        speaking = false
        synthesizer.stopSpeaking(at: .immediate)
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            self.speaking = false
            self.onUtteranceFinished?()
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor in
            self.speaking = false
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

    func speak(_ text: String, volume: Float) {
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

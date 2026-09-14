import AVFoundation
import Foundation
import Observation

/// Full-duplex agent listen: wake or ⇧⌘ Space opens a session; silence endpoints one
/// turn; the session stays open until Done, idle, or goodbye.
///
/// Copied from Qwen's turn machine, not its cloud VAD: `realtime-input-runtime.mjs`
/// (`speech_started` / `speech_stopped` / `committed`) plus `sleep-controller.mjs`
/// (idle → sleep). Energy VAD on the mic track only. Dictation stays push-to-talk.
@MainActor
@Observable
final class AgentCaptureController {
    static let shared = AgentCaptureController()

    enum Limits {
        static let speechLevel: Float = 0.06
        static let silenceLevel: Float = 0.04
        /// After speech, this much quiet commits the turn. Qwen's provider VAD is
        /// typically a sub-second endpoint; 900 ms is enough to finish a clause.
        static let endpointSilence: TimeInterval = 0.9
        static let minSpeech: TimeInterval = 0.25
        static let minCharacters = 2
        /// No speech after a reply: go back to sleep, like Qwen's SleepController.
        static let idleSession: TimeInterval = 25
        static let tick: Duration = .milliseconds(100)
    }

    enum EndpointSource: String, Sendable {
        case vad
        case goodbye
        case done
        case idle
        case none
    }

    private(set) var transcript = ""
    private(set) var level: Float = 0
    private(set) var lastReply = ""
    private(set) var isSessionActive = false
    /// What closed the last turn. `--selftest-realtime` fails unless a reply came from `vad`.
    private(set) var lastEndpoint: EndpointSource = .none

    private var engine: (any TranscriptionEngine)?
    private var consumeTask: Task<Void, Never>?
    private var vadTask: Task<Void, Never>?
    /// A tool or permission request belongs to a turn, not to the VAD timer.
    /// The timer must keep endpointing speech while this task is suspended.
    private var activeTurnTask: Task<Void, Never>?
    private var turnGeneration = 0
    /// A suspended fake lets `--selftest-realtime` prove the next endpoint does
    /// not wait for a previous tool. Never installed during normal operation.
    @ObservationIgnored var turnHandlerForTesting: (@MainActor (String) async -> Void)?
    private var heardSpeech = false
    private var speechBeganAt: Date?
    private var lastSpeechAt: Date?
    private var lastActivityAt: Date?
    private var committedPrefix = ""
    private var lastEmittedRequest = ""
    private var captureAudio = true

    func begin() async {
        await beginSession(captureAudio: !SelfTest.isRunning)
    }

    func beginSession(captureAudio: Bool = true) async {
        if isSessionActive { return }
        turnGeneration &+= 1
        activeTurnTask?.cancel()
        activeTurnTask = nil
        self.captureAudio = captureAudio
        isSessionActive = true
        RealtimeAudioSession.shared.begin()
        ActivationController.shared.markListening()
        lastEndpoint = .none
        lastReply = ""
        lastEmittedRequest = ""
        resetTurn()
        IslandState.shared.showAgentListening(transcript: "", level: 0)

        if captureAudio {
            guard await Permissions.requestMicrophone() else {
                IslandState.shared.showAgentReply("Microphone access is off.")
                await endSession(source: .done)
                return
            }
            do {
                try await startEngine()
            } catch {
                IslandState.shared.showAgentReply(error.localizedDescription)
                await endSession(source: .done)
                return
            }
            startVAD()
        }
    }

    /// Island Done / second shortcut: leave the conversation. Not how a turn ends.
    func endSession(source: EndpointSource = .done) async {
        guard isSessionActive else { return }
        isSessionActive = false
        turnGeneration &+= 1
        activeTurnTask?.cancel()
        activeTurnTask = nil
        _ = ACPConfirmationGate.shared.cancel()
        if RealtimeAgent.shared.isThinking {
            RealtimeAgent.shared.cancel()
        }
        lastEndpoint = source
        RealtimeAudioSession.shared.end()
        stopVAD()
        await stopEngine()
        // Done closes the session. The VAD endpoint is the only path that
        // submits speech; a cumulative ASR tail after Done is often playback
        // or a revision of a request already in flight.
        if lastReply.isEmpty {
            IslandState.shared.showAgentReply(source == .idle ? "Going quiet." : "Stopped.")
            ActivationController.shared.finishAgent()
        } else {
            IslandState.shared.showAgentReply(lastReply)
            ActivationController.shared.finishAgent()
        }
        transcript = ""
        heardSpeech = false
        lastEmittedRequest = ""
    }

    /// Old name: callers that meant “user pressed Done” now end the session.
    func finish() async {
        await endSession(source: .done)
    }

    /// Self-test / wake remainder: speech then silence, no Done.
    func simulateSpeech(_ text: String, level: Float = 0.3) {
        RealtimeAudioSession.shared.noteUserSpeech()
        self.level = level
        heardSpeech = true
        if speechBeganAt == nil { speechBeganAt = Date().addingTimeInterval(-Limits.minSpeech - 0.05) }
        lastSpeechAt = Date()
        lastActivityAt = Date()
        transcript = text
        IslandState.shared.showAgentListening(transcript: text, level: level)
    }

    func simulateSilence() {
        level = 0
        lastSpeechAt = Date().addingTimeInterval(-Limits.endpointSilence - 0.05)
    }

    @discardableResult
    func considerEndpoint() async -> Bool {
        await tick(force: true)
    }

    private func startEngine() async throws {
        let engine = AppleSpeechEngine()
        self.engine = engine
        guard let format = await engine.preferredInputFormat() else {
            throw TranscriptionError.noAudioFormat
        }
        let stream = try await engine.start()
        consumeTask = Task { @MainActor [weak self] in
            do {
                for try await chunk in stream {
                    guard let self, self.isSessionActive else { return }
                    let full = chunk.text
                    let turn = Self.pending(full: full, committed: self.committedPrefix)
                    self.transcript = turn
                    // Energy alone is not a speech-start event: while the speaker
                    // plays TTS it regularly crosses the VAD threshold. Wait for
                    // a new ASR fragment that is not our own spoken reply before
                    // clearing playback and cancelling the in-flight turn.
                    if (RealtimeAudioSession.shared.isSpeaking || RealtimeAgent.shared.isThinking),
                       turn.count >= Limits.minCharacters,
                       !RealtimeAudioSession.shared.isLikelyPlaybackEcho(turn),
                       !Self.isInFlightRepeat(turn, previous: self.lastEmittedRequest),
                       !Self.isCommittedTranscriptRevision(turn, committed: self.committedPrefix),
                       let began = self.speechBeganAt,
                       Date().timeIntervalSince(began) >= Limits.minSpeech {
                        RealtimeAgent.shared.interrupt()
                    }
                    IslandState.shared.showAgentListening(transcript: turn, level: self.level)
                    if chunk.isFinal, turn.count >= Limits.minCharacters {
                        self.heardSpeech = true
                        self.lastSpeechAt = Date().addingTimeInterval(-Limits.endpointSilence)
                    }
                }
            } catch {
                Log.agent.error("agent capture: \(error.localizedDescription, privacy: .public)")
            }
        }
        try AudioCaptureHub.shared.subscribe(.agent, outputFormat: format, onBuffer: { chunk in
            Task { await engine.feed(chunk) }
        }, onLevel: { level in
            Task { @MainActor in
                AgentCaptureController.shared.noteLevel(level)
            }
        })
    }

    private func stopEngine() async {
        AudioCaptureHub.shared.unsubscribe(.agent)
        let finishing = engine
        engine = nil
        consumeTask?.cancel()
        consumeTask = nil
        if let finishing {
            _ = await withBoundedWait(RealtimeAgent.Limits.captureFinish) {
                await finishing.finish()
            }
        }
    }

    private func startVAD() {
        vadTask?.cancel()
        vadTask = Task { @MainActor [weak self] in
            while let self, self.isSessionActive, !Task.isCancelled {
                _ = await self.tick(force: false)
                try? await Task.sleep(for: Limits.tick)
            }
        }
    }

    private func stopVAD() {
        vadTask?.cancel()
        vadTask = nil
    }

    private func noteLevel(_ level: Float) {
        self.level = level
        guard isSessionActive else { return }
        if level >= Limits.speechLevel {
            // A loud sample is not a user speech-start event, including while
            // the model is thinking. Keep capture live and wait for a novel
            // transcript fragment above before interrupting output or work.
            heardSpeech = true
            if speechBeganAt == nil { speechBeganAt = Date() }
            lastSpeechAt = Date()
            lastActivityAt = Date()
        }
        IslandState.shared.showAgentListening(transcript: transcript, level: level)
    }

    @discardableResult
    private func tick(force: Bool) async -> Bool {
        guard isSessionActive else { return false }
        let now = Date()

        if heardSpeech,
           let lastSpeechAt,
           let began = speechBeganAt,
           now.timeIntervalSince(lastSpeechAt) >= Limits.endpointSilence,
           now.timeIntervalSince(began) >= Limits.minSpeech,
           (level <= Limits.silenceLevel || force) {
            let text = pendingTurn()
            if text.count >= Limits.minCharacters {
                if RealtimeAgent.shared.isThinking,
                   Self.isInFlightRepeat(text, previous: lastEmittedRequest) {
                    // A repeated question or its unfinished prefix is not a new
                    // command. Keep listening briefly for a different ending;
                    // otherwise absorb the duplicate without cancelling the read.
                    if now.timeIntervalSince(lastSpeechAt) < 2.5,
                       Self.isPartialRepeat(text, previous: lastEmittedRequest) {
                        return false
                    }
                    Log.agent.info("realtime · ignored repeated in-flight request")
                    committedPrefix = committedPrefix.isEmpty
                        ? transcript : committedPrefix + " " + transcript
                    resetTurn()
                    return true
                }
                if RealtimeAudioSession.shared.isLikelyPlaybackEcho(text) {
                    Log.agent.info("realtime · discarded playback echo")
                    committedPrefix = transcript
                    resetTurn()
                    return true
                }
                if Self.isCommittedTranscriptRevision(text, committed: committedPrefix) {
                    Log.agent.info("realtime · discarded revised transcript")
                    committedPrefix = transcript
                    resetTurn()
                    return true
                }
                if Self.isGoodbye(text) {
                    isSessionActive = false
                    RealtimeAudioSession.shared.end()
                    await emitTurn(text, source: .goodbye, continueSession: false)
                    stopVAD()
                    await stopEngine()
                } else {
                    await emitTurn(text, source: .vad, continueSession: true)
                }
                return true
            }
        }

        if !heardSpeech,
           pendingTurn().isEmpty,
           let lastActivityAt,
           now.timeIntervalSince(lastActivityAt) >= Limits.idleSession {
            await endSession(source: .idle)
            return true
        }
        return false
    }

    private func emitTurn(
        _ text: String,
        source: EndpointSource,
        continueSession: Bool
    ) async {
        lastEndpoint = source
        lastEmittedRequest = text
        committedPrefix = committedPrefix.isEmpty ? transcript : committedPrefix + " " + text
        resetTurn()
        // Release the VAD before `handle` so the next utterance can barge in while
        // a tool is running. Holding `isEndingTurn` across the whole turn is what
        // made “are you checking my email?” never become a turn of its own.
        Log.agent.info("realtime · endpoint \(source.rawValue, privacy: .public)")
        if RealtimeAgent.shared.isThinking {
            RealtimeAgent.shared.interrupt()
        }
        activeTurnTask?.cancel()
        _ = ACPConfirmationGate.shared.cancel()
        turnGeneration &+= 1
        let generation = turnGeneration
        if continueSession {
            // `startVAD` awaits `tick`. Awaiting a tool here would prevent the
            // next utterance from reaching another endpoint until that tool
            // returned (up to twenty seconds). Own the reply separately.
            activeTurnTask = Task { @MainActor [weak self] in
                if let testHandler = self?.turnHandlerForTesting {
                    await testHandler(text)
                } else {
                    _ = await RealtimeAgent.shared.handle(text, source: .voice)
                }
                guard let self, self.turnGeneration == generation, self.isSessionActive else {
                    return
                }
                self.activeTurnTask = nil
                self.lastActivityAt = Date()
                ActivationController.shared.markListening()
                IslandState.shared.showAgentListening(transcript: "", level: 0)
            }
            return
        }
        _ = await RealtimeAgent.shared.handle(text, source: .voice)
        lastActivityAt = Date()
    }

    /// Wait for a lightweight test turn before asserting its reply.
    func waitForActiveTurnForTesting() async {
        await activeTurnTask?.value
    }

    func noteAssistantReply(_ text: String) {
        lastReply = text
    }

    private func resetTurn() {
        transcript = ""
        heardSpeech = false
        speechBeganAt = nil
        lastSpeechAt = nil
        lastActivityAt = Date()
        level = 0
    }

    private func pendingTurn() -> String {
        transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func pending(full: String, committed: String) -> String {
        let trimmed = full.trimmingCharacters(in: .whitespacesAndNewlines)
        if committed.isEmpty { return trimmed }
        if trimmed.hasPrefix(committed) {
            return String(trimmed.dropFirst(committed.count))
                .replacingOccurrences(of: #"^[\s\p{P}]+"#, with: "", options: .regularExpression)
        }
        let normalizedFull = normalized(trimmed)
        let normalizedCommitted = normalized(committed)
        if normalizedFull == normalizedCommitted { return "" }
        if normalizedFull.hasPrefix(normalizedCommitted + " ") {
            // Use normalized words only to locate the boundary. Preserve the
            // original casing and punctuation of the newly spoken request.
            let wordCount = normalizedCommitted.split(separator: " ").count
            let original = trimmed as NSString
            let range = NSRange(location: 0, length: original.length)
            let words = try? NSRegularExpression(pattern: #"[\p{L}\p{N}]+"#)
                .matches(in: trimmed, range: range)
            if let words, words.count >= wordCount, wordCount > 0 {
                let last = words[wordCount - 1].range
                return original.substring(from: last.location + last.length)
                    .replacingOccurrences(of: #"^[\s\p{P}]+"#, with: "", options: .regularExpression)
            }
        }
        return trimmed
    }

    /// Apple SpeechAnalyzer publishes cumulative volatile text. A punctuation
    /// or casing revision of the just-committed turn must not become a second
    /// tool request after `pending` can no longer strip an exact prefix.
    private static func isCommittedTranscriptRevision(_ text: String, committed: String) -> Bool {
        let heard = normalized(text)
        let earlier = normalized(committed)
        guard heard.count >= Limits.minCharacters, !earlier.isEmpty else { return false }
        return earlier == heard || earlier.hasSuffix(" " + heard)
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func repeatWords(_ text: String) -> String {
        normalized(text.lowercased()
            .replacingOccurrences(of: "what's", with: "what is")
            .replacingOccurrences(of: "what’s", with: "what is"))
    }

    private static func isPartialRepeat(_ text: String, previous: String) -> Bool {
        let current = repeatWords(text)
        let earlier = repeatWords(previous)
        guard !earlier.isEmpty, current.split(separator: " ").count <= 3 else { return false }
        return earlier.hasPrefix(current + " ")
    }

    private static func isInFlightRepeat(_ text: String, previous: String) -> Bool {
        let current = repeatWords(text)
        return !current.isEmpty &&
            (current == repeatWords(previous) || isPartialRepeat(text, previous: previous))
    }

    static func transcriptBoundarySelfTestFailures() -> [String] {
        var failures: [String] = []
        if pending(full: "Check email.", committed: "check email") != "" {
            failures.append("a revised cumulative transcript became a new turn")
        }
        if pending(full: "Check email. What about the calendar?", committed: "Check email")
            != "What about the calendar?" {
            failures.append("a new turn was lost after a punctuation revision")
        }
        if pending(full: "Check email. Open Safari now.", committed: "check email")
            != "Open Safari now." {
            failures.append("a revised prefix changed the new request's casing")
        }
        if !isCommittedTranscriptRevision("check email", committed: "Check email.") {
            failures.append("the old request could be re-emitted")
        }
        if isCommittedTranscriptRevision("what about the calendar", committed: "Check email") {
            failures.append("a novel request was mistaken for an old revision")
        }
        if !isInFlightRepeat("What is", previous: "What's the content of my calendar for today?") {
            failures.append("a partial repeat interrupted its original calendar read")
        }
        if isInFlightRepeat("Open Safari", previous: "What's on my calendar?") {
            failures.append("a different request was suppressed as a repeat")
        }
        return failures
    }

    private static func isGoodbye(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return [
            "that's all", "thats all", "that's it", "thats it",
            "goodbye", "good bye", "stop listening", "go to sleep",
            "nothing else", "we're done", "we are done",
        ].contains { lowered.contains($0) }
    }
}

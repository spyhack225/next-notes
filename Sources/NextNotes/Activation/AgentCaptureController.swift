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

    private let capture = AudioCapture()
    private var engine: (any TranscriptionEngine)?
    private var consumeTask: Task<Void, Never>?
    private var vadTask: Task<Void, Never>?
    private var heardSpeech = false
    private var speechBeganAt: Date?
    private var lastSpeechAt: Date?
    private var lastActivityAt: Date?
    private var committedPrefix = ""
    private var isEndingTurn = false
    private var captureAudio = true

    func begin() async {
        await beginSession(captureAudio: !SelfTest.isRunning)
    }

    func beginSession(captureAudio: Bool = true) async {
        if isSessionActive { return }
        self.captureAudio = captureAudio
        isSessionActive = true
        ActivationController.shared.markListening()
        lastEndpoint = .none
        lastReply = ""
        resetTurn()
        WakeWordAudioMonitor.shared.beginHold()
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
        lastEndpoint = source
        stopVAD()
        await stopEngine()
        WakeWordAudioMonitor.shared.endHold()
        let leftover = pendingTurn()
        if source == .done, leftover.count >= Limits.minCharacters {
            await emitTurn(leftover, source: .done, continueSession: false)
        } else if lastReply.isEmpty {
            IslandState.shared.showAgentReply(source == .idle ? "Going quiet." : "Stopped.")
            ActivationController.shared.finishAgent()
        } else {
            IslandState.shared.showAgentReply(lastReply)
            ActivationController.shared.finishAgent()
        }
        transcript = ""
        heardSpeech = false
    }

    /// Old name: callers that meant “user pressed Done” now end the session.
    func finish() async {
        await endSession(source: .done)
    }

    /// Self-test / wake remainder: speech then silence, no Done.
    func simulateSpeech(_ text: String, level: Float = 0.3) {
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
        try capture.start(outputFormat: format, onBuffer: { chunk in
            Task { await engine.feed(chunk) }
        }, onLevel: { level in
            Task { @MainActor in
                AgentCaptureController.shared.noteLevel(level)
            }
        })
    }

    private func stopEngine() async {
        capture.stop()
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
            if ActivationController.shared.mode == .agentWorking {
                RealtimeAgent.shared.interrupt()
            }
            heardSpeech = true
            if speechBeganAt == nil { speechBeganAt = Date() }
            lastSpeechAt = Date()
            lastActivityAt = Date()
        }
        IslandState.shared.showAgentListening(transcript: transcript, level: level)
    }

    @discardableResult
    private func tick(force: Bool) async -> Bool {
        guard isSessionActive, !isEndingTurn else { return false }
        let now = Date()

        if heardSpeech,
           let lastSpeechAt,
           let began = speechBeganAt,
           now.timeIntervalSince(lastSpeechAt) >= Limits.endpointSilence,
           now.timeIntervalSince(began) >= Limits.minSpeech,
           (level <= Limits.silenceLevel || force) {
            let text = pendingTurn()
            if text.count >= Limits.minCharacters {
                if Self.isGoodbye(text) {
                    isSessionActive = false
                    await emitTurn(text, source: .goodbye, continueSession: false)
                    stopVAD()
                    await stopEngine()
                    WakeWordAudioMonitor.shared.endHold()
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
        isEndingTurn = true
        lastEndpoint = source
        committedPrefix = committedPrefix.isEmpty ? transcript : committedPrefix + " " + text
        resetTurn()
        Log.agent.info("realtime · endpoint \(source.rawValue, privacy: .public)")
        _ = await RealtimeAgent.shared.handle(text, source: .voice)
        isEndingTurn = false
        lastActivityAt = Date()
        if continueSession, isSessionActive {
            ActivationController.shared.markListening()
            IslandState.shared.showAgentListening(transcript: "", level: 0)
        }
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
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
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

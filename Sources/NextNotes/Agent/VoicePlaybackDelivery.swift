import Foundation

/// Generated text stays in the feed. Conversational context separately records
/// complete clauses acknowledged by the output backend, never guessed words or
/// physical audibility. A partially played clause is conservatively unconfirmed.
struct VoiceSpeechDelivery: Codable, Equatable {
    var completedText: String = ""
    var status: String = "pending"
    var availabilityMessage: String? = nil
}

@MainActor
final class VoicePlaybackDelivery {
    static let shared = VoicePlaybackDelivery()
    private var injectedOutput: OutputScheduler?
    func installOutputForTesting(_ output: OutputScheduler?) -> Bool {
        guard SelfTest.isRunning, ["--selftest-voice-delivery", "--selftest-voice-turn-routing", "--selftest-island", "--selftest-voice-duplex-work"].contains(SelfTest.requested ?? ""),
              output?.permitsHarness != false else { return false }
        injectedOutput = output
        return true
    }
    var installedOutputForTesting: OutputScheduler? {
        guard SelfTest.isRunning, ["--selftest-voice-delivery", "--selftest-voice-turn-routing", "--selftest-island", "--selftest-voice-duplex-work"].contains(SelfTest.requested ?? ""),
              injectedOutput?.permitsHarness != false else { return nil }
        return injectedOutput
    }
    func outputSessionOpened() { (injectedOutput ?? OutputScheduler.shared).sessionOpened() }
    func outputSessionClosed() { (injectedOutput ?? OutputScheduler.shared).sessionClosed() }
    func flushOutput(userHasFloor: Bool) -> Bool { (injectedOutput ?? OutputScheduler.shared).flush(userHasFloor: userHasFloor) }
    func enqueueApproval(requestID: String) { (injectedOutput ?? OutputScheduler.shared).enqueueApproval(requestID: requestID) }
    func withdrawApproval(requestID: String) { (injectedOutput ?? OutputScheduler.shared).withdrawApproval(requestID: requestID) }
    func withdrawQuestion(_ id: TaskID, requestID: String) {
        (injectedOutput ?? OutputScheduler.shared).withdrawQuestion(id, requestID: requestID)
    }
    /// The SAME scheduler owns an answer and delivery priority. The existing
    /// confined injected output is also the one receiving playback callbacks.
    func beginAnswer(turn: TurnID?) -> OutputHandle {
        (injectedOutput ?? OutputScheduler.shared).beginAnswer(turn: turn)
    }
    func noteUserBargeIn() { (injectedOutput ?? OutputScheduler.shared).noteUserBargeIn() }
    private var outputID: OutputID?
    private var outputGeneration: UInt64?
    private var turn = -1
    private var messageID: UUID?
    private var queued = 0
    private var enqueuedAny = false
    private var completed: [String] = []
    private var interrupted = false

    private var snapshot: VoiceSpeechDelivery {
        VoiceSpeechDelivery(completedText: completed.joined(separator: " "),
                            status: interrupted ? "interrupted" : queued > 0 || !enqueuedAny ? "pending" : "completed",
                            availabilityMessage: AgentSpeechSynthesizer.shared.outputAvailability?.message)
    }

    func noteBegan(output: OutputID, generation: UInt64) {
        outputID = output
        outputGeneration = generation
    }

    func receive(_ event: AgentSpeechSynthesizer.PlaybackEvent) {
        switch event {
        case .began:
            outputID = nil
            outputGeneration = nil
            messageID = nil
            queued = 0
            enqueuedAny = false
            completed = []
            interrupted = false
        case .enqueued:
            enqueuedAny = true
            queued += 1
        case .completed(let clause):
            queued = max(0, queued - 1)
            completed.append(clause)
        case .interrupted:
            queued = max(0, queued - 1)
            interrupted = true
        case .startAcknowledged, .resumeRequested, .resumeAcknowledged: break
        }
        if let messageID { AgentSession.shared.updateSpeech(messageID: messageID, delivery: snapshot) }
        (injectedOutput ?? OutputScheduler.shared).receive(event)
    }

    func endSession() {
        messageID = nil
        turn = -1
        outputID = nil
        outputGeneration = nil
        queued = 0
        enqueuedAny = false
        completed = []
        interrupted = false
    }

    func bind(messageID: UUID, output: OutputID, turn: Int) {
        guard outputID == output,
              outputGeneration == AgentSpeechSynthesizer.shared.outputGeneration else { return }
        self.messageID = messageID
        AgentSession.shared.updateSpeech(messageID: messageID, delivery: snapshot)
    }
}

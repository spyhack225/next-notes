import Foundation

/// Generated text stays in the feed. Conversational context separately records
/// complete clauses acknowledged by the output backend, never guessed words or
/// physical audibility. A partially played clause is conservatively unconfirmed.
struct VoiceSpeechDelivery: Codable, Equatable {
    var completedText: String = ""
    var status: String = "pending"
}

@MainActor
final class VoicePlaybackDelivery {
    static let shared = VoicePlaybackDelivery()
    private var turn = -1
    private var messageID: UUID?
    private var queued = 0
    private var enqueuedAny = false
    private var completed: [String] = []
    private var interrupted = false

    private var snapshot: VoiceSpeechDelivery {
        VoiceSpeechDelivery(completedText: completed.joined(separator: " "),
                            status: interrupted ? "interrupted" : queued > 0 || !enqueuedAny ? "pending" : "completed")
    }

    func receive(_ event: AgentSpeechSynthesizer.PlaybackEvent) {
        switch event {
        case .began:
            turn = RealtimeAgent.shared.currentGeneration
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
        case .startAcknowledged: break
        }
        if let messageID { AgentSession.shared.updateSpeech(messageID: messageID, delivery: snapshot) }
        VoiceAnnouncementQueue.shared.receive(event)
    }

    func endSession() {
        messageID = nil
        turn = -1
        queued = 0
        enqueuedAny = false
        completed = []
        interrupted = false
    }

    func bind(messageID: UUID, turn: Int) {
        guard self.turn == turn else { return }
        self.messageID = messageID
        AgentSession.shared.updateSpeech(messageID: messageID, delivery: snapshot)
    }
}

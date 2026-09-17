import Foundation

/// Work completion and spoken delivery have different lifetimes. Keep an update
/// until its clauses complete; an interruption returns unfinished clauses to the
/// queue for the next quiet interval. Session close discards delivery only.
@MainActor
final class VoiceAnnouncementQueue {
    static let shared = VoiceAnnouncementQueue()
    private var pending: [String] = []
    private var inFlight: [String]?

    func enqueue(_ text: String) {
        guard AgentCaptureController.shared.isSessionActive else { return }
        pending.append(text)
    }

    func clear() {
        pending.removeAll()
        inFlight = nil
    }

    func receive(_ event: AgentSpeechSynthesizer.PlaybackEvent) {
        guard var clauses = inFlight else { return }
        switch event {
        case .completed(let text):
            guard clauses.first == text else { return }
            clauses.removeFirst()
            inFlight = clauses.isEmpty ? nil : clauses
        case .interrupted:
            // No word-level timing is inferred for the current partial clause.
            // Replay that clause, retaining all still-unspoken result information.
            pending.insert(clauses.joined(separator: " "), at: 0)
            inFlight = nil
        default: break
        }
    }

    @discardableResult
    func flush(userHasFloor: Bool) -> Bool {
        guard AgentCaptureController.shared.isSessionActive, !userHasFloor,
              !RealtimeAgent.shared.voiceInputActive, !RealtimeAgent.shared.isThinking,
              !RealtimeAudioSession.shared.isSpeaking,
              !AgentSpeechSynthesizer.shared.isSpeaking,
              inFlight == nil, !pending.isEmpty else { return false }
        let text = pending.removeFirst()
        let brief = AgentSpeechPolicy.spokenClauses(text).prefix(2).joined(separator: " ")
        let spoken = !brief.isEmpty && brief.count <= 300
            ? brief : "There's an update from your background task. The details are in the conversation."
        inFlight = AgentSpeechPolicy.spokenClauses(spoken)
        RealtimeAudioSession.shared.speak(spoken)
        return true
    }
}

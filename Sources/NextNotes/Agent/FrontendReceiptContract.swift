import Foundation

/// The frontend creates a decision; only the existing Bridge's committed receipt
/// admits work. This payload owns no task, tool, model or playback state.
struct FrontendDecisionPayload: Codable, Sendable, Equatable {
    var intent: String
    var taskNumber: Int? = nil
    var objective: String? = nil
    var acknowledgement: String? = nil
    var approval: String? = nil
    var amendment: String? = nil
    var task: Int? = nil
    var decision: String? = nil
    var change: String? = nil

    func controlChunk() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return "<decision>" + String(decoding: try encoder.encode(self), as: UTF8.self) + "</decision>"
    }
}

enum ObjectiveFidelity {
    private static let insignificant: Set<String> = ["the", "and", "for", "with", "please", "can", "could", "would", "you", "your", "me", "my", "it", "its", "that", "this", "these", "those", "them", "him", "her", "his", "there", "then", "just", "also", "now", "again"]
    private static func tokens(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }
            .filter { ($0.count >= 3 || $0.allSatisfy(\.isNumber) || $0 == "no") && !insignificant.contains(String($0)) }
            .map { $0.hasSuffix("s") ? String($0.dropLast()) : String($0) })
    }
    static func accepts(_ objective: String, userWords: String) -> Bool {
        let text = objective.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty && text.count <= 400 && !text.contains("://")
            && tokens(userWords).isSubset(of: tokens(text))
    }
}

@MainActor
enum ReceiptAck {
    static let maxWords = 8
    static let fallback = "I'm on it."
    private static let banned = ["wait", "hold on", "moment", "second", "minute", "shortly", "soon", "let you know", "get back to you", "stay tuned", "thanks for", "thank you", "great question", "done", "finished", "complete", "all set", "task", "background", "tool", "://"]
    static func accept(_ ack: String?) -> String? {
        guard let text = ack?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        let lower = text.lowercased()
        guard text.split(whereSeparator: \.isWhitespace).count <= maxWords,
              AgentSpeechPolicy.spokenClauses(text).count == 1, !text.hasSuffix("?"),
              !banned.contains(where: lower.contains),
              lower.range(of: #"\d{3,}"#, options: .regularExpression) == nil,
              !text.contains("/"), !text.contains("\\"), !text.contains("@"),
              AgentSpeechPolicy.isSpeakableReply(text) else { return nil }
        return text
    }
    static func reply(for receipt: TaskReceipt, modelAck: String?) -> String {
        guard receipt.status == .accepted else { return receipt.spokenAcknowledgment }
        return accept(modelAck) ?? fallback
    }
}

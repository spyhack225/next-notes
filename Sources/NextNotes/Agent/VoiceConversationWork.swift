import Foundation

/// A work item outlives individual microphone turns. Input revisions invalidate
/// unexecuted plans, not completed tool results or operations already underway.
/// All accesses share the conversation's main actor; no audio callback waits here.
@MainActor
final class VoiceConversationWork {
    let id = UUID()
    let original: String
    private(set) var revision = 0
    private(set) var followUps: [String] = []

    init(_ original: String) { self.original = original }

    func append(_ text: String) {
        followUps.append(text)
        revision += 1
    }

    var prompt: String {
        guard !followUps.isEmpty else { return original }
        return """
            Original user request (retain unfinished parts):
            \(original)

            Subsequent user speech, in order:
            \(followUps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))

            Interpret these as one ongoing conversation. Apply corrections to the
            original request. An acknowledgement does not cancel work. A status
            question asks about this work. If the user clearly cancels or replaces
            the request, respect that. Never repeat a step whose result is provided.
            """
    }
}

/// Routing and an ordinary answer share one stream. A protocol prefix is never
/// spoken, and an invalid prefix never escalates to tool execution.
enum VoiceResponseEnvelope: Equatable {
    case pending
    case answer(String)
    case tools
    case invalid

    static func parse(_ snapshot: String) -> Self {
        let text = snapshot.trimmingCharacters(in: .whitespacesAndNewlines)
        let answer = "<answer/>"
        let answerWrapper = "<answer>"
        let tools = "<use_tools/>"
        if text.hasPrefix(answer) || text.hasPrefix(answerWrapper) {
            let prefix = text.hasPrefix(answer) ? answer : answerWrapper
            var body = String(text.dropFirst(prefix.count))
            let closing = "</answer>"
            if let count = (1...closing.count).reversed().first(where: {
                body.hasSuffix(String(closing.prefix($0)))
            }) { body.removeLast(count) }
            return .answer(body)
        }
        if text.hasPrefix(tools) { return .tools }
        if answer.hasPrefix(text) || answerWrapper.hasPrefix(text) || tools.hasPrefix(text) {
            return .pending
        }
        if text.hasPrefix("<") || text.hasPrefix("{") { return .invalid }
        return .answer(text)
    }
}

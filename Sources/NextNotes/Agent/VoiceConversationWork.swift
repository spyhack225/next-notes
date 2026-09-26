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

    /// The markers that mean "this is a call, not an answer". P1-04: a model that reached
    /// for a tool and wrote the call instead of a header used to fail the turn with "The
    /// model returned an invalid response header." — the one case where the planner could
    /// have run the call and was never asked.
    private static let callMarkers = [
        "<tool_call", "<function", "<invoke", "{\"name\"", "{\"tool\"", "[TOOL_CALLS]",
        "<|python_tag|>", "name=\"",
    ]

    static func parse(_ snapshot: String) -> Self {
        let text = strippingReasoning(snapshot).trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = text.lowercased()
        let answer = "<answer/>"
        let answerWrapper = "<answer>"
        let tools = "<use_tools/>"
        // Case-insensitive, and the unslashed spelling: a model that writes `<Answer/>` or
        // `<use_tools>` meant exactly one thing, and the difference is capitalisation.
        if lowered.hasPrefix(answer) || lowered.hasPrefix(answerWrapper) {
            let prefix = lowered.hasPrefix(answer) ? answer.count : answerWrapper.count
            var body = String(text.dropFirst(prefix))
            let closing = "</answer>"
            if let count = (1...closing.count).reversed().first(where: {
                body.lowercased().hasSuffix(String(closing.prefix($0)))
            }) { body.removeLast(count) }
            return .answer(body)
        }
        if lowered.hasPrefix(tools) || lowered.hasPrefix("<use_tools>") { return .tools }
        if answer.hasPrefix(lowered) || answerWrapper.hasPrefix(lowered) || tools.hasPrefix(lowered)
            || callMarkers.contains(where: { $0.hasPrefix(lowered) }) {
            return .pending
        }
        if callMarkers.contains(where: { lowered.hasPrefix($0) }) { return .tools }
        if text.hasPrefix("<") || text.hasPrefix("{") { return .invalid }
        return .answer(text)
    }

    /// A `<think>` block is reasoning, in whatever case the model spelled it.
    private static func strippingReasoning(_ text: String) -> String {
        guard text.contains("<think>") else { return text }
        var out = text
        while let open = out.range(of: "<think>") {
            if let close = out[open.upperBound...].range(of: "</think>") {
                out = String(out[..<open.lowerBound]) + String(out[close.upperBound...])
            } else {
                out = String(out[..<open.lowerBound])
                break
            }
        }
        return out
    }
}

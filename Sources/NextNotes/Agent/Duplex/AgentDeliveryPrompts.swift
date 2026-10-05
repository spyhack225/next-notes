import Foundation

@MainActor
enum AgentDeliveryPrompts {
    static let resultRules = """
        This is the result of work the person asked for earlier. It is not a new request.
        Tell them the result in one or two short spoken sentences, as your own work.
        Open with the actual result, finding, problem or question. Never open with okay,
        got it, done, all set, task complete or anything like it.
        If there are several results, cover every one of them.
        If a result asks them for something, ask it plainly and stop.
        If the full details are on screen, give the gist and say where to look.
        Do not read identifiers, file paths, web addresses or long numbers.
        Do not mention background work, tasks, tools or how the work was done.
        Add nothing that is not in the results. Never call unfinished work finished.
        """
    static let carriedOverRule = "They were away when this finished. Begin While you were away, and continue."
    static func resultInstructions(carriedOver: Bool) -> String {
        let rules = resultRules + (carriedOver ? "\n" + carriedOverRule : "")
        if SelfTest.isRunning {
            // Explicit admitted harness context: never use owner identity, frozen
            // memory or Now facts populated by an earlier flag consumer. The SAME
            // persona assembler still uses its existing guarded temporary base.
            let grounding = AgentGrounding(assistantName: "", userFullName: "",
                folders: [], indexedItems: 0, surfaces: [])
            return AgentPromptContext.assemble(.voiceAnswer, rules: rules,
                memory: "", now: "", grounding: grounding).system
        }
        return AgentPromptContext.assemble(.voiceAnswer, rules: rules).system
    }
    static func facts(_ batch: [DeliveryItem]) -> String {
        "Results of work you started earlier (not a new request):\n" + batch.enumerated().map { index, item in
            let outcome: String = switch item.kind {
            case .result: "done"
            case .failure: "did not work"
            case .cancelled: "stopped"
            case .question, .approval: "waiting for an answer"
            }
            return "\(index + 1). Work: \(item.title). Outcome: \(outcome). Result: \(item.facts)"
        }.joined(separator: "\n")
    }
    static func acceptedPhrase(_ raw: String) -> String? {
        // Reject protocol/unsafe narration before scrub: removing a raw path or
        // identifier does not make unsupported model wording grounded.
        let lower = raw.lowercased()
        guard !["task", "background", "tool", "://"].contains(where: lower.contains),
              raw.range(of: #"\d{6,}"#, options: .regularExpression) == nil,
              raw.range(of: #"(?:^|\s)(?:/[^\s]+|[A-Za-z]:\\[^\s]+)"#, options: .regularExpression) == nil else { return nil }
        let spoken = RealtimeAgent.voiceSafeReply(raw)
        guard !AgentSpeechPolicy.spokenClauses(spoken).isEmpty else { return nil }
        return spoken
    }
}

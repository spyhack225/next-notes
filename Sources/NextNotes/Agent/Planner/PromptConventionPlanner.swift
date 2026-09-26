import Foundation

/// The planner as it behaves without a native tool channel: the catalogue is prose in the
/// system prompt, the model writes `<tool_call>{…}</tool_call>`, and P1-04's parser reads it.
///
/// This is not a legacy path kept for a model we have not taught yet. It is what every turn
/// does until the native channel is switched on, it is the rollback path, and it is the only
/// path a server that cannot take `tools` will ever take — so it is neither deleted nor made
/// hard to reach. The prompt is exactly the one the loop built before any of this existed,
/// which is what makes `--planner prompt` a fair comparison rather than a different experiment.
struct PromptConventionPlanner: AgentPlannerBackend {
    let provider: any LLMProvider

    var label: String { "prompt-convention" }

    func round(
        system: String, messages: [LLMChatMessage], manifest: AgentCapabilityManifest,
        maxTokens: Int, interactive: Bool,
        onText: @escaping @Sendable (String) async -> Void
    ) async throws -> PlannerRound {
        var assembled = ""
        var cutOff = false
        do {
            let stream = await self.stream(
                system: system, messages: messages, maxTokens: maxTokens, interactive: interactive)
            for try await chunk in stream {
                try Task.checkCancellation()
                if chunk.isEmpty { continue }
                assembled += chunk
                await onText(assembled)
            }
        } catch let error as OpenRouterError {
            // P0-17: a reply cut off with visible text keeps it, and one cut off before
            // anything is visible ends the turn on the cut-off's own sentence.
            // `cutOff` carries whether there was visible text to keep, not the text.
            if case .cutOff(let hadVisibleText) = error, hadVisibleText {
                cutOff = true
            } else {
                throw LlamaGrammarPlanner.roundError(from: error, visible: assembled)
            }
        } catch {
            throw LlamaGrammarPlanner.roundError(from: error, visible: assembled)
        }
        let parsed = AgentToolCallParser.parse(
            assembled, knownNames: LlamaGrammarPlanner.callNames(manifest))
        return PlannerRound(
            text: parsed.prose, calls: parsed.calls, malformed: parsed.malformed,
            raw: assembled, cutOff: cutOff)
    }
}

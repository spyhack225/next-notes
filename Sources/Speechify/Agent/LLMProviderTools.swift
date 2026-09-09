import Foundation

/// Tool calling, added to Phase 4's providers rather than built into them.
///
/// An extension, and one that both providers get for free, because tool calling here is a
/// prompt convention rather than a runtime feature: the catalogue goes into the system
/// message as a `<tools>` block and the calls come back as `<tool_call>` tags in ordinary
/// text. Qwen3.5 was tuned on exactly that shape.
///
/// Apple's `Tool` protocol was the obvious alternative for the second provider and is the
/// wrong shape twice over: it wants a compile-time `@Generable` argument type per tool,
/// which a catalogue built at runtime cannot supply, and it *performs* the call itself —
/// the one thing this agent must never do. Every write in Phase 7 is a question for a person
/// before it is an action, so the model's job ends at naming one.
extension LLMProvider {
    func complete(
        system: String,
        user: String,
        maxTokens: Int,
        tools: [WorkspaceTool]
    ) async throws -> LLMCompletion {
        try await complete(
            system: tools.isEmpty ? system : system + "\n\n" + AgentPrompts.toolBlock(tools: tools),
            user: user,
            maxTokens: maxTokens
        )
    }
}

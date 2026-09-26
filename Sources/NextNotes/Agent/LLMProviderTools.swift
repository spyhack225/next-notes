import Foundation

/// Tool calling is native wherever the reader supports it, and a prompt convention where it
/// does not.
///
/// Four channels, one answer, and the choice is `PlannerBackends`' alone:
///
/// - **The app's own runtime** (llama.cpp, any GGUF): a GBNF grammar built from the turn's
///   `AgentCapabilityManifest`, so the sampler cannot emit an unoffered tool name or an
///   argument object of the wrong shape. The prompt is unchanged — the catalogue stays prose
///   and the call stays Hermes JSON — which is what keeps P0-18's KV prefix reuse holding.
/// - **Apple Foundation Models**: one `Tool` per selected entry with a `GenerationSchema`
///   built from `DynamicGenerationSchema`, and a `Tool.call` body that is a *bridge* into
///   `ToolStepRunner`.
/// - **OpenRouter and a model app on this Mac**: a `tools` array in the request body with
///   `tool_choice: "auto"`, and the calls reassembled out of the `tool_calls` stream.
/// - **Anything else**, and the rollback path: today's prose catalogue plus the Hermes
///   instruction, read by P1-04's tolerant parser.
///
/// ## Why the framework never gets to perform a call
///
/// The old note here rejected Apple's `Tool` protocol because it "performs the call itself".
/// That objection is right and it is now answered by construction rather than by avoidance:
/// `ManifestTool.call` does one thing — hand an `AgentToolCall` to `ToolStepRunner` and map
/// the outcome to text — and `ToolStepRunner` is the only caller of `AgentToolExecutor.run`
/// inside the planner. The framework still only ever *names* a call, and every write is still
/// a question for a person before it is an action.
///
/// The second old objection — that `Tool` wants a compile-time `@Generable` argument type
/// per tool — is answered by `Arguments = GeneratedContent`, which a runtime-built catalogue
/// can supply.
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

    /// The same convention for a mixed catalogue — the meeting review's Workspace tools plus
    /// the knowledge index's read tools.
    func complete(
        system: String,
        user: String,
        maxTokens: Int,
        tools: [AgentTool]
    ) async throws -> LLMCompletion {
        try await complete(
            system: tools.isEmpty ? system : system + "\n\n" + AgentPrompts.toolBlock(tools: tools),
            user: user,
            maxTokens: maxTokens
        )
    }
}

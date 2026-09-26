import Foundation

/// The planner on an endpoint that speaks OpenAI-style structured tool calls: OpenRouter, or
/// a model app already running on this Mac.
///
/// The request body carries `tools` and `tool_choice: "auto"`, and the calls come back as
/// `tool_calls` in the stream rather than as tags in prose. That is the whole difference, and
/// it removes a class of failure rather than repairing it: a model that wanted a tool cannot
/// answer in prose by accident, and a call cut off mid-arguments cannot be a call at all.
///
/// The tag round trip is not gone. `OpenAICompatibleLLMProvider` assembles a server's
/// `tool_calls` deltas back into `<tool_call>` tags and `AgentToolCallParser` reads them, so
/// there is one reader of a planner completion whether the model wrote tags or the server
/// structured them — and a model that ignored the `tools` field entirely still arrives through
/// P1-04's tolerant parser, which is the whole reason that parser is kept.
final class OpenAIToolsPlanner: AgentPlannerBackend, @unchecked Sendable {
    let provider: any LLMProvider
    /// Today's behaviour, used when a server refuses the `tools` field.
    private let fallback: PromptConventionPlanner
    /// Set the first time a server refuses the field. A lock rather than a `var` because a
    /// backend is handed to a `@Sendable` round, and one refusal should cost a round once
    /// rather than once per round for the rest of the turn.
    private let refused = RefusalLatch()

    var label: String { "openai-tools" }

    init(provider: any LLMProvider) {
        self.provider = provider
        self.fallback = PromptConventionPlanner(provider: provider)
    }

    /// Once a server has refused the field, this turn runs the prompt convention — the exact
    /// path the setting was off before — rather than failing a turn over a wire detail.
    private var toolsRefused: Bool { refused.isSet }

    func round(
        system: String, messages: [LLMChatMessage], manifest: AgentCapabilityManifest,
        maxTokens: Int, interactive: Bool,
        onText: @escaping @Sendable (String) async -> Void
    ) async throws -> PlannerRound {
        if toolsRefused {
            return try await fallback.round(
                system: system, messages: messages, manifest: manifest,
                maxTokens: maxTokens, interactive: interactive, onText: onText)
        }
        let tools = manifest.toolWireDefinitions()
        var assembled = ""
        do {
            let stream = await provider.streamConversation(
                system: system, messages: messages, maxTokens: maxTokens, tools: tools)
            // One user message goes out as a `user` message, exactly as the prompt-convention
            // backend sends it: the `tools` field is the only difference between the two
            // channels, and a comparison run needs the prompt to be the other constant.
            for try await chunk in stream {
                try Task.checkCancellation()
                if chunk.isEmpty { continue }
                assembled += chunk
                await onText(assembled)
            }
        } catch {
            // A 400 naming the field is the one failure worth a second try, and the planner
            // makes exactly one: the same prompt without it is a path this app ran for a year.
            guard Self.looksLikeToolsRefusal(error) else {
                throw LlamaGrammarPlanner.roundError(from: error, visible: assembled)
            }
            refused.mark()
            Log.agent.info("planner tools field refused · prompt convention for the rest of the turn")
            return try await fallback.round(
                system: system, messages: messages, manifest: manifest,
                maxTokens: maxTokens, interactive: interactive, onText: onText)
        }
        let parsed = AgentToolCallParser.parse(
            assembled, knownNames: LlamaGrammarPlanner.callNames(manifest))
        return PlannerRound(
            text: parsed.prose, calls: parsed.calls, malformed: parsed.malformed, raw: assembled)
    }

    /// Whether an error is the endpoint refusing the `tools` field rather than the request.
    ///
    /// Narrow on purpose, and it must name tools: a 429, a quota error or a model that simply
    /// failed is not a refusal of anything, and re-asking as a plain prompt would turn one
    /// cloud failure into two.
    static func looksLikeToolsRefusal(_ error: Error) -> Bool {
        let text = error.localizedDescription.lowercased()
        guard text.contains("tool") else { return false }
        return text.contains("not supported") || text.contains("unsupported")
            || text.contains("invalid") || text.contains("unknown")
            || text.contains("unrecognized") || text.contains("unrecognised")
            || text.contains("extra") || text.contains("not permitted")
    }
}

/// A one-way boolean, locked. `AgentCapabilityMirror` in the manifest file is the same shape
/// for the same reason: a value read from a `@Sendable` round that only ever goes false→true.
private final class RefusalLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func mark() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

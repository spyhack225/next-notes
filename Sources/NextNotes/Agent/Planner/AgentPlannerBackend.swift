import Foundation

/// One model round of the tool planner, whatever produced it.
///
/// The backends differ in how a call is *made* — a GBNF grammar over the manifest for llama,
/// Apple's `Tool` protocol, OpenAI's `tools` array, or the Hermes tags a small model was
/// tuned on — and they agree on what a round hands back. That is the point of the type: a
/// backend may not execute a tool, may not decide what a turn may do (that is
/// `AgentCapabilityManifest`), and may not speak to a person. It returns what the model wrote
/// and stops.
struct PlannerRound: Sendable {
    /// Answer text, already free of call markup. Empty on a round that only called a tool.
    var text: String = ""
    /// Names are resolved by the loop (P1-04), not here: resolution reads the manifest and
    /// the registry, and a backend that resolved a name would be a second answer to "what
    /// may this turn do".
    var calls: [AgentToolCall] = []
    /// Always empty for a grammar or native backend — that is what the constraint buys. Never
    /// removed from the type, because the prompt-convention backend is a first-class path and
    /// P1-04's repair loop has to stay reachable for a model not running under a grammar.
    var malformed: [MalformedCall] = []
    /// Exactly what the model wrote, for `PlannerTraceEvent` and the audit log.
    var raw: String = ""
    /// The model spent its allowance and stopped (`finish_reason: length`). P0-17's honesty
    /// rule: a reply that was cut off says so.
    var cutOff: Bool = false
}

/// How a round failed. Deliberately the shapes the loop already handled, so swapping
/// `provider.stream` for a backend changes what a failure *means* and nothing else.
enum PlannerRoundError: Error, Sendable {
    /// The model was unavailable — the one failure a turn may honestly retry elsewhere.
    case modelUnavailable(String)
    /// P1-10's third shape: the prompt did not fit the reader, which is the answer being too
    /// big and not the model failing.
    case contextOverflow(String)
    /// Anything else. The loop renders this as one plain sentence and records the reason in
    /// the usage log (P1-10b).
    case failed(String)
    /// Cut off before it wrote anything visible.
    case cutOff
}

/// One model round. Never executes a tool.
protocol AgentPlannerBackend: Sendable {
    /// The provider this round talks to, so the shared request shape above is one place.
    var provider: any LLMProvider { get }

    /// - Parameters:
    ///   - interactive: the voice frontend's own round, which may take the higher-priority
    ///     lane. The grammar and the tool shape are the same either way.
    ///   - onText: incremental answer text for `AgentToolSpeechTracker.receive`, which already
    ///     ignores anything starting with `<` or `{`.
    func round(
        system: String, messages: [LLMChatMessage], manifest: AgentCapabilityManifest,
        maxTokens: Int, interactive: Bool,
        onText: @escaping @Sendable (String) async -> Void
    ) async throws -> PlannerRound

    /// Plain words for `usage.jsonl` and a self-test's sub-line. Never a person.
    var label: String { get }
}

/// A backend that runs the whole turn inside the model framework. Apple's session owns the
/// call loop, so the planner cannot see round boundaries; the executor arrives as an object
/// and the model decides when to call it.
protocol AgentWholeTurnPlanner: Sendable {
    func runTurn(
        system: String, request: String, manifest: AgentCapabilityManifest,
        executor: any ToolStepExecuting, maxTokens: Int
    ) async throws -> String
    var label: String { get }
}

/// The seam the Apple FM bridge and the planner loop share.
///
/// A protocol rather than the class so a self-test can run Apple's model against a fake
/// executor. Nothing else in the app implements it: `ToolStepRunner` is the only caller of
/// `AgentToolExecutor.run` inside the planner, and a second implementer would be a second
/// answer to "what may this turn do".
///
/// `@MainActor` because the runner is main-actor state and Apple's `Tool.call` body is not:
/// the bridge awaits across the hop rather than reaching into a shared store from off it.
@MainActor
protocol ToolStepExecuting: AnyObject, Sendable {
    /// One call: resolve, check, run, classify. Never speaks to a person and never returns a
    /// sentence one reads — the caller renders `ToolStepEnd`.
    func execute(_ call: AgentToolCall) async -> ToolStepResult
    /// Set on a denial, an infrastructure failure, or a spent budget. The bridge reads it so a
    /// `STOP:` it writes is not contradicted by a model that tries one more call.
    var terminalOutcome: ToolStepOutcome? { get }
}

/// Which backend a turn runs, chosen once before its first round.
enum PlannerBackendChoice: Sendable {
    case rounds(any AgentPlannerBackend)
    case wholeTurn(any AgentWholeTurnPlanner)

    /// A log line and a self-test sub-line both name the backend by this.
    var label: String {
        switch self {
        case .rounds(let backend): backend.label
        case .wholeTurn(let planner): planner.label
        }
    }
}

/// The one request shape a planner round sends, and the reason it is written out once here.
///
/// The planner always has exactly one user message, and before P1-05 it sent it through
/// `stream(system:user:maxTokens:)`. Routing a single message through
/// `streamConversation(system:messages:…)` instead would be *nearly* the same request and
/// measurably not the same one: a provider that folds messages into text prefixes them with
/// the role ("User: …"), which is two tokens per round, which moves the visible budget, which
/// moves the fitted prompt, which moves the reused prefix. So the single-message case keeps
/// the old call and only a real conversation takes the conversation form.
extension AgentPlannerBackend {
    func stream(
        system: String, messages: [LLMChatMessage], maxTokens: Int, interactive: Bool
    ) async -> AsyncThrowingStream<String, Error> {
        if messages.count == 1, messages[0].role == .user, !interactive {
            return await provider.stream(
                system: system, user: messages[0].content, maxTokens: maxTokens)
        }
        return interactive
            ? await provider.streamInteractiveConversation(
                system: system, messages: messages, maxTokens: maxTokens)
            : await provider.streamConversation(
                system: system, messages: messages, maxTokens: maxTokens)
    }

    /// The same, with decoding constrained. Only the in-process runtime takes a grammar; the
    /// protocol default ignores it, which is why `PlannerBackends` is the only caller that
    /// decides a grammar will be enforced.
    func stream(
        system: String, messages: [LLMChatMessage], maxTokens: Int, interactive: Bool,
        grammar: GBNFGrammar
    ) async -> AsyncThrowingStream<String, Error> {
        if messages.count == 1, messages[0].role == .user, !interactive {
            return await provider.stream(
                system: system, user: messages[0].content, maxTokens: maxTokens, grammar: grammar)
        }
        return interactive
            ? await provider.streamInteractiveConversation(
                system: system, messages: messages, maxTokens: maxTokens, grammar: grammar)
            : await provider.streamConversation(
                system: system, messages: messages, maxTokens: maxTokens, grammar: grammar)
    }
}

/// Forced for one process by the live eval's `--planner native|prompt`; nil means the setting.
enum PlannerMode: String, Sendable {
    case native
    case prompt
}

extension AgentWholeTurnPlanner {
    var label: String { "whole-turn" }
}

/// Which backend a turn's reader gets, and why.
///
/// A backend may only be chosen here. `PromptConventionPlanner` is not a lesser path kept for
/// a model we have not taught yet — it is today's behaviour plus P1-04's parser, and it is
/// the rollback path for the setting, so it is never deleted and never made hard to reach.
@MainActor
enum PlannerBackends {
    /// Scripts the framework-owned turn while retaining the production runner and
    /// final action boundary. A harness can never select this in a normal launch.
    static var wholeTurnOverrideForTesting: (any AgentWholeTurnPlanner)?

    /// The choice for a turn, from the provider the turn already resolved (P0-14: one
    /// resolution per turn) and the turn's own manifest.
    ///
    /// `forced` exists for the live eval's `--planner native|prompt`; it never writes a
    /// preference and never survives the process.
    static func make(
        for provider: any LLMProvider, manifest: AgentCapabilityManifest,
        forced: PlannerMode? = nil
    ) async -> PlannerBackendChoice {
        if SelfTest.isRunning, let wholeTurn = wholeTurnOverrideForTesting {
            return .wholeTurn(wholeTurn)
        }
        let mode = forced ?? requestedMode ?? (Settings.shared.agentNativeToolCalling ? .native : .prompt)
        guard mode == .native, !manifest.selected.isEmpty else {
            return .rounds(PromptConventionPlanner(provider: provider))
        }
        switch provider.id {
        case .appleFoundation:
            return .wholeTurn(FoundationModelsToolPlanner())
        case .appLLM:
            // A grammar the native parser refuses is a grammar this build cannot enforce, and
            // an unenforced grammar that looks enforced is worse than no grammar: the model is
            // steered toward a shape nothing checks. One `structuralProblems()` per turn, over
            // a grammar a few hundred bytes long.
            let grammar = LlamaGrammarPlanner.grammar(for: manifest)
            let problems = grammar.structuralProblems()
            if !problems.isEmpty {
                Log.agent.info("planner grammar refused · \(problems.joined(separator: "; "), privacy: .public)")
                return .rounds(PromptConventionPlanner(provider: provider))
            }
            return .rounds(LlamaGrammarPlanner(provider: provider, grammar: grammar))
        case .openRouter, .localServer:
            // A server that does not speak `tools` rejects the request outright, so this is
            // asked before the round rather than repaired after one.
            guard await provider.supportsStructuredToolCalls else {
                return .rounds(PromptConventionPlanner(provider: provider))
            }
            return .rounds(OpenAIToolsPlanner(provider: provider))
        }
    }

    /// `--planner native|prompt`, process-only, and only under the harness so a comparison
    /// run cannot change a preference. Read from the command line rather than stored: the
    /// live eval launches the app with the flag and nothing else needs to set it.
    static var requestedMode: PlannerMode? {
        guard SelfTest.isRunning, let raw = SelfTest.value(after: "--planner") else { return nil }
        return PlannerMode(rawValue: raw)
    }
}

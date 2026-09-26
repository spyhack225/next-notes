import Foundation

/// Which text-generation model writes the notes or answers a turn.
///
/// The local case deliberately does not name a file. What runs on this Mac is
/// `InstalledModelLibrary.activeAgentModelID` — the built-in download or one the user
/// fetched themselves — and the provider reports that file's own name through
/// `displayModelName` instead of claiming to be whichever model shipped this release.
/// A provider identity that names a model the user replaced is how a notes history ends up
/// saying "Gemma" while MiniCPM wrote the notes.
enum LLMProviderID: String, CaseIterable, Sendable, Codable, Identifiable {
    /// The app's own on-device runtime, loading whichever model file the library points at.
    case appLLM
    case appleFoundation
    case openRouter
    /// A model held by an app already running on this Mac — Ollama, LM Studio, or any
    /// other OpenAI-compatible server on loopback.
    case localServer

    /// Reads the stored spelling, including the retired `gemma4E4B` name. Settings and
    /// records written by an older build must keep working: a stored value that no longer
    /// decodes the way it once did silently becomes a different provider, which is how a
    /// model choice changes itself without anybody touching it.
    init?(rawValue: String) {
        switch rawValue {
        case "appLLM", "gemma4E4B": self = .appLLM
        case "appleFoundation": self = .appleFoundation
        case "openRouter": self = .openRouter
        case "localServer": self = .localServer
        default: return nil
        }
    }

    /// The notes and meeting pickers enumerate this to offer a model, and the fallback
    /// chain walks it. `localServer` is deliberately absent from both: it is not one model
    /// but a whole catalogue that may or may not be running, so it is chosen through the
    /// model-role rows in Settings ▸ Agent, and it is never fallen back *to* — falling
    /// back means the built-in model.
    static var allCases: [LLMProviderID] { [.appLLM, .appleFoundation, .openRouter] }

    var id: String { rawValue }

    /// The kind's name. The concrete model's name comes from the provider itself
    /// (`displayModelName`), because only it knows which file the runtime will load.
    var displayName: String {
        switch self {
        case .appLLM: "The model on this Mac"
        case .appleFoundation: "Apple Foundation Model"
        case .openRouter: "OpenRouter"
        case .localServer: "A model app on this Mac"
        }
    }

    /// What the difference actually means to someone choosing between them.
    var summary: String {
        switch self {
        case .appLLM:
            "The model Next Notes runs itself — the built-in download, or one you added in "
                + "Models settings and selected."
        case .appleFoundation:
            "Already on this Mac and fast, but its short context means a long meeting is "
                + "summarised in pieces."
        case .openRouter:
            "Uses the cloud model selected here. Add the API key in Models settings. "
                + "Transcript or Agent prompts are sent to OpenRouter and may incur charges."
        case .localServer:
            "Uses a model from Ollama, LM Studio or another app already running on this "
                + "Mac. Nothing leaves the machine."
        }
    }
}

/// One text-generation model, described the way the notes generator needs it.
///
/// The generator's only real decision is "does this transcript fit in one prompt", so a
/// provider has to answer two questions beyond generating: how much context it has, and how
/// many tokens a piece of text costs. Everything else — loading, unloading, sampling — is
/// the provider's own business.
protocol LLMProvider: Sendable {
    var id: LLMProviderID { get }
    var displayModelName: String { get }

    /// The largest prompt this provider will accept, in tokens.
    var contextTokens: Int { get }

    /// Why this provider can't run right now, or nil when it can.
    var unavailableReason: String? { get async }

    func countTokens(_ text: String) async throws -> Int

    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion

    /// Whether `complete(…grammar:)` actually constrains decoding. Only the in-process llama
    /// runtime can; the others generate freely and the caller validates what comes back.
    var enforcesGrammar: Bool { get }

    /// A completion constrained to `grammar` where the provider supports it (`GBNFGrammar`),
    /// and an ordinary completion where it does not.
    func complete(system: String, user: String, maxTokens: Int, grammar: GBNFGrammar) async throws -> LLMCompletion

    /// Incremental text for interactive answers. Providers with a native token stream
    /// should override this; the default keeps existing providers compatible while still
    /// giving callers one cancellable interface.
    func stream(
        system: String,
        user: String,
        maxTokens: Int
    ) async -> AsyncThrowingStream<String, Error>

    func streamConversation(
        system: String,
        messages: [LLMChatMessage],
        maxTokens: Int
    ) async -> AsyncThrowingStream<String, Error>

    /// User-facing turns may use a higher compute priority than meeting notes.
    func streamInteractiveConversation(
        system: String,
        messages: [LLMChatMessage],
        maxTokens: Int
    ) async -> AsyncThrowingStream<String, Error>

    /// Whether this provider can take a structured `tools` array and return calls as calls.
    ///
    /// A provider that cannot has to be asked for a call in prose instead, so this is a
    /// question about the endpoint rather than about the model, and it is answered before a
    /// round rather than repaired after one. Only the llama runtime can constrain decoding
    /// with a grammar (`enforcesGrammar`); this is the separate OpenAI-style channel.
    ///
    /// `async` because the answer can come from main-actor state — OpenRouter's model
    /// catalogue — and a provider is a value handed to actors that cannot read it.
    var supportsStructuredToolCalls: Bool { get async }
}

extension LLMProvider {
    var displayModelName: String { id.displayName }

    var enforcesGrammar: Bool { false }

    var supportsStructuredToolCalls: Bool { false }

    /// A stream whose decoding is constrained to `grammar`, where the provider supports it.
    ///
    /// The default ignores the grammar rather than throwing: a provider that cannot enforce
    /// one is a provider the planner asked with the wrong backend, and the caller — not this
    /// shim — decides that. `PlannerBackends` is the one place the decision is made.
    func stream(
        system: String, user: String, maxTokens: Int, grammar: GBNFGrammar
    ) async -> AsyncThrowingStream<String, Error> {
        await stream(system: system, user: user, maxTokens: maxTokens)
    }

    func streamConversation(
        system: String, messages: [LLMChatMessage], maxTokens: Int, grammar: GBNFGrammar
    ) async -> AsyncThrowingStream<String, Error> {
        await streamConversation(system: system, messages: messages, maxTokens: maxTokens)
    }

    func streamInteractiveConversation(
        system: String, messages: [LLMChatMessage], maxTokens: Int, grammar: GBNFGrammar
    ) async -> AsyncThrowingStream<String, Error> {
        await streamInteractiveConversation(system: system, messages: messages, maxTokens: maxTokens)
    }

    /// A stream that asks for `tools` and returns the calls as Hermes tags.
    ///
    /// The tag round trip is deliberate for this default. `OpenAICompatibleLLMProvider`
    /// already reassembles a server's structured `tool_calls` into those tags, and
    /// `AgentToolCallParser` already reads them — so one reader serves both channels, and
    /// P1-04's recovery stays reachable for a model that ignored the `tools` field.
    func streamConversation(
        system: String, messages: [LLMChatMessage], maxTokens: Int, tools: [ToolWireDefinition]
    ) async -> AsyncThrowingStream<String, Error> {
        await streamConversation(system: system, messages: messages, maxTokens: maxTokens)
    }

    func complete(system: String, user: String, maxTokens: Int, grammar: GBNFGrammar) async throws -> LLMCompletion {
        try await complete(system: system, user: user, maxTokens: maxTokens)
    }

    func streamInteractiveConversation(
        system: String,
        messages: [LLMChatMessage],
        maxTokens: Int
    ) async -> AsyncThrowingStream<String, Error> {
        await streamConversation(system: system, messages: messages, maxTokens: maxTokens)
    }

    func streamConversation(
        system: String,
        messages: [LLMChatMessage],
        maxTokens: Int
    ) async -> AsyncThrowingStream<String, Error> {
        let user = messages.map { "\($0.role.rawValue.capitalized): \($0.content)" }
            .joined(separator: "\n\n")
        return await stream(system: system, user: user, maxTokens: maxTokens)
    }

    func stream(
        system: String,
        user: String,
        maxTokens: Int
    ) async -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let completion = try await complete(
                        system: system,
                        user: user,
                        maxTokens: maxTokens
                    )
                    try Task.checkCancellation()
                    continuation.yield(completion.text)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

/// Typed voice-boundary error codes (P0-7). Providers map their failures to one of
/// these; the single renderer at the voice boundary maps codes to user sentences.
/// Raw provider strings stay in the log and never reach speech.
enum VoiceProviderErrorCode: String, Sendable {
    case quotaExceeded
    case rateLimited
    case modelMissing
    case notConfigured
    case timeout
    case unavailable
    case unknown
}

/// A provider error that knows its own voice code.
protocol VoiceCodedError {
    var voiceCode: VoiceProviderErrorCode { get }
}

extension Error {
    /// The voice code for any error: the provider's own mapping, or unknown.
    var asVoiceCode: VoiceProviderErrorCode {
        (self as? VoiceCodedError)?.voiceCode ?? .unknown
    }
}

/// What a generation produced, and what it cost.
///
/// The token count and duration are here rather than logged inside each provider because
/// `--selftest-notes` reports tokens per second, and a number the provider keeps to itself
/// can't be reported by the thing that ran it.
struct LLMCompletion: Sendable {
    let text: String
    let generatedTokens: Int
    let duration: TimeInterval
    /// M-13: the model stopped because its allowance ran out, not because it finished.
    /// A default so every existing memberwise call still compiles; a provider that cannot
    /// tell leaves it false.
    var finishedByLimit: Bool = false

    var tokensPerSecond: Double {
        duration > 0 ? Double(generatedTokens) / duration : 0
    }
}

/// Actual conversation roles for providers that support chat templates. Folding
/// prior assistant turns into one user string made the small local model treat
/// its own earlier answer as part of the current request.
struct LLMChatMessage: Sendable {
    enum Role: String, Sendable { case system, user, assistant }
    let role: Role
    let content: String
    /// A `role: "assistant"` turn that carried structured calls, for an endpoint that wants
    /// the previous round's calls back in the shape it sent them. Nil for a plain turn, and
    /// for every provider that speaks Hermes tags instead.
    var toolCalls: [ToolCallTurn] = []
    /// The call this `role: "tool"` turn is the answer to.
    var toolCallID: String?

    init(role: Role, content: String, toolCalls: [ToolCallTurn] = [], toolCallID: String? = nil) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
    }
}

/// One call as a `role: "assistant"` turn carries it back to an OpenAI-style endpoint.
struct ToolCallTurn: Sendable, Equatable, Codable {
    let id: String
    let name: String
    /// The arguments as the server sent them, so the wire round-trips byte for byte.
    let argumentsJSON: String

    struct Function: Codable, Sendable, Equatable {
        let name: String
        let arguments: String
    }

    let type: String = "function"
    let function: Function

    init(id: String, name: String, argumentsJSON: String) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
        self.function = Function(name: name, arguments: argumentsJSON)
    }

    enum CodingKeys: String, CodingKey {
        case id, type
        case function
        case name
        case argumentsJSON = "arguments"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        function = try container.decode(Function.self, forKey: .function)
        name = function.name
        argumentsJSON = function.arguments
    }
}

/// One tool as an OpenAI-style endpoint wants it.
///
/// Carried as encoded bytes rather than as `[[String: Any]]` so it crosses an actor boundary
/// under Swift 6 without a second copy of the JSON-schema rules. The `parameters` blob is
/// `WorkspaceTool.Parameter.schema` — "everything is a string", because the model writes
/// command-line arguments and a schema promising an array produces one that then has to be
/// flattened back into a flag anyway.
struct ToolWireDefinition: Sendable, Equatable {
    let name: String
    let description: String
    let parametersJSON: String

    /// The `{"type":"function","function":{…}}` envelope, or nil when the parameters blob is
    /// not a JSON object — a caller that cannot serialise its own schema must not send a
    /// half-built tool.
    func envelope() -> [String: Any]? {
        guard let data = parametersJSON.data(using: .utf8),
              let parameters = try? JSONSerialization.jsonObject(with: data),
              let object = parameters as? [String: Any] else { return nil }
        return [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": object,
            ] as [String: Any],
        ]
    }

    /// A `Codable` request struct's view of one tool: the envelope's three fields, with the
    /// parameters carried as already-encoded JSON.
    var encoded: (name: String, description: String, parameters: RawJSON) {
        (name, description, RawJSON(parametersJSON))
    }
}

/// One fragment of one structured tool call, as the server numbered it.
///
/// Top-level rather than nested in `OpenAICompatibleLLMProvider` because two providers read
/// it: that one and OpenRouter. The typealiases at the bottom of that file keep its own call
/// sites spelling it the old way, so nothing there had to churn to share it.
struct ToolCallDelta: Equatable, Sendable {
    let index: Int
    let name: String?
    let argumentsFragment: String?
}

/// Reassembles `tool_calls` deltas into the `<tool_call>` tags `AgentToolCallParser` reads.
///
/// The index is the server's, and both the name and the arguments can be split across
/// chunks. Turning them back into tags rather than into a richer type is deliberate: one
/// reader of a planner completion whether the model wrote tags itself or the server
/// structured them, and P1-04's recovery stays reachable for a model that ignored the field.
struct ToolCallAccumulator: Sendable {
    private var order: [Int] = []
    private var names: [Int: String] = [:]
    private var arguments: [Int: String] = [:]

    mutating func apply(_ delta: ToolCallDelta) {
        if !order.contains(delta.index) { order.append(delta.index) }
        if let name = delta.name, !name.isEmpty { names[delta.index, default: ""] += name }
        if let fragment = delta.argumentsFragment {
            arguments[delta.index, default: ""] += fragment
        }
    }

    /// The calls, as the arguments the server sent rather than a parsed object, so the wire
    /// round-trips byte for byte when they go back as an assistant turn.
    var turns: [ToolCallTurn] {
        order.compactMap { index in
            guard let name = names[index], !name.isEmpty else { return nil }
            return ToolCallTurn(
                id: "call_\(index)", name: name, argumentsJSON: arguments[index] ?? "{}")
        }
    }

    /// The calls as the `<tool_call>` tags `AgentToolCallParser` reads, in the server's order.
    /// The app's own tag renderer, so the wire round trip produces text the one existing
    /// reader understands rather than a second format only the planner knows.
    func tags() -> String {
        turns.map { OpenAICompatibleLLMProvider.toolCallTag(
            name: $0.name, argumentsJSON: $0.argumentsJSON) }
            .joined(separator: "\n")
    }

    var isEmpty: Bool { order.isEmpty }
}

/// A pre-encoded JSON value, written into a `Codable` body without being decoded first.
///
/// The reason `ToolWireDefinition` carries bytes rather than `[String: Any]`: a `Codable`
/// request struct has to hold the tools too, and `[String: Any]` cannot cross an actor
/// boundary under Swift 6. Encoding a `Data` field as raw JSON is the same trick the
/// manifests' own blob storage uses.
struct RawJSON: Encodable, Sendable, Equatable {
    private let data: Data

    init(_ json: String) { self.data = Data(json.utf8) }
    init(_ data: Data) { self.data = data }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(data)
    }
}

@MainActor
enum LLMProviders {
    static func make(
        _ id: LLMProviderID,
        modelID: String? = nil,
        contextTokens: Int? = nil
    ) -> any LLMProvider {
        switch id {
        case .appLLM:
            // The concrete model name is read here, on the main actor, where the library
            // lives, and carried into the provider: `displayModelName` is read from actors
            // and from nonisolated code that cannot ask the library itself.
            LlamaLLMProvider(modelName: InstalledModelLibrary.shared.activeModel?.displayName)
        case .appleFoundation: FoundationModelLLMProvider()
        case .openRouter:
            // The reasoning policy travels with the model id: the picker records whether a
            // model reasons (`Settings.openRouterModelReasons`), and the request builder
            // needs it wherever the provider was made from.
            OpenRouterLLMProvider(
                modelID: modelID ?? Settings.shared.openRouterNotesModelID,
                contextTokens: contextTokens ?? Settings.shared.openRouterNotesContextTokens,
                reasoning: OpenRouterReasoningPolicy.policy(
                    for: modelID ?? Settings.shared.openRouterNotesModelID)
            )
        case .localServer:
            // Which server and which of its models is a role decision, so it is read from
            // the role store rather than passed through the notes-shaped arguments here.
            ModelRoleStore.shared.localServerProviderForAgentRole()
                ?? OpenAICompatibleLLMProvider(
                    baseURL: LocalRuntimeKind.ollama.defaultBaseURL!,
                    modelID: "",
                    serverName: LocalRuntimeKind.ollama.displayName
                )
        }
    }

    /// Local choices fall back to the other local provider when needed. An explicit
    /// OpenRouter choice never falls back: doing so would hide a missing key or a cloud
    /// failure from someone expecting that particular model.
    ///
    /// Falling back rather than failing is deliberate: a user who turned on automatic notes
    /// and then deleted the built-in download should still get notes, and being told which model
    /// wrote them (`Meeting.notesModel`) is a better outcome than an empty Notes tab.
    static func resolve(
        preferring preferred: LLMProviderID,
        modelID: String? = nil,
        contextTokens: Int? = nil
    ) async -> (any LLMProvider)? {
        if preferred == .openRouter {
            let provider = make(preferred, modelID: modelID, contextTokens: contextTokens)
            return await provider.unavailableReason == nil ? provider : nil
        }
        let ordered = [preferred] + LLMProviderID.allCases.filter { $0 != preferred && $0 != .openRouter }
        for id in ordered {
            let provider = make(id)
            if await provider.unavailableReason == nil { return provider }
        }
        return nil
    }
}

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
}

extension LLMProvider {
    var displayModelName: String { id.displayName }

    var enforcesGrammar: Bool { false }

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
            OpenRouterLLMProvider(
                modelID: modelID ?? Settings.shared.openRouterNotesModelID,
                contextTokens: contextTokens ?? Settings.shared.openRouterNotesContextTokens
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

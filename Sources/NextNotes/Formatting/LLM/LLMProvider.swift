import Foundation

/// Which local language model writes the notes.
///
/// Both are on-device and both are optional: Qwen is a 2.7 GB download the user may not
/// want to keep, and Apple's model needs Apple Intelligence turned on. The generator picks
/// the configured one and falls back to the other rather than producing nothing.
enum LLMProviderID: String, CaseIterable, Sendable, Codable, Identifiable {
    case qwen35_4b
    case appleFoundation
    case openRouter

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .qwen35_4b: "Qwen3.5-4B"
        case .appleFoundation: "Apple Foundation Model"
        case .openRouter: "OpenRouter"
        }
    }

    /// What the difference actually means to someone choosing between them.
    var summary: String {
        switch self {
        case .qwen35_4b:
            "A 2.7 GB download that reads a whole meeting at once. Slower, and much better "
                + "at long transcripts."
        case .appleFoundation:
            "Already on this Mac and fast, but its short context means a long meeting is "
                + "summarised in pieces."
        case .openRouter:
            "Uses the cloud model selected here. Add the API key in Models settings. "
                + "Transcript or Agent prompts are sent to OpenRouter and may incur charges."
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
        case .qwen35_4b: LlamaLLMProvider()
        case .appleFoundation: FoundationModelLLMProvider()
        case .openRouter:
            OpenRouterLLMProvider(
                modelID: modelID ?? Settings.shared.openRouterNotesModelID,
                contextTokens: contextTokens ?? Settings.shared.openRouterNotesContextTokens
            )
        }
    }

    /// Local choices fall back to the other local provider when needed. An explicit
    /// OpenRouter choice never falls back: doing so would hide a missing key or a cloud
    /// failure from someone expecting that particular model.
    ///
    /// Falling back rather than failing is deliberate: a user who turned on automatic notes
    /// and then deleted the Qwen download should still get notes, and being told which model
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

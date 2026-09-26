import Foundation

/// The notes model, behind the provider protocol.
///
/// A thin value type rather than the actor itself: providers are chosen per generation and
/// passed around, while the runtime is a process singleton that owns gigabytes. The
/// runtime is injected so a self-test can hand a turn a provider bound to its own runtime
/// instead of the process-wide one — and so the provider a turn holds is the same runtime
/// the turn's `select` completed against.
struct LlamaLLMProvider: LLMProvider {
    let id = LLMProviderID.appLLM

    /// The file the runtime will load, when the caller could read the library. Captured at
    /// construction because a provider is a value handed to actors, while the library is
    /// main-actor state; nil falls back to the built-in model's name.
    let modelName: String?

    /// The runtime this provider loads, generates and unloads through.
    let runtime: NotesModelRuntime

    init(modelName: String? = nil, runtime: NotesModelRuntime = .shared) {
        self.modelName = modelName
        self.runtime = runtime
    }

    /// The name of the model that will actually answer — not the model that happened to
    /// ship this release. `Meeting.notesModel` and every log line report this, so a notes
    /// history that says "Gemma" while MiniCPM wrote it is the bug this prevents.
    var displayModelName: String { modelName ?? NotesModels.spec.displayName }

    var contextTokens: Int { NotesModelRuntime.maxContextTokens }

    /// Why the local model cannot answer right now.
    ///
    /// The active model is whichever one the runtime holds — a model the user fetched from
    /// Hugging Face, or the built-in one — so the reason has to name that file rather than
    /// always naming the built-in model. A selected model whose file has gone missing
    /// reports as unavailable here; the call path falls back to another provider and says
    /// so through `ModelLoadNotice`.
    var unavailableReason: String? {
        get async {
            let active = await runtime.activeSpec()
            if active.isDownloaded { return nil }
            if active.fileURL == NotesModels.spec.fileURL {
                return "\(NotesModels.spec.displayName) isn\u{2019}t downloaded (\(NotesModels.spec.displaySize))."
            }
            return "\(active.displayName) is no longer on this Mac. Choose a model in Models settings."
        }
    }

    func countTokens(_ text: String) async throws -> Int {
        try await runtime.countTokens(text)
    }

    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        try await runtime.complete(
            system: system,
            user: user,
            maxTokens: maxTokens
        )
    }

    var enforcesGrammar: Bool { true }

    func complete(system: String, user: String, maxTokens: Int, grammar: GBNFGrammar) async throws -> LLMCompletion {
        try await runtime.complete(
            system: system, user: user, maxTokens: maxTokens, grammar: grammar)
    }

    func stream(
        system: String,
        user: String,
        maxTokens: Int
    ) async -> AsyncThrowingStream<String, Error> {
        await runtime.stream(
            system: system,
            user: user,
            maxTokens: maxTokens
        )
    }

    func streamConversation(
        system: String,
        messages: [LLMChatMessage],
        maxTokens: Int
    ) async -> AsyncThrowingStream<String, Error> {
        await runtime.streamConversation(
            system: system, messages: messages, maxTokens: maxTokens
        )
    }

    func streamConversation(
        system: String,
        messages: [LLMChatMessage],
        maxTokens: Int,
        grammar: GBNFGrammar
    ) async -> AsyncThrowingStream<String, Error> {
        await runtime.streamConversation(
            system: system, messages: messages, maxTokens: maxTokens, grammar: grammar
        )
    }

    func streamInteractiveConversation(
        system: String,
        messages: [LLMChatMessage],
        maxTokens: Int
    ) async -> AsyncThrowingStream<String, Error> {
        await runtime.streamInteractiveConversation(
            system: system, messages: messages, maxTokens: maxTokens
        )
    }

    func streamInteractiveConversation(
        system: String,
        messages: [LLMChatMessage],
        maxTokens: Int,
        grammar: GBNFGrammar
    ) async -> AsyncThrowingStream<String, Error> {
        await runtime.streamInteractiveConversation(
            system: system, messages: messages, maxTokens: maxTokens, grammar: grammar
        )
    }
}

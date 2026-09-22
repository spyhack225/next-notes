import Foundation

/// The notes model, behind the provider protocol.
///
/// A thin value type rather than the actor itself: providers are chosen per generation and
/// passed around, while the runtime is a process singleton that owns gigabytes.
struct LlamaLLMProvider: LLMProvider {
    let id = LLMProviderID.gemma4E4B

    var contextTokens: Int { NotesModelRuntime.maxContextTokens }

    /// Why the local model cannot answer right now.
    ///
    /// The active model is whichever one the Models tab has selected — a model the user
    /// fetched from Hugging Face, or the built-in one — so the reason has to name that file
    /// rather than always naming the built-in model. A selected model whose file has gone missing reports
    /// as unavailable here; the runtime falls back to the built-in on its next load and says
    /// so through `ModelLoadNotice`.
    var unavailableReason: String? {
        get async {
            let active = await NotesModelRuntime.shared.activeSpec()
            if active.isDownloaded { return nil }
            if active.fileURL == NotesModels.spec.fileURL {
                return "\(NotesModels.spec.displayName) isn\u{2019}t downloaded (\(NotesModels.spec.displaySize))."
            }
            return "\(active.displayName) is no longer on this Mac. Choose a model in Models settings."
        }
    }

    func countTokens(_ text: String) async throws -> Int {
        try await NotesModelRuntime.shared.countTokens(text)
    }

    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        try await NotesModelRuntime.shared.complete(
            system: system,
            user: user,
            maxTokens: maxTokens
        )
    }

    var enforcesGrammar: Bool { true }

    func complete(system: String, user: String, maxTokens: Int, grammar: GBNFGrammar) async throws -> LLMCompletion {
        try await NotesModelRuntime.shared.complete(
            system: system, user: user, maxTokens: maxTokens, grammar: grammar)
    }

    func stream(
        system: String,
        user: String,
        maxTokens: Int
    ) async -> AsyncThrowingStream<String, Error> {
        await NotesModelRuntime.shared.stream(
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
        await NotesModelRuntime.shared.streamConversation(
            system: system, messages: messages, maxTokens: maxTokens
        )
    }

    func streamInteractiveConversation(
        system: String,
        messages: [LLMChatMessage],
        maxTokens: Int
    ) async -> AsyncThrowingStream<String, Error> {
        await NotesModelRuntime.shared.streamInteractiveConversation(
            system: system, messages: messages, maxTokens: maxTokens
        )
    }
}

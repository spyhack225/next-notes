import Foundation

/// The notes model, behind the provider protocol.
///
/// A thin value type rather than the actor itself: providers are chosen per generation and
/// passed around, while the runtime is a process singleton that owns gigabytes.
struct LlamaLLMProvider: LLMProvider {
    let id = LLMProviderID.qwen35_4b

    var contextTokens: Int { NotesModelRuntime.maxContextTokens }

    var unavailableReason: String? {
        get async {
            NotesModels.isDownloaded
                ? nil
                : "\(NotesModels.spec.displayName) isn\u{2019}t downloaded (\(NotesModels.spec.displaySize))."
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
}

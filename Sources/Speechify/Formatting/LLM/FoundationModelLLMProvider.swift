import Foundation
import FoundationModels

/// Apple's on-device model as a notes provider.
///
/// The secondary provider, and the only one that needs no download. Its cost is context:
/// 4096 tokens covers roughly fifteen minutes of speech, so anything longer goes through
/// the generator's map-reduce path rather than being read in one piece.
struct FoundationModelLLMProvider: LLMProvider {
    let id = LLMProviderID.appleFoundation

    /// The documented window for `LanguageModelSession`, shared between prompt and response.
    let contextTokens = 4_096

    var unavailableReason: String? {
        get async { FoundationModelFormatter.unavailableReason }
    }

    /// Estimated, not measured: Foundation Models exposes no tokenizer, and the generator
    /// only needs this to decide how much transcript fits in one prompt.
    ///
    /// Four characters per token is the usual English rule of thumb; a transcript is plain
    /// prose with no code or markup, which is exactly the case that rule was measured on.
    /// The generator leaves a wide margin below `contextTokens`, so the estimate being a
    /// few percent low costs nothing.
    func countTokens(_ text: String) async throws -> Int {
        max(1, (text.count + charactersPerToken - 1) / charactersPerToken)
    }

    private let charactersPerToken = 4

    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        let began = Date()
        let session = LanguageModelSession(instructions: system)
        let response = try await session.respond(
            to: user,
            options: GenerationOptions(
                temperature: temperature,
                maximumResponseTokens: maxTokens
            )
        )
        let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return LLMCompletion(
            text: text,
            // The response carries no token count either, so tokens/second reported for this
            // provider is the same estimate as `countTokens`, and is labelled as such where
            // it is printed.
            generatedTokens: (try? await countTokens(text)) ?? 0,
            duration: Date().timeIntervalSince(began)
        )
    }

    /// Low, for the same reason dictation cleanup runs low: notes are an extraction task.
    /// Inventing a decision nobody made is the failure mode that matters here.
    private let temperature = 0.3
}

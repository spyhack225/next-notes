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

    /// Native incremental stream supplied by Foundation Models.
    ///
    /// `ResponseStream<String>` yields snapshots, rather than deltas.  The snapshots are
    /// cumulative, so only the suffix after the previously observed snapshot is forwarded
    /// to the speech buffer.  If the framework ever supplies a replacement snapshot, fail
    /// the stream instead of repeating or silently dropping words: spoken output cannot be
    /// retracted once it has reached the synthesizer.
    func stream(
        system: String,
        user: String,
        maxTokens: Int
    ) async -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try Task.checkCancellation()
                    let session = LanguageModelSession(instructions: system)
                    let responseStream = session.streamResponse(
                        to: user,
                        options: GenerationOptions(
                            temperature: temperature,
                            maximumResponseTokens: maxTokens
                        )
                    )

                    var previous = ""
                    for try await snapshot in responseStream {
                        try Task.checkCancellation()
                        let current = snapshot.content
                        guard let delta = Self.delta(previous: previous, current: current) else {
                            throw StreamError.replacementSnapshot
                        }
                        if !delta.isEmpty {
                            continuation.yield(delta)
                        }
                        previous = current
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// Low, for the same reason dictation cleanup runs low: notes are an extraction task.
    /// Inventing a decision nobody made is the failure mode that matters here.
    private let temperature = 0.3

    /// `nil` means the framework revised earlier text; replaying a replacement
    /// snapshot would duplicate already spoken words.
    static func delta(previous: String, current: String) -> String? {
        guard current.hasPrefix(previous) else { return nil }
        return String(current.dropFirst(previous.count))
    }

    private enum StreamError: LocalizedError {
        case replacementSnapshot

        var errorDescription: String? {
            "Foundation Model returned a non-cumulative response snapshot"
        }
    }
}

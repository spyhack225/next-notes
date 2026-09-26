import Foundation
import FoundationModels

/// Apple's on-device model as a notes provider.
///
/// The secondary provider, and the only one that needs no download. Its cost is context:
/// the window the framework reports — 8,192 tokens on the current hardware generation,
/// 4,096 on the first — covers roughly half an hour of speech, so anything longer goes
/// through the generator's map-reduce path rather than being read in one piece.
struct FoundationModelLLMProvider: LLMProvider {
    let id = LLMProviderID.appleFoundation

    /// The window the framework itself reports, shared between prompt and response
    /// (P1-10a step 0, landed in M-12). `contextSize` answers 4,096 on macOS 26.x and
    /// the real window on 27+, and may answer nothing useful while the model is
    /// unavailable — the 4,096 floor keeps the budget arithmetic sane either way.
    var contextTokens: Int {
        let reported = SystemLanguageModel.default.contextSize
        return reported > 0 ? reported : 4_096
    }

    var unavailableReason: String? {
        get async { FoundationModelFormatter.unavailableReason }
    }

    /// The budget counter (M-12): the system model's own tokenizer on macOS 26.4+,
    /// characters / 3 otherwise. Three rather than the old four is an estimate, and
    /// deliberately lower: French tokenises denser than the English rule of thumb, and
    /// an estimate that over-counts costs a slice of window, not a rejected prompt.
    func countTokens(_ text: String) async throws -> Int {
        if #available(macOS 26.4, *) {
            if let count = try? await SystemLanguageModel.default.tokenCount(for: text) {
                return max(1, count)
            }
        }
        return max(1, (text.count + charactersPerToken - 1) / charactersPerToken)
    }

    /// The fallback's characters-per-token, labelled an estimate: see `countTokens`.
    private let charactersPerToken = 3

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
        // P0-20a: the system model's own tokenizer where the OS has it (macOS 26.4+),
        // characters / 4 otherwise — and `estimated` says which.
        let prompt = await Self.measuredTokenCount(system + user)
        let completion = await Self.measuredTokenCount(text)
        ModelPassRecorder.current?.report(
            promptTokens: prompt.count,
            cachedTokens: nil,
            completionTokens: completion.count,
            reasoningTokens: nil,
            finishReason: nil,
            estimated: prompt.estimated || completion.estimated)
        return LLMCompletion(
            text: text,
            // The response carries no token count either, so tokens/second reported for this
            // provider is the same estimate as `countTokens`, and is labelled as such where
            // it is printed.
            generatedTokens: (try? await countTokens(text)) ?? 0,
            duration: Date().timeIntervalSince(began)
        )
    }

    /// The system model's own token count on macOS 26.4+, characters / 4 otherwise.
    static func measuredTokenCount(_ text: String) async -> (count: Int, estimated: Bool) {
        if #available(macOS 26.4, *) {
            if let count = try? await SystemLanguageModel.default.tokenCount(for: text) {
                return (max(1, count), false)
            }
        }
        return (max(1, text.count / 4), true)
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
                    // P0-20a: counted after the stream ended, never in front of a token.
                    let prompt = await Self.measuredTokenCount(system + user)
                    let completion = await Self.measuredTokenCount(previous)
                    ModelPassRecorder.current?.report(
                        promptTokens: prompt.count,
                        cachedTokens: nil,
                        completionTokens: completion.count,
                        reasoningTokens: nil,
                        finishReason: nil,
                        estimated: prompt.estimated || completion.estimated)
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

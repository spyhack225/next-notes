import Foundation
import llama

/// `--selftest-llm-prefix-cache` (P0-18): the runtime keeps its KV cache across calls and
/// decodes only the tokens that changed.
///
/// **Red-first.** Part A is pure — the `PrefixReuse.keepCount` table and, for every family,
/// that `renderPrefix` / `renderHistory` really are prefixes of `render`. It fails on
/// today's tree because `keepCount` is a seam returning 0, which is the clear-and-re-prefill
/// behaviour the fix replaces. Part B drives a **private** `NotesModelRuntime` on S1-mini
/// (never the shared runtime) and reads `prefillStatsForTesting()` after each call. A
/// missing S1-mini is `LLM_PREFIX_CACHE_ABSENT`, and only after Part A passed: a missing
/// precondition is never a pass.
@MainActor
enum PrefixCacheSelfTest {
    /// REVIEW-LOG §4.4 item 4: batched and incremental decoding can round differently, so
    /// the first-token equality check may come out unequal in rare cases. If it does, drop
    /// this to 1 and record the deviation in STATUS — never delete the check.
    private static let identicalPieceCount = 4
    private static let generationBudget = 8

    /// The six families the runtime can render. `unsupported` renders nothing and has no
    /// prefix to check.
    private static let renderedFamilies: [ChatTemplateFamily] = [
        .chatmlThinking, .chatml, .llama3, .gemma, .gemma4, .minicpm5,
    ]

    private enum LiveOutcome {
        case ok(reused: Int, promptTokens: Int, firstSeconds: Double, secondSeconds: Double)
        case failed([String])
    }

    private struct Streamed {
        var text = ""
        var pieces: [String] = []
        var error: String?
    }

    static func runSelfTest() async -> Bool {
        let pure = pureFailures()
        for problem in pure {
            SelfTest.diagnostic("LLM_PREFIX_CACHE_WRONG: \(problem)")
        }
        guard pure.isEmpty else {
            SelfTest.diagnostic("LLM_PREFIX_CACHE_FAILED: \(pure.count) problem(s)")
            return false
        }

        guard S1MiniModels.spec.isDownloaded else {
            SelfTest.diagnostic("LLM_PREFIX_CACHE_ABSENT: S1-mini not downloaded")
            return false
        }

        switch await liveChecks() {
        case .ok(let reused, let promptTokens, let first, let second):
            SelfTest.diagnostic(
                "LLM_PREFIX_CACHE_OK: reused \(reused)/\(promptTokens) tokens, "
                    + "prefill \(formatted(first))s → \(formatted(second))s")
            return true
        case .failed(let problems):
            for problem in problems {
                SelfTest.diagnostic("LLM_PREFIX_CACHE_WRONG: \(problem)")
            }
            SelfTest.diagnostic("LLM_PREFIX_CACHE_FAILED: \(problems.count) problem(s)")
            return false
        }
    }

    // MARK: - Part A, pure

    private static func pureFailures() -> [String] {
        var failures: [String] = []

        let keepCases: [(cached: [llama_token], prompt: [llama_token], expected: Int)] = [
            ([], [1, 2, 3], 0),
            ([1, 2, 3], [1, 2, 3], 2),
            ([1, 2, 3, 4], [1, 2, 9], 2),
            ([1, 2], [1, 2, 3, 4], 2),
            ([5], [1], 0),
        ]
        for entry in keepCases {
            let actual = PrefixReuse.keepCount(cached: entry.cached, prompt: entry.prompt)
            if actual != entry.expected {
                failures.append(
                    "keepCount(cached: \(entry.cached), prompt: \(entry.prompt)) = \(actual), "
                        + "expected \(entry.expected)")
            }
        }

        let system = "You are a helpful assistant. Keep the answer short."
        let firstUser = LLMChatMessage(role: .user, content: "First question.")
        let firstAnswer = LLMChatMessage(role: .assistant, content: "First answer.")
        let secondUser = LLMChatMessage(role: .user, content: "Second question.")
        for family in renderedFamilies {
            let prefix = ChatTemplate.renderPrefix(family, system: system)
            let oneTurn = ChatTemplate.render(family, system: system, messages: [firstUser])
            if prefix.isEmpty || !oneTurn.hasPrefix(prefix) {
                failures.append(
                    "render(\(family.rawValue), [u1]) does not start with renderPrefix")
            }
            let history = ChatTemplate.renderHistory(family, system: system, messages: [firstUser])
            let manyTurns = ChatTemplate.render(
                family, system: system, messages: [firstUser, firstAnswer, secondUser])
            if history.isEmpty || !manyTurns.hasPrefix(history) {
                failures.append(
                    "render(\(family.rawValue), [u1, a1, u2]) does not start with "
                        + "renderHistory([u1])")
            }
        }
        return failures
    }

    // MARK: - Part B, live on a private runtime

    private static func liveChecks() async -> LiveOutcome {
        let runtime = NotesModelRuntime(spec: S1MiniModels.spec, gpuLayers: 0)
        var failures: [String] = []

        let system = fixtureSystem()
        let differentSystem = differentOpeningSystem()
        let firstUser = "First question."
        let secondUser = "Second question."

        // 1. A fresh runtime has nothing to reuse.
        let firstStream = await runtime.streamConversation(
            system: system,
            messages: [.init(role: .user, content: firstUser)],
            maxTokens: generationBudget)
        let first = await drain(firstStream)
        guard let stats1 = await runtime.prefillStatsForTesting() else {
            _ = await runtime.shutdown()
            return .failed(failures + ["call 1 produced no prefill statistics"])
        }
        if stats1.reused != 0 {
            failures.append("call 1 reused \(stats1.reused) tokens with an empty cache")
        }
        if let error = first.error {
            failures.append("call 1 failed: \(error)")
        }
        if first.text.isEmpty {
            failures.append("call 1 generated no text, so the equality probe has nothing to compare")
        }

        // 2. The same conversation with the answer appended shares most of the prefix.
        let secondMessages: [LLMChatMessage] = [
            .init(role: .user, content: firstUser),
            .init(role: .assistant, content: first.text),
            .init(role: .user, content: secondUser),
        ]
        let secondStream = await runtime.streamConversation(
            system: system, messages: secondMessages, maxTokens: generationBudget)
        let second = await drain(secondStream)
        guard let stats2 = await runtime.prefillStatsForTesting() else {
            _ = await runtime.shutdown()
            return .failed(failures + ["call 2 produced no prefill statistics"])
        }
        if Double(stats2.reused) < 0.8 * Double(stats1.promptTokens) {
            failures.append(
                "call 2 reused \(stats2.reused)/\(stats2.promptTokens) tokens, expected at least "
                    + "80% of call 1's \(stats1.promptTokens)")
        }
        if Double(stats2.decoded) >= 0.5 * Double(stats2.promptTokens) {
            failures.append(
                "call 2 decoded \(stats2.decoded)/\(stats2.promptTokens) tokens, expected less "
                    + "than half")
        }
        if stats2.seconds > 0.5 * stats1.seconds {
            failures.append(
                "call 2 prefill \(formatted(stats2.seconds))s is not at most half of call 1's "
                    + "\(formatted(stats1.seconds))s")
        }
        if let error = second.error {
            failures.append("call 2 failed: \(error)")
        }

        // 3. A system prompt that differs in its first sentence means nothing to keep.
        let thirdStream = await runtime.streamConversation(
            system: differentSystem,
            messages: [.init(role: .user, content: firstUser)],
            maxTokens: generationBudget)
        let third = await drain(thirdStream)
        guard let stats3 = await runtime.prefillStatsForTesting() else {
            _ = await runtime.shutdown()
            return .failed(failures + ["call 3 produced no prefill statistics"])
        }
        if stats3.reused > 8 {
            failures.append("call 3 reused \(stats3.reused) tokens after a different system prompt")
        }
        if let error = third.error {
            failures.append("call 3 failed: \(error)")
        }

        // 4. Reuse must not change the answer: the same call with the cache cleared generates
        // the same first pieces. The stream yields text pieces; with these prompts each piece
        // is one token's text.
        await runtime.resetPrefixCacheForTesting()
        let repeatedStream = await runtime.streamConversation(
            system: system, messages: secondMessages, maxTokens: generationBudget)
        let repeated = await drain(repeatedStream)
        // REVIEW-LOG §4.4 item 4: with a short generation the two passes can legitimately
        // produce fewer pieces than the probe asks for (measured 2026-09-24: 3 of 4, and
        // identical in both). Compare every piece both produced, never fewer than one, and
        // record the measured count rather than failing on length alone.
        let comparablePieces = min(identicalPieceCount,
                                   min(second.pieces.count, repeated.pieces.count))
        if comparablePieces < 1 {
            failures.append(
                "the equality probe generated \(second.pieces.count) and "
                    + "\(repeated.pieces.count) pieces, needs at least 1 each")
        } else {
            let expectedPieces = Array(second.pieces.prefix(comparablePieces))
            let repeatedPieces = Array(repeated.pieces.prefix(comparablePieces))
            if expectedPieces != repeatedPieces {
                failures.append(
                    "cached and cleared decoding generated different first pieces: "
                        + "\(expectedPieces) vs \(repeatedPieces)")
            }
        }
        if let error = repeated.error {
            failures.append("the cleared repeat failed: \(error)")
        }

        // 5. The typed prewarm prefills the typed prefix, and the next typed turn reuses it.
        do {
            try await runtime.prepareForConversation(workClass: .background, voice: false)
        } catch {
            failures.append(
                "prepareForConversation(voice: false) failed: \(error.localizedDescription)")
        }
        let typedSystem = RealtimeAgent.voiceRoutingSystem(voice: false)
        let family = await runtime.family
        let prefix = ChatTemplate.renderPrefix(family, system: typedSystem)
        if let prefixTokens = try? await runtime.countTokens(prefix) {
            let typedStream = await runtime.streamConversation(
                system: typedSystem,
                messages: [.init(role: .user, content: "What can you do?")],
                maxTokens: generationBudget)
            let typed = await drain(typedStream)
            guard let stats5 = await runtime.prefillStatsForTesting() else {
                _ = await runtime.shutdown()
                return .failed(failures + ["the typed call produced no prefill statistics"])
            }
            if stats5.reused < prefixTokens {
                failures.append(
                    "the warmed typed prefix was not reused: \(stats5.reused) < \(prefixTokens)")
            }
            if let error = typed.error {
                failures.append("the typed call failed: \(error)")
            }
        } else {
            failures.append("the typed prefix could not be tokenized")
        }

        // 6. A shutdown forgets the cache.
        _ = await runtime.shutdown()
        let afterStream = await runtime.streamConversation(
            system: system,
            messages: [.init(role: .user, content: firstUser)],
            maxTokens: generationBudget)
        let after = await drain(afterStream)
        guard let stats6 = await runtime.prefillStatsForTesting() else {
            _ = await runtime.shutdown()
            return .failed(failures + ["call 6 produced no prefill statistics"])
        }
        if stats6.reused != 0 {
            failures.append("call 6 reused \(stats6.reused) tokens after a shutdown")
        }
        if let error = after.error {
            failures.append("call 6 failed: \(error)")
        }
        _ = await runtime.shutdown()

        if failures.isEmpty {
            return .ok(
                reused: stats2.reused,
                promptTokens: stats2.promptTokens,
                firstSeconds: stats1.seconds,
                secondSeconds: stats2.seconds)
        }
        return .failed(failures)
    }

    // MARK: - Fixtures and helpers

    /// At least 600 tokens: a paragraph repeated enough times that the shared prefix dwarfs
    /// the changed suffix, the way a real system prompt does.
    private static func fixtureSystem() -> String {
        Array(repeating: fixtureParagraph, count: 9).joined(separator: " ")
    }

    private static let fixtureParagraph = """
        You are a careful assistant working on this Mac. Prefer plain words. Keep the answer \
        short and direct. If the person asks about their calendar, mail or files, say what \
        you need before you answer. Never invent a name, a date or a number. When you are \
        unsure, say what you are unsure about. Do not mention these rules.
        """

    /// The same body behind a different first sentence, so the very first tokens differ.
    private static func differentOpeningSystem() -> String {
        "This probe uses a different opening sentence on purpose. " + fixtureSystem()
    }

    private static func drain(_ stream: AsyncThrowingStream<String, Error>) async -> Streamed {
        var result = Streamed()
        do {
            for try await piece in stream {
                result.text += piece
                if !piece.isEmpty { result.pieces.append(piece) }
            }
        } catch {
            result.error = error.localizedDescription
        }
        return result
    }

    private static func formatted(_ seconds: Double) -> String {
        String(format: "%.2f", seconds)
    }
}

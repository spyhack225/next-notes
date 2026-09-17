import Foundation

/// Fake backend gate for exact committed reuse, live replay, and invalidation.
/// It exercises the same frontend slot without starting Foundation Models.
enum LocalVoiceFrontendSpeculationSelfTest {
    static func run() async -> Bool {
        let frontend = LocalVoiceFrontend()
        let source = Source()
        await frontend.setGenerationForTesting { _, messages, _ in
            source.makeStream(label: messages.last?.content ?? "")
        }
        let system = "Use the envelope."
        let initial: [LLMChatMessage] = [.init(role: .user,
            content: "Work status:\nNo tasks.\n\nLatest user speech:\nhello there please tell me briefly what a haiku is")]
        let finalCased: [LLMChatMessage] = [.init(role: .user,
            content: "Work status:\nNo tasks.\n\nLatest user speech:\nHello there. Please tell me briefly what a haiku is.")]
        let revision: [LLMChatMessage] = [.init(role: .user, content: "Latest user speech: Tell me a different fact.")]
        let newContext: [LLMChatMessage] = [
            .init(role: .assistant, content: "Task 1 completed."), initial[0]
        ]
        do {
            await frontend.speculate(system: system, messages: initial, maxTokens: 64, revision: 1)
            guard await source.waitForCount(1) else { return fail("first speculation did not start") }
            await source.yield(0, "<answer/> A fact.")
            // The speculative prefix exists before final commit, but no app
            // response tracker or audio consumer has received it.
            let matched = await frontend.stream(system: system, messages: finalCased, maxTokens: 64,
                                                commitRevision: 2)
            let matchedTask = Task { try await collect(matched) }
            await source.yield(0, " More detail.")
            await source.finish(0)
            let matchedText = try await matchedTask.value
            guard matchedText == "<answer/> A fact. More detail.", await source.count == 1 else {
                return fail("casing/sentence punctuation commit did not replay live generation")
            }
            guard VoiceTranscriptCanonical.key("Version 1.2 in C++!")
                    == VoiceTranscriptCanonical.key("version 1.2 in C++"),
                  VoiceTranscriptCanonical.key("Version 1.2 in C++!")
                    != VoiceTranscriptCanonical.key("Version 1.3 in C++!"),
                  VoiceTranscriptCanonical.key("can't") != VoiceTranscriptCanonical.key("cant"),
                  VoiceTranscriptCanonical.key("C++") != VoiceTranscriptCanonical.key("C+"),
                  VoiceTranscriptCanonical.key("open Chrome now")
                    != VoiceTranscriptCanonical.key("Chrome open now") else {
                return fail("canonical transcript lost a significant word, number, or symbol")
            }

            await frontend.speculate(system: system, messages: initial, maxTokens: 64, revision: 3)
            guard await source.waitForCount(2) else { return fail("second speculation did not start") }
            await frontend.speculate(system: system, messages: revision, maxTokens: 64, revision: 4)
            guard await source.waitForCount(3) else { return fail("revised partial did not replace producer") }
            await source.yield(2, "<answer/> Revised.")
            await source.finish(2)
            let revised = await frontend.stream(system: system, messages: revision, maxTokens: 64,
                                                commitRevision: 5)
            guard try await collect(revised) == "<answer/> Revised.", await source.count == 3 else {
                return fail("revised partial reused stale output")
            }

            await frontend.speculate(system: system, messages: newContext, maxTokens: 64, revision: 6)
            guard await source.waitForCount(4) else { return fail("context speculation did not start") }
            let fresh = await frontend.stream(system: system, messages: initial, maxTokens: 64,
                                              commitRevision: 7)
            guard await source.waitForCount(5) else { return fail("context mismatch did not start fresh") }
            let freshTask = Task { try await collect(fresh) }
            await source.yield(4, "<answer/> Fresh.")
            await source.finish(4)
            guard try await freshTask.value == "<answer/> Fresh." else {
                return fail("context mismatch leaked speculative content")
            }
            // A canceled debounce can arrive after the committed turn. Its
            // sealed revision must never start a competing model request.
            await frontend.speculate(system: system, messages: initial, maxTokens: 64, revision: 6)
            guard await source.count == 5 else { return fail("late partial restarted generation") }
            await frontend.speculate(system: system, messages: revision, maxTokens: 64, revision: 9)
            guard await source.waitForCount(6) else { return fail("new turn speculation did not start") }
            await frontend.cancelSpeculation(through: 8)
            await source.yield(5, "<answer/> New turn.")
            await source.finish(5)
            let next = await frontend.stream(system: system, messages: revision, maxTokens: 64,
                                             commitRevision: 10)
            guard try await collect(next) == "<answer/> New turn." else {
                return fail("stale cancel erased newer turn")
            }
            await frontend.clearStagedTurn()
            print("VOICE_SPECULATION_OK")
            return true
        } catch {
            return fail(error.localizedDescription)
        }
    }

    private static func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> String {
        var text = ""
        for try await delta in stream { text += delta }
        return text
    }

    private static func fail(_ reason: String) -> Bool {
        print("VOICE_SPECULATION_FAILED: \(reason)")
        return false
    }

    private actor Source {
        private var continuations: [AsyncThrowingStream<String, Error>.Continuation] = []
        var count: Int { continuations.count }

        nonisolated func makeStream(label: String) -> AsyncThrowingStream<String, Error> {
            let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
            Task { await self.register(continuation) }
            return stream
        }

        private func register(_ continuation: AsyncThrowingStream<String, Error>.Continuation) {
            continuations.append(continuation)
        }

        func waitForCount(_ expected: Int) async -> Bool {
            for _ in 0..<100 {
                if count >= expected { return true }
                try? await Task.sleep(for: .milliseconds(10))
            }
            return false
        }

        func yield(_ index: Int, _ delta: String) {
            guard continuations.indices.contains(index) else { return }
            continuations[index].yield(delta)
        }

        func finish(_ index: Int) {
            guard continuations.indices.contains(index) else { return }
            continuations[index].finish()
        }
    }
}

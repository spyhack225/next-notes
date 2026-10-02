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
            guard try await correlatedRecorderCases() else { return false }
            print("VOICE_SPECULATION_OK")
            return true
        } catch {
            return fail(error.localizedDescription)
        }
    }

    /// Actual speculative slot and task-local propagation, with scripted model
    /// deltas and the real pass recorder writing to an isolated usage file.
    /// The installed five-turn run separately proves the coordinator/native path.
    private static func correlatedRecorderCases() async throws -> Bool {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nextnotes-voice-speculation-usage-\(UUID().uuidString)")
        let log = UsageLog(directory: directory)
        defer { log.flush(); try? FileManager.default.removeItem(at: directory) }
        let frontend = LocalVoiceFrontend()
        let source = Source(log: log)
        await frontend.setGenerationForTesting { _, messages, _ in
            source.makeStream(label: messages.last?.content ?? "")
        }
        let messages = [LLMChatMessage(role: .user, content: "Latest user speech: Explain a haiku briefly.")]
        let revised = [LLMChatMessage(role: .user, content: "Latest user speech: Explain a sonnet briefly.")]
        let system = "Use the envelope."
        let first = UsageCorrelation(turnID: UUID(), conversationID: UUID())
        await ModelPassRecorder.$correlation.withValue(first) {
            await frontend.speculate(system: system, messages: messages, maxTokens: 64, revision: 1)
        }
        guard await source.waitForCount(1) else { return fail("correlated speculation did not start") }
        await source.yield(0, "<answer/> Recorded before commit.")
        await source.finish(0)
        log.flush()
        guard log.load().count == 1, log.load().first?.turnID == first.turnID,
              log.load().first?.conversationID == first.conversationID else {
            return fail("speculative recorder did not retain the prospective ids before commit")
        }
        let reused = await ModelPassRecorder.$correlation.withValue(first) {
            await frontend.stream(system: system, messages: messages, maxTokens: 64, commitRevision: 2)
        }
        guard try await collect(reused) == "<answer/> Recorded before commit.",
              await source.count == 1, log.load().count == 1 else {
            return fail("completed correlated hit restarted inference or duplicated its usage row")
        }
        await ModelPassRecorder.$correlation.withValue(first) {
            await frontend.speculate(system: system, messages: messages, maxTokens: 64, revision: 3)
        }
        guard await source.waitForCount(2) else { return fail("first partial revision did not start") }
        await source.finish(1)
        await ModelPassRecorder.$correlation.withValue(first) {
            await frontend.speculate(system: system, messages: revised, maxTokens: 64, revision: 4)
        }
        guard await source.waitForCount(3) else { return fail("changed partial did not start a replacement") }
        await source.yield(2, "<answer/> Revised with the same ids.")
        await source.finish(2)
        let revision = await ModelPassRecorder.$correlation.withValue(first) {
            await frontend.stream(system: system, messages: revised, maxTokens: 64, commitRevision: 5)
        }
        guard try await collect(revision) == "<answer/> Revised with the same ids.",
              log.load().count == 3,
              log.load().allSatisfy({ $0.turnID == first.turnID && $0.conversationID == first.conversationID }) else {
            return fail("partial revision lost its original prospective ids")
        }
        let nextTurn = UsageCorrelation(turnID: UUID(), conversationID: first.conversationID)
        let nextConversation = UsageCorrelation(turnID: first.turnID, conversationID: UUID())
        let cases: [(String, UsageCorrelation, Bool)] = [
            ("changed turn", nextTurn, false),
            ("changed conversation", nextConversation, false),
            ("same revision changed correlation", nextTurn, true)
        ]
        var revisionNumber: UInt64 = 6
        for (name, committed, sameRevision) in cases {
            let base = await source.count
            await ModelPassRecorder.$correlation.withValue(first) {
                await frontend.speculate(system: system, messages: messages, maxTokens: 64,
                                         revision: revisionNumber)
            }
            guard await source.waitForCount(base + 1) else { return fail("\(name): old speculation did not start") }
            await source.yield(base, "<answer/> Wrong old identity.")
            await source.finish(base)
            if sameRevision {
                await ModelPassRecorder.$correlation.withValue(committed) {
                    await frontend.speculate(system: system, messages: messages, maxTokens: 64,
                                             revision: revisionNumber)
                }
                guard await source.waitForCount(base + 2) else {
                    return fail("same request/revision reused a producer from another correlation")
                }
            }
            let stream = await ModelPassRecorder.$correlation.withValue(committed) {
                await frontend.stream(system: system, messages: messages, maxTokens: 64,
                                      commitRevision: revisionNumber + 1)
            }
            guard await source.waitForCount(base + 2) else {
                return fail("\(name): same-request commit adopted another identity's producer")
            }
            await source.yield(base + 1, "<answer/> Correct new identity.")
            await source.finish(base + 1)
            guard try await collect(stream) == "<answer/> Correct new identity.",
                  await source.count == base + 2 else {
                return fail("\(name): fresh identity was not consumed exactly once")
            }
            let last = log.load().last
            guard last?.turnID == committed.turnID, last?.conversationID == committed.conversationID else {
                return fail("\(name): real recorder emitted the wrong committed ids")
            }
            revisionNumber += 2
        }
        await frontend.clearStagedTurn()
        guard log.load().count == 9,
              log.load().allSatisfy({ $0.feature == UsageFeature.agentVoice.rawValue
                  && $0.pass == "frontend-answer" && $0.turnID != nil && $0.conversationID != nil }) else {
            return fail("correlation cases omitted or duplicated a real pass record")
        }
        print("VOICE_SPECULATION_USAGE_OK: 5 cases, 9 actual recorder rows; scripted generation")
        return true
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
        private var recorders: [ModelPassRecorder?] = []
        private let log: UsageLog?
        init(log: UsageLog? = nil) { self.log = log }
        var count: Int { continuations.count }

        nonisolated func makeStream(label: String) -> AsyncThrowingStream<String, Error> {
            let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
            let recorder = log.map { ModelPassRecorder(feature: .agentVoice, pass: "frontend-answer",
                provider: FoundationModelLLMProvider(),
                ids: ModelPassRecorder.correlation ?? UsageCorrelation(), log: $0) }
            continuation.onTermination = { termination in
                if case .cancelled = termination { recorder?.finish(reason: "cancelled") }
                else { recorder?.finish(reason: "stop") }
            }
            Task { await self.register(continuation, recorder: recorder) }
            return stream
        }

        private func register(_ continuation: AsyncThrowingStream<String, Error>.Continuation,
                              recorder: ModelPassRecorder?) {
            continuations.append(continuation)
            recorders.append(recorder)
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
            recorders[index]?.finish(reason: "stop")
        }
    }
}

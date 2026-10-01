import Foundation

/// Actual typed entry → planner stream → presentation → one committed history row.
/// The suspended fixture stream lets us inspect the first chunk before the model ends.
@MainActor
enum AgentPresentationSelfTest {
    static func run() async -> Bool {
        guard SelfTest.isRunning else { return false }
        let before = SelfTestStoreGuard.take()
        let agent = RealtimeAgent.shared
        let previousProvider = agent.localModelProviderForTesting
        let previousApproval = agent.denyUnattendedApprovalsForTesting
        defer {
            agent.interrupt()
            agent.localModelProviderForTesting = previousProvider
            agent.denyUnattendedApprovalsForTesting = previousApproval
        }
        var failures: [String] = []
        func check(_ condition: Bool, _ name: String) {
            if !condition { failures.append(name) }
        }
        agent.denyUnattendedApprovalsForTesting = true
        let stream = PresentationFixtureStream()
        agent.localModelProviderForTesting = PresentationFixtureProvider(script: stream)
        let turn = Task { await agent.handle("Explain how a rainbow forms.", source: .text) }
        let appeared = await waitUntil { agent.respondingMessage?.text == "Sunlight enters a raindrop." }
        let partial = agent.respondingMessage
        check(appeared, "the real first chunk never reached the pane before model completion")
        check(AgentSession.shared.messages.last?.role == "user",
              "a partial answer entered saved/model history")
        let presented = AgentView.presentedMessages(AgentSession.shared.messages, responding: partial)
        check(partial != nil && presented.last?.id == partial?.id,
              "the real pane mapping did not expose the partial")
        await stream.emit(" It bends and splits into colours.")
        check(await waitUntil { agent.respondingMessage?.text.contains("colours") == true },
              "a later chunk did not extend the same answer")
        check(agent.respondingMessage?.id == partial?.id, "the answer row identity changed between chunks")
        await stream.finish()
        let completed = await turn.value
        let stored = AgentSession.shared.messages.last
        check(completed.reply == "Sunlight enters a raindrop. It bends and splits into colours.",
              "the committed answer lost or reordered chunks")
        check(stored?.id == partial?.id && stored?.at == partial?.at,
              "commit replaced the visible row identity or position")
        check(agent.respondingMessage == nil, "the finished answer left a live draft")
        let finalRows = AgentView.presentedMessages(AgentSession.shared.messages, responding: partial)
        check(finalRows.filter { $0.id == partial?.id }.count == 1,
              "the pane showed both partial and committed answer")

        let cancelledStream = PresentationFixtureStream()
        agent.localModelProviderForTesting = PresentationFixtureProvider(script: cancelledStream)
        let cancelled = Task { await agent.handle("Explain how light bends.", source: .text) }
        check(await waitUntil { agent.respondingMessage != nil }, "Stop fixture never began responding")
        let oldGeneration = agent.currentGeneration
        agent.cancel()
        check(agent.respondingMessage == nil, "Stop left an animated answer on screen")
        agent.presentAnswer("Late answer from stopped turn", turn: oldGeneration)
        check(agent.respondingMessage == nil, "a stopped producer overwrote the pane")
        await cancelledStream.emit(" Late chunk.")
        await cancelledStream.finish()
        _ = await cancelled.value
        check(agent.respondingMessage == nil, "a stopped actual model stream republished its answer")

        // Same tracker used by production: tool scaffolding must not render as an answer.
        let tags = PresentationFixtureStream(first: "<tool_call>")
        agent.localModelProviderForTesting = PresentationFixtureProvider(script: tags)
        let tagged = Task { await agent.handle("Explain reflection.", source: .text) }
        _ = await waitUntil { agent.isThinking }
        // Give the actual consumer a turn, then keep the incomplete call suspended.
        for _ in 0..<20 { await Task.yield() }
        check(agent.respondingMessage == nil, "tool scaffolding was displayed as a reply")
        agent.cancel()
        await tags.finish()
        _ = await tagged.value
        let changes = SelfTestStoreGuard.diff(before, SelfTestStoreGuard.take())
        check(changes.isEmpty, "the harness changed an owner store")
        for failure in failures { SelfTest.diagnostic("AGENT_PRESENTATION_WRONG: \(failure)") }
        SelfTest.diagnostic(failures.isEmpty
            ? "AGENT_PRESENTATION_OK: actual typed stream, stable commit, Stop, isolation"
            : "AGENT_PRESENTATION_FAILED: \(failures.count) problem(s)")
        return failures.isEmpty
    }

    private static func waitUntil(_ predicate: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if predicate() { return true }
            // Harness-only polling of a deliberately suspended provider; no production delay.
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }
}

private actor PresentationFixtureStream {
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?
    private var isFinished = false
    private let first: String
    init(first: String = "Sunlight enters a raindrop.") { self.first = first }
    func open() -> AsyncThrowingStream<String, Error> {
        let pair = AsyncThrowingStream<String, Error>.makeStream()
        continuation = pair.continuation
        pair.continuation.yield(first)
        if isFinished { pair.continuation.finish() }
        return pair.stream
    }
    func emit(_ chunk: String) { continuation?.yield(chunk) }
    func finish() { isFinished = true; continuation?.finish(); continuation = nil }
}

private struct PresentationFixtureProvider: LLMProvider {
    let script: PresentationFixtureStream
    var id: LLMProviderID { .appLLM }
    var contextTokens: Int { 32_768 }
    var unavailableReason: String? { get async { nil } }
    func countTokens(_ text: String) async throws -> Int { text.count / 4 + 1 }
    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        throw CancellationError()
    }
    func stream(system: String, user: String, maxTokens: Int) async -> AsyncThrowingStream<String, Error> {
        await script.open()
    }
}

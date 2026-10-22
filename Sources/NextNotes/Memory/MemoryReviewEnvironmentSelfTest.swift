import Foundation

/// Authored facts through the real reviewer, provenance and temporary memory writer.
/// No native model, provider, owner history or settings override.
@MainActor
enum MemoryReviewEnvironmentSelfTest {
    static func failures(root: URL) async -> [String] {
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let resolved = root.resolvingSymlinksInPath().standardizedFileURL
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-memory-review",
              resolved.path.hasPrefix(temp.path + "/"),
              !resolved.pathComponents.contains("Application Support") else {
            return ["environment modal: isolated diagnostic root required"]
        }
        let kept = [
            "The user is unavailable on Fridays.",
            "The user prefers offline-first tools.",
            "The user's company builds search software.",
            "The user fixes bugs before features.",
            "The user is unavailable on Fridays. Their camera is blue.",
            "The user fixes bugs before features. Their app is called Cedar.",
        ]
        let skipped = [
            "The user's microphone isn't working.",
            "The user's microphone wasn't working.",
            "The user's phone doesn't connect.",
            "The user's phone didn't connect.",
            "The user's app won't load.",
            "The user's camera can't open.",
            "The user's camera couldn't open.",
            "The user's app cannot respond.",
            "The user's app stopped responding.",
            "The user's network keeps dropping.",
            "The user's microphone can't hear.",
            "The user's microphone wasn't hearing.",
            "The user's app didn't start.",
            "The user's camera couldn’t open.",
        ]
        var failures: [String] = []
        var checks = 0
        func check(_ label: String, _ value: Bool) {
            checks += 1
            if !value { failures.append("environment modal: " + label) }
        }
        let epoch = Date(timeIntervalSince1970: 1_800_000_000)
        do {
            for (index, fact) in (kept + skipped).enumerated() {
                let shouldKeep = index < kept.count
                let store = NextMemory(directory: root.appendingPathComponent("case-\(index)"), isEnabled: { true })
                let writer = ObservedWriter(store: store)
                let job = MemoryReviewJob(source: .userSaidToAgent, trigger: .conversationEnded,
                    sourceKey: "conversation:" + UUID().uuidString, label: "", sessionID: UUID(),
                    userText: [fact], untrustedText: [], occurredAt: epoch)
                let bytes = try JSONSerialization.data(withJSONObject: ["name": "memory.remember",
                    "arguments": ["kind": "profile", "text": fact]], options: [.sortedKeys])
                let answer = "<tool_call>" + String(decoding: bytes, as: UTF8.self) + "</tool_call>"
                let model = ScriptedMemoryReviewModel { _, _ in answer }
                let outcome = try await MemoryReviewer.review(job, model: model, writer: writer)
                let id = String(format: "E%02d", index)
                check(id + " actual decision", shouldKeep
                    ? outcome.saved.count == 1 && outcome.saved.first?.text == fact && outcome.skipped.isEmpty
                    : outcome.saved.isEmpty && outcome.skipped.map(\.reason) == ["an environment failure, not a fact about the user"])
                check(id + " original proposal and writer boundary", model.callCount == 1 && outcome.proposed == 1
                    && writer.names == (shouldKeep ? ["memory.remember"] : []) && outcome.refused.isEmpty)
                check(id + " actual stored provenance", shouldKeep
                    ? store.entries.count == 1 && store.entries.first?.text == fact
                        && store.entries.first?.source == .review && store.entries.first?.sessionID == job.sessionID
                    : store.entries.isEmpty)
                print("MEMORY_ENVIRONMENT_TRACE case=\(index) keep=\(shouldKeep) saved=\(outcome.saved.count) skipped=\(outcome.skipped.count) refused=\(outcome.refused.count) writerCalls=\(writer.names.count)")
            }
        } catch {
            failures.append("environment modal: authored real reviewer/writer input failed")
        }
        print("MEMORY_ENVIRONMENT_CHECKS=\(checks) problems=\(failures.count)")
        return failures
    }

    private final class ObservedWriter: MemoryReviewWriter {
        let store: NextMemory
        private(set) var names: [String] = []
        init(store: NextMemory) { self.store = store }
        func run(_ call: AgentToolCall, provenance: MemoryProvenance) async throws -> AgentToolResult {
            names.append(call.name)
            return try await StoreMemoryReviewWriter(store: store).run(call, provenance: provenance)
        }
    }
}

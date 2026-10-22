import Foundation

/// Actual cached wrapper -> existing reviewer -> real writer prompt consumer.
/// Scripted capacity snapshots are metadata contracts, not loaded Llama proof.
@MainActor
enum MemoryReviewProviderCapacitySelfTest {
    static func failures(root: URL) async -> [String] {
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let resolved = root.resolvingSymlinksInPath().standardizedFileURL
        guard SelfTest.requested == "--selftest-memory-review", resolved.path.hasPrefix(temporary.path + "/"),
              !resolved.pathComponents.contains("Application Support") else {
            return ["provider capacity: isolated diagnostic root required"]
        }
        var failures: [String] = []
        var checks = 0
        func check(_ name: String, _ condition: Bool) {
            checks += 1
            if !condition { failures.append("provider capacity: " + name) }
        }
        let facts = ["The user's colleague is Rowan.", "The user's pet is Willow.", "The user's club is Coral.",
                     "The user's camera is Onyx.", "The user's mentor is Lumen.", "The user's university is Iris.",
                     "The user's band is Juniper.", "The user's workshop is Indigo."]
        let epoch = Date(timeIntervalSince1970: 1_800_000_000)
        func job() -> MemoryReviewJob {
            MemoryReviewJob(source: .userSaidToAgent, trigger: .conversationEnded,
                sourceKey: "conversation:" + UUID().uuidString, label: "", sessionID: UUID(),
                userText: ["My laboratory is Rowan."], untrustedText: [], occurredAt: epoch)
        }
        do {
            // Explicit resolved snapshots are authored metadata, never a fake loaded runtime.
            for (index, snapshot) in [Int?(4_096), 8_192, 8_193, nil].enumerated() {
                let store = NextMemory(directory: root.appendingPathComponent("cached-\(index)"))
                for fact in facts { try store.remember(kind: .profile, text: fact, source: .manual) }
                let before = store.entries
                let provider = CapturingProvider(contextTokens: 32_768)
                let model = ProviderMemoryReviewModel(provider: provider, resolvedContextTokens: snapshot)
                let outcome = try await MemoryReviewer.review(job(), model: model, writer: StoreMemoryReviewWriter(store: store))
                let prompts = await provider.prompts
                let prompt = prompts.first?.user ?? ""
                let expected = snapshot ?? provider.contextTokens
                let small = expected <= 8_192
                let selected = memoryRows(prompt).map { $0["text"] ?? "" }
                check("snapshot \(index) actual reader exposes captured capacity", model.contextTokens == expected)
                check("snapshot \(index) real reviewer selects matching data", selected == (small ? [facts[0]] : facts))
                check("snapshot \(index) unrelated rows follow actual capacity", small
                    ? facts.dropFirst().allSatisfy { !prompt.contains($0) }
                    : facts.allSatisfy { prompt.contains($0) })
                check("snapshot \(index) one original completion with same system and budget", prompts.count == 1
                    && prompts.first?.system == MemoryReviewer.system(for: .userSaidToAgent) && prompts.first?.maxTokens == 512)
                check("snapshot \(index) same no-op writer outcome and retained rows", outcome.modelCalled && outcome.proposed == 0
                    && outcome.saved.isEmpty && outcome.refused.isEmpty && store.entries == before)
            }
            for window in [4_096, 32_768] {
                let provider = CapturingProvider(contextTokens: window)
                let factory = LiveMemoryReviewModels(localProviderForTesting: provider)
                guard let model = await factory.model(for: .local), let wrapped = model as? ProviderMemoryReviewModel else {
                    return failures + ["provider capacity: actual isolated factory unavailable"]
                }
                let store = NextMemory(directory: root.appendingPathComponent("factory-\(window)"))
                for fact in facts { try store.remember(kind: .profile, text: fact, source: .manual) }
                let before = store.entries
                let outcome = try await MemoryReviewer.review(job(), model: model, writer: StoreMemoryReviewWriter(store: store))
                let prompts = await provider.prompts
                let selected = memoryRows(prompts.first?.user ?? "").map { $0["text"] ?? "" }
                check("factory \(window) same exact provider and cached snapshot", (wrapped.provider as? CapturingProvider) === provider
                    && wrapped.resolvedContextTokens == window && model.contextTokens == window)
                check("factory \(window) real consumer receives resolved model", selected == (window <= 8_192 ? [facts[0]] : facts)
                    && prompts.count == 1 && outcome.modelCalled)
                check("factory \(window) same real no-op writer outcome", outcome.proposed == 0 && store.entries == before)
                let waiting = await factory.model(for: .wait("fixture"))
                let afterWaiting = await provider.prompts
                check("factory \(window) waiting route constructs no provider pass", waiting == nil && afterWaiting.count == 1)
            }
        } catch {
            failures.append("provider capacity: actual fixture prerequisite failed (\(type(of: error)))")
        }
        print("MEMORY_REVIEW_PROVIDER_CAPACITY_CHECKS=\(checks) problems=\(failures.count)")
        return failures
    }

    private static func memoryRows(_ prompt: String) -> [[String: String]] {
        for prefix in ["Current memory (data): ", "Facts already saved — do not repeat (data): "] {
            guard let line = prompt.components(separatedBy: "\n").first(where: { $0.hasPrefix(prefix) }),
                  let data = String(line.dropFirst(prefix.count)).data(using: .utf8),
                  let rows = try? JSONDecoder().decode([[String: String]].self, from: data) else { continue }
            return rows
        }
        return []
    }

    private actor CapturingProvider: LLMProvider {
        nonisolated let id = LLMProviderID.localServer
        nonisolated let displayModelName = "Owned capacity metadata fixture"
        nonisolated let contextTokens: Int
        struct Prompt: Sendable { let system: String; let user: String; let maxTokens: Int }
        private(set) var prompts: [Prompt] = []
        init(contextTokens: Int) { self.contextTokens = contextTokens }
        var unavailableReason: String? { get async { nil } }
        func countTokens(_ text: String) async throws -> Int { text.count / 4 + 1 }
        func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
            prompts.append(Prompt(system: system, user: user, maxTokens: maxTokens))
            return LLMCompletion(text: "NONE", generatedTokens: 1, duration: 0.001)
        }
    }
}

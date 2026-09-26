import Foundation

/// `--selftest-store-isolation` (P0-11).
///
/// Proves a harness run leaves the owner's real stores untouched: the files in
/// `SelfTestStoreGuard.fileNames` plus `Models/library.json`, and every `UserDefaults`
/// key under `modelRoles.`, `modelLibrary.`, `agent` and `codex.` (P1-12's
/// `CodexQuotaStore`). Two legs:
///
/// 1. **The seeded write.** A real `ModelRoleStore.shared.setChoice` call must not
///    reach the owner's domain. It is red until `.shared` reads and writes a
///    per-process suite under the harness; after that the same call lands in the
///    suite and the owner's key never moves.
/// 2. **The harness's own flows.** The model-role self-test, the production tool loop,
///    the memory tools and one typed turn on a stub provider run in-process between
///    two snapshots.
///
/// The final line is `STORE_ISOLATION_OK: <n> files and <m> defaults unchanged`, or
/// `STORE_ISOLATION_FAILED: <what changed>`.
@MainActor
enum StoreIsolationSelfTest {
    static func run() async -> String {
        let roles = ModelRoleStore.shared
        let ownerChoice = roles.choice(for: .computerUse)
        // Hand the owner their own value back when the run ends. While the store is
        // not isolated this write is real, so the red run leaves the preference as it
        // found it; once `.shared` is isolated the write goes to the suite and the
        // owner's domain was never touched at all.
        defer { roles.setChoice(ownerChoice, for: .computerUse) }

        // A value the owner is not already on, so the seeded write is guaranteed to
        // move the stored token while the store is not isolated. This Mac already has
        // Apple's model on the computer-use role.
        let probe: ModelRoleChoice = ownerChoice == .appleFoundation ? .builtIn : .appleFoundation

        let beforeSeeded = SelfTestStoreGuard.take()
        roles.setChoice(probe, for: .computerUse)
        if let change = SelfTestStoreGuard.diff(beforeSeeded, SelfTestStoreGuard.take()).first {
            return "STORE_ISOLATION_FAILED: \(change)"
        }

        let before = SelfTestStoreGuard.take()

        let roleFailures = await ModelRoleSelfTest.run()
        for failure in roleFailures {
            SelfTest.diagnostic("STORE_ISOLATION_FLOW model-roles: \(failure)")
        }

        _ = await RealtimeAgentToolLoopSelfTest.run()

        let provenance = MemoryProvenance(
            origin: .userConversation,
            sessionID: UUID(),
            userText: ["Remember I take the train to work."],
            untrustedText: []
        )
        do {
            _ = try await MemoryProvenance.$current.withValue(provenance) {
                try await AgentToolExecutor.run(
                    "memory.remember",
                    arguments: ["kind": "profile", "text": "The user takes the train to work."],
                    policy: .denyMutations,
                    autoApproveReads: true
                )
            }
            _ = try await MemoryProvenance.$current.withValue(provenance) {
                try await AgentToolExecutor.run(
                    "memory.forget",
                    arguments: ["match": "train to work"],
                    policy: .denyMutations,
                    autoApproveReads: true
                )
            }
        } catch {
            SelfTest.diagnostic("STORE_ISOLATION_FLOW memory tools: \(error.localizedDescription)")
        }

        let agent = RealtimeAgent.shared
        agent.localModelProviderForTesting = StoreIsolationTestProvider()
        agent.denyUnattendedApprovalsForTesting = true
        defer {
            agent.localModelProviderForTesting = nil
            agent.denyUnattendedApprovalsForTesting = false
        }
        _ = await agent.handle("hello", source: .text)

        if let change = SelfTestStoreGuard.diff(before, SelfTestStoreGuard.take()).first {
            return "STORE_ISOLATION_FAILED: \(change)"
        }
        return "STORE_ISOLATION_OK: \(before.files.count) files and \(before.defaults.count) defaults unchanged"
    }
}

/// One typed turn's model, scripted. It never runs a tool and never opens a model
/// file: the turn is here for what it touches on the way through, not for its answer.
private struct StoreIsolationTestProvider: LLMProvider {
    let id = LLMProviderID.appLLM

    var contextTokens: Int { 4_096 }
    var unavailableReason: String? { get async { nil } }

    func countTokens(_ text: String) async throws -> Int { text.count / 4 + 1 }

    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        LLMCompletion(text: "<answer/>Hello.", generatedTokens: 6, duration: 0)
    }

    func stream(
        system: String, user: String, maxTokens: Int
    ) async -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield("<answer/>Hello.")
            continuation.finish()
        }
    }
}

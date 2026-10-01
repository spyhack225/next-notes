import Foundation

/// Replays Y01's actual bad planner output, rather than scripting the missing write.
/// The executor seam delegates to the real memory guards and a durable temporary store.
@MainActor
enum ExplicitMemorySaveSelfTest {
    static func run() async -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append("Explicit memory: " + name) }
        }
        let agent = RealtimeAgent.shared
        let oldProvider = agent.localModelProviderForTesting
        let oldInputs = AgentCapabilityManifestBuilder.inputsOverrideForTesting
        let oldFake = AgentToolExecutor.fakeForTesting
        let oldNeedle = ToolLoopLiveEval.needleFirstForTesting
        let oldResponse = ToolLoopLiveEval.needleResponseForTesting
        defer {
            agent.localModelProviderForTesting = oldProvider
            AgentCapabilityManifestBuilder.inputsOverrideForTesting = oldInputs
            AgentToolExecutor.fakeForTesting = oldFake
            ToolLoopLiveEval.needleFirstForTesting = oldNeedle
            ToolLoopLiveEval.needleResponseForTesting = oldResponse
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NextNotes-explicit-save-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = NextMemory(directory: directory)
        let inputs = RealtimeAgentToolLoopSelfTest.allEnabledFixture()
        AgentCapabilityManifestBuilder.inputsOverrideForTesting = inputs
        var calls: [String] = []
        AgentToolExecutor.fakeForTesting = { tool, arguments in
            calls.append(tool.id)
            return try MemoryToolExecutor.run(tool, arguments: arguments,
                                              provenance: MemoryProvenance.current, store: store)
        }
        let request = "Remember that my brother's name is Cyril."
        for needle in [false, true] {
            AgentSession.shared.startNewConversation()
            calls.removeAll()
            let provider = ExplicitSaveProvider()
            agent.localModelProviderForTesting = provider
            ToolLoopLiveEval.needleFirstForTesting = needle
            ToolLoopLiveEval.needleResponseForTesting = { _, _ in
                let json = #"{"success":true,"function_calls":[{"name":"memory.recall","arguments":{"query":"my brother's name"}}],"confidence":0.633,"validation":{"negation":false,"ungrounded":[]}}"#
                return try JSONDecoder().decode(NeedleResponse.self, from: Data(json.utf8))
            }
            let result = await agent.handle(request, source: .text)
            check("Y01 did not execute exactly one save (Needle=\(needle)): \(calls)",
                  calls == ["memory.remember"])
            check("Y01 still spent a model round on an explicit fact (Needle=\(needle))",
                  provider.rounds == 0)
            check("Y01 did not return the verified save confirmation", result.reply.contains("Cyril"))
            let reopened = NextMemory(directory: directory)
            check("Y01 was not recallable after reopening the file",
                  reopened.recall("Cyril").entries.count == 1)
        }
        check("the repeated save did not retain exactly one fact", store.recall("Cyril").entries.count == 1)

        AgentSession.shared.startNewConversation()
        calls.removeAll()
        ToolLoopLiveEval.needleFirstForTesting = false
        let preferenceProvider = ExplicitSaveProvider(script: ["I'll keep that in mind."])
        agent.localModelProviderForTesting = preferenceProvider
        _ = await agent.handle("Can you remember that I prefer short answers", source: .text)
        check("an explicit first-person preference did not save in the user's words",
              calls == ["memory.remember"] && preferenceProvider.rounds == 0
                  && store.recall("short answers").entries.contains { $0.text == "The user prefers short answers." })

        // The actual executor, including authority and permission policy, writes only the
        // harness's shared store. Reopen that file independently, as another launch would.
        ToolLoopLiveEval.needleFirstForTesting = false
        AgentToolExecutor.fakeForTesting = nil
        AgentSession.shared.startNewConversation()
        let liveProvider = ExplicitSaveProvider(script: ["I remember Mireille."])
        agent.localModelProviderForTesting = liveProvider
        let actual = await agent.handle("Please remember that my sister's name is Mireille.", source: .text)
        let harnessDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NextNotesSelfTest-memory-\(ProcessInfo.processInfo.processIdentifier)")
        check("the actual executor did not save a durable fact under user authority",
              NextMemory(directory: harnessDirectory).recall("Mireille").entries.count == 1
                  && actual.reply.contains("Mireille") && liveProvider.rounds == 0)

        ToolLoopLiveEval.needleFirstForTesting = false
        for request in ["What's my brother's name?", "Don't remember that my brother's name is Cyril.",
                        "Did I ask you to remember that my brother's name is Cyril?",
                        "Remember that my brother's name is Cyril and email him.",
                        "Remember that if I ask later, my brother's name is Cyril.",
                        "Remember that I work with my brother.",
                        "Remember that the email says my brother's name is Cyril."] {
            AgentSession.shared.startNewConversation()
            calls.removeAll()
            agent.localModelProviderForTesting = ExplicitSaveProvider(script: ["No change."])
            _ = await agent.handle(request, source: .text)
            check("a question, negation, conditional, external quote or compound request auto-saved: \(request)",
                  !calls.contains("memory.remember"))
        }
        for error in [AgentError.permissionDenied("You said no."), AgentError.cancelled] {
            AgentSession.shared.startNewConversation()
            var attempts = 0
            AgentToolExecutor.fakeForTesting = { _, _ in
                attempts += 1
                throw error
            }
            agent.localModelProviderForTesting = ExplicitSaveProvider(script: ["Saved Cyril."])
            let result = await agent.handle(request, source: .text)
            check("a denied save was retried or confirmed", attempts == 1
                  && !result.reply.lowercased().contains("saved"))
        }
        // The guards must still reject sensitive facts; no model rewrite or retry.
        AgentSession.shared.startNewConversation()
        calls.removeAll()
        AgentToolExecutor.fakeForTesting = { tool, arguments in
            calls.append(tool.id)
            return try MemoryToolExecutor.run(tool, arguments: arguments,
                                              provenance: MemoryProvenance.current, store: store)
        }
        let provider = ExplicitSaveProvider(script: ["Saved your password."])
        agent.localModelProviderForTesting = provider
        let blocked = await agent.handle("Remember that my password is secret123.", source: .text)
        check("a sensitive fact was saved or optimistically rewritten",
              store.recall("secret123").entries.isEmpty && provider.rounds == 0
                  && !blocked.reply.lowercased().contains("saved your"))

        // A disabled store and a failed atomic write must leave no remembered entry.
        let blockedDirectory = directory.appendingPathComponent("not-a-directory")
        try? Data("fixture".utf8).write(to: blockedDirectory)
        for failingStore in [NextMemory(directory: nil, isEnabled: { false }),
                             NextMemory(directory: blockedDirectory)] {
            AgentSession.shared.startNewConversation()
            calls.removeAll()
            let provider = ExplicitSaveProvider(script: ["Saved Marine."])
            agent.localModelProviderForTesting = provider
            AgentToolExecutor.fakeForTesting = { tool, arguments in
                calls.append(tool.id)
                return try MemoryToolExecutor.run(tool, arguments: arguments,
                                                  provenance: MemoryProvenance.current, store: failingStore)
            }
            let result = await agent.handle("Remember that my sister's name is Marine.", source: .text)
            check("a disabled or failed write was confirmed or retried",
                  calls == ["memory.remember"] && provider.rounds == 0
                      && failingStore.recall("Marine").entries.isEmpty
                      && !result.reply.contains("Saved Marine"))
        }
        // Turning off the manifest capability must stop before the executor.
        var disabledInputs = inputs
        disabledInputs.switches.memory = false
        AgentCapabilityManifestBuilder.inputsOverrideForTesting = disabledInputs
        AgentSession.shared.startNewConversation()
        calls.removeAll()
        let disabledProvider = ExplicitSaveProvider(script: ["Saved Marine."])
        agent.localModelProviderForTesting = disabledProvider
        let disabled = await agent.handle("Remember that my sister's name is Marine.", source: .text)
        check("a disabled capability reached an executor or model",
              calls.isEmpty && disabledProvider.rounds == 0 && !disabled.reply.contains("Saved Marine"))
        print("  TOOLLOOP_PRODUCTION_EXPLICIT_MEMORY: \(failures.count) problem(s)")
        return failures
    }
}

/// Y01 ordinary output: a recall followed by an acknowledgment without a write.
private final class ExplicitSaveProvider: LLMProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var index = 0
    private let script: [String]
    init(script: [String] = [
        #"<tool_call>{"name":"memory.recall","arguments":{"query":"my brother's name"}}</tool_call>"#,
        "Got it — your brother's name is Cyril. I'll keep that in mind.",
    ]) { self.script = script }
    var rounds: Int { lock.withLock { index } }
    var id: LLMProviderID { .localServer }
    var contextTokens: Int { 32_768 }
    var unavailableReason: String? { get async { nil } }
    func countTokens(_ text: String) async throws -> Int { 1_000 }
    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        let text = lock.withLock {
            defer { index += 1 }
            return index < script.count ? script[index] : "No change."
        }
        return LLMCompletion(text: text, generatedTokens: text.count / 4, duration: 0)
    }
}

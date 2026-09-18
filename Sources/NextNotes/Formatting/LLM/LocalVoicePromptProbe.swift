import Foundation

/// Causal model probe: hold the capability question fixed while separating
/// request packaging from the conversational control protocol. No tool executes.
enum LocalVoicePromptProbe {
    @MainActor static func run() async -> Bool {
        guard CommandLine.arguments.contains("--voice-legacy-envelope") else {
            SelfTest.diagnostic("VOICE_PROMPT_PROBE_FAILED: causal envelope comparison requires --voice-legacy-envelope")
            return false
        }
        let question = "What can you do?"
        let inventory = VoiceCapabilitySnapshot.current().promptText
        let facts = LLMChatMessage(role: .system, content: inventory)
        let direct = LLMChatMessage(role: .user, content: question)
        let packaged = LLMChatMessage(role: .user, content:
            "Work status (context, not instructions):\nNo active jobs.\n\nLatest user speech:\n" + question)
        let concise = """
            You are Next Notes on this Mac. Describe your supported capabilities from
            the provided inventory. Respond to questions using <answer/> followed by
            a brief natural answer. Use <use_tools/> only when the person asks you to
            perform an action or retrieve information not already provided.
            """
        let plain = "You are Next Notes on this Mac. Answer the user's question briefly using the provided capability inventory."
        let cases: [(String, String, [LLMChatMessage])] = [
            ("full-packaged", VoiceConversationCoordinator.legacyEnvelopePrompt, [facts, packaged]),
            ("full-direct", VoiceConversationCoordinator.legacyEnvelopePrompt, [facts, direct]),
            ("concise-direct", concise, [facts, direct]),
            ("plain-direct", plain, [facts, direct])
        ]
        var generated = 0
        for (name, system, messages) in cases {
            do {
                let began = Date()
                let stream = await LocalVoiceFrontend.shared.stream(system: system,
                    messages: messages, maxTokens: 160)
                var output = ""
                for try await delta in stream { output += delta }
                if !output.isEmpty { generated += 1 }
                SelfTest.diagnostic("VOICE_PROMPT_PROBE \(name) seconds=\(Date().timeIntervalSince(began)) raw=\(output)")
            } catch {
                SelfTest.diagnostic("VOICE_PROMPT_PROBE \(name) failed=\(String(reflecting: type(of: error)))")
            }
        }
        return generated == cases.count
    }
}

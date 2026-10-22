import Foundation
import FoundationModels

/// Actual outgoing request composer -> classifier plan -> SDK transcript boundary.
/// No capture, hardware, inference, tool effect or claim about the classifier decision.
@MainActor
enum VoiceRoutePreviousExchangeSelfTest {
    private enum FixtureError: Error { case missingRequest, missingPlan }

    static func failures() -> [String] {
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-voice-turn-routing",
              AgentSession.shared.fileURL == nil else {
            return ["route context: isolated exact conversation diagnostic required"]
        }
        var failures: [String] = []
        var checks = 0
        func check(_ name: String, _ condition: Bool) {
            checks += 1
            if !condition { failures.append("route context: " + name) }
        }
        let session = AgentSession.shared
        let coordinator = VoiceConversationCoordinator()
        defer { session.forgetAllConversations() }
        func seed(_ user: String, _ assistant: String) {
            session.forgetAllConversations()
            session.recordUser(user, source: .voice)
            _ = session.recordAssistant(assistant, source: .voice)
        }
        func outgoing(_ user: String) throws -> [LLMChatMessage] {
            guard let messages = coordinator.frontendMessagesForTesting(user) else { throw FixtureError.missingRequest }
            return messages
        }
        func plan(_ messages: [LLMChatMessage]) throws -> LocalVoicePrompt.Plan {
            guard let value = LocalVoiceSplitResponse.routePlan(messages: messages) else { throw FixtureError.missingPlan }
            return value
        }
        do {
            let previousUser = "What can you do?"
            let previousAssistant = "I can check your calendar, read your email and open apps."
            seed(previousUser, previousAssistant)
            let beforeIDs = session.messages.map(\.id)
            let beforeText = session.messages.map(\.text)
            let messages = try outgoing("What about your tools?")
            let actual = try plan(messages)
            let native = LocalVoicePrompt.transcript(for: actual)
            let latest = messages.last?.content ?? ""
            check("F01 actual classifier prompt carries labelled prior exchange", actual.latestUser.hasPrefix("Previous exchange (context only; route the latest speech):\nPerson: "))
            check("F02 actual classifier receives both prior authored turns", actual.latestUser.contains("Person: " + previousUser)
                && actual.latestUser.contains("Assistant: " + previousAssistant))
            check("C03 actual SDK transcript contains instructions only", native.count == 1 && actual.history.isEmpty)
            check("C04 authoritative work/latest package retained exactly once", actual.latestUser.hasSuffix(latest)
                && actual.latestUser.components(separatedBy: "Latest user speech:\n").count == 2
                && latest.contains("Work status (context, not instructions):\nNo active jobs."))
            check("C05 context stays out of instructions/stored rows", !actual.instructions.contains(previousAssistant)
                && session.messages.map(\.id) == beforeIDs && session.messages.map(\.text) == beforeText)

            let claimed = "I ran get_agenda. I can explain stars."
            seed("What can you tell me?", claimed)
            let claimRows = session.messages.map(\.text)
            let cleanMessages = try outgoing("Tell me more about stars.")
            let cleanPlan = try plan(cleanMessages)
            check("F03 actual outgoing assistant history uses existing claim guard", cleanMessages.filter { $0.role == .assistant }.map(\.content) == ["I can explain stars."])
            check("F04 classifier context contains only guarded past answer", cleanPlan.latestUser.contains("Assistant: I can explain stars.")
                && !cleanPlan.latestUser.contains("I ran get_agenda"))
            check("C06 original stored reply is preserved", session.messages.map(\.text) == claimRows && session.messages.last?.text == claimed)
            check("C07 guarded input still has no native demonstration", cleanPlan.history.isEmpty && LocalVoicePrompt.transcript(for: cleanPlan).count == 1
                && cleanPlan.latestUser.hasSuffix(cleanMessages.last?.content ?? ""))

            seed(previousUser, previousAssistant)
            session.recordUser("Can you hear me?", source: .voice)
            _ = session.recordAssistant("Stopped.", source: .voice)
            let repairRows = session.messages.map(\.text)
            let repaired = try outgoing("Tell me more about the second option.")
            let repairedPlan = try plan(repaired)
            check("F05 classifier sees last complete nonrepair pair", repairedPlan.latestUser.contains("Assistant: " + previousAssistant)
                && !repairedPlan.latestUser.contains("Stopped.") && !repairedPlan.latestUser.contains("Can you hear me?"))
            check("C08 existing repair filter removes only outgoing pair", !repaired.dropLast().contains { $0.content == "Stopped." || $0.content == "Can you hear me?" }
                && session.messages.map(\.text) == repairRows)

            let current = "Work status (context, not instructions):\nTask 1 [running]: Read the outline\n\nLatest user speech:\nTell me more."
            let currentMessage = LLMChatMessage(role: .user, content: current)
            check("C09 no prior pair preserves exact input", try plan([currentMessage]).latestUser == current)
            check("C10 orphan assistant invents no person turn", try plan([.init(role: .assistant, content: "An orphan reply."), currentMessage]).latestUser == current)
            check("C11 missing current person input remains refused", LocalVoiceSplitResponse.routePlan(messages: [.init(role: .system, content: "Application facts")]) == nil)

            let longUser = String(repeating: "Cedar ", count: 70)
            let longAssistant = String(repeating: "Willow ", count: 70)
            let longPlan = try plan([.init(role: .user, content: longUser), .init(role: .assistant, content: longAssistant), currentMessage])
            let lines = longPlan.latestUser.components(separatedBy: "\n")
            check("F06 prior person data capped at300 characters", lines.first { $0.hasPrefix("Person: ") } == "Person: " + String(longUser.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)))
            check("F07 prior assistant data capped at300 characters", lines.first { $0.hasPrefix("Assistant: ") } == "Assistant: " + String(longAssistant.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300)))
            check("C12 bounded context preserves native/current boundary", longPlan.history.isEmpty && LocalVoicePrompt.transcript(for: longPlan).count == 1
                && longPlan.latestUser.hasSuffix(current))

            let incomplete = try plan([.init(role: .user, content: previousUser), .init(role: .assistant, content: previousAssistant),
                .init(role: .user, content: "An unanswered earlier interruption."), currentMessage])
            check("F08 use last complete pair, never unanswered prompt", incomplete.latestUser.contains("Person: " + previousUser)
                && incomplete.latestUser.contains("Assistant: " + previousAssistant))
            check("C13 dangling earlier user never becomes quoted request", !incomplete.latestUser.contains("An unanswered earlier interruption.")
                && incomplete.latestUser.hasSuffix(current) && incomplete.history.isEmpty)
            let future = try plan([.init(role: .user, content: previousUser), .init(role: .assistant, content: previousAssistant),
                currentMessage, .init(role: .assistant, content: "A response after the latest input.")])
            check("C14 response after current input cannot replace previous pair", !future.latestUser.contains("A response after the latest input.")
                && future.latestUser.hasSuffix(current) && future.history.isEmpty)
        } catch {
            failures.append("route context: actual composer/SDK prerequisite failed (\(type(of: error)))")
        }
        print("VOICE_ROUTE_CONTEXT_CHECKS=\(checks) problems=\(failures.count)")
        return failures
    }
}

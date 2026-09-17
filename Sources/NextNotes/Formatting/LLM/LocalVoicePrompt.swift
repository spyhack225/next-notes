import Foundation
import FoundationModels

/// Pure description of the native transcript handed to Foundation Models.
/// Keeping this separate makes role order and
/// the latest-prompt boundary testable without loading a model.
enum LocalVoicePrompt {
    struct HistoryEntry: Equatable, Sendable {
        let role: LLMChatMessage.Role
        let content: String
    }

    struct Plan: Equatable, Sendable {
        let instructions: String
        let history: [HistoryEntry]
        let latestUser: String

        var entryRoles: [LLMChatMessage.Role] {
            history.map(\.role)
        }
    }

    /// Select native roles for a legacy envelope comparison. The production
    /// route/answer path always constructs native transcripts directly.
    static var isEnabled: Bool {
        SelfTest.isRunning && CommandLine.arguments.contains("--voice-legacy-envelope")
            && CommandLine.arguments.contains("--voice-native-history")
    }

    /// Build application instructions from the caller's system messages, then
    /// retain preceding user/assistant turns as distinct transcript entries.
    /// The final user message is supplied to `streamResponse(to:)` separately.
    static func plan(system: String, messages: [LLMChatMessage]) -> Plan? {
        guard let latestIndex = messages.lastIndex(where: { $0.role == .user }) else {
            return nil
        }
        let systemMessages = messages.filter { $0.role == .system }.map(\.content)
        let instructions = ([system] + systemMessages)
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let history = messages.enumerated().compactMap { index, message -> HistoryEntry? in
            guard index < latestIndex, message.role != .system else { return nil }
            return HistoryEntry(role: message.role, content: message.content)
        }
        return Plan(
            instructions: instructions,
            history: history,
            latestUser: messages[latestIndex].content
        )
    }

    /// Convert a pure plan into the SDK transcript. There are no tool
    /// definitions: this lane can only produce conversational control text.
    static func transcript(for plan: Plan) -> Transcript {
        let instructionSegments = [Transcript.Segment.text(
            Transcript.TextSegment(content: plan.instructions)
        )]
        var entries: [Transcript.Entry] = [
            .instructions(.init(segments: instructionSegments, toolDefinitions: []))
        ]
        for item in plan.history {
            let segments = [Transcript.Segment.text(Transcript.TextSegment(content: item.content))]
            switch item.role {
            case .user:
                entries.append(.prompt(.init(segments: segments)))
            case .assistant:
                entries.append(.response(.init(assetIDs: [], segments: segments)))
            case .system:
                // System entries are folded into Instructions in `plan`.
                break
            }
        }
        return Transcript(entries: entries)
    }
}

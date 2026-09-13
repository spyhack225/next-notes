import Foundation

/// Structured meeting reads. These never execute anything — they return what
/// `MeetingContextStore` has already extracted.
enum MeetingToolCatalogue {
    static let all: [AgentTool] = [
        .native(
            namespace: .meeting,
            name: "current",
            description: "Summarise the meeting that is recording or was most recently open: "
                + "title, participants, and how long it has been going.",
            risk: .observe,
            title: "Current meeting"
        ),
        .native(
            namespace: .meeting,
            name: "transcript",
            description: "Return recent transcript lines. Optional minutes (default 3) limits "
                + "how far back.",
            risk: .read,
            parameters: [
                .init(name: "minutes", description: "How many minutes to include.", isRequired: false)
            ],
            title: "Recent transcript"
        ),
        .native(
            namespace: .meeting,
            name: "recent_context",
            description: "The structured meeting state: topics, decisions, questions, "
                + "commitments and unresolved items. Prefer this over rereading the transcript.",
            risk: .observe,
            title: "Meeting context"
        ),
        .native(
            namespace: .meeting,
            name: "participants",
            description: "Who is on the invite and who has been heard so far.",
            risk: .observe,
            title: "Participants"
        ),
        .native(
            namespace: .meeting,
            name: "action_items",
            description: "Action items extracted so far, including candidate actions that "
                + "other people asked for but the user has not authorised.",
            risk: .observe,
            title: "Action items"
        ),
        .native(
            namespace: .meeting,
            name: "decisions",
            description: "Decisions recorded in this meeting.",
            risk: .observe,
            title: "Decisions"
        ),
        .native(
            namespace: .meeting,
            name: "search",
            description: "Search this meeting's transcript for a phrase.",
            risk: .read,
            parameters: [
                .init(name: "query", description: "Words to find.")
            ]
        ),
    ]
}

enum MeetingToolExecutor {
    @MainActor
    static func run(_ tool: AgentTool, arguments: [String: String]) throws -> AgentToolResult {
        let context = MeetingContextStore.shared.current
        switch tool.name {
        case "current":
            guard let context else {
                return AgentToolResult(summary: "No meeting is active.")
            }
            return AgentToolResult(summary: context.overview)
        case "transcript":
            let minutes = Double(arguments["minutes"] ?? "") ?? 3
            let lines = MeetingContextStore.shared.recentTranscript(minutes: minutes)
            return AgentToolResult(summary: lines.isEmpty ? "Nothing has been said recently." : lines)
        case "recent_context":
            guard let context else {
                return AgentToolResult(summary: "No meeting context has been extracted yet.")
            }
            return AgentToolResult(summary: context.summary)
        case "participants":
            guard let context else {
                return AgentToolResult(summary: "No meeting is active.")
            }
            let names = context.participants.isEmpty
                ? "No participants recorded."
                : context.participants.joined(separator: ", ")
            return AgentToolResult(summary: names)
        case "action_items":
            guard let context else {
                return AgentToolResult(summary: "No action items yet.")
            }
            return AgentToolResult(summary: context.actionItemsSummary)
        case "decisions":
            guard let context else {
                return AgentToolResult(summary: "No decisions recorded.")
            }
            return AgentToolResult(summary: context.decisionsSummary)
        case "search":
            let query = arguments["query"] ?? ""
            let hits = MeetingContextStore.shared.searchTranscript(query)
            return AgentToolResult(summary: hits.isEmpty ? "No matches for \(query)." : hits)
        default:
            throw AgentError.unknownTool(tool.id)
        }
    }
}

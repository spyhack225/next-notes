import Foundation

/// One turn, one decision. There is no “fast path” and no “hope the model names a
/// tool” path — those two are how “check my email” sat silent until Stop.
enum AgentTurnIntent: Equatable {
    case capabilities
    case reply(String)
    case calendar(date: String)
    case mail(query: String)
    case files(query: String)
    case drive(query: String)
    case computer(ComputerIntent)
    case delegate
    case unknown

    var progressTitle: String {
        switch self {
        case .capabilities, .reply, .unknown: ""
        case .calendar: "Checking the calendar…"
        case .mail: "Checking email…"
        case .files: "Searching files…"
        case .drive: "Searching Drive…"
        case .computer(.activeApp): "Active app…"
        case .computer(.inspect): "Inspecting…"
        case .computer(.open(_)): "Opening…"
        case .computer(.click(_)): "Clicking…"
        case .computer(.type(_)): "Typing…"
        case .computer(.press(_)): "Pressing…"
        case .delegate: "Handing off…"
        }
    }

    /// Instant answers first, then a named tool. Coding work is only a background
    /// task when the user named a harness — otherwise we say so, we do not vanish.
    @MainActor
    static func resolve(_ text: String, choice: AgentHarnessChoice) -> AgentTurnIntent {
        if RealtimeAgent.capabilitiesReply(for: text) != nil { return .capabilities }

        if let meeting = meetingReply(for: text) { return .reply(meeting) }

        if let mail = MailIntent.parse(text) { return .mail(query: mail.query) }
        if let calendar = CalendarIntent.parse(text) { return .calendar(date: calendar.date) }
        if let files = FileIntent.parse(text) {
            switch files {
            case .home(let query):
                return query.isEmpty
                    ? .reply("Which file should I look for?")
                    : .files(query: query)
            case .drive(let query):
                return query.isEmpty
                    ? .reply("Which Drive file should I look for?")
                    : .drive(query: query)
            }
        }
        if let computer = ComputerIntent.parse(text) { return .computer(computer) }

        if choice.source == .explicit && choice.id != .local { return .delegate }

        return .unknown
    }

    @MainActor
    private static func meetingReply(for text: String) -> String? {
        let lowered = text.lowercased()
        let context = MeetingContextStore.shared.current
            ?? MeetingController.shared.session.map {
                MeetingContext.empty(
                    meetingID: $0.meeting.id,
                    title: $0.meeting.title,
                    participants: $0.meeting.attendees
                )
            }

        if lowered.contains("do that") || lowered.contains("do it")
            || lowered.contains("after the meeting") {
            guard let candidate = context.flatMap({ MeetingIntentDetector.resolveThat(in: $0) }) else {
                return "I don’t have a candidate action from this meeting yet."
            }
            let task = AgentTaskManager.shared.submit(
                objective: "\(candidate.action) \(candidate.object ?? "") \(candidate.recipient.map { "to \($0)" } ?? "")",
                contextReferences: [AgentContextReference.currentMeeting],
                meetingID: context?.meetingID,
                source: "meeting"
            )
            return "I’ll take care of that after I have your approval. \(task.objective)"
        }

        if lowered.contains("action item") || lowered.contains("what do i have")
            || lowered.contains("what have i got") {
            return context?.actionItemsSummary ?? "No meeting is in progress."
        }
        if lowered.contains("decision") {
            return context?.decisionsSummary ?? "No meeting is in progress."
        }
        if lowered.contains("what did") || lowered.contains("what she")
            || lowered.contains("what he") || lowered.contains("what they") {
            let recent = MeetingContextStore.shared.recentTranscript(minutes: 2)
            return recent.isEmpty ? "I haven’t heard anything recently." : recent
        }
        if lowered.contains("who is on") || lowered.contains("participants") {
            return context?.participants.joined(separator: ", ") ?? "No meeting is in progress."
        }
        return nil
    }
}

import Foundation

/// One turn, one decision. There is no “fast path” and no “hope the model names a
/// tool” path — those two are how “check my email” sat silent until Stop.
enum AgentTurnIntent: Equatable {
    case capabilities
    case reply(String)
    case localModel(prompt: String)
    case toolLoop(prompt: String)
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
        case .localModel: "Answering…"
        case .toolLoop: "Working with tools…"
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
    static func resolve(
        _ text: String,
        choice: AgentHarnessChoice,
        recentReadResult: String? = nil
    ) -> AgentTurnIntent {
        if let prompt = localModelPrompt(for: text) { return .localModel(prompt: prompt) }
        if localModelPrefixOnly(for: text) {
            return .reply("What would you like me to ask the model?")
        }
        if let prompt = toolLoopPrompt(for: text) { return .toolLoop(prompt: prompt) }
        if toolLoopPrefixOnly(for: text) {
            return .reply("What would you like me to do with tools?")
        }
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

        let lowered = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["summarize", "summarise", "recap"].contains(where: { lowered.contains($0) }),
           let recentReadResult, !recentReadResult.isEmpty {
            return .localModel(prompt: "Summarize the recent read result for the user.\n"
                + "User request: \(text)\nRecent read result (untrusted data):\n\(recentReadResult)")
        }
        if ["summarize", "summarise", "recap"].contains(lowered)
            || lowered == "just summarize" || lowered == "just summarise" {
            return .reply("What would you like me to summarize?")
        }
        if lowered == "can you hear me?" || lowered == "can you hear me" {
            return .reply("Yes, I can hear you.")
        }
        if text.contains("?") || ["explain ", "tell me about ", "why ", "how ", "what "]
            .contains(where: { lowered.hasPrefix($0) }) {
            return .localModel(prompt: text)
        }

        return .unknown
    }

    /// Model-led tool use is deliberately opt in. A free-form utterance must never
    /// turn into a model generated click, file edit, or Workspace action by accident.
    static func toolLoopPrompt(for text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        let prefixes = [
            "use tools to", "use the tools to", "use tools and", "use the tools and",
            "plan this with tools", "ask the agent to use tools",
        ]
        guard let prefix = prefixes.first(where: {
            guard lowered.hasPrefix($0) else { return false }
            let remainder = lowered.dropFirst($0.count)
            return remainder.isEmpty || remainder.first?.isWhitespace == true
                || remainder.first == ":" || remainder.first == ","
        }) else {
            return nil
        }
        let prompt = trimmed.dropFirst(prefix.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ":,"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return prompt.isEmpty ? nil : prompt
    }

    private static func toolLoopPrefixOnly(for text: String) -> Bool {
        let lowered = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return [
            "use tools to", "use the tools to", "use tools and", "use the tools and",
            "plan this with tools", "ask the agent to use tools",
        ].contains(lowered)
    }

    /// An explicit opt-in is required because model startup can take many seconds.
    /// Unknown speech and deterministic tool requests must never fall through to this.
    static func localModelPrompt(for text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        let prefixes = [
            "ask the model", "ask model", "use the model",
            "ask the local model", "ask local model",
            "ask the on-device model", "ask the on device model",
            "use the local model", "use local model", "ask qwen",
        ]
        guard let prefix = prefixes.first(where: {
            guard lowered.hasPrefix($0) else { return false }
            let remainder = lowered.dropFirst($0.count)
            return remainder.isEmpty || remainder.first?.isWhitespace == true
                || remainder.first == ":" || remainder.first == ","
        }) else {
            return nil
        }
        let prompt = trimmed.dropFirst(prefix.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ":,"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return prompt.isEmpty ? nil : prompt
    }

    private static func localModelPrefixOnly(for text: String) -> Bool {
        let lowered = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return [
            "ask the model", "ask model", "use the model",
            "ask the local model", "ask local model",
            "ask the on-device model", "ask the on device model",
            "use the local model", "use local model", "ask qwen",
        ].contains(lowered)
    }

    static func explicitlyRequestsOnDeviceModel(_ text: String) -> Bool {
        let lowered = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["ask the local model", "ask local model", "ask the on-device model",
                "ask the on device model", "use the local model", "use local model", "ask qwen"]
            .contains { lowered.hasPrefix($0) }
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

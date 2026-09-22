import Foundation

/// One turn, one model-led decision. The model can answer or request a tool
/// without a phrase trigger; the executor retains the approval boundary.
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

    var contextKind: String? {
        switch self {
        case .calendar: "calendar"
        case .mail: "mail"
        case .files: "files"
        case .drive: "drive"
        case .computer: "computer"
        case .toolLoop: "tools"
        default: nil
        }
    }

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

    /// The selected model decides whether an ordinary turn needs a tool. Only an
    /// explicitly named external coding harness bypasses the local planner.
    @MainActor
    static func resolve(
        _ text: String,
        choice: AgentHarnessChoice,
        hasConversationContext: Bool = false
    ) -> AgentTurnIntent {
        _ = hasConversationContext
        if choice.source == .explicit && choice.id != .local { return .delegate }
        // Explicit on-device Q&A remains an answer-only choice. It cannot
        // silently turn into a computer or cloud write.
        if explicitlyRequestsOnDeviceModel(text),
           let prompt = localModelPrompt(for: text) {
            return .localModel(prompt: prompt)
        }
        return .toolLoop(prompt: text)
    }

    /// Explicit on-device phrasing selects the answer-only local model route.
    static func localModelPrompt(for text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        let prefixes = [
            "ask the model", "ask model", "use the model",
            "ask the local model", "ask local model",
            "ask the on-device model", "ask the on device model",
            "use the local model", "use local model", "ask qwen", "ask gemma",
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
            "use the local model", "use local model", "ask qwen", "ask gemma",
        ].contains(lowered)
    }

    static func explicitlyRequestsOnDeviceModel(_ text: String) -> Bool {
        let lowered = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["ask the local model", "ask local model", "ask the on-device model",
                "ask the on device model", "use the local model", "use local model",
                "ask qwen", "ask gemma"]
            .contains { lowered.hasPrefix($0) }
    }

}

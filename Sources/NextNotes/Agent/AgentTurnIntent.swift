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
        case .localModel: "Working with tools…"
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
        // "Ask the agent", "ask the app": the person is addressing this app, not a model
        // inside it, so the rest of the sentence is a request and the planner is what
        // answers it. These prefixes used to select the answer-only local model, which is
        // where "Ask the agent what's on my calendar tomorrow" came back "I don't have that
        // information" — with get_agenda in the roster and no route that could reach it.
        if let rest = strippedPrefix(text, among: addressesTheAgent) {
            return .toolLoop(prompt: rest)
        }
        // Explicit on-device phrasing is still its own route, and it is still the app's own
        // model: the planner, with read tools only. It cannot become a write, and it cannot
        // become a different model.
        if let prompt = localModelPrompt(for: text) {
            return .localModel(prompt: prompt)
        }
        return .toolLoop(prompt: text)
    }

    /// The phrasings that address this app rather than a model inside it. Longest first so
    /// "ask the agent" is never read as a shorter prefix of itself.
    private static let addressesTheAgent = [
        "ask the agent", "ask agent", "ask the app", "ask app",
    ]

    /// The phrasings that mean the on-device model specifically. "ask the model" is here
    /// because a person who says it means the thing on their Mac; "ask qwen" and "ask gemma"
    /// are the legacy spellings for utterances spoken when the app LLM carried those names.
    private static let onDevicePrefixes = [
        "ask the local model", "ask local model",
        "ask the on-device model", "ask the on device model",
        "use the local model", "use local model",
        "ask the model", "ask model", "use the model",
        "ask qwen", "ask gemma",
    ]

    /// The words after one of `prefixes`, or nil when the sentence does not start with one.
    ///
    /// Word-bounded on both sides, which is the whole reason this is one function rather
    /// than a `hasPrefix` per list: "ask apple support" begins with the letters of
    /// "ask app", and a prefix test alone read it as the local-model route. The separator
    /// may be a space, a colon or a comma, and it is trimmed away with the punctuation
    /// around it — "ask the local model, explain this" is one request.
    static func strippedPrefix(_ text: String, among prefixes: [String]) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        guard let prefix = prefixes.first(where: { lowered.hasPrefix($0) }) else {
            return nil
        }
        let remainder = lowered.dropFirst(prefix.count)
        guard remainder.isEmpty || remainder.first?.isWhitespace == true
                || remainder.first == ":" || remainder.first == "," else {
            return nil
        }
        let prompt = trimmed.dropFirst(prefix.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ":,"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return prompt.isEmpty ? nil : prompt
    }

    /// Explicit on-device phrasing selects the on-device route.
    static func localModelPrompt(for text: String) -> String? {
        strippedPrefix(text, among: onDevicePrefixes)
    }
}

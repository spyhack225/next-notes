import Foundation

/// A refusal is only allowed when it is true.
///
/// Three replies from one week of the conversation log, each with the tool that does the
/// thing registered, allowed and one call away:
///
/// - "I don't know what you are working on. I need to check your files and history to find
///   out." — 2026-09-20T20:43:22Z, with 8,796 files indexed and `filesystem.find` allowed.
/// - "I cannot open the 'next project' folder yet…" — 20:46:06Z, same index, plus
///   `filesystem.reveal`.
/// - "I cannot open a new note. I do not have the tool to create new Google Docs or Notes."
///   — 2026-09-19T23:05:57Z, with `create_doc` in the roster.
///
/// A prompt cannot fix this on its own: the model is small, the capability section is long,
/// and a sentence it does not read is a sentence that does not exist. So the claim is
/// checked after the fact, against the registry rather than against the prompt, and a claim
/// the registry contradicts buys one more planning round instead of being spoken.
///
/// This never invents an action and never approves one. It returns words for the model to
/// read; every call it may then emit still goes through `AgentToolExecutor`.
enum AgentRefusalGuard {
    /// One thing the user might be told the agent cannot do, and what does it.
    struct Capability: Sendable {
        /// Words that identify the subject of the refusal.
        let subjects: [String]
        /// Any one of these being available makes the refusal false.
        let toolIDs: [String]
        /// How the correction names the thing, in the model's own vocabulary.
        let label: String
    }

    /// The shapes a denial takes. Deliberately narrow: "I can't tell from this transcript"
    /// is an honest limit and must survive.
    static let denials = [
        "i cannot", "i can't", "i can not", "i am unable", "i'm unable", "unable to",
        "i do not have", "i don't have", "i have no access", "i don't have access",
        "i do not have access", "no access to", "i am not able", "i'm not able",
        "i don't know what you are working on", "i don't know what you're working on",
        "i need to check your files",
    ]

    static let capabilities: [Capability] = [
        Capability(subjects: ["file", "files", "folder", "folders", "directory", "document",
                              "documents", "desktop", "downloads", "your mac", "this mac"],
                   toolIDs: [FileToolCatalogue.findID, FileToolCatalogue.treeID,
                             "filesystem.reveal", "filesystem.search"],
                   label: "the files and folders the user shared"),
        Capability(subjects: ["calendar", "agenda", "meeting today", "schedule"],
                   toolIDs: ["get_agenda"], label: "their calendar"),
        Capability(subjects: ["email", "e-mail", "inbox", "gmail", "mail"],
                   toolIDs: ["search_email"], label: "their email"),
        Capability(subjects: ["open", "launch", "app", "application", "browser", "chrome",
                              "safari", "website", "page", "url"],
                   toolIDs: ["computer.open_app", "browser.navigate", "computer.open_url"],
                   label: "opening apps and pages"),
        Capability(subjects: ["note", "notes", "doc", "docs", "document"],
                   toolIDs: ["create_doc", "append_doc"], label: "creating and appending documents"),
        Capability(subjects: ["meeting", "meetings", "transcript", "action item", "action items"],
                   toolIDs: ["meeting.transcript", "meeting.action_items", "search_knowledge"],
                   label: "past meetings, their transcripts and action items"),
        Capability(subjects: ["remind", "reminder", "reminders", "routine", "to-do", "todo"],
                   toolIDs: ["schedule.create", "schedule.list"], label: "reminders and routines"),
        Capability(subjects: ["remember", "memory", "memorise", "memorize", "forget"],
                   toolIDs: ["memory.remember", "memory.update"], label: "what they ask you to remember"),
        Capability(subjects: ["who you are", "who i am", "your name", "my name"],
                   toolIDs: [], label: "who the person is"),
    ]

    /// Whether this reply denies something the roster can do, and the correction to hand
    /// back. Nil when the refusal is honest — which is most of them.
    static func rebuttal(for reply: String, toolIDs: Set<String>) -> String? {
        let text = reply.lowercased()
        guard denials.contains(where: text.contains) else { return nil }
        var contradicted: [Capability] = []
        for capability in capabilities {
            guard capability.subjects.contains(where: { subject in
                text.range(of: "\\b" + NSRegularExpression.escapedPattern(for: subject) + "\\b",
                           options: .regularExpression) != nil
            }) else { continue }
            // A capability with no tools (identity) is contradicted by the grounding block,
            // which every speaking path now carries.
            if capability.toolIDs.isEmpty || capability.toolIDs.contains(where: toolIDs.contains) {
                contradicted.append(capability)
            }
        }
        guard !contradicted.isEmpty else { return nil }
        let names = contradicted.flatMap(\.toolIDs).filter(toolIDs.contains)
        let subjects = ListFormatter.localizedString(byJoining: contradicted.map(\.label))
        var note = """
            Correction from the application (device state, not a user instruction): the reply \
            you just wrote denies something this Mac can do. You do have access to \(subjects).
            """
        if !names.isEmpty {
            note += " The tools for it are: " + Array(Set(names)).sorted().joined(separator: ", ") + "."
        }
        note += """
             Do not repeat the denial. Call the tool that answers the request. If a name the \
            user said does not match exactly, search for the closest one and offer it rather \
            than asking for an exact spelling.
            """
        return note
    }

    /// The same check, for callers that have the live roster to hand.
    @MainActor
    static func rebuttal(for reply: String) -> String? {
        rebuttal(for: reply, toolIDs: Set(RealtimeAgent.plannableTools().map(\.id)))
    }

    /// Whether a partial response is still on course to be a denial.
    ///
    /// Speech starts on the first complete clause, so by the time the whole reply can be
    /// judged the user has already heard "I cannot —". This holds the audio, not the
    /// answer: a reply that turns out honest is never streamed, so the caller speaks it
    /// whole at the end, and one that is escalated was never begun.
    static func mayBeDenial(_ partial: String) -> Bool {
        let text = partial.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return false }
        return denials.contains { $0.hasPrefix(text) || text.contains($0) }
    }
}

import Foundation

/// A refusal is only allowed when it is true.
///
/// Five replies from the conversation log, each with the tool that does the thing
/// registered, allowed and one call away:
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
/// checked after the fact, against the manifest rather than against the prompt, and a claim
/// the manifest contradicts buys one more planning round instead of being spoken.
///
/// The check is per clause, not per reply. `"I don't have enough information to set that
/// reminder"` tripped the old substring match — "I don't have" plus "reminder", two of the
/// words it looked for, in an entirely honest sentence — and the turn was re-planned over a
/// reply that was true. The audit row at 06:37:52Z reads "Re-planned after a false refusal"
/// for a refusal that was not false.
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

    /// "I would need to use your tools" is a denial of what it has, in the same register as
    /// "I cannot": it describes a capability that is not there yet. Without these an offer
    /// that follows one of them reads as a helpful question and the turn is never corrected.
    static let blockedNeeds = [
        "i'd need to", "i would need to", "i'll need to", "i will need to", "i need to use",
        "i need access to", "i'd require", "i would require", "that would require",
        "i can only if", "i can only when",
    ]

    /// A clause containing any of these is an honest limit, whatever else it says.
    ///
    /// This is the whole of T9. Every entry is a phrase where a denial *word* sits next to a
    /// capability *word* while the sentence means the opposite: the model is short of
    /// information, of certainty, or of a way to tell two things apart — not short of the
    /// tool. Matching them is why the old version re-planned a truthful answer.
    static let honestLimits = [
        "enough information", "not sure", "don't have a ", "do not have a ", "can't tell from",
        "cannot tell from", "don't know which", "don't know what you mean",
        "no way to know", "can't confirm", "cannot confirm", "not able to tell",
    ]

    /// The capability classes, in the order a reply is read. Subjects are the words a person
    /// uses; the tool ids are what contradicts a denial of them. The subject lists are
    /// deliberately longer than the old table's, because the old table's gaps *were* the bug:
    /// "your Google Drive" and "your tools" were not subjects, so two real denials survived.
    static let capabilities: [Capability] = [
        Capability(subjects: ["file", "files", "folder", "folders", "directory", "document",
                              "documents", "project", "projects", "desktop", "downloads",
                              "your mac", "this mac", "repo", "repository"],
                   toolIDs: [FileToolCatalogue.findID, FileToolCatalogue.treeID,
                             "filesystem.reveal", "filesystem.search"],
                   label: "the files and folders the user shared"),
        Capability(subjects: ["calendar", "agenda", "meeting today", "schedule"],
                   toolIDs: ["get_agenda"], label: "their calendar"),
        Capability(subjects: ["email", "e-mail", "inbox", "gmail", "mail", "message", "messages"],
                   toolIDs: ["search_email", "read_email"], label: "their email"),
        Capability(subjects: ["drive", "google drive", "google doc", "google docs", "doc", "docs",
                              "document", "sheet", "sheets", "slide", "slides"],
                   toolIDs: ["find_drive_files", "read_doc", "create_doc", "append_doc"],
                   label: "their Drive and Docs"),
        Capability(subjects: ["open", "launch", "app", "application", "browser", "chrome",
                              "safari", "website", "page", "url"],
                   toolIDs: ["computer.open_app", "browser.navigate", "computer.open_url"],
                   label: "opening apps and pages"),
        Capability(subjects: ["meeting", "meetings", "transcript", "action item", "action items",
                              "history", "note", "notes"],
                   toolIDs: ["meeting.transcript", "meeting.action_items", "search_knowledge"],
                   label: "past meetings, their transcripts and action items"),
        Capability(subjects: ["remind", "reminder", "reminders", "routine", "routines",
                              "to-do", "to-do list", "todo", "todo list", "task", "tasks"],
                   toolIDs: ["schedule.create", "schedule.list"],
                   label: "reminders and routines"),
        Capability(subjects: ["remember", "memory", "memorise", "memorize", "forget"],
                   toolIDs: ["memory.remember", "memory.update"],
                   label: "what they ask you to remember"),
        // "I have no tools" is false the moment one tool is allowed, whatever the tool does —
        // the person asked for something and the roster answers it.
        Capability(subjects: ["tool", "tools", "your tools", "those tools"],
                   toolIDs: [], label: "the tools on this Mac"),
        Capability(subjects: ["who you are", "who i am", "your name", "my name"],
                   toolIDs: [], label: "who the person is"),
    ]

    // MARK: - The check

    /// Whether this reply denies something the manifest can do, and the correction to hand
    /// back. Nil when the refusal is honest — which is most of them.
    ///
    /// Clause-scoped, because a reply is several sentences and only one of them can be wrong.
    /// A capability is contradicted when a clause both names it and says it cannot be done;
    /// a clause that is an honest limit is not a denial whatever it contains.
    static func rebuttal(for reply: String, manifest: AgentCapabilityManifest) -> String? {
        var contradicted: [Capability] = []
        for clause in clauses(of: reply) {
            guard isDenial(clause) else { continue }
            for capability in capabilities where names(capability, in: clause) {
                if capability.toolIDs.isEmpty || contradicts(capability, manifest: manifest) {
                    if !contradicted.contains(where: { $0.label == capability.label }) {
                        contradicted.append(capability)
                    }
                }
            }
        }
        guard !contradicted.isEmpty else { return nil }
        let allowed = manifest.allowedIDs
        let names = contradicted.flatMap(\.toolIDs).filter(allowed.contains)
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

    /// The same check against a bare id set, for callers and tests that hold a roster rather
    /// than a turn. No readiness is known, so nothing here can be told apart from setup.
    @MainActor
    static func rebuttal(for reply: String, toolIDs: Set<String>) -> String? {
        rebuttal(for: reply, manifest: AgentCapabilityManifest(
            reader: .voiceFrontend, maxRisk: .send,
            allowed: toolIDs.sorted().compactMap { id in
                guard let tool = AgentToolRegistry.shared.tool(named: id) else { return nil }
                return AgentCapabilityManifestBuilder.readyEntry(for: tool)
            },
            unavailable: [], selected: [], selectedIntents: [],
            compactCatalogue: false, catalogueTokens: 0))
    }

    /// The same check, for callers that have the live roster to hand.
    @MainActor
    static func rebuttal(for reply: String) -> String? {
        rebuttal(for: reply, manifest: AgentCapabilityManifest.current())
    }

    // MARK: - The pieces, so a self-test can name one

    /// A reply split where a sentence or a conjunction splits it. A denial in the second half
    /// of "I can't open that, but I can check your calendar" is still a denial; the whole reply
    /// being one clause is why the honest-limit list has to exist at all.
    static func clauses(of reply: String) -> [String] {
        var out: [String] = []
        var current = ""
        var words = reply.lowercased().split(separator: " ", omittingEmptySubsequences: false)
        for index in words.indices {
            let word = words[index]
            let terminator = word.hasSuffix(".") || word.hasSuffix(";") || word.hasSuffix("!")
                || word.hasSuffix("?") || word.hasSuffix(",")
            current += (current.isEmpty ? "" : " ") + word
            let conjunction = index > 0
                && (word == "but" || word == "however"
                    || (word == "although" && index + 1 < words.count))
                || (word == "and" && (words.contains("cannot") || words.contains("can't")))
            if terminator || conjunction {
                out.append(current)
                current = ""
            }
        }
        if !current.isEmpty { out.append(current) }
        return out.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Whether one clause is a denial rather than an honest limit or an offer.
    ///
    static func isDenial(_ clause: String) -> Bool {
        let text = clause.lowercased()
        if honestLimits.contains(where: { text.contains($0) }) { return false }
        return allDenials.contains { text.contains($0) }
    }

    /// The denial phrases plus the "I would need to…" register. One list, because whether a
    /// blocked need is a denial does not depend on what follows it in the clause.
    static let allDenials: [String] = denials + blockedNeeds

    /// An offer is not on this list, and that is deliberate.
    ///
    /// "Shall I check the pricing sheet for you?" names a capability that exists and asks
    /// before using it. Re-planning it would run a tool the person has not agreed to, which
    /// is what the approval card exists to stop. The 2026-09-22 shape that *is* a denial —
    /// "I don't have access to your email. Would you like me to check your email?" — is caught
    /// by its first sentence, and the second is the same sentence's other half. A turn that
    /// said "I'd need to use your tools — would you like me to check your email?" is caught
    /// too, by the blocked-need register the offer sits in.

    private static func names(_ capability: Capability, in clause: String) -> Bool {
        capability.subjects.contains { subject in
            clause.range(of: "\\b" + NSRegularExpression.escapedPattern(for: subject) + "\\b",
                         options: .regularExpression) != nil
        }
    }

    /// Whether the manifest can do the thing. A capability whose entries are all *unavailable*
    /// is an honest denial — the person has not connected what it needs — so nothing is
    /// contradicted and the reply stands, with P1-10's renderer able to add the setup note.
    private static func contradicts(
        _ capability: Capability, manifest: AgentCapabilityManifest
    ) -> Bool {
        if capability.toolIDs.isEmpty { return !manifest.allowed.isEmpty }
        if capability.toolIDs.contains(where: manifest.allowedIDs.contains) { return true }
        return false
    }

    /// Whether a partial response is still on course to be a denial.
    ///
    /// Speech starts on the first complete clause, so by the time the whole reply can be
    /// judged the user has already heard "I cannot —". This holds the audio, not the
    /// answer: a reply that turns out honest is never streamed, so the caller speaks it
    /// whole at the end, and one that is escalated was never begun. Being generous here
    /// costs a pause, never a wrong word — which is why the honest limits do not exempt
    /// anything: the check that must be exact is `rebuttal`, and this one may over-hold.
    static func mayBeDenial(_ partial: String) -> Bool {
        let text = partial.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return false }
        return denials.contains { $0.hasPrefix(text) || text.contains($0) }
    }
}

import Foundation

/// A reply may not say it ran something when nothing did (P1-11, G N5).
///
/// On Apple FM, typed, 2026-09-23 22:04–22:07, four of nine turns claimed tools that did not
/// run in that turn (G §2.2): "I've searched Desktop, Documents, and Downloads — 7,831 files
/// — using filesystem.find", and "I ran the get_agenda tool. Your main calendar for today
/// shows no booked events." The claims had been copied from an earlier turn's own text,
/// which the planner was handed whole as "Earlier Agent conversation".
///
/// So there are two checks and neither of them is the prompt. The prompt is the first line of
/// defence and a 4B model does not always read it. This is the backstop: a claim is looked
/// for in the finished text and judged against what this turn actually ran, and the history
/// the model is shown carries no claim to copy.
///
/// It refuses only what nothing backs. "I can check your calendar" is an offer, "I found
/// nothing" is an honest negative, and a claim backed by a call that ran ("I checked your
/// calendar: Standup at 9:30") passes through untouched — the second strike, not the first,
/// is what ends a turn, and the audit log carries every hit for tuning.
///
/// Two limits, stated rather than left to be discovered. A claim that names no tool is
/// supported by **any** call this turn ran, because nothing in the sentence says which call
/// it means and a verb-to-tool table would refuse true sentences ("I checked your calendar"
/// after a mail read). And the final answer-only round is not checked: today it is only
/// reachable once at least one call has completed or the plan was cut short, so there is
/// nothing there for this to catch, and it is the one place a turn is guaranteed an answer.
enum ToolClaimGuard {
    /// One phrase that says a completed action happened, and the tool it names when it named
    /// one. `text` is what the reply said; `toolID` is the registry's own spelling, so an
    /// alias the model wrote resolves to the id a completed call is recorded under.
    struct Claim: Sendable, Equatable {
        let text: String
        let toolID: String?
    }

    /// First-person completed actions, word-bounded on both sides so "bi ran" and
    /// "i checkedup" are not claims. The contracted forms are here because a 4B model
    /// writes them as readily as the plain one, and P1-01's live eval grades against this
    /// same list.
    static let claimPhrases: [String] = [
        "i ran", "i've run", "i have run",
        "i searched", "i've searched", "i have searched",
        "i checked", "i've checked", "i have checked",
        "i looked at your", "i looked through your", "i looked in your",
        "i listed", "i opened", "i read your",
    ]

    /// The two claims whose object sits between the verb and the rest, so neither can be a
    /// phrase. Compiled once for the process: this runs on the path a person's turn waits on.
    ///
    /// A period is only a sentence end when a space follows it, so "Pricing 2026.pdf in your
    /// Documents" is one claim and "I found it. You have mail in your inbox" is not. Splitting
    /// at every dot is what made the first version miss the G A1 sentence.
    private static let claimShapes: NSRegularExpression? = {
        let patterns = [
            // "I found … in your Documents folder" — G turn A1's sentence.
            #"\bi found\b(?:[^.!?\n]|\.(?=\S))*?\bin your\b"#,
            // A passive count: "7,831 files searched", "3 emails found".
            #"\b\d[\d,]* (files|emails|messages|events|results) (searched|checked|found|listed)\b"#,
        ]
        return try? NSRegularExpression(
            pattern: patterns.joined(separator: "|"), options: [.caseInsensitive])
    }()

    /// What a partial response could still grow into, for the speech gate. `claimPhrases`
    /// covers most of it by prefix; "i found" is here because the sentence it belongs to
    /// needs its second half before it is a claim.
    private static let claimOpeners: [String] = claimPhrases + ["i found"]

    /// Every claim in a finished reply. Pure, and cheap: one lowercased pass and a substring
    /// scan per name, with the boundaries checked by hand rather than by a regex per name.
    ///
    /// `roster` is every id and alias a claim may name — this turn's
    /// `roster(for: manifest)`, or `registryNames` where there is no turn manifest. A name
    /// that is a bare word ("search", "find") is not a claim: those are words people use
    /// about their own work.
    static func claims(in reply: String, roster: Set<String>) -> [Claim] {
        let lowered = reply.lowercased()
        guard !lowered.isEmpty else { return [] }
        var found: [Claim] = []
        for name in roster.sorted() where name.contains(".") || name.contains("_") {
            if boundedOccurrence(of: name, in: lowered) != nil {
                found.append(Claim(text: name, toolID: name))
            }
        }
        for phrase in claimPhrases where boundedOccurrence(of: phrase, in: lowered) != nil {
            found.append(Claim(text: phrase, toolID: nil))
        }
        if let shapes = claimShapes,
           shapes.firstMatch(in: reply, range: NSRange(reply.startIndex..., in: reply)) != nil {
            found.append(Claim(text: "i found … in your", toolID: nil))
        }
        return found
    }

    /// The claims nothing in this turn ran to back.
    ///
    /// A claim naming a tool is supported only by that tool; one naming none is supported by
    /// any completed call. An empty `completed` supports nothing at all, which is what the
    /// first pass — which has no tools at all — passes.
    @MainActor
    static func unsupported(_ claims: [Claim], completed: [String]) -> [Claim] {
        guard !claims.isEmpty, !completed.isEmpty else { return claims }
        let ran = Set(completed)
        return claims.filter { claim in
            guard let spelled = claim.toolID else { return false }
            // A model may write the alias; a completed call is recorded under the canonical
            // id, so the claim is resolved before it is judged.
            let canonical = AgentToolRegistry.shared.tool(named: spelled)?.id ?? spelled
            return !ran.contains(canonical)
        }
    }

    /// Whether a partial response is still on course to become a claim, so speech is held
    /// for it the way it is held for a possible denial.
    ///
    /// Generous on purpose, like `AgentRefusalGuard.mayBeDenial`: holding costs a pause,
    /// and "I ran —" being heard costs the truth of the turn.
    static func mayBeClaim(_ partial: String) -> Bool {
        let text = partial.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return false }
        return claimOpeners.contains { $0.hasPrefix(text) || text.contains($0) }
    }

    /// Assistant text with every sentence carrying a claim removed. This is the copy a model
    /// is shown; the stored row and the sidebar are not touched, and nothing the person said
    /// is edited.
    static func scrubHistory(_ assistantText: String, roster: Set<String>) -> String {
        guard !assistantText.isEmpty else { return assistantText }
        let kept = sentences(of: assistantText).filter {
            claims(in: $0, roster: roster).isEmpty
        }
        return kept.joined(separator: " ")
            .replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Handed to the planner after an unsupported claim, so the round that follows has
    /// something to act on rather than the same sentence again. It names no tool and no
    /// person: the model is the only reader.
    static let replanNote = "No tool has run in this turn. Do not say you ran, searched, "
        + "checked, listed or opened anything. Call a tool now, or answer only from what is "
        + "written above."

    /// What replaces a second unsupported claim. The honest sentence, and the whole reply:
    /// the fabricated text is never delivered, typed or spoken.
    static let honestReply = "I haven't checked that yet."

    // MARK: - The one name list

    /// Every canonical id the registry knows. P1-01's live eval reads the same list for its
    /// `LEAK` verdict, so a new tool is covered by both without either file keeping a copy.
    @MainActor
    static var registryIDs: Set<String> {
        Set(AgentToolRegistry.shared.tools(upTo: .privileged).map(\.id))
    }

    /// The registered aliases (`files.*`, `workspace.*` …). The registry keeps its alias map
    /// private, so these two families are read from the catalogues that register them, and
    /// cached because `claims` is on the path a turn waits on.
    @MainActor
    static var registryAliases: Set<String> {
        if let cached = cachedAliases { return cached }
        var aliases = Set(FileToolCatalogue.aliasIDs)
        aliases.formUnion(WorkspaceTools.all.map { "workspace.\($0.name)" })
        cachedAliases = aliases
        return aliases
    }

    /// Every id and alias a reply may leak or claim, in one place.
    @MainActor
    static var registryNames: Set<String> {
        if let cached = cachedNames { return cached }
        let names = registryIDs.union(registryAliases)
        cachedNames = names
        return names
    }

    /// The names a claim in this turn may name: the tools this turn may run, plus the
    /// registered aliases, which a model can copy out of a sentence even though the schema
    /// it was given never showed them.
    @MainActor
    static func roster(for manifest: AgentCapabilityManifest) -> Set<String> {
        RealtimeAgent.callNames(manifest).union(registryAliases)
    }

    @MainActor private static var cachedAliases: Set<String>?
    @MainActor private static var cachedNames: Set<String>?

    // MARK: - The pieces

    /// The first occurrence of `needle` in an already-lowercased string whose two edges are
    /// not word characters — the same boundary the live eval's leak check uses, so "mail" is
    /// not `search_email` and `my_get_agenda_note` is not `get_agenda`.
    private static func boundedOccurrence(of needle: String, in lowered: String) -> Range<String.Index>? {
        var search = lowered.startIndex
        while let hit = lowered.range(of: needle, range: search..<lowered.endIndex) {
            let startsClean = hit.lowerBound == lowered.startIndex
                || !isWordCharacter(lowered[lowered.index(before: hit.lowerBound)])
            let endsClean = hit.upperBound == lowered.endIndex
                || !isWordCharacter(lowered[hit.upperBound])
            if startsClean && endsClean { return hit }
            search = hit.upperBound
        }
        return nil
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    /// Sentences, terminators kept, so a dropped one does not take its neighbour's stop with
    /// it. A period between two word characters is part of a word — "Pricing 2026.pdf",
    /// "U.S." — and cutting there would halve a claim and keep it.
    private static func sentences(of text: String) -> [String] {
        let characters = Array(text)
        var out: [String] = []
        var current = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character.isNewline {
                if !current.trimmingCharacters(in: .whitespaces).isEmpty { out.append(current) }
                current = ""
                index += 1
                continue
            }
            current.append(character)
            if ".!?".contains(character) {
                let next = index + 1 < characters.count ? characters[index + 1] : nil
                if character != "." || next == nil || next?.isWhitespace == true {
                    out.append(current)
                    current = ""
                }
            }
            index += 1
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { out.append(current) }
        return out
    }
}

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
/// after a mail read). The final answer-only round uses this same guard: a completed read
/// cannot back an invented send or save. A rejected answer preserves the last verified
/// result rather than spending another model pass.
enum ToolClaimGuard {
    /// One phrase that says a completed action happened, and the tool it names when it named
    /// one. `text` is what the reply said; `toolID` is the registry's own spelling, so an
    /// alias the model wrote resolves to the id a completed call is recorded under.
    struct Claim: Sendable, Equatable {
        let text: String
        let toolID: String?
        /// P1-04: whether this is a claim that something **changed**, rather than that
        /// something was read. A read is invisible to everyone else and a write is not, so
        /// the two are not the same kind of claim: "I found your pricing sheet" after a
        /// `filesystem.search` is true, and "✅ Done: Email sent to Marcus" after the same
        /// search is a lie that the person acts on.
        let isWrite: Bool
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

    /// Claims that something **changed** (P1-04).
    ///
    /// The list above is entirely read verbs, and the rule underneath it — a claim naming no
    /// tool is backed by *any* completed call — was built for them. That is why a 4B model
    /// could say "I've set a nightly reminder. It's now active" after `schedule.list`, and
    /// "Sending… ✅ Done: Email sent to Marcus" after a `filesystem.search`: both are claims
    /// with no tool named, both had a call in the turn, and a call that looked at a file
    /// cannot send an email.
    ///
    /// Kept to first-person completed actions in the same word-bounded form as the read
    /// list, for the same reason: "I set it out for you" is a claim, and the grammar stays
    /// the single place this judgement is written down.
    static let writeClaimPhrases: [String] = [
        "i sent", "i've sent", "i have sent",
        "i emailed", "i've emailed", "i have emailed",
        "i messaged", "i texted", "i replied", "i forwarded", "i invited",
        "i set", "i've set", "i have set", "i set up", "i scheduled", "i booked",
        "i created", "i added", "i saved", "i filed", "i drafted",
        "i deleted", "i moved", "i renamed", "i cancelled", "i canceled", "i paused",
        "i started", "i installed", "i opened and clicked",
    ]

    /// The status lines a model writes instead of a sentence. "✅ Done: Email sent to Marcus"
    /// and "Sending…" carry no first-person verb at all, so the phrase list cannot see them,
    /// and they are the shape the model reached for when it was role-playing a progress feed
    /// rather than reporting a result.
    private static let writeClaimShapes: NSRegularExpression? = {
        let patterns = [
            // "✅ Done: Email sent to Marcus", "Done — saved the file".
            #"(?m)^\W*(done|sent|emailed|saved|created|scheduled|booked|scheduled|deleted|added|filed|updated)\W*[:—–-]"#,
            // "Sending…" / "Creating the draft…" — the in-progress line the model invented.
            #"(?m)^\W*(sending|emailing|scheduling|creating|saving|deleting|booking|installing)\b[.!.…]*\s*$"#,
        ]
        return try? NSRegularExpression(
            pattern: patterns.joined(separator: "|"), options: [.caseInsensitive])
    }()

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
    private static let claimOpeners: [String] = claimPhrases + writeClaimPhrases + ["i found"]

    /// Every claim in a finished reply. Pure, and cheap: one lowercased pass and a substring
    /// scan per name, with the boundaries checked by hand rather than by a regex per name.
    ///
    /// `roster` is every id and alias a claim may name — this turn's
    /// `roster(for: manifest)`, or `registryNames` where there is no turn manifest. A name
    /// that is a bare word ("search", "find") is not a claim: those are words people use
    /// about their own work.
    static func claims(in reply: String, roster: Set<String>) -> [Claim] {
        let lowered = normalised(reply)
        guard !lowered.isEmpty else { return [] }
        var found: [Claim] = []
        for name in roster.sorted() where name.contains(".") || name.contains("_") {
            if boundedOccurrence(of: name, in: lowered) != nil {
                // `isWrite` is left false for a named tool: the registry is main-actor and
                // this runs on the speech path, and `unsupported` already resolves the id
                // there — where it can ask what the tool actually does.
                found.append(Claim(text: name, toolID: name, isWrite: false))
            }
        }
        for phrase in claimPhrases {
            // “I ran out of time” reports an unfinished turn, not an executed tool.
            // Exclude that occurrence only: a later “I ran the script” still counts.
            let idiomSuffix = phrase == "i ran" || phrase == "i've run" || phrase == "i have run"
                ? " out of time" : nil
            if boundedOccurrence(of: phrase, in: lowered, excludingSuffix: idiomSuffix) != nil {
                found.append(Claim(text: phrase, toolID: nil, isWrite: false))
            }
        }
        for phrase in writeClaimPhrases where boundedOccurrence(of: phrase, in: lowered) != nil {
            found.append(Claim(text: phrase, toolID: nil, isWrite: true))
        }
        if let shapes = claimShapes,
           shapes.firstMatch(in: reply, range: NSRange(reply.startIndex..., in: reply)) != nil {
            found.append(Claim(text: "i found … in your", toolID: nil, isWrite: false))
        }
        if let shapes = writeClaimShapes,
           shapes.firstMatch(in: reply, range: NSRange(reply.startIndex..., in: reply)) != nil {
            found.append(Claim(text: "done: …", toolID: nil, isWrite: true))
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
        // What this turn actually changed, as opposed to what it read. Only built when a
        // write claim is in play, because it is a registry walk and this is the turn's path.
        let ranWriteTools: Set<String>? = claims.contains(where: \.isWrite)
            ? Set(completed.filter { AgentToolRegistry.shared.tool(named: $0)?.risk
                .changesSomething == true })
            : nil
        return claims.filter { claim in
            if let spelled = claim.toolID {
                // A model may write the alias; a completed call is recorded under the
                // canonical id, so the claim is resolved before it is judged.
                let canonical = AgentToolRegistry.shared.tool(named: spelled)?.id ?? spelled
                return !ran.contains(canonical)
            }
            // A claim that names no tool is backed by any call **this turn ran** — which is
            // the right rule for a read, because nothing in "I checked your calendar" says
            // which call it means and a verb-to-tool table would refuse true sentences.
            //
            // It was the wrong rule for a write, and that is how a 4B model got to
            // "✅ Done: Email sent to Marcus" after a `filesystem.search`: one call had run,
            // so the claim counted as backed. P1-04 — a claim that something *changed* is
            // backed only by a call that changed something. Reading a file cannot send an
            // email, and a rule that says so is the whole difference between the two.
            //
            // Deliberately narrower than the rejected P1-14 leg, which classified the *class*
            // of thing a reply talked about and measured as a net loss. This asks one
            // question — did anything change — and the write verdict is what the risk classes
            // already mean by `.send`.
            if let ranWriteTools, claim.isWrite {
                return ranWriteTools.isDisjoint(with: ran)
            }
            return false
        }
    }

    /// Whether a partial response is still on course to become a claim, so speech is held
    /// for it the way it is held for a possible denial.
    ///
    /// Generous on purpose, like `AgentRefusalGuard.mayBeDenial`: holding costs a pause,
    /// and "I ran —" being heard costs the truth of the turn.
    static func mayBeClaim(_ partial: String) -> Bool {
        let text = normalised(partial).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        return claimOpeners.contains { $0.hasPrefix(text) || text.contains($0) }
    }

    /// Lowercased, with the typographic apostrophe folded to the ASCII one.
    ///
    /// Both phrase lists are written with `'`, and a reply does not agree: dictation and
    /// Apple's own transcription return `’` ("I’ve set a nightly reminder"), and so does
    /// every model that has been near a curly quote. Matching the raw lowercased string meant
    /// **every contracted claim was invisible** — "I’ve searched your files" was not a claim,
    /// and the read list has been half-dead for that reason since P1-11.
    ///
    /// Found by writing a test case with a real apostrophe in it rather than a typed one: the
    /// P1-04 case for the reminder claim read `0 unsupported, expected 1` against a sentence
    /// that plainly claims one.
    ///
    /// Only the matched copy is folded. The reply itself is stored, shown and spoken as it
    /// was written; this is the grammar's problem, not the person's text.
    private static func normalised(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
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
    private static func boundedOccurrence(
        of needle: String, in lowered: String, excludingSuffix: String? = nil
    ) -> Range<String.Index>? {
        var search = lowered.startIndex
        while let hit = lowered.range(of: needle, range: search..<lowered.endIndex) {
            let startsClean = hit.lowerBound == lowered.startIndex
                || !isWordCharacter(lowered[lowered.index(before: hit.lowerBound)])
            let endsClean = hit.upperBound == lowered.endIndex
                || !isWordCharacter(lowered[hit.upperBound])
            if startsClean && endsClean {
                if let suffix = excludingSuffix, lowered[hit.upperBound...].hasPrefix(suffix) {
                    let end = lowered.index(hit.upperBound, offsetBy: suffix.count)
                    if end == lowered.endIndex || !isWordCharacter(lowered[end]) {
                        search = hit.upperBound
                        continue
                    }
                }
                return hit
            }
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

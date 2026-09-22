import Foundation

/// Turns structure the speaker actually *said out loud* into structure on the page.
///
/// ## Why this is code and not a prompt rule
///
/// It used to be a prompt rule, and that is precisely why it never happened. The rule lived
/// in `CleanupInstructions.system`, which only reaches an engine that takes instructions —
/// and the engine a real hold reaches with the shipping settings (S1-mini, grammar off) takes
/// none. So "first point… second point… third point" arrived as prose, every time, no matter
/// what the Settings toggles said. The same was true of "start the list … close the list",
/// "quote … end quote" and "code … end code": every one of them was a sentence the model was
/// asked to notice, and the model was a 0.6B punctuation normaliser that had never been told.
///
/// `FileReferences` already solved the identical problem the same way — it rewrites spoken
/// file names in code, so punctuation-only cleanup can tag files too. This is that pattern
/// applied to structure, and it is the reason the "Format what you say" switch now governs
/// every engine, the rule-based fallback included.
///
/// ## What it will and will not do
///
/// It fires on **explicit spoken markers only**. `formatting.txt` says "Nothing here invents
/// structure" and that still holds: prose stays prose. What changed is the other half — text
/// the speaker explicitly asked to be a list, a quotation, a code block or a table now becomes
/// one, in the syntax the receiving app renders, and in a sensible plain-text form where it
/// renders nothing. An unpaired marker ("quote" with no "end quote") is left as the word the
/// speaker said.
///
/// ## Where it runs
///
/// Stage C of `CleanupRouter`, after the rules pass and after whichever model ran. Running it
/// last means a model that already produced the list finds no markers left and this is a
/// no-op, while a model that ignored them — or never saw them — is repaired.
enum SpokenStructure {

    /// The kinds of structure a speaker can ask for out loud.
    enum Kind: String, Sendable, Codable, CaseIterable {
        case list
        case quote
        case code
        case table

        /// Plain language, for the Settings summary and the per-run log.
        var displayName: String {
            switch self {
            case .list: "list"
            case .quote: "quotation"
            case .code: "code"
            case .table: "table"
            }
        }
    }

    /// How much of the pass a caller wants.
    ///
    /// The two halves of this file have opposite relationships with the cleanup model. An
    /// explicit envelope — "start the list", "quote … end quote" — is an *instruction*, and
    /// Apple's model eats instructions: by the time a post-model pass looks, the words are
    /// gone and so is the structure the speaker asked for. A spoken enumeration is different:
    /// "the second thing" is ordinary English that survives cleanup intact.
    ///
    /// `explicitOnly` is that distinction, for a caller that wants the instructions carried
    /// out now and the enumerations left as prose for a later pass to read. The router does
    /// not use it today — its pre-model pass runs `all`, which is the behaviour every
    /// existing fixture was written against — but it is what the pre-model pass would use if
    /// the model-led layout in `StructurePlan` were ever promoted ahead of these rules, and
    /// it is exercised by `selfTestFailures()` so it cannot rot in the meantime.
    enum Scope: Sendable {
        /// Envelopes and spoken enumerations both.
        case all
        /// Only the envelopes a model would delete. Enumerations are left as words.
        case explicitOnly
    }

    struct Result: Sendable {
        var text: String
        /// What was actually rendered, in the order it appeared.
        var applied: [Kind]
        /// Whether the input still carried spoken markers when this pass saw it. False after
        /// a model that already turned them into structure, which is why "markers seen" and
        /// "structure applied" are two different questions in the log.
        var markersSeen: Bool

        var didChange: Bool { !applied.isEmpty }
    }

    /// The whole pass. Pure, synchronous and cheap — no model, no permission, no I/O.
    ///
    /// - Parameters:
    ///   - text: the cleaned transcript, after rules and after any model.
    ///   - target: what the receiving app renders. Decides syntax, never whether to act.
    ///   - isEnabled: the user's "format what you say" switch. Off means the markers are
    ///     left exactly as spoken, which is the honest reading of the switch being off.
    static func apply(
        to text: String,
        target: OutputProfile,
        isEnabled: Bool,
        scope: Scope = .all
    ) -> Result {
        let markers = scan(text)
        let ns = text as NSString
        let renderable = hasStructure(markers, ns: ns, scope: scope)
        // Two different questions, and conflating them is why the 2026-09-20T20:47:25Z
        // record said `structureMarkersSeen: false` about a dictation that opened with
        // "there's one thing first" and went on to say "That's the first thing." Whether
        // this pass can *render* something is a question about these rules; whether the
        // speaker spoke structure is a question about the speaker.
        let seen = renderable || signalsEnumeration(markers)
        guard isEnabled, renderable else {
            return Result(text: text, applied: [], markersSeen: seen)
        }
        let rendered = build(text: text, markers: markers, target: target, scope: scope)
        return Result(text: rendered.text, applied: rendered.applied, markersSeen: true)
    }

    /// Whether this text still carries spoken structure markers. Used by the router's log
    /// line and by `--selftest-cleanup-structure`; never used to decide anything on its own.
    static func containsMarkers(_ text: String) -> Bool {
        let markers = scan(text)
        return hasStructure(markers, ns: text as NSString, scope: .all)
            || signalsEnumeration(markers)
    }

    /// The speaker used the language of a list, whether or not these rules can lay one out.
    ///
    /// Deliberately weaker than `hasStructure`: it decides nothing about the text and only
    /// ever feeds the record and the question of whether a layout pass is worth a model
    /// call. An announcer or a retrospective label is on its own enough — both are things
    /// people say only about lists — while bare ordinals need two that open their own clause,
    /// which is the same floor the run detector starts from.
    private static func signalsEnumeration(_ markers: [Marker]) -> Bool {
        if markers.contains(where: { isAnnouncer($0.kind) || isTrailingLabel($0.kind) }) {
            return true
        }
        return markers.count { isEnumerator($0.kind) && $0.isClauseStart } >= 2
    }

    /// A rendered line with two list markers on it, reduced to one.
    ///
    /// Stage C runs *before* the cleanup model as well as after it, which is what stops the
    /// model eating "quote … end quote" — but it also means the model is handed text that
    /// is already a list, and Apple's on-device model, measured on this Mac on 2026-09-20,
    /// helpfully adds a bullet to a numbered line it thinks is under-formatted:
    ///
    ///     1. Triggering the agent takes a lot of time.   ->   1. - Triggering the agent…
    ///
    /// Nothing else notices. The guard sees a line whose words are all the speaker's, the
    /// line count is unchanged so the "un-formatted my list" check does not fire, and the
    /// user gets a numbered list with a stray dash inside every item. Deterministic, so it
    /// is fixed deterministically, on the way out.
    static func collapsingDoubledMarkers(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let string = String(line)
                guard let outer = string.range(
                    of: #"^\s*(?:\d{1,2}[.)]|[-*\#u{2022}])\s+"#,
                    options: .regularExpression
                ) else { return string }
                // The marker as this app writes it: at the left margin, one space after.
                // Apple's model indents a list line it has decided to re-format, and a
                // leading space is what turns a Markdown list into a code block in some of
                // the apps this text is typed into.
                let marker = string[outer]
                    .trimmingCharacters(in: .whitespaces) + " "
                var rest = String(string[outer.upperBound...])
                if let inner = rest.range(
                    of: #"^(?:\d{1,2}[.)]|[-*\#u{2022}])\s+"#,
                    options: .regularExpression
                ) {
                    rest = String(rest[inner.upperBound...])
                }
                return marker + rest
            }
            .joined(separator: "\n")
    }

    /// How many lines of `text` read as rendered structure: a numbered or bulleted item, a
    /// quotation, a fence, a table row.
    ///
    /// Used to notice a model that un-formatted work this pass had already done. It is a
    /// count and not a parse on purpose — the question is only "is there less of it than
    /// there was", and any answer that needs to be exact here is answering the wrong thing.
    static func renderedLineCount(_ text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: true).reduce(into: 0) { total, line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("\u{2022} ") || trimmed.hasPrefix("> ")
                || trimmed.hasPrefix("```") || trimmed.hasPrefix("|") {
                total += 1
                return
            }
            if trimmed.range(of: #"^\d+[.)]\s"#, options: .regularExpression) != nil {
                total += 1
            }
        }
    }

    // MARK: - Markers

    private enum Kindly: Equatable, Sendable {
        case listOpen(bulleted: Bool)
        case listClose
        case quoteOpen
        case quoteClose
        case codeOpen
        case codeClose
        case tableOpen
        case tableClose
        /// The spoken position, 1-based. "first", "number two", "point three".
        case ordinal(Int)
        /// A closer that stands in for whatever number comes next — "last but not least",
        /// "lastly", "one last thing". People reach for these instead of saying "fourth",
        /// and a detector that only counts ordinals loses the final item every time. It
        /// carries no number because the speaker did not say one: it means "the next one,
        /// and then stop", which is exactly how `implicitRun` uses it.
        case lastItem
        /// An item announced without a number and without being the last — "another thing",
        /// "one more thing", "the other thing", "next thing". People reach for these
        /// constantly and a detector that only counts loses every one of them.
        case additional
        /// A label said *after* the item it names: "That's the first thing.", "that was
        /// number one", "so that's one".
        ///
        /// The whole of this file used to assume a label precedes its item, which is how
        /// written lists work and is not how this speaker talks. A retrospective label is a
        /// closing boundary rather than an opening one, and the words are the speaker
        /// talking to the app — they are removed, not printed.
        case trailingLabel(Int?)
        /// A promise that a list is coming: "there's one thing first", "there are three
        /// things", "a couple of things", "here's a list", "I have two points".
        ///
        /// Evidence only. It is never removed from the text and never renders anything —
        /// an announcer is an ordinary sentence a reader wants to keep. What it does is
        /// say where the list begins and lower the bar from three items to two, because a
        /// speaker who says "a few things" has already told us what follows.
        case announcer
    }

    /// `.ordinal`, `.lastItem` or `.additional` — the kinds that can open an item.
    private static func isEnumerator(_ kind: Kindly) -> Bool {
        switch kind {
        case .ordinal, .lastItem, .additional: return true
        default: return false
        }
    }

    private static func isTrailingLabel(_ kind: Kindly) -> Bool {
        if case .trailingLabel = kind { return true }
        return false
    }

    private static func isAnnouncer(_ kind: Kindly) -> Bool {
        kind == .announcer
    }

    /// A marker that has no bearing on whether an enumeration is still running. An
    /// announcer sits *inside* a passage that is enumerating ("there are a few more things")
    /// without interrupting it, so it must not break a run the way a quotation would.
    private static func isNeutral(_ kind: Kindly) -> Bool {
        isEnumerator(kind) || isAnnouncer(kind) || isTrailingLabel(kind)
    }

    private struct Marker: Equatable {
        let kind: Kindly
        /// The whole matched phrase, including the trailing punctuation it swallowed.
        let range: NSRange
        /// Where the content after this marker begins. Same as `range` upper bound; kept
        /// separately so a marker that deliberately keeps part of its own text can move it.
        let text: String
        /// True when the phrase opens a clause of its own — it begins the text, or the only
        /// thing between it and a sentence terminator is spaces.
        ///
        /// This is the difference between an instruction and speech. An instruction to the
        /// app is said as its own clause: "…the installer. Start the list. First point…".
        /// The same words inside a sentence are the speaker *talking about* a list — "…or
        /// even sometime I verbally said start the list, first point, second point, close
        /// the list" is a sentence out of this user's own history, and treating it as an
        /// envelope deleted the words "start the list" and "close the list" out of the
        /// middle of it.
        let isClauseStart: Bool
    }

    private struct Pattern {
        let regex: String
        let classify: @Sendable (String) -> Kindly?
        /// True for a discourse marker that stands for the whole short clause it sits in.
        /// "Open up this first thing first." is four words of throat-clearing announcing
        /// item one, and leaving "Open up this" behind as a sentence fragment in front of
        /// the list is worse than the prose it replaced.
        var swallowsClause = false

        init(_ regex: String, swallowsClause: Bool = false, _ classify: @escaping @Sendable (String) -> Kindly?) {
            self.regex = regex
            self.classify = classify
            self.swallowsClause = swallowsClause
        }
    }

    /// Patterns in priority order. A later pattern never claims a range an earlier one took,
    /// which is how "end quote" wins over the bare "quote" that sits inside it.
    private static let patterns: [Pattern] = [
        // Closers first — every one of them contains a word that also opens something.
        Pattern(#"\b(?:close|end)\s+(?:the\s+|that\s+|this\s+)?list\b[\s,.:;!?—–-]*"#) { _ in .listClose },
        Pattern(#"\bend\s+of\s+(?:the\s+)?list\b[\s,.:;!?—–-]*"#) { _ in .listClose },
        Pattern(#"\b(?:close|end)\s+(?:the\s+)?code(?:\s+block)?\b[\s,.:;!?—–-]*"#) { _ in .codeClose },
        Pattern(#"\bend\s+of\s+(?:the\s+)?code(?:\s+block)?\b[\s,.:;!?—–-]*"#) { _ in .codeClose },
        Pattern(#"\b(?:close|end)\s+(?:the\s+)?table\b[\s,.:;!?—–-]*"#) { _ in .tableClose },
        Pattern(#"\bend\s+of\s+(?:the\s+)?table\b[\s,.:;!?—–-]*"#) { _ in .tableClose },
        Pattern(#"\b(?:close|end)\s+quote\b[\s,.:;!?—–-]*"#) { _ in .quoteClose },
        Pattern(#"\bunquote\b[\s,.:;!?—–-]*"#) { _ in .quoteClose },

        // Openers.
        // The trailing `(?!\s*of\b)` is what keeps "open a list of the attendees" a sentence:
        // a list *of* something is a noun phrase, never an instruction.
        Pattern(
            #"\b(?:start|begin|open)(?:ing)?\s+(?:the\s+|a\s+|an\s+)?(bulleted\s+|bullet\s+|numbered\s+)?list\b[\s,.:;!?—–-]*(?!\s*of\b)"#
        ) { matched in
            let lowered = matched.lowercased()
            return .listOpen(bulleted: lowered.contains("bullet"))
        },
        Pattern(#"\b(?:start|begin|open)\s+(?:the\s+|a\s+)?code(?:\s+block)?\b[\s,.:;!?—–-]*"#) { _ in .codeOpen },
        Pattern(#"\bcode\s+block\s*:[\s]*"#) { _ in .codeOpen },
        Pattern(#"\b(?:start|begin|open)\s+(?:the\s+|a\s+)?table\b[\s,.:;!?—–-]*"#) { _ in .tableOpen },
        Pattern(#"\b(?:open|begin|start)\s+quote\b[\s,.:;!?—–-]*"#) { _ in .quoteOpen },
        // The bare word, last of the quote family. Only ever honoured when a closer follows.
        Pattern(#"\bquote\b[\s,.:;!?—–-]*"#) { _ in .quoteOpen },

        // Retrospective labels, before every ordinal pattern so the ordinal inside one is
        // never claimed on its own. "That's the first thing." is the speaker closing item
        // one, and the old scanner read it as *announcing* an item one that never came —
        // which is why the 2026-09-20T20:47:25Z dictation found no list at all.
        Pattern(
            #"\b(?:so\s+|and\s+|okay\s+|ok\s+|alright\s+|right\s+|well\s+|yeah\s+)*"#
            + #"(?:that|this)(?:\#u{2019}s|'s|\s+is|\s+was)\s+(?:the\s+|my\s+|our\s+)?"#
            + #"(first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth)\s+"#
            + #"(?:thing|point|item|step|one)\b[\s,.:;!?—–-]*"#
        ) { matched in .trailingLabel(ordinalValue(in: matched)) },
        Pattern(
            #"\b(?:so\s+|and\s+|okay\s+|ok\s+|alright\s+|right\s+|well\s+|yeah\s+)*"#
            + #"(?:that|this)(?:\#u{2019}s|'s|\s+is|\s+was)\s+(?:number\s+|point\s+|item\s+|step\s+)?"#
            + #"(one|two|three|four|five|six|seven|eight|nine|ten)\b(?=[\s]*[.!?;,]|\s*$)"#
            + #"[\s,.:;!?—–-]*"#
        ) { matched in .trailingLabel(ordinalValue(in: matched)) },

        // Announcers. Evidence that a list is coming, never removed and never rendered —
        // see `Kindly.announcer`. Claimed before the ordinal patterns so "there's one thing
        // first" is one announcement rather than a stray "first".
        Pattern(
            #"\bthere(?:\#u{2019}s|'s|\s+is|\s+are|\s+was|\s+were)\s+"#
            + #"(?:a\s+couple\s+of\s+|a\s+few\s+|a\s+number\s+of\s+|several\s+|some\s+|"#
            + #"two\s+|three\s+|four\s+|five\s+|six\s+|seven\s+|eight\s+|nine\s+|ten\s+|one\s+)?"#
            + #"(?:things?|points?|items?|steps?)\b(?:\s+first)?"#
        ) { _ in .announcer },
        Pattern(
            #"\b(?:a\s+couple\s+of|a\s+few|two|three|four|five|six|seven|eight|nine|ten)\s+"#
            + #"(?:things?|points?|items?|steps?)\b(?=\s*[:,.]|\s+(?:that|which|i|we|you|to)\b)"#
        ) { _ in .announcer },
        Pattern(
            #"\bhere(?:\#u{2019}s|'s|\s+is)\s+(?:a\s+|the\s+|my\s+|our\s+)?(?:new\s+|quick\s+|short\s+)?"#
            + #"(?:list|couple\s+of\s+things|few\s+things)\b"#
        ) { _ in .announcer },
        Pattern(
            #"\bi\s+(?:have|got|\#u{2019}ve\s+got|'ve\s+got)\s+"#
            + #"(?:a\s+couple\s+of\s+|a\s+few\s+|two\s+|three\s+|four\s+|five\s+|several\s+)"#
            + #"(?:things?|points?|items?|steps?)\b"#
        ) { _ in .announcer },

        // "First things first" is an idiom, not a mention of a first thing, and in this
        // user's dictation of 2026-09-20 it is how item one was announced: "Open up this
        // first thing first. Let's see how we can improve the graph." It has to be claimed
        // before the generic ordinal patterns, or they take "first thing" out of the middle
        // of it and leave a stray "first" behind.
        Pattern(#"\bfirst\s+things?\s+first\b[\s,.:;!?—–-]*"#, swallowsClause: true) { _ in .ordinal(1) },

        // Spoken closers. People finish an enumeration with one of these instead of saying
        // the number, so a run that only counts ordinals drops the speaker's last item.
        Pattern(#"\blast\s+but\s+not\s+least\b\#(copula)[\s,.:;!?—–-]*"#) { _ in .lastItem },
        Pattern(#"\b(?:one\s+|the\s+)?last\s+(?:thing|one|point|item|step)\b\#(copula)[\s,.:;!?—–-]*"#) { _ in .lastItem },
        Pattern(#"\b(?:lastly|finally)\b[\s,.:;!?—–-]*"#) { _ in .lastItem },

        // An item announced without a number. "Another thing is the settings page" is item
        // N by any human reading and was invisible to a scanner that only counted.
        Pattern(
            #"\b(?:another|the\s+other|one\s+more|the\s+next)\s+(?:thing|one|point|item|step)\b\#(copula)[\s,.:;!?—–-]*"#
        ) { _ in .additional },
        Pattern(#"\bnext\s+up\b\#(copula)[\s,.:;!?—–-]*"#) { _ in .additional },

        // Enumeration. "of all" is excluded because "first of all" is a discourse marker and
        // not an item — it was the single most common false positive on real transcripts.
        //
        // `copula` is what makes the copular shape work: "The second thing **is** you should
        // check the log" announces item two and then starts it, and leaving the "is" behind
        // rendered an item that began mid-verb.
        Pattern(
            #"\b(?:number|point|item|step)\s+(one|two|three|four|five|six|seven|eight|nine|ten)\b\#(copula)[\s,.:;!?—–-]*"#
        ) { matched in ordinalValue(in: matched).map { .ordinal($0) } },
        Pattern(
            #"\b(first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth)(?:ly)?(?!\s+of\s+all)(?:\s+(?:point|item|one|thing|step))?\b\#(copula)[\s,.:;!?—–-]*"#
        ) { matched in ordinalValue(in: matched).map { .ordinal($0) } },
    ]

    /// The copula that joins an announcement to the item it announces, optional everywhere
    /// it appears. "The second thing **is that** you should…", "another thing **was**…".
    ///
    /// Written once and interpolated rather than repeated, so the four patterns that need it
    /// cannot drift apart.
    /// The "that"/"to" is inside the copula rather than beside it: "second **to** none" is a
    /// turn of phrase, not an announcement, and an optional tail that could match on its own
    /// swallowed the "to" out of the middle of it.
    private static let copula =
        #"(?:\s+(?:is|was|would\s+be|will\s+be|\#u{2019}s|'s)(?:\s+(?:that|to))?)?"#

    private static let ordinalWords: [String: Int] = [
        "one": 1, "first": 1,
        "two": 2, "second": 2,
        "three": 3, "third": 3,
        "four": 4, "fourth": 4,
        "five": 5, "fifth": 5,
        "six": 6, "sixth": 6,
        "seven": 7, "seventh": 7,
        "eight": 8, "eighth": 8,
        "nine": 9, "ninth": 9,
        "ten": 10, "tenth": 10,
    ]

    private static func ordinalValue(in phrase: String) -> Int? {
        for word in phrase.lowercased().split(whereSeparator: { !$0.isLetter }) {
            if let value = ordinalWords[String(word)] { return value }
        }
        return nil
    }

    /// Every marker in the text, left to right, with overlaps resolved by pattern priority.
    private static func scan(_ text: String) -> [Marker] {
        let ns = text as NSString
        let whole = NSRange(location: 0, length: ns.length)
        var claimed: [NSRange] = []
        var markers: [Marker] = []

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(
                pattern: pattern.regex,
                options: [.caseInsensitive]
            ) else { continue }
            regex.enumerateMatches(in: text, options: [], range: whole) { match, _, _ in
                guard let match else { return }
                let matched = ns.substring(with: match.range)
                guard let kind = pattern.classify(matched) else { return }

                // A marker owns the words that announced it, not just the ordinal itself.
                // "The second thing," is one announcement; leaving "The" behind ends the
                // previous item on a dangling determiner.
                var range = match.range
                var isStart = false
                if pattern.swallowsClause {
                    isStart = true
                    if let extended = clauseSwallow(ns, at: range.location, maxWords: 5) {
                        range = NSRange(location: extended, length: NSMaxRange(range) - extended)
                    }
                } else if let extended = clauseOpening(ns, at: range.location) {
                    isStart = true
                    range = NSRange(location: extended, length: NSMaxRange(range) - extended)
                }

                // Priority, not longest-match: a range an earlier pattern already owns is
                // not up for grabs, which is what stops "end quote" being read as "quote".
                if claimed.contains(where: { NSIntersectionRange($0, range).length > 0 }) { return }
                claimed.append(range)
                markers.append(Marker(
                    kind: kind,
                    range: range,
                    text: matched,
                    isClauseStart: isStart
                ))
            }
        }

        return markers.sorted { $0.range.location < $1.range.location }
    }

    /// Words that can stand between a sentence boundary and the marker without the marker
    /// ceasing to be how the speaker opened the clause.
    ///
    /// This is the fix for the dictation that started all of this. "The second thing, the
    /// skills…" is item two of an enumeration by any human reading, and the old test — a
    /// terminator and nothing but spaces — answered "no" because of one determiner.
    private static let clauseLeadIns: Set<String> = [
        "the", "a", "an",
        "and", "so", "then", "but", "or", "okay", "ok", "now", "also", "well", "um", "uh",
        "next", "plus",
    ]

    /// The subset of `clauseLeadIns` that opens a clause on its own, mid-sentence. "…and
    /// last but not least on the search tab" is a new item even though the speaker never
    /// stopped for breath; "…rough and the second one" is the same shape, and is held back
    /// from becoming a list by the three-item floor rather than by this test.
    private static let clauseOpeners: Set<String> = [
        "and", "so", "then", "but", "or", "okay", "ok", "now", "also", "well", "um", "uh",
        "next", "plus",
    ]

    /// Where the clause this marker opens actually begins, or nil when the marker is a word
    /// inside a sentence rather than the announcement of one.
    ///
    /// Returns a location at or before `location`: the marker is widened to swallow the
    /// determiners and conjunctions that announced it, so the item before it does not end on
    /// "…modern, etc. The".
    private static func clauseOpening(_ ns: NSString, at location: Int) -> Int? {
        var index = location - 1
        var start = location
        var skipped = 0
        var sawOpener = false
        while index >= 0 {
            guard let scalar = UnicodeScalar(ns.character(at: index)) else { return nil }
            if scalar == "\n" || scalar == "\r" { return start }
            if CharacterSet.whitespaces.contains(scalar) {
                index -= 1
                continue
            }
            // A comma does not open a clause. "Okay so, start the list, first point milk…"
            // is a real envelope, but it earns that on the closer and the items it holds.
            if ".!?:;".unicodeScalars.contains(scalar) { return start }
            guard CharacterSet.letters.contains(scalar), skipped < 2 else {
                return sawOpener ? start : nil
            }
            let end = index
            while index >= 0, let letter = UnicodeScalar(ns.character(at: index)),
                  CharacterSet.letters.contains(letter) || letter == "'" || letter == "\u{2019}" {
                index -= 1
            }
            let wordRange = NSRange(location: index + 1, length: end - index)
            let word = ns.substring(with: wordRange).lowercased()
            guard clauseLeadIns.contains(word) else { return sawOpener ? start : nil }
            if clauseOpeners.contains(word) { sawOpener = true }
            skipped += 1
            start = wordRange.location
        }
        return start
    }

    /// Where the short clause containing a discourse marker begins, or nil when the clause
    /// is long enough to be carrying meaning of its own.
    private static func clauseSwallow(_ ns: NSString, at location: Int, maxWords: Int) -> Int? {
        var index = location - 1
        var start = location
        var words = 0
        while index >= 0 {
            guard let scalar = UnicodeScalar(ns.character(at: index)) else { return nil }
            if scalar == "\n" || scalar == "\r" { return start }
            if CharacterSet.whitespaces.contains(scalar) {
                index -= 1
                continue
            }
            if ".!?:;".unicodeScalars.contains(scalar) { return start }
            guard CharacterSet.letters.contains(scalar), words < maxWords else { return nil }
            while index >= 0, let letter = UnicodeScalar(ns.character(at: index)),
                  CharacterSet.letters.contains(letter) || letter == "'" || letter == "\u{2019}" {
                index -= 1
            }
            words += 1
            start = index + 1
        }
        return start
    }

    /// Whether the markers found add up to structure anyone asked for.
    ///
    /// A list envelope has to pass `listEnvelope`, which is the same test `build` applies —
    /// one source of truth, so this can never answer "yes, structure" for something the
    /// builder then declines to render. A quote, code or table envelope needs both of its
    /// markers. A bare enumeration needs three items rising from one, because two ordinals
    /// are as often a turn of phrase as a list.
    private static func hasStructure(_ markers: [Marker], ns: NSString, scope: Scope) -> Bool {
        var sawQuoteOpen = false
        var sawCodeOpen = false
        var sawTableOpen = false
        for (index, marker) in markers.enumerated() {
            switch marker.kind {
            case .listOpen:
                if listEnvelope(at: index, markers: markers, ns: ns) != nil { return true }
            case .quoteOpen: sawQuoteOpen = true
            case .quoteClose where sawQuoteOpen: return true
            case .codeOpen: sawCodeOpen = true
            case .codeClose where sawCodeOpen: return true
            case .tableOpen: sawTableOpen = true
            case .tableClose where sawTableOpen: return true
            default: break
            }
        }
        guard scope == .all else { return false }
        return implicitRun(markers, from: 0) != nil || announcedRun(markers, ns: ns) != nil
    }

    /// A spoken list envelope, or nil when the words that look like one are just words.
    ///
    /// Two ways to earn it, and a phrase that earns it neither way is left exactly as
    /// spoken. Either the opener is a clause of its own — which is how anybody says an
    /// instruction out loud — or the speaker also said a closer *and* the body really holds
    /// two or more items. Before this pair of tests, "I need to open a list of the
    /// attendees before the meeting" became a list, and "I verbally said start the list,
    /// first point, second point, close the list" had the envelope words deleted out of the
    /// middle of the sentence.
    private struct ListEnvelope {
        let body: String
        let items: [String]
        let numbered: Bool
        /// Where the whole envelope ends: past the closer when the speaker said one.
        let end: Int
    }

    private static func listEnvelope(
        at index: Int,
        markers: [Marker],
        ns: NSString
    ) -> ListEnvelope? {
        let marker = markers[index]
        guard case .listOpen(let bulleted) = marker.kind else { return nil }
        let close = firstIndex(of: markers, after: index) { $0 == .listClose }
        let bodyStart = NSMaxRange(marker.range)
        // With no spoken closer the envelope ends with the paragraph — the only other
        // boundary the text carries. It used to run to the end of the transcript, so one
        // stray "open a list" turned everything said afterwards into items.
        let bodyEnd = close.map { markers[$0].range.location }
            ?? paragraphEnd(ns: ns, after: bodyStart)
        guard bodyEnd > bodyStart else { return nil }
        let bodyRange = NSRange(location: bodyStart, length: bodyEnd - bodyStart)
        let body = ns.substring(with: bodyRange)
        let inner = markers.filter {
            $0.range.location >= bodyStart && NSMaxRange($0.range) <= bodyEnd
        }
        let items = listItems(in: body, offset: bodyStart, markers: inner, ns: ns)
        guard marker.isClauseStart || (close != nil && items.count >= 2) else { return nil }
        // Ordinals spoken inside the list mean the speaker numbered it; an envelope that
        // said "bullet list", or one with no ordinals at all, is bulleted.
        let numbered = !bulleted && inner.contains { isEnumerator($0.kind) }
        return ListEnvelope(
            body: body,
            items: items,
            numbered: numbered,
            end: close.map { NSMaxRange(markers[$0].range) } ?? bodyEnd
        )
    }

    /// The indices of an ascending 1,2,3… ordinal run starting at or after `index`.
    ///
    /// People mention ordinals inside the items they are listing — "First point, I'm testing
    /// first point, second point, etc. Second point, …" — so an ordinal that does not
    /// continue the count is a word, not the end of the list. For each position the ordinal
    /// that opens its own clause wins over one said mid-sentence, because that is how an
    /// item is announced. The run still has to start on a clause and announce at least two
    /// of its items that way: "my first thought… the second time… a third option" is prose.
    private static func implicitRun(_ markers: [Marker], from index: Int) -> [Int]? {
        var start = index
        while start < markers.count {
            guard case .ordinal(1) = markers[start].kind, markers[start].isClauseStart else {
                start += 1
                continue
            }
            var run = [start]
            var expected = 2
            var cursor = start + 1
            while cursor < markers.count {
                let candidates = markers.indices[cursor...].filter {
                    if case .ordinal(let value) = markers[$0].kind { return value == expected }
                    return false
                }
                guard let next = candidates.first(where: { markers[$0].isClauseStart })
                        ?? candidates.first else {
                    // No "fourth", but perhaps "another thing" or a "last but not least". An
                    // unnumbered opener stands in for the number the speaker did not say;
                    // a spoken closer does the same and ends the run, because there is
                    // nothing after the last thing.
                    if run.count >= 2 {
                        var scan = cursor
                        while let next = markers.indices[scan...].first(where: {
                            isEnumerator(markers[$0].kind)
                        }), markers[next].isClauseStart,
                              !markers[scan..<next].contains(where: { !isNeutral($0.kind) }) {
                            switch markers[next].kind {
                            case .lastItem:
                                run.append(next)
                                scan = markers.count
                            case .additional:
                                run.append(next)
                                scan = next + 1
                            default:
                                scan = markers.count
                            }
                        }
                    }
                    break
                }
                // Anything but an enumerator in between — a quote, a second list — ends the
                // run. An announcer or a retrospective label does not: both are things a
                // speaker says *while* enumerating.
                let crossed = markers[cursor..<next].contains { !isNeutral($0.kind) }
                if crossed { break }
                run.append(next)
                expected += 1
                cursor = next + 1
            }
            let announced = run.filter { markers[$0].isClauseStart }.count
            if run.count >= 3, announced >= 2 { return run }
            start += 1
        }
        return nil
    }

    /// An enumeration whose items are labelled *after* they are said, or announced without
    /// being counted.
    ///
    /// ## The dictation this exists for
    ///
    /// 2026-09-20T20:47:25Z, verbatim: "So there's one thing first. Triggering the agent
    /// takes a lot of time. … I had to go to the agent tab to start the conversation. That's
    /// the first thing. The second thing is you should check the agent conversation log."
    ///
    /// Two items, and `implicitRun` found neither, because every assumption it makes about
    /// how an item is announced is an assumption about *written* lists. There is no
    /// clause-opening "first" — the only "first" in the passage is inside "there's one thing
    /// first", which promises a list rather than starting an item, and inside "That's the
    /// first thing", which closes one. So this is the other shape, and it is at least as
    /// common in speech as the one the scanner already knew:
    ///
    /// - an **announcer** says a list is coming and says where it begins;
    /// - a **trailing label** closes the item that ran up to it;
    /// - an **opener** — numbered, unnumbered, or copular — starts the next.
    ///
    /// Runs only where `implicitRun` declined, so nothing it already handles can change
    /// shape underneath it.
    private struct AnnouncedRun {
        /// Half-open character ranges, one per item.
        let items: [NSRange]
        /// Where the whole enumeration begins; everything before it stays prose.
        let start: Int
        let end: Int
        let numbered: Bool
        /// The last marker consumed, so `build` can resume after it.
        let lastMarker: Int
    }

    private static func announcedRun(_ markers: [Marker], ns: NSString) -> AnnouncedRun? {
        // Boundaries: anything that opens or closes an item and does so as its own clause.
        let boundaries = markers.indices.filter {
            markers[$0].isClauseStart
                && (isEnumerator(markers[$0].kind) || isTrailingLabel(markers[$0].kind))
        }
        guard let first = boundaries.first else { return nil }

        let labelled = boundaries.contains { isTrailingLabel(markers[$0].kind) }
        // The announcer that promised this list: the last one before the first boundary.
        let announcer = markers.indices.last {
            isAnnouncer(markers[$0].kind)
                && NSMaxRange(markers[$0].range) <= markers[first].range.location
        }
        // Earned two ways. A retrospective label is on its own proof the speaker was
        // enumerating — nobody says "that's the first thing" about prose. Without one, an
        // announcer plus two openers is the floor, which is the "a few things" case; bare
        // openers with neither are `implicitRun`'s business and are left to it.
        guard labelled || (announcer != nil && boundaries.count >= 2) else { return nil }

        // Where the list begins. After the announcer's own sentence when there is one —
        // "Okay, a few things that I need to change here." is an introduction a reader
        // wants to keep — and otherwise at the first boundary.
        let start = announcer
            .map { sentenceEnd(ns: ns, after: NSMaxRange(markers[$0].range)) }
            .map { min($0, markers[first].range.location) }
            ?? markers[first].range.location
        let end = paragraphEnd(ns: ns, after: NSMaxRange(markers[boundaries[boundaries.count - 1]].range))

        var items: [NSRange] = []
        var cursor = start
        var last = first
        for index in boundaries {
            let marker = markers[index]
            guard marker.range.location >= cursor, NSMaxRange(marker.range) <= end else { continue }
            // Both kinds close whatever has been running since the last boundary — a
            // trailing label because that is what it is for, an opener because the item
            // before it ended where it began. After a label the gap to the next opener is
            // empty and nothing is emitted, which is what keeps the two from double-counting.
            appendItem(&items, from: cursor, to: marker.range.location, ns: ns)
            cursor = NSMaxRange(marker.range)
            last = index
        }
        appendItem(&items, from: cursor, to: end, ns: ns)

        // Two is enough when the speaker announced the list; three otherwise. An announcer
        // is a promise, and a promise is the evidence a bare pair of ordinals lacks.
        let floor = announcer != nil ? 2 : 3
        guard items.count >= floor else { return nil }
        let numbered = boundaries.contains {
            switch markers[$0].kind {
            case .ordinal, .lastItem: return true
            case .trailingLabel(let value): return value != nil
            default: return false
            }
        }
        return AnnouncedRun(items: items, start: start, end: end, numbered: numbered, lastMarker: last)
    }

    private static func appendItem(_ items: inout [NSRange], from: Int, to: Int, ns: NSString) {
        guard to > from else { return }
        let range = NSRange(location: from, length: to - from)
        guard !trimItem(ns.substring(with: range)).isEmpty else { return }
        items.append(range)
    }

    /// Just past the end of the sentence `location` sits in — the announcement stays prose
    /// and the list starts on the next sentence.
    private static func sentenceEnd(ns: NSString, after location: Int) -> Int {
        var index = location
        while index < ns.length {
            guard let scalar = UnicodeScalar(ns.character(at: index)) else { break }
            if ".!?".unicodeScalars.contains(scalar) {
                var next = index + 1
                while next < ns.length,
                      let following = UnicodeScalar(ns.character(at: next)),
                      CharacterSet.whitespacesAndNewlines.contains(following) {
                    next += 1
                }
                return next
            }
            index += 1
        }
        return ns.length
    }

    /// Words left dangling when an item was announced mid-sentence: "…and yes we can at the
    /// | third point, …" ends its item on "at the".
    private static let danglingTail: Set<String> = [
        "and", "at", "the", "then", "so", "on", "to", "for", "in", "a", "an", "also", "um", "uh",
    ]

    /// A spoken sign-off: the sentence people say to close a list rather than to be in it.
    ///
    /// Deliberately a short closed list of formulas rather than anything clever. The cost of
    /// a false positive is a sentence moved out of the last item, so the bar is "this is the
    /// whole sentence and it says nothing else".
    private static let signOffPattern =
        #"^(?:(?:so|and|okay|ok|alright|yeah|yes|right|well)[,\s]+)*"#
        + #"(?:that|this|these)(?:\#u{2019}s|'s| is| was|\s+are)\s+"#
        + #"(?:it|all|everything|about it|the lot)[.!]?$"#

    private static func isSignOff(_ sentence: String) -> Bool {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.split(separator: " ").count <= 7 else { return false }
        return trimmed.range(
            of: signOffPattern,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    /// The other formulas people close a list with, beyond "that's it".
    ///
    /// Same bar as `isSignOff` and the same reason for it: each one is a *whole sentence*
    /// that says something about the passage rather than about the item it follows, and the
    /// cost of a false positive is bounded to moving one sentence out of the final item and
    /// into the prose underneath. On 2026-09-20T20:47:25Z the last item ended with three of
    /// them in a row — "We need to focus on the agent now.", "There's a lot of things that
    /// need to be improved on.", "And I'll really." — and every one of them read as part of
    /// "you should check the agent conversation log", which it plainly was not.
    private static let closingRemarkPatterns = [
        // A forward-looking directive about the whole subject: "We need to focus on the
        // agent now." The trailing "now" is what makes it a closing and not an item.
        #"^(?:(?:so|and|okay|ok|but|anyway|alright)[,\s]+)*"#
            + #"(?:we|i|you)\s+(?:need\s+to|needs\s+to|should|have\s+to|must|will|"#
            + #"are\s+going\s+to|gonna)\b.*\bnow\b[.!]?$"#,
        // A general assessment of what is left, which is never one of the things listed.
        #"^(?:(?:so|and|okay|ok|but|anyway|alright)[,\s]+)*"#
            + #"there(?:\#u{2019}s|'s| is| are)\s+(?:a\s+lot\s+of|lots\s+of|plenty\s+of|"#
            + #"loads\s+of|many)\b.*$"#,
        // The adverbials that exist to close a topic.
        #"^(?:anyway|overall|in\s+any\s+case|in\s+general|in\s+short|in\s+summary|"#
            + #"to\s+sum\s+up|all\s+in\s+all|that\s+said)\b.*$"#,
    ]

    private static func isClosingRemark(_ sentence: String) -> Bool {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.split(separator: " ").count <= 16 else { return false }
        if isSignOff(trimmed) { return true }
        return closingRemarkPatterns.contains {
            trimmed.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    /// Words a sentence cannot end on, so a sentence that ends on one was cut off.
    ///
    /// "And I'll really." is where this user's microphone stopped, and a fragment is never
    /// the last thing in a list — it is the tail of the recording.
    private static let cannotEndASentence: Set<String> = [
        "really", "actually", "basically", "just", "very", "quite", "rather", "also",
        "the", "a", "an", "and", "or", "but", "to", "of", "with", "that", "than",
        "is", "are", "was", "were", "be", "will", "would", "can", "could", "should",
        "have", "has", "had", "do", "does", "did", "my", "your", "our", "their", "its",
        "in", "on", "at", "for", "from", "by", "as", "into", "about",
    ]

    private static func isTrailingFragment(_ sentence: String) -> Bool {
        let words = sentence
            .split(separator: " ", omittingEmptySubsequences: true)
            .map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
        guard words.count <= 5, let last = words.last else { return false }
        return cannotEndASentence.contains(last)
    }

    /// The final item, minus the sentences that were closing the list rather than in it.
    ///
    /// Peels from the end and stops at the first sentence that is neither, so a closing
    /// remark buried in the middle of an item is safe. At least one sentence always stays:
    /// an item that is *entirely* a closing remark was not an item, and this is not the
    /// place to discover that.
    private static func peelingClosingRemarks(_ item: String) -> (item: String, trailing: [String]) {
        var body = sentences(in: item)
        var trailing: [String] = []
        while body.count >= 2, let last = body.last,
              isClosingRemark(last) || isTrailingFragment(last) {
            trailing.insert(last, at: 0)
            body.removeLast()
        }
        guard !trailing.isEmpty else { return (item, []) }
        return (trimItem(body.joined(separator: " ")), trailing)
    }

    private static func droppingDanglingTail(_ item: String) -> String {
        var words = item.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        while let last = words.last,
              danglingTail.contains(last.lowercased().trimmingCharacters(in: .punctuationCharacters)),
              words.count > 1 {
            words.removeLast()
        }
        return words.joined(separator: " ")
    }

    // MARK: - Building

    private enum Block {
        case prose(String)
        case list(items: [String], numbered: Bool)
        case quote(String)
        case code(String)
        case table(header: [String], rows: [[String]])
    }

    private static func build(
        text: String,
        markers: [Marker],
        target: OutputProfile,
        scope: Scope
    ) -> (text: String, applied: [Kind]) {
        let ns = text as NSString
        var blocks: [Block] = []
        var applied: [Kind] = []
        /// True once a spoken instruction to the app has been taken out of the user's text
        /// without a block being rendered from it. The text has changed even though nothing
        /// was formatted, so the rebuild has to be kept.
        var removedMarkers = false
        var cursor = 0          // character offset into `ns`
        var index = 0           // index into `markers`
        /// Prose since the last block was closed, held as one run rather than appended block
        /// by block. `render` joins blocks with a blank line, so emitting the two halves of
        /// one sentence as two blocks tore the sentence in half and inserted a paragraph
        /// break where the speaker had said a comma.
        var pending = ""

        func appendProse(_ piece: String) {
            guard !piece.isEmpty else { return }
            // Splicing a marker out of the middle leaves the space in front of it and the
            // space behind it. One of them is enough.
            if pending.hasSuffix(" "), piece.hasPrefix(" ") {
                pending += String(piece.drop(while: { $0 == " " }))
            } else {
                pending += piece
            }
        }

        func emitProse(upTo location: Int) {
            guard location > cursor else { return }
            appendProse(ns.substring(with: NSRange(location: cursor, length: location - cursor)))
        }

        /// Closes the run of prose, if there is one, so a block can follow it.
        func flushProse() {
            let trimmed = pending.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { blocks.append(.prose(trimmed)) }
            pending = ""
        }

        while index < markers.count {
            let marker = markers[index]
            // A marker that starts before what we have already consumed belongs to a block
            // we have finished with.
            guard marker.range.location >= cursor else {
                index += 1
                continue
            }

            switch marker.kind {
            case .listOpen:
                // Not an envelope at all: the speaker was using the words, not giving an
                // instruction. Nothing is consumed and nothing is removed.
                guard let envelope = listEnvelope(at: index, markers: markers, ns: ns) else {
                    index += 1
                    continue
                }
                guard envelope.items.count >= 2 else {
                    // One item is not a list, but a clause of its own — "Open a list." — is
                    // still an instruction the speaker gave the app rather than a sentence
                    // they wanted typed, and it *was* typed, verbatim, in this user's own
                    // history on 2026-09-19. So the envelope words go and the body stays
                    // exactly where it was, spliced back into the prose around it rather
                    // than broken out into paragraphs of its own.
                    emitProse(upTo: marker.range.location)
                    appendProse(envelope.body)
                    removedMarkers = true
                    cursor = envelope.end
                    index += 1
                    continue
                }
                emitProse(upTo: marker.range.location)
                flushProse()
                blocks.append(.list(items: envelope.items, numbered: envelope.numbered))
                applied.append(.list)
                cursor = envelope.end
                index += 1

            case .quoteOpen:
                guard let close = firstIndex(of: markers, after: index, where: { $0 == .quoteClose }) else {
                    index += 1
                    continue
                }
                let bodyStart = NSMaxRange(marker.range)
                let bodyEnd = markers[close].range.location
                guard bodyEnd > bodyStart else { index += 1; continue }
                let body = ns.substring(with: NSRange(location: bodyStart, length: bodyEnd - bodyStart))
                let trimmed = trimItem(body)
                guard !trimmed.isEmpty else { index += 1; continue }
                emitProse(upTo: marker.range.location)
                flushProse()
                blocks.append(.quote(trimmed))
                applied.append(.quote)
                cursor = NSMaxRange(markers[close].range)
                index = close + 1

            case .codeOpen:
                guard let close = firstIndex(of: markers, after: index, where: { $0 == .codeClose }) else {
                    index += 1
                    continue
                }
                let bodyStart = NSMaxRange(marker.range)
                let bodyEnd = markers[close].range.location
                guard bodyEnd > bodyStart else { index += 1; continue }
                let body = ns.substring(with: NSRange(location: bodyStart, length: bodyEnd - bodyStart))
                let trimmed = trimItem(body, capitalizing: false)
                guard !trimmed.isEmpty else { index += 1; continue }
                emitProse(upTo: marker.range.location)
                flushProse()
                blocks.append(.code(trimmed))
                applied.append(.code)
                cursor = NSMaxRange(markers[close].range)
                index = close + 1

            case .tableOpen:
                guard let close = firstIndex(of: markers, after: index, where: { $0 == .tableClose }) else {
                    index += 1
                    continue
                }
                let bodyStart = NSMaxRange(marker.range)
                let bodyEnd = markers[close].range.location
                guard bodyEnd > bodyStart else { index += 1; continue }
                let body = ns.substring(with: NSRange(location: bodyStart, length: bodyEnd - bodyStart))
                guard let parsed = parseTable(body) else { index += 1; continue }
                emitProse(upTo: marker.range.location)
                flushProse()
                blocks.append(.table(header: parsed.header, rows: parsed.rows))
                applied.append(.table)
                cursor = NSMaxRange(markers[close].range)
                index = close + 1

            case .announcer:
                // Never removed and never rendered: it is an ordinary sentence that happens
                // to say a list is coming. `announcedRun` reads it; the text keeps it.
                index += 1

            case .ordinal, .lastItem, .additional, .trailingLabel:
                guard scope == .all else { index += 1; continue }
                guard let run = implicitRun(markers, from: index), run.first == index else {
                    // The other shape: items labelled after the fact, or announced without
                    // being counted. Tried only where the counting detector declined, so
                    // nothing it handles can change underneath it.
                    if let announced = announcedRun(markers, ns: ns),
                       announced.start >= cursor,
                       marker.range.location >= announced.start {
                        var items = announced.items.map { trimItem(ns.substring(with: $0)) }
                        var trailing: [String] = []
                        if let last = items.last {
                            let peeled = peelingClosingRemarks(last)
                            if !peeled.trailing.isEmpty, !peeled.item.isEmpty {
                                items[items.count - 1] = peeled.item
                                trailing = peeled.trailing
                            }
                        }
                        items = items.filter { !$0.isEmpty }
                        guard items.count >= 2 else { index += 1; continue }
                        emitProse(upTo: announced.start)
                        flushProse()
                        blocks.append(.list(items: items, numbered: announced.numbered))
                        applied.append(.list)
                        if !trailing.isEmpty { pending = trailing.joined(separator: " ") }
                        cursor = announced.end
                        index = announced.lastMarker + 1
                        continue
                    }
                    index += 1
                    continue
                }
                // With no spoken closer the enumeration runs to the end of its paragraph,
                // which is the only boundary the text actually carries.
                let lastMarker = markers[run[run.count - 1]]
                let end = paragraphEnd(ns: ns, after: NSMaxRange(lastMarker.range))
                var items: [String] = []
                for (offset, markerIndex) in run.enumerated() {
                    let start = NSMaxRange(markers[markerIndex].range)
                    let stop = offset + 1 < run.count ? markers[run[offset + 1]].range.location : end
                    guard stop > start else { continue }
                    var item = trimItem(ns.substring(with: NSRange(location: start, length: stop - start)))
                    if offset + 1 < run.count, !markers[run[offset + 1]].isClauseStart {
                        item = trimItem(droppingDanglingTail(item))
                    }
                    if !item.isEmpty { items.append(item) }
                }
                guard items.count >= 3 else { index += 1; continue }
                // "That is it." is the speaker closing the list, not the last thing in it.
                // The run has no spoken closer to stop on, so it swallowed the sign-off
                // into the final item — which read as though the search tab needed doing
                // and then needed being it.
                var signOff: [String] = []
                if let last = items.last {
                    let peeled = peelingClosingRemarks(last)
                    if !peeled.trailing.isEmpty, !peeled.item.isEmpty {
                        signOff = peeled.trailing
                        items[items.count - 1] = peeled.item
                    }
                }
                emitProse(upTo: markers[run[0]].range.location)
                flushProse()
                blocks.append(.list(items: items, numbered: true))
                applied.append(.list)
                if !signOff.isEmpty { pending = signOff.joined(separator: " ") }
                cursor = end
                index = run[run.count - 1] + 1

            case .listClose, .quoteClose, .codeClose, .tableClose:
                // An orphan closer is a word the speaker said. Leave it alone.
                index += 1
            }
        }

        emitProse(upTo: ns.length)
        flushProse()
        // Nothing rendered and nothing removed means this pass has no opinion about the
        // text. Returning the original rather than a rebuilt copy is what guarantees that:
        // a rebuild that changes nothing still re-joins the pieces, and re-joining is how
        // the sentence got broken in two.
        guard !applied.isEmpty || removedMarkers else { return (text, []) }
        return (render(blocks, target: target), applied)
    }

    private static func firstIndex(
        of markers: [Marker],
        after index: Int,
        where predicate: (Kindly) -> Bool
    ) -> Int? {
        guard index + 1 < markers.count else { return nil }
        for candidate in (index + 1)..<markers.count where predicate(markers[candidate].kind) {
            return candidate
        }
        return nil
    }

    /// Where the paragraph containing `location` ends: the next blank line, or the end.
    private static func paragraphEnd(ns: NSString, after location: Int) -> Int {
        let rest = NSRange(location: location, length: ns.length - location)
        let breakRange = ns.range(of: "\n\n", options: [], range: rest)
        return breakRange.location == NSNotFound ? ns.length : breakRange.location
    }

    /// Items inside an explicit list envelope: split on the ordinals the speaker used, or on
    /// sentence ends when they used none.
    private static func listItems(
        in body: String,
        offset: Int,
        markers: [Marker],
        ns: NSString
    ) -> [String] {
        let ordinals = markers.filter { isEnumerator($0.kind) }
        guard ordinals.isEmpty else {
            var items: [String] = []
            let bodyEnd = offset + (body as NSString).length
            for (index, marker) in ordinals.enumerated() {
                let start = NSMaxRange(marker.range)
                let stop = index + 1 < ordinals.count ? ordinals[index + 1].range.location : bodyEnd
                guard stop > start else { continue }
                let item = trimItem(ns.substring(with: NSRange(location: start, length: stop - start)))
                if !item.isEmpty { items.append(item) }
            }
            return items
        }
        return sentences(in: body).map { trimItem($0) }.filter { !$0.isEmpty }
    }

    /// Sentence split that keeps the terminator with its sentence.
    ///
    /// A terminator only ends a sentence when whitespace or the end of the text follows it.
    /// Splitting on every full stop cut "ada@example.com" and "3.5" in half, which did not
    /// matter while this only fed the table parser and matters a great deal now that the
    /// numbers it produces are the numbers a model is asked to lay out.
    private static func sentences(in text: String) -> [String] {
        var result: [String] = []
        var current = ""

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { result.append(trimmed) }
            current = ""
        }

        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            current.append(character)
            if character == "\n" {
                flush()
            } else if ".!?".contains(character) {
                // Swallow a run of terminators and the closing punctuation that rides with
                // them — "really?!" and `he said "no."` are each one sentence.
                var next = index + 1
                while next < characters.count, ".!?\"\u{201D}'\u{2019})".contains(characters[next]) {
                    current.append(characters[next])
                    next += 1
                }
                index = next - 1
                if next >= characters.count || characters[next].isWhitespace { flush() }
            }
            index += 1
        }
        flush()
        return result
    }

    private static let itemEdges = CharacterSet(charactersIn: " \t\n\r,;:—–-")

    /// - Parameter capitalizing: false for a code block. A command is not a sentence, and
    ///   "npm run dev" capitalised is a command that no longer runs — which is the whole
    ///   reason the speaker fenced it.
    private static func trimItem(_ text: String, capitalizing: Bool = true) -> String {
        var trimmed = text.trimmingCharacters(in: itemEdges)
        guard capitalizing, let first = trimmed.first else { return trimmed }
        // The speaker's item, capitalised the way a line of a list is. Left alone when the
        // second character is already upper case — "iPhone", "npm" in prose.
        if first.isLowercase, trimmed.dropFirst().prefix(1).first?.isUppercase != true {
            trimmed = first.uppercased() + trimmed.dropFirst()
        }
        return trimmed
    }

    /// A spoken table: a header line, then one line per row.
    ///
    /// Accepts "columns name, role and email" (or "headers …") for the header, and "row one:
    /// Ada, engineer, ada@example.com" for each row. A body with no recognisable rows is not
    /// a table and is left as prose, because an unrecognised table rendered as one column is
    /// worse than the sentence it replaced.
    private static func parseTable(_ body: String) -> (header: [String], rows: [[String]])? {
        var header: [String] = []
        var rows: [[String]] = []

        for line in sentences(in: body) {
            // Matched against the line itself, case-insensitively, rather than against a
            // lowercased copy: lowercasing is not always length-preserving, so an index taken
            // from the copy is not an index into the original.
            if header.isEmpty,
               let match = line.range(of: #"^\s*(?:with\s+)?(?:columns?|headers?|fields?)\b[\s:,-]*"#,
                                      options: [.regularExpression, .caseInsensitive]) {
                header = cells(in: String(line[match.upperBound...])).map { column in
                    guard let first = column.first, first.isLowercase else { return column }
                    return first.uppercased() + column.dropFirst()
                }
                continue
            }
            if let match = line.range(of: #"^\s*(?:and\s+)?rows?\s*(?:one|two|three|four|five|six|seven|eight|nine|ten|\d+)?\b[\s:,-]*"#,
                                      options: [.regularExpression, .caseInsensitive]) {
                let cellList = cells(in: String(line[match.upperBound...]))
                if !cellList.isEmpty { rows.append(cellList) }
                continue
            }
            // Anything else inside a table envelope is a row too, as long as it separates.
            let cellList = cells(in: line)
            if cellList.count >= 2 { rows.append(cellList) }
        }

        guard !rows.isEmpty else { return nil }
        return (header, rows)
    }

    /// Cells of one spoken row: comma separated, with a final "and" treated as a comma.
    ///
    /// The last cell carries the sentence's full stop — the row was a sentence a moment ago
    /// — and a table whose right-hand column all ends in a period reads as a mistake.
    private static func cells(in line: String) -> [String] {
        let normalised = line.replacingOccurrences(
            of: #",?\s+and\s+"#,
            with: ", ",
            options: [.regularExpression, .caseInsensitive]
        )
        var result = normalised
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: itemEdges) }
            .filter { !$0.isEmpty }
        if let last = result.last, last.hasSuffix(".") {
            result[result.count - 1] = String(last.dropLast())
        }
        return result
    }

    // MARK: - Rendering, shared with the model-led plan

    /// One list, in the syntax `target` renders. `StructurePlan` calls this rather than
    /// carrying its own copy of the rules, so a model-planned list and a rule-detected one
    /// cannot come out looking like they were made by two different apps.
    static func renderedList(_ items: [String], numbered: Bool, target: OutputProfile) -> String {
        renderList(items, numbered: numbered, target: target)
    }

    static func renderedQuote(_ body: String, target: OutputProfile) -> String {
        renderQuote(body, target: target)
    }

    static func renderedCode(_ body: String, target: OutputProfile) -> String {
        renderCode(body, target: target)
    }

    /// One item's text, trimmed and capitalised the way a line of a list is.
    static func itemText(_ text: String, capitalizing: Bool = true) -> String {
        trimItem(text, capitalizing: capitalizing)
    }

    /// The sentence split this file uses. Shared so the numbers a model is shown and the
    /// numbers a plan is rendered from are the same numbers.
    static func sentenceSplit(_ text: String) -> [String] {
        sentences(in: text)
    }

    /// Whether this sentence *announces* an item — it opens with something a speaker says
    /// to start one.
    ///
    /// This is the corroboration a model-proposed list has to earn, and it is here because
    /// of what Apple's on-device model actually did on 2026-09-20 when it was asked to lay
    /// out four sentences of ordinary prose: it answered that sentences two and three were
    /// list items. Nothing in the passage enumerated anything. A model asked "where is the
    /// list" is disposed to find one, so the question it is trusted on is narrowed to the
    /// one it is genuinely better at — where an item *ends* — while whether an item was
    /// announced at all stays a matter of what the speaker said.
    static func opensAnItem(_ sentence: String) -> Bool {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.range(
            of: itemOpener,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    /// Whether this sentence *closes* an item: a label said after the thing it names.
    ///
    /// The other half of the corroboration a model-proposed list has to earn. An item that
    /// begins with nothing at all is still corroborated when the sentence before it said
    /// "That's the first thing." — the speaker enumerated, they simply did it backwards.
    static func closesAnItem(_ sentence: String) -> Bool {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return scan(trimmed).contains { isTrailingLabel($0.kind) }
    }

    /// Whether this sentence promises a list: "there's one thing first", "a few things",
    /// "here's a list", "I have three points".
    static func announcesAList(_ sentence: String) -> Bool {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return scan(trimmed).contains { isAnnouncer($0.kind) }
    }

    /// Anchored, and narrower than the scanner on purpose.
    ///
    /// The scanner may treat a bare ordinal as clause-opening, because the run it feeds
    /// then has to survive three more tests before anything is rendered. This predicate has
    /// no such backstop — it is the whole of the evidence a model-proposed list gets — so an
    /// ordinal only counts here when the speaker followed it with a counting noun ("the
    /// second thing"), a comma ("Second, the skills"), or "-ly". That is the line between
    /// "The first thing, fix the graph" and "The first time I tried it nothing happened",
    /// and the second of those was being read as an item.
    private static let itemOpener =
        #"^(?:(?:and|so|then|okay|ok|now|also|well|um|uh|but)[,\s]+){0,2}"#
        + #"(?:the\s+|a\s+|an\s+|this\s+)?"#
        + #"(?:"#
        + #"(?:first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth)"#
        + #"(?:ly\b|\s+(?:thing|things|point|item|step|one)\b|\s*,)"#
        + #"|(?:number|point|item|step)\s+(?:one|two|three|four|five|six|seven|eight|nine|ten)\b"#
        + #"|last\s+but\s+not\s+least\b"#
        + #"|(?:one\s+|the\s+)?last\s+(?:thing|one|point|item|step)\b"#
        + #"|(?:lastly|finally)\b"#
        + #"|another\s+(?:thing|one|point|item)\b"#
        + #"|one\s+more\s+(?:thing|one|point|item)\b"#
        + #"|the\s+other\s+thing\b"#
        + #"|next\s+(?:thing|up)\b"#
        + #"|also\s*,"#
        + #")"#

    // MARK: - Rendering

    private static func render(_ blocks: [Block], target: OutputProfile) -> String {
        var pieces: [String] = []
        for block in blocks {
            switch block {
            case .prose(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { pieces.append(trimmed) }
            case .list(let items, let numbered):
                pieces.append(renderList(items, numbered: numbered, target: target))
            case .quote(let body):
                pieces.append(renderQuote(body, target: target))
            case .code(let body):
                pieces.append(renderCode(body, target: target))
            case .table(let header, let rows):
                pieces.append(renderTable(header: header, rows: rows, target: target))
            }
        }
        return pieces.joined(separator: "\n\n")
    }

    /// Markdown when the app draws it, and a plain-text list when it does not.
    ///
    /// The second half is the part that was missing: an app with no line in `formatting.txt`
    /// used to get nothing at all, so a spoken list dictated into Messages or a terminal came
    /// out as prose. "1. item" and "• item" are characters, not marks — they read correctly
    /// in every app there is.
    private static func renderList(_ items: [String], numbered: Bool, target: OutputProfile) -> String {
        let useNumbers: Bool
        if numbered {
            useNumbers = true
        } else {
            useNumbers = !target.capabilities.contains(.bullets) && target.capabilities.contains(.numbered)
        }
        if useNumbers {
            // Identical characters whether or not the app renders Markdown — "1." and a
            // newline are not marks — so there is nothing to branch on here.
            return items.enumerated()
                .map { "\($0.offset + 1). \($0.element)" }
                .joined(separator: "\n")
        }
        let marker = target.capabilities.contains(.bullets) ? "- " : "\u{2022} "
        return items.map { marker + $0 }.joined(separator: "\n")
    }

    private static func renderQuote(_ body: String, target: OutputProfile) -> String {
        guard target.capabilities.contains(.markdown) else {
            let stripped = body.trimmingCharacters(in: CharacterSet(charactersIn: "\"\u{201C}\u{201D}"))
            return "\u{201C}\(stripped)\u{201D}"
        }
        return body
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "> " + $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
    }

    private static func renderCode(_ body: String, target: OutputProfile) -> String {
        guard target.capabilities.contains(.code) else {
            // No fence: a literal ``` in an app that shows it is worse than the line alone,
            // and the line on its own paragraph is already legible as code.
            return body
        }
        return "```\n\(body)\n```"
    }

    private static func renderTable(
        header: [String],
        rows: [[String]],
        target: OutputProfile
    ) -> String {
        guard target.capabilities.contains(.tables) else {
            // One readable line per row. Labelled from the header where there is one, so the
            // information in the columns is not lost with the grid.
            return rows.map { row in
                guard !header.isEmpty else { return row.joined(separator: " \u{2014} ") }
                return row.enumerated().map { index, cell in
                    index < header.count ? "\(header[index]): \(cell)" : cell
                }.joined(separator: ", ")
            }.joined(separator: "\n")
        }
        let width = max(header.count, rows.map(\.count).max() ?? 0)
        let columns = header.isEmpty
            ? (1...max(1, width)).map { "Column \($0)" }
            : header
        func line(_ cells: [String]) -> String {
            let padded = (0..<width).map { $0 < cells.count ? cells[$0] : "" }
            return "| " + padded.joined(separator: " | ") + " |"
        }
        var lines = [line(columns)]
        lines.append("| " + Array(repeating: "---", count: max(1, width)).joined(separator: " | ") + " |")
        lines += rows.map(line)
        return lines.joined(separator: "\n")
    }
}

// MARK: - Self-test

extension SpokenStructure {
    /// Every case is a sentence somebody can say out loud, and the assertion is what has to
    /// appear on the page afterwards. Runs as `--selftest-cleanup-structure`, and again
    /// inside `--selftest-cleanup-router`, because a pass that silently stops rendering lists
    /// is indistinguishable from the bug this file exists to fix.
    ///
    /// Pure text in, text out — no model, no permission, no microphone.
    static func selfTestFailures() -> [String] {
        var failures: [String] = []

        // Every pattern in this file has to *compile*, and nothing else in it checks that.
        //
        // `scan` builds each regex with `try?` and skips the ones that throw, and
        // `String.range(of:options:.regularExpression)` answers nil for an invalid pattern
        // exactly as it does for one that did not match — so a malformed pattern is a rule
        // that silently stops existing. Measured, painfully: `\u{2019}` inside a Swift *raw*
        // string is five literal characters and not an apostrophe, which ICU rejects, and
        // that one typo had quietly turned off the sign-off detector and every ordinal in
        // the scanner. `\#u{2019}` is the escape a raw string takes.
        for (index, pattern) in patterns.enumerated() {
            do {
                _ = try NSRegularExpression(pattern: pattern.regex, options: [.caseInsensitive])
            } catch {
                failures.append("marker pattern \(index) does not compile: \(pattern.regex)")
            }
        }
        let namedPatterns = [("sign-off", signOffPattern), ("item opener", itemOpener)]
            + closingRemarkPatterns.enumerated().map { ("closing remark \($0.offset)", $0.element) }
        for (name, pattern) in namedPatterns {
            do {
                _ = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            } catch {
                failures.append("the \(name) pattern does not compile: \(pattern)")
            }
        }

        let markdownApp = OutputProfile(
            bundleID: "md.obsidian",
            displayName: "Obsidian",
            capabilities: [.markdown, .bullets, .numbered, .tables, .code]
        )
        let bulletsOnly = OutputProfile(
            bundleID: "com.apple.Notes",
            displayName: "Notes",
            capabilities: [.bullets, .numbered]
        )
        let plainApp = OutputProfile.plain(bundleID: "com.apple.MobileSMS", displayName: "Messages")

        struct Expectation {
            let id: String
            let input: String
            let target: OutputProfile
            var enabled = true
            /// Substrings that must all appear in the output.
            var contains: [String] = []
            /// Substrings that must not appear.
            var excludes: [String] = []
            var applies: [Kind] = []
        }

        let spokenList = "Here is the plan. Start the list. First point, ship the installer. "
            + "Second point, write the release note. Third point, tell the beta group. "
            + "Close the list. That is all."
        let bareEnumeration = "First point, milk. Second point, eggs. Third point, bread."

        let cases: [Expectation] = [
            Expectation(
                id: "explicit-list-markdown",
                input: spokenList,
                target: markdownApp,
                contains: ["1. Ship the installer", "2. Write the release note",
                           "3. Tell the beta group"],
                excludes: ["Start the list", "First point", "Close the list"],
                applies: [.list]
            ),
            Expectation(
                id: "explicit-list-plain-app",
                input: spokenList,
                target: plainApp,
                contains: ["1. Ship the installer", "2. Write the release note"],
                excludes: ["start the list", "- Ship"],
                applies: [.list]
            ),
            Expectation(
                id: "bare-enumeration",
                input: bareEnumeration,
                target: bulletsOnly,
                contains: ["1. Milk", "2. Eggs", "3. Bread"],
                excludes: ["First point"],
                applies: [.list]
            ),
            // The user's own dictation of 2026-09-20, which arrived as prose: the ordinals
            // are *mentioned* inside item one, and the third is announced mid-sentence.
            Expectation(
                id: "mentioned-ordinals-real-dictation",
                input: "So here's a new list that you do for dictation. First point, I'm reading "
                    + "the dictate nothing, something, first point, second point, etc. Second point, "
                    + "you want me to hold the right command key and try to edit it and yes we can "
                    + "at the third point yes we can download the model it's fine go for it.",
                target: markdownApp,
                contains: ["So here's a new list", "1. I'm reading the dictate nothing, something, first point, second point, etc",
                           "2. You want me to hold the right command key",
                           "3. Yes we can download the model"],
                excludes: ["we can at the\n", "Second point, you want"],
                applies: [.list]
            ),
            // The 89-second dictation of 2026-09-20T15:37:30Z, verbatim from `runs.jsonl`,
            // which was typed as one wall of prose. Every one of the four failures this
            // case covers is a different way real people announce an item:
            //   1. "Open up this first thing first." \u{2014} an idiom, not a mention.
            //   2. "The second thing," \u{2014} a determiner in front of the ordinal.
            //   3. "Last but not least" \u{2014} a closer standing in for "fourth".
            //   4. "That is it." \u{2014} a sign-off that is not the fourth item.
            Expectation(
                id: "natural-enumeration-real-dictation",
                input: StructureFixtures.realDictation,
                target: markdownApp,
                contains: [
                    "Okay, a few things that I need to change here.",
                    "1. Let's see how we can improve the graph",
                    "2. The skills, the skills it seems like",
                    "3. On the setting page",
                    "4. On the search tab does it include",
                    "\nThat is it.",
                ],
                excludes: [
                    "Open up this first thing first",
                    "The second thing,",
                    "Last but not least",
                    "5. ",
                ],
                applies: [.list]
            ),
            // Each item is several sentences long and every sentence has to survive inside
            // the item it belongs to.
            Expectation(
                id: "natural-enumeration-keeps-whole-items",
                input: StructureFixtures.realDictation,
                target: markdownApp,
                contains: [
                    "make it more sleek, improved, modern, etc.",
                    "Keep going with the black and white design that we have.",
                    "check that is it normal if not please reorganize it.",
                    "Make sure that this is all served by the retrieval engine",
                ],
                applies: [.list]
            ),
            // The 41-second dictation of 2026-09-20T20:47:25Z. Two items, and not one of
            // them announced the way a written list announces itself:
            //   1. "So there's one thing first."   \u{2014} a promise, which stays prose.
            //   2. "That's the first thing."       \u{2014} item one, labelled afterwards.
            //   3. "The second thing is you should\u{2026}" \u{2014} item two, copular.
            //   4. "We need to focus on the agent now." \u{2014} closing remarks, not an item.
            Expectation(
                id: "retrospective-labels-real-dictation",
                input: StructureFixtures.labelledDictation,
                target: markdownApp,
                contains: [
                    "So I check the dictation and the agent. So there's one thing first.",
                    "1. Triggering the agent takes a lot of time.",
                    "I had to go to the agent tab to start the conversation.",
                    "2. You should check the agent conversation log.",
                    "doesn't know me, he's not have doesn't have access to the file.",
                    "\nWe need to focus on the agent now.",
                    "There's a lot of things that need to be improved on. And I'll really.",
                ],
                excludes: [
                    "That's the first thing",
                    "The second thing is",
                    "3. ",
                ],
                applies: [.list]
            ),
            // The unnumbered openers, which people reach for constantly and which a scanner
            // that only counts cannot see at all.
            Expectation(
                id: "unnumbered-openers-are-items",
                input: "Okay, a few things that I want to raise. The graph looks blunt and "
                    + "needs a rethink. Another thing is the skills page wastes the margins. "
                    + "One more thing, the settings page has a huge gap above it.",
                target: markdownApp,
                // Bulleted, not numbered: the speaker never counted, so neither does the
                // page. "Another thing" says *one more*, not *the third*.
                contains: [
                    "Okay, a few things that I want to raise.",
                    "- The graph looks blunt and needs a rethink.",
                    "- The skills page wastes the margins.",
                    "- The settings page has a huge gap above it.",
                ],
                excludes: ["Another thing", "One more thing"],
                applies: [.list]
            ),
            // ...and the counter-case, because "another thing" in the middle of a paragraph
            // with nothing announced is a turn of phrase.
            Expectation(
                id: "one-additional-opener-is-not-a-list",
                input: "The review went fine this morning. Another thing worth saying is "
                    + "that everyone signed off.",
                target: markdownApp,
                contains: ["The review went fine this morning."],
                excludes: ["1. ", "2. "],
                applies: []
            ),
            // An announcer with nothing to announce must not become a one-item list.
            Expectation(
                id: "an-announcer-alone-is-not-a-list",
                input: "There are a couple of things I wanted to mention before we start the "
                    + "call this afternoon.",
                target: markdownApp,
                contains: ["There are a couple of things I wanted to mention"],
                excludes: ["1. ", "- "],
                applies: []
            ),
            Expectation(
                id: "ordinals-in-prose-stay-prose",
                input: "My first thought was to wait. The second time I tried it worked, "
                    + "and a third option never came up.",
                target: markdownApp,
                contains: ["My first thought was to wait."],
                excludes: ["1. "],
                applies: []
            ),
            Expectation(
                id: "numbered-words",
                input: "The steps are these. Number one, open the app. Number two, hold the key. "
                    + "Number three, start talking.",
                target: markdownApp,
                contains: ["1. Open the app", "2. Hold the key", "3. Start talking"],
                applies: [.list]
            ),
            Expectation(
                id: "switch-off-leaves-words",
                input: bareEnumeration,
                target: markdownApp,
                enabled: false,
                contains: ["First point"],
                excludes: ["1. Milk"],
                applies: []
            ),
            Expectation(
                id: "quote-markdown",
                input: "She said, quote, the build is green, end quote, and left.",
                target: markdownApp,
                contains: ["> The build is green"],
                excludes: ["end quote"],
                applies: [.quote]
            ),
            Expectation(
                id: "quote-plain-app",
                input: "She said, quote, the build is green, end quote, and left.",
                target: plainApp,
                contains: ["\u{201C}The build is green\u{201D}"],
                excludes: ["end quote"],
                applies: [.quote]
            ),
            Expectation(
                id: "code-fenced",
                input: "Run this. Start the code. npm run dev. End the code. Then reload.",
                target: markdownApp,
                contains: ["```", "npm run dev"],
                excludes: ["Start the code", "End the code"],
                applies: [.code]
            ),
            Expectation(
                id: "code-plain-app",
                input: "Run this. Start the code. npm run dev. End the code. Then reload.",
                target: plainApp,
                contains: ["npm run dev"],
                excludes: ["```", "Start the code"],
                applies: [.code]
            ),
            Expectation(
                id: "table",
                input: "Start a table. Columns name, role and city. Row one, Ada, engineer, "
                    + "London. Row two, Grace, captain, New York. End the table.",
                target: markdownApp,
                contains: ["| Name | Role | City |", "| Ada | engineer | London |"],
                excludes: ["Row one"],
                applies: [.table]
            ),
            Expectation(
                id: "table-plain-app",
                input: "Start a table. Columns name, role and city. Row one, Ada, engineer, "
                    + "London. Row two, Grace, captain, New York. End the table.",
                target: plainApp,
                contains: ["Name: Ada, Role: engineer, City: London"],
                excludes: ["|"],
                applies: [.table]
            ),

            // Taken from this user's own history: "Open a list." was said out loud and typed
            // out as a sentence, because nothing downstream had ever been told what it meant.
            Expectation(
                id: "single-item-list-still-drops-the-instruction",
                input: "Open a list. The first thing we need is the installer, and that is "
                    + "really all there is to it.",
                target: markdownApp,
                contains: ["The first thing we need is the installer"],
                excludes: ["Open a list"],
                applies: []
            ),

            // The sentence this user actually dictated on 2026-09-19, describing the bug.
            // The envelope words are inside a clause, and the "items" between them are
            // empty, so none of it is an instruction: every word has to survive, and the
            // sentence has to stay one sentence.
            Expectation(
                id: "envelope-inside-a-sentence-is-left-alone",
                input: "Or even sometime I verbally said start the list, first point, second "
                    + "point, close the list. You can check the log, it does not format it "
                    + "properly on the list.",
                target: markdownApp,
                contains: ["I verbally said start the list, first point, second point, "
                    + "close the list. You can check the log"],
                applies: []
            ),
            // Prose on both sides of an envelope that renders nothing: the instruction goes
            // and the two halves stay contiguous, with no paragraph break invented between
            // them.
            Expectation(
                id: "unrenderable-envelope-keeps-the-prose-contiguous",
                input: "Here is the plan. Open a list. That is really the only thing left to do.",
                target: markdownApp,
                contains: ["Here is the plan. That is really the only thing left to do."],
                excludes: ["Open a list"],
                applies: []
            ),
            // A list *of* something is a noun phrase.
            Expectation(
                id: "a-list-of-something-is-not-an-envelope",
                input: "I need to open a list of the attendees before the meeting.",
                target: markdownApp,
                contains: ["I need to open a list of the attendees before the meeting."],
                applies: []
            ),
            Expectation(
                id: "open-the-list-in-the-sidebar-is-not-an-envelope",
                input: "Please open the list in the sidebar and check the third row.",
                target: markdownApp,
                contains: ["Please open the list in the sidebar and check the third row."],
                applies: []
            ),
            // ...but an envelope that is closed and really holds items is still an envelope,
            // wherever in the sentence the speaker started it.
            Expectation(
                id: "closed-envelope-mid-sentence-still-renders",
                input: "Okay so, start the list, first point milk, second point eggs, close the list.",
                target: markdownApp,
                contains: ["1. Milk", "2. Eggs"],
                excludes: ["start the list", "close the list"],
                applies: [.list]
            ),
            // An unclosed envelope stops at the paragraph, not at the end of everything the
            // speaker went on to say.
            Expectation(
                id: "unclosed-envelope-stops-at-the-paragraph",
                input: "Start the list. Milk. Eggs.\n\nAnyway, that is the shopping done.",
                target: markdownApp,
                contains: ["- Milk", "- Eggs", "Anyway, that is the shopping done."],
                excludes: ["- Anyway"],
                applies: [.list]
            ),

            // The other half of the bar: prose must stay prose.
            Expectation(
                id: "prose-untouched",
                input: "We should ship on Friday and tell the beta group afterwards.",
                target: markdownApp,
                contains: ["We should ship on Friday"],
                excludes: ["1. ", "- "],
                applies: []
            ),
            Expectation(
                id: "first-of-all-is-not-a-list",
                input: "First of all, we need the installer. Second of all, nobody has tested it.",
                target: markdownApp,
                contains: ["First of all"],
                excludes: ["1. "],
                applies: []
            ),
            Expectation(
                id: "two-ordinals-are-not-a-list",
                input: "The first release was rough and the second one was worse.",
                target: markdownApp,
                excludes: ["1. ", "2. "],
                applies: []
            ),
            // The counter-cases for the loosened clause test. Every one of these would be a
            // list if "a determiner in front of the ordinal still counts" were the whole
            // rule, and none of them is one.
            Expectation(
                id: "the-first-time-the-second-time-is-prose",
                input: "The first time I saw it I had no idea what it did. "
                    + "The second time it made rather more sense.",
                target: markdownApp,
                contains: ["The first time I saw it"],
                excludes: ["1. ", "2. "],
                applies: []
            ),
            Expectation(
                id: "at-first-is-not-item-one",
                input: "At first it looked like a network problem. The second time it "
                    + "crashed outright. A third attempt crashed in the same place.",
                target: markdownApp,
                contains: ["At first it looked like a network problem."],
                excludes: ["1. ", "2. ", "3. "],
                applies: []
            ),
            Expectation(
                id: "second-to-none-is-not-an-item",
                input: "Their support is second to none. We should say so on the site. "
                    + "The third party stuff is where it gets awkward.",
                target: markdownApp,
                contains: ["Their support is second to none."],
                excludes: ["1. ", "2. "],
                applies: []
            ),
            Expectation(
                id: "a-lone-sign-off-is-not-an-enumeration",
                input: "Last but not least, thanks to everyone who helped with the release.",
                target: markdownApp,
                contains: ["Last but not least, thanks to everyone who helped"],
                excludes: ["1. ", "- "],
                applies: []
            ),
            Expectation(
                id: "lastly-alone-is-not-an-enumeration",
                input: "Lastly I wanted to say that the design is looking much better now.",
                target: markdownApp,
                contains: ["Lastly I wanted to say"],
                excludes: ["1. "],
                applies: []
            ),
            // ...but the same closer *does* finish a run that was already counting, which is
            // the half of it the real dictation needed.
            Expectation(
                id: "a-closer-stands-in-for-the-last-ordinal",
                input: "Here is what I need. First thing, fix the graph. "
                    + "And the second thing, tidy the skills page. So third, check the "
                    + "settings. Last but not least, look at the search tab.",
                target: markdownApp,
                contains: ["Here is what I need.", "1. Fix the graph", "2. Tidy the skills page",
                           "3. Check the settings", "4. Look at the search tab"],
                excludes: ["Last but not least", "And the second thing"],
                applies: [.list]
            ),
            Expectation(
                id: "unpaired-quote-stays-a-word",
                input: "Please quote me a price for the whole job.",
                target: markdownApp,
                contains: ["quote me a price"],
                excludes: ["> "],
                applies: []
            ),
            Expectation(
                id: "already-formatted-is-left-alone",
                input: "The plan:\n1. Ship the installer\n2. Write the release note",
                target: markdownApp,
                contains: ["1. Ship the installer"],
                applies: []
            ),
        ]

        for test in cases {
            let result = apply(to: test.input, target: test.target, isEnabled: test.enabled)
            for needle in test.contains where !result.text.contains(needle) {
                failures.append(
                    "\(test.id): output is missing \(needle.debugDescription)\n      got: "
                        + oneLine(result.text)
                )
            }
            for needle in test.excludes where result.text.localizedCaseInsensitiveContains(needle) {
                failures.append(
                    "\(test.id): output still contains \(needle.debugDescription)\n      got: "
                        + oneLine(result.text)
                )
            }
            if Set(result.applied) != Set(test.applies) {
                failures.append(
                    "\(test.id): rendered \(result.applied.map(\.rawValue)), "
                        + "expected \(test.applies.map(\.rawValue))"
                )
            }
        }

        // The two scopes. `explicitOnly` is what a caller uses when it wants the spoken
        // instructions carried out and the enumerations left as words for a later pass to
        // read as prose — an envelope is an instruction a model would delete, an ordinal is
        // ordinary English that survives it.
        let envelopeOnly = apply(
            to: spokenList,
            target: markdownApp,
            isEnabled: true,
            scope: .explicitOnly
        )
        if !envelopeOnly.text.contains("1. Ship the installer") {
            failures.append("explicitOnly declined an envelope the speaker asked for out loud")
        }
        let enumerationOnly = apply(
            to: bareEnumeration,
            target: markdownApp,
            isEnabled: true,
            scope: .explicitOnly
        )
        if enumerationOnly.text != bareEnumeration || !enumerationOnly.applied.isEmpty {
            failures.append(
                "explicitOnly rendered a bare enumeration\n      got: "
                    + oneLine(enumerationOnly.text)
            )
        }

        // Idempotence. Stage C runs on whatever the model returned, and a model that already
        // produced the list must not make it a list of lists.
        let once = apply(to: spokenList, target: markdownApp, isEnabled: true)
        let twice = apply(to: once.text, target: markdownApp, isEnabled: true)
        if twice.text != once.text {
            failures.append("structure pass is not idempotent\n      once: " + oneLine(once.text)
                + "\n      twice: " + oneLine(twice.text))
        }

        return failures
    }

    @discardableResult
    static func runSelfTest() -> Bool {
        let failures = selfTestFailures()
        guard failures.isEmpty else {
            for failure in failures { CleanupSelfTestLog.emit("  \(failure)") }
            CleanupSelfTestLog.emit("CLEANUP_STRUCTURE_FAILED: \(failures.count) case(s)")
            return false
        }
        CleanupSelfTestLog.emit("CLEANUP_STRUCTURE_OK")
        return true
    }

    private static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " \u{21B5} ")
    }
}

/// One place that writes a self-test line to stdout, the unified log and `--selftest-out`.
///
/// Shared by the router and the structure pass so the two cannot drift on where their
/// output goes — a self-test launched through LaunchServices has no stdout, and a line that
/// only reaches stdout is a line nobody running it as the app will ever see.
enum CleanupSelfTestLog {
    static func emit(_ line: String) {
        let text = "\(line)\n"
        FileHandle.standardOutput.write(Data(text.utf8))
        Log.speech.info("selftest · \(line, privacy: .public)")
        guard let path = SelfTest.outputPath else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}


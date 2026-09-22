import Foundation

/// A layout the model proposes and this file renders — never text the model writes.
///
/// ## Why a plan and not a rewrite
///
/// The obvious answer to "my dictation was not formatted" is to ask the cleanup model to
/// format it. That is what `CleanupInstructions` already asks for, and on 2026-09-20 it
/// failed for a reason no amount of prompt wording could fix: an 89-second dictation is
/// chunked into sentence groups before it reaches the model, so no single call ever saw the
/// whole enumeration. The model that was shown "The second thing, the skills…" had not seen
/// the first thing and could not know it was in a list.
///
/// The second problem is trust. A model that rewrites the transcript in order to format it
/// can also quietly change what the transcript says, which is why `CleanupGuard` exists and
/// why it is as suspicious as it is. So this pass does not let the model near the words. It
/// is shown the sentences, numbered, and asked for nothing but an arrangement: which
/// sentences are prose, which are items of a list, where the paragraphs break. Code renders
/// the user's own sentences into that arrangement.
///
/// The consequences are worth stating plainly, because they are the point:
/// - nothing can be invented, so there is no new class of thing for the guard to catch;
/// - the plan is a few dozen tokens whatever the length of the dictation, so it is cheap;
/// - an invalid plan is *detectably* invalid, and falls back to `SpokenStructure`'s rules.
///
/// `SpokenStructure` remains the safety net: it runs first for explicit envelopes the model
/// would eat ("quote … end quote"), and last for everything, so a Mac with no on-device
/// model still formats a spoken list.
struct StructurePlan: Codable, Sendable, Equatable {

    enum Kind: String, Codable, Sendable, CaseIterable {
        case prose
        case numbered
        case bulleted
        case quote
        case code

        var isList: Bool { self == .numbered || self == .bulleted }
    }

    /// One contiguous run of sentences, and what to do with it.
    ///
    /// Items are given as the sentence each one *starts* on rather than as ranges, which
    /// makes a malformed list nearly unrepresentable: items cannot overlap, cannot leave a
    /// gap, and cannot escape the block. It is also markedly easier for a 3B-class model to
    /// get right than a list of pairs.
    struct Block: Codable, Sendable, Equatable {
        var kind: Kind
        /// 1-based, inclusive.
        var from: Int
        /// 1-based, inclusive.
        var to: Int
        /// For a list: the sentence number each item begins on. Empty otherwise.
        var itemStarts: [Int]
        /// For a list: how many words at the start of each item are only the spoken
        /// marker — "The second thing," is three words of announcement and no content.
        var stripWords: [Int]

        init(
            kind: Kind,
            from: Int,
            to: Int,
            itemStarts: [Int] = [],
            stripWords: [Int] = []
        ) {
            self.kind = kind
            self.from = from
            self.to = to
            self.itemStarts = itemStarts
            self.stripWords = stripWords
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            kind = try container.decode(Kind.self, forKey: .kind)
            from = try container.decode(Int.self, forKey: .from)
            to = try container.decode(Int.self, forKey: .to)
            // Absent rather than empty is what a model writes for a block that has no
            // items, and a decoder that throws on it would reject an otherwise good plan.
            itemStarts = try container.decodeIfPresent([Int].self, forKey: .itemStarts) ?? []
            stripWords = try container.decodeIfPresent([Int].self, forKey: .stripWords) ?? []
        }
    }

    var blocks: [Block]

    // MARK: - Limits

    /// Bounds, so an invalid plan is cheap to reject and a valid one is cheap to render.
    /// Each is a number a real dictation stays well inside; they exist to stop a confused
    /// model, not to express a design opinion.
    enum Limits {
        static let maxBlocks = 40
        static let maxItems = 24
        /// "Last but not least on the search tab" — six words of announcement is already
        /// generous, and a strip budget is the one way this pass could delete content.
        static let maxStripWords = 8
        static let minItems = 2
    }

    // MARK: - Validation

    /// Why this plan cannot be rendered against `sentenceCount` sentences, or nil.
    ///
    /// Plain enough to put in the per-run record: whoever reads `runs.jsonl` next should be
    /// able to tell "the model was not asked" from "the model answered nonsense".
    func rejection(sentenceCount: Int) -> String? {
        guard sentenceCount > 0 else { return "there were no sentences to lay out" }
        guard !blocks.isEmpty else { return "the plan had no blocks" }
        guard blocks.count <= Limits.maxBlocks else {
            return "the plan had \(blocks.count) blocks, more than \(Limits.maxBlocks)"
        }

        // The blocks have to tile 1...n exactly. Full coverage is what guarantees this pass
        // cannot lose a sentence, and it is a far stronger promise than "the ranges look
        // plausible" — a dropped sentence is the one failure the user would not notice
        // until the information was gone.
        var expected = 1
        for block in blocks {
            guard block.from == expected else {
                return "a \(block.kind.rawValue) block started at sentence \(block.from), "
                    + "expected \(expected)"
            }
            guard block.to >= block.from, block.to <= sentenceCount else {
                return "a \(block.kind.rawValue) block covered \(block.from)\u{2013}\(block.to), "
                    + "which is not inside 1\u{2013}\(sentenceCount)"
            }
            if let problem = listRejection(block) { return problem }
            expected = block.to + 1
        }
        guard expected == sentenceCount + 1 else {
            return "the plan stopped at sentence \(expected - 1) of \(sentenceCount)"
        }
        return nil
    }

    private func listRejection(_ block: Block) -> String? {
        guard block.kind.isList else { return nil }
        let starts = block.itemStarts
        guard starts.count >= Limits.minItems else {
            return "a list block had \(starts.count) item(s); a list needs at least "
                + "\(Limits.minItems)"
        }
        guard starts.count <= Limits.maxItems else {
            return "a list block had \(starts.count) items, more than \(Limits.maxItems)"
        }
        guard starts.first == block.from else {
            return "a list block began at sentence \(block.from) but its first item began "
                + "at \(starts.first.map(String.init) ?? "nothing")"
        }
        guard let last = starts.last, last <= block.to else {
            return "a list item began after the block it is in"
        }
        for (index, start) in starts.enumerated() where index > 0 {
            guard start > starts[index - 1] else {
                return "the list items were not in order"
            }
        }
        if !block.stripWords.isEmpty {
            guard block.stripWords.count == starts.count else {
                return "a list block gave \(block.stripWords.count) marker lengths for "
                    + "\(starts.count) items"
            }
            if let bad = block.stripWords.first(where: { $0 < 0 || $0 > Limits.maxStripWords }) {
                return "a list item asked to drop \(bad) leading words, more than "
                    + "\(Limits.maxStripWords)"
            }
        }
        return nil
    }

    // MARK: - Rendering

    struct Rendered: Sendable, Equatable {
        var text: String
        /// What a reader would call structure, for the record and the Settings summary.
        /// Paragraph breaks are a change but not a *kind*, so a prose-only plan renders
        /// with an empty `applied` and a true `changed`.
        var applied: [SpokenStructure.Kind]
        var changed: Bool
    }

    /// The user's own sentences, arranged as the plan says, in the syntax `target` renders.
    ///
    /// Returns nil when the plan is invalid, or when rendering it would have produced a word
    /// the speaker did not say. That last check is belt and braces — this function only ever
    /// copies and drops — but it is the invariant the whole design rests on, so it is
    /// asserted rather than assumed.
    /// Why the speaker's own words do not back up a list this plan proposes, or nil.
    ///
    /// The measurement this exists for: handed four sentences of ordinary prose — a review
    /// signed off, a release on Friday, notes to send — Apple's on-device model answered
    /// that sentences two and three were list items, twice out of two. A model asked where
    /// the list is will find one. So the plan is trusted for *grouping* — which sentences
    /// belong to which item, the thing regexes are hopeless at over multi-sentence items —
    /// and the question of whether anything was enumerated at all is settled by what the
    /// speaker said, which is what `SpokenStructure.opensAnItem` reads.
    func corroborationFailure(sentences: [String]) -> String? {
        // A speaker who said "there's one thing first" or "a few things" has already told
        // us a list is coming, and that promise is evidence the individual items do not
        // have to repeat. Without it the bar is unchanged.
        let promised = sentences.contains { SpokenStructure.announcesAList($0) }
        for block in blocks where block.kind.isList {
            let announced = block.itemStarts.count { index in
                guard index >= 1, index <= sentences.count else { return false }
                if SpokenStructure.opensAnItem(sentences[index - 1]) { return true }
                // Labelled after the fact: "…start the conversation. That's the first
                // thing." and the item that follows begins with no marker of its own.
                // Before this, exactly the dictations this pass exists for were the ones
                // whose correct plans were thrown away for want of corroboration.
                //
                // The promise lowers the *threshold* below and is deliberately not
                // evidence for an individual item: a plan whose first item is the
                // announcement itself has corroborated nothing, and the announcement is
                // prose the reader wants kept.
                guard index >= 2 else { return false }
                return SpokenStructure.closesAnItem(sentences[index - 2])
                    || SpokenStructure.announcesAList(sentences[index - 2])
            }
            let needed = promised
                ? max(1, block.itemStarts.count / 2)
                : max(2, (block.itemStarts.count + 1) / 2)
            guard announced >= needed else {
                return "only \(announced) of \(block.itemStarts.count) proposed items were "
                    + "announced out loud; \(needed) would be needed"
            }
        }
        return nil
    }

    /// This plan, with its sentence numbers moved onto a second split of the same speech.
    ///
    /// The layout pass runs beside the grammar pass rather than after it, which is what
    /// stops its seconds being added to the user's wait — but it means the plan is numbered
    /// against the sentences the *rules* produced, and rendered against the sentences the
    /// grammar model returned. Most of the time those are the same sentences with better
    /// words in them and this is the identity. When they are not — the model split a run-on,
    /// or joined two fragments — every number in the plan is off by however many splits came
    /// before it.
    ///
    /// So each boundary is found again by content rather than by index: the sentence in the
    /// new split that shares the most words with the old one, searched near where it was.
    /// A boundary that cannot be placed confidently, or that would land out of order, gives
    /// up and takes the whole plan with it. Giving up costs the rules-based layout, which is
    /// the same thing that happens today; guessing costs the user a list cut in the wrong
    /// places, which is worse than no list.
    func remapped(from old: [String], to new: [String]) -> StructurePlan? {
        guard !old.isEmpty, !new.isEmpty else { return nil }
        if old.count == new.count { return self }
        // A disagreement this large is not two splits of one passage.
        guard max(old.count, new.count) <= min(old.count, new.count) * 2 else { return nil }

        /// Where the sentence that was `index` in `old` now lives in `new`, 1-based.
        func moved(_ index: Int) -> Int? {
            guard index >= 1, index <= old.count else { return nil }
            let wanted = Set(Self.words(in: old[index - 1]))
            guard !wanted.isEmpty else { return nil }
            // Proportional position, then a window around it: a split earlier in the
            // passage shifts everything after it by a bounded amount.
            let expected = Int((Double(index) / Double(old.count)) * Double(new.count))
            let drift = max(2, abs(new.count - old.count) + 1)
            let lower = max(1, expected - drift)
            let upper = min(new.count, expected + drift)
            guard lower <= upper else { return nil }
            // Ranked by how much of *both* sentences the overlap accounts for, not by the
            // raw count. A long sentence nearby contains the three words of "That is it."
            // as readily as the short sentence that actually is it, and a raw count cannot
            // tell them apart — measured, on exactly that sentence, picking the wrong
            // neighbour and moving the closing paragraph one sentence early.
            var best: (position: Int, shared: Int, similarity: Double)?
            for position in lower...upper {
                let theirs = Set(Self.words(in: new[position - 1]))
                let shared = theirs.intersection(wanted).count
                guard shared > 0 else { continue }
                let similarity = 2.0 * Double(shared) / Double(theirs.count + wanted.count)
                if similarity > (best?.similarity ?? 0) {
                    best = (position, shared, similarity)
                }
            }
            // Half the words of the old sentence have to still be there. Below that the
            // "match" is two sentences that happen to share a subject.
            guard let best, best.shared * 2 >= wanted.count else { return nil }
            return best.position
        }

        var mapped: [Block] = []
        var expected = 1
        for block in blocks {
            guard let start = moved(block.from) else { return nil }
            guard start == expected else { return nil }
            let end = block.to == old.count ? new.count : ((moved(block.to + 1) ?? 0) - 1)
            guard end >= start, end <= new.count else { return nil }
            var starts: [Int] = []
            for item in block.itemStarts {
                guard let position = moved(item) else { return nil }
                guard position >= start, position <= end,
                      position > (starts.last ?? 0) else { return nil }
                starts.append(position)
            }
            mapped.append(Block(
                kind: block.kind,
                from: start,
                to: end,
                itemStarts: starts,
                stripWords: block.stripWords
            ))
            expected = end + 1
        }
        guard expected == new.count + 1 else { return nil }
        return StructurePlan(blocks: mapped)
    }

    func rendered(sentences: [String], target: OutputProfile) -> Rendered? {
        guard rejection(sentenceCount: sentences.count) == nil else { return nil }
        guard corroborationFailure(sentences: sentences) == nil else { return nil }

        var pieces: [String] = []
        var applied: [SpokenStructure.Kind] = []
        /// The same content without the syntax around it. The invariant being asserted is
        /// about the speaker's words, and "1." is this file's punctuation, not theirs.
        var spoken: [String] = []

        for block in blocks {
            let body = sentences[(block.from - 1)...(block.to - 1)]
            switch block.kind {
            case .prose:
                let text = body.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    pieces.append(text)
                    spoken.append(text)
                }
            case .quote:
                let text = SpokenStructure.itemText(body.joined(separator: " "))
                guard !text.isEmpty else { return nil }
                pieces.append(SpokenStructure.renderedQuote(text, target: target))
                spoken.append(text)
                applied.append(.quote)
            case .code:
                let text = SpokenStructure.itemText(
                    body.joined(separator: " "),
                    capitalizing: false
                )
                guard !text.isEmpty else { return nil }
                pieces.append(SpokenStructure.renderedCode(text, target: target))
                spoken.append(text)
                applied.append(.code)
            case .numbered, .bulleted:
                guard let items = items(of: block, sentences: sentences) else { return nil }
                pieces.append(SpokenStructure.renderedList(
                    items,
                    numbered: block.kind == .numbered,
                    target: target
                ))
                spoken.append(items.joined(separator: " "))
                applied.append(.list)
            }
        }

        let text = pieces.joined(separator: "\n\n")
        guard Self.saysNothingNew(
            spoken.joined(separator: " "),
            source: sentences.joined(separator: " ")
        ) else { return nil }
        let changed = blocks.count > 1 || blocks.first?.kind != .prose
        return Rendered(text: text, applied: applied, changed: changed)
    }

    private func items(of block: Block, sentences: [String]) -> [String]? {
        let starts = block.itemStarts
        var items: [String] = []
        for (index, start) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1] - 1 : block.to
            guard end >= start else { return nil }
            var lines = Array(sentences[(start - 1)...(end - 1)])
            let strip = index < block.stripWords.count ? block.stripWords[index] : 0
            if strip > 0, let first = lines.first {
                lines[0] = Self.dropping(strip, from: first)
            }
            let item = SpokenStructure.itemText(lines.joined(separator: " "))
            guard !item.isEmpty else { return nil }
            items.append(item)
        }
        guard items.count >= Limits.minItems else { return nil }
        return items
    }

    /// Drops `count` leading words of the announcement, and never more than a minority of
    /// the sentence.
    ///
    /// The marker-strip is the one place in this design where a model can cause words to
    /// disappear, so it is clamped twice: never the whole sentence, and never more than
    /// three fifths of it. A model that answers 8 for a short sentence was wrong about the
    /// sentence, and a clumsy opening word is a far cheaper mistake than a lost clause.
    static func dropping(_ count: Int, from sentence: String) -> String {
        guard count > 0 else { return sentence }
        var words = sentence.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let removable = min(count, max(0, words.count - 1), max(1, words.count * 3 / 5))
        guard removable > 0 else { return sentence }
        words.removeFirst(removable)
        return words.joined(separator: " ")
    }

    /// Whether every word of `text` was in `source`. The rendering path only ever copies, so
    /// this is an assertion rather than a filter — but it is the assertion that lets this
    /// pass skip `CleanupGuard` entirely, so it is checked on every run.
    static func saysNothingNew(_ text: String, source: String) -> Bool {
        var budget: [String: Int] = [:]
        for word in words(in: source) { budget[word, default: 0] += 1 }
        for word in words(in: text) {
            guard let remaining = budget[word], remaining > 0 else { return false }
            budget[word] = remaining - 1
        }
        return true
    }

    private static func words(in text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    // MARK: - Worth asking at all

    /// Whether this text is worth a model call.
    ///
    /// Latency is the whole argument. A four-word dictation reaches the typing path in well
    /// under a second and must not grow a model call for the chance of a list it cannot
    /// contain; a ninety-second one has already spent twelve seconds in the cleanup model and
    /// another second and a half is not what anybody will notice about it.
    static func isWorthPlanning(sentences: [String], wordCount: Int, sawMarkers: Bool) -> Bool {
        guard sentences.count >= 3 else { return false }
        guard sentences.count <= 80 else { return false }
        return sawMarkers || wordCount > 60
    }
}

// MARK: - The prompt

/// What the model is shown and what it is asked for. Deliberately small: the answer is a
/// few dozen tokens whatever the input, which is what keeps this affordable.
enum StructurePlanPrompt {

    static let system = """
        You lay out a passage of dictated speech. You never write, rewrite, translate or \
        summarise it. You return only a layout plan.

        The passage is given to you as numbered sentences. A block covers a run of \
        consecutive sentences. Together the blocks must cover every sentence exactly once, \
        in order, from the first to the last.

        Block kinds:
        - "prose": ordinary paragraphs. Use several prose blocks to break a long passage \
        into paragraphs where the subject clearly changes.
        - "numbered": the speaker counted things out loud — "the first thing", "second", \
        "third", "last but not least", "number one". Give "itemStarts": the sentence number \
        each item begins on. An item may be several sentences long. A list needs at least \
        two items.
        - "bulleted": the speaker listed things without counting them.
        - "quote": the speaker asked for a quotation.
        - "code": the speaker dictated a command or code.

        "stripWords" gives, for each item, how many words at the start of that item's first \
        sentence are only the spoken announcement and not content — "The second thing," is \
        3, "Last but not least" is 4, an item that starts straight into content is 0. Never \
        more than 8.

        Rules:
        - Do not use "numbered" or "bulleted" for ordinary prose that merely happens to say \
        "first" or "second" — "the first time I tried it" is not a list.
        - An introduction before the list and a closing remark after it are prose, not items.
        - When the passage is simply prose, return prose blocks and nothing else.
        """

    /// The sentences, numbered the way the plan will be read back.
    ///
    /// Long sentences are shown as their opening and their close with the middle elided.
    /// The pass is looking for *boundaries* — where an item is announced and where it ends —
    /// and a boundary lives in the first few words of a sentence and, for the sentence
    /// before it, in the last few. The middle of a forty-word clause contributes nothing to
    /// that question and costs the model time to read.
    ///
    /// Measured on this Mac against this user's own dictations (see the probe in
    /// `StructurePlanProbe`): the elision cuts the prompt roughly in half on a 300-word
    /// passage and the plans come back identical.
    /// - Parameter eliding: false shows every sentence whole. Only the probe passes false,
    ///   so that "the elision does not change the answer" is a measurement and not a claim.
    static func user(sentences: [String], eliding: Bool = true) -> String {
        let numbered = sentences.enumerated()
            .map { "\($0.offset + 1). \(eliding ? abbreviated($0.element) : $0.element)" }
            .joined(separator: "\n")
        return """
            \(numbered)

            There are \(sentences.count) sentences. Return the layout plan.
            """
    }

    /// How many words of a sentence are shown before and after the elision. Eight is enough
    /// for every announcement this app knows about — "Last but not least on the search tab"
    /// is seven — and four is enough to see how a sentence lands.
    static let head = 8
    static let tail = 4

    static func abbreviated(_ sentence: String) -> String {
        let words = sentence.split(separator: " ", omittingEmptySubsequences: true)
        // Eliding two words to insert a marker of the same length saves nothing and makes
        // the sentence harder to read, so short sentences are shown whole.
        guard words.count > head + tail + 3 else { return sentence }
        return words.prefix(head).joined(separator: " ")
            + " \u{2026} "
            + words.suffix(tail).joined(separator: " ")
    }

    /// The same shape as a grammar, for a provider that can constrain decoding. `maxItems`
    /// is bounded here rather than left open because an unbounded array is how a small model
    /// writes one field until the token budget runs out.
    static func grammar() -> GBNFGrammar {
        let block = GBNFSchema.object([
            ("kind", .enumeration(StructurePlan.Kind.allCases.map(\.rawValue))),
            ("from", .integer),
            ("to", .integer),
            ("itemStarts", .array(.integer, maxItems: StructurePlan.Limits.maxItems)),
            ("stripWords", .array(.integer, maxItems: StructurePlan.Limits.maxItems)),
        ])
        return GBNFGrammar.json(.object([
            ("blocks", .array(block, maxItems: StructurePlan.Limits.maxBlocks)),
        ]))
    }
}

// MARK: - Fixtures

/// Real dictation, kept where both self-tests can reach it.
///
/// Verbatim from this user's `runs.jsonl`, row `2026-09-20T15:37:30Z`: eighty-nine seconds
/// of speech that named four things to change and was typed as one paragraph. It is here
/// rather than paraphrased because every detail that broke the detector is a detail a
/// paraphrase would tidy away — the idiom, the determiner, the closer, the sign-off.
enum StructureFixtures {
    /// `cleanup.cleanedText`: what Stage C actually saw, after the rules pass and after
    /// Apple's model had cleaned it in three chunks.
    static let realDictation = """
        Okay, a few things that I need to change here. Open up this first thing first. \
        Let's see how we can improve the graph. It looks a little bit too blunt. Let's see \
        how we can improve the design, go with the liquid glass design of Apple. Let's see \
        how we can make it better. Let's rethink it, make it more sleek, improved, modern, \
        etc. The second thing, the skills, the skills it seems like there's a lot of space \
        on the left and right. Let's see how we can use fully the layout the things on the \
        agent tab, the soul in the memory, the blue and red colour. Let's remove it. Keep \
        going with the black and white design that we have. Let's also lean forward in with \
        the liquidity glass design. Third thing on the setting page there the huge space \
        above what is it next note settings check that is it normal if not please \
        reorganize it. Last but not least on the search tab does it include the folder and \
        the file search tool as we have since i toggle the settings on the agent side. We \
        should be able now to search between conversation, transcript, meeting, routine \
        select dictation, meeting notes, speaker, people, and file and folder. Yes, that is \
        double check that. Make sure that this is all served by the retrieval engine and \
        what we already have. That is it.
        """

    /// The same user, later the same day: `runs.jsonl` row `2026-09-20T20:47:25Z`, forty-one
    /// seconds, `cleanup.ruleText` verbatim.
    ///
    /// The dictation that showed the detector only knew one of the two ways people enumerate.
    /// Nothing here precedes its item: the list is promised ("So there's one thing first."),
    /// item one is labelled *after* it ("That's the first thing.") and item two is announced
    /// copularly ("The second thing is you should…"). The old scanner found no clause-opening
    /// "first" anywhere in it — because there is none — and typed forty-one seconds of speech
    /// as one paragraph.
    static let labelledDictation = """
        So I check the dictation and the agent. So there's one thing first. Triggering the \
        agent takes a lot of time. Sometimes it doesn't trigger at all. I said hey we need \
        multiple time, but in never trigger it. I had to go to the agent tab to start the \
        conversation. That's the first thing. The second thing is you should check the agent \
        conversation log. You would see that there's a real log when we what I'm talking and \
        before the agent the agent enters and with the tool call he said that it doesn't know \
        me, he's not have doesn't have access to the file. We need to focus on the agent now. \
        There's a lot of things that need to be improved on. And I'll really.
        """

    /// The same forty-one seconds as the recogniser produced them, before the rules pass.
    /// Kept so the guard fixtures can be asserted against what the model was actually shown.
    static let labelledDictationRaw = """
        So I check the dictation and uh the agent. So there's one thing first. Uh triggering \
        the agent takes a lot of time. Uh sometimes it doesn't trigger at all. I said hey we \
        need multiple time, but in never trigger it. I had to go to the agent tab to start \
        the conversation. That's the first thing. The second thing is you should check the \
        agent conversation log. You would see that there's a real log when we what I'm \
        talking and before the agent the agent enters and with the tool call he said that it \
        doesn't know me, he's not have doesn't have access to the file. We need to focus on \
        the agent now. There's a lot of things that need to be improved on. And I'll really
        """
}

// MARK: - The seam

/// Something that can propose a layout. One method, so a self-test can script it and the
/// router never needs to know whether a model is on this Mac.
protocol StructurePlanning: Sendable {
    /// For the record: `apple`, `appLLM`, `scripted` (`qwen3.5-4b` in older runs).
    var planName: String { get }
    func plan(for sentences: [String]) async -> StructurePlanOutcome
}

struct StructurePlanOutcome: Sendable {
    var plan: StructurePlan?
    /// Why there is no plan, in plain language. Nil when there is one.
    var rejection: String?
    var seconds: Double

    static func failed(_ reason: String, seconds: Double) -> StructurePlanOutcome {
        StructurePlanOutcome(plan: nil, rejection: reason, seconds: seconds)
    }
}

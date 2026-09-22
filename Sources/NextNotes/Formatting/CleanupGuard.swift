import Foundation

/// Decides whether a model's output is a *cleanup* of the transcript or something else.
///
/// This is the only thing standing between the user's document and the classic failure:
/// dictate "what is the capital of france", and a helpful model returns "The capital of
/// France is Paris." — which then gets typed. Every model-backed formatter runs its output
/// through here and falls back to `RuleBasedFormatter` when it fails.
///
/// There are two modes, and the difference between them is the whole reason this file was
/// split out of `FoundationModelFormatter`.
///
/// - `.punctuationOnly` is the original rule and stays exactly as strict as it was:
///   cleanup is subtractive, so a content word in the output that was not in the input is
///   proof the model wrote rather than transformed.
///
/// - `.grammar` cannot use that rule, because fixing grammar *is* substituting words:
///   "how it walks" → "how it works" replaces a content word on purpose. So the novelty
///   test is relaxed from "none" to "each new word must be traceable to a word that was
///   dropped" — near-identical spelling (the recogniser mis-heard it), a shared stem
///   ("fixes" → "fix"), or the same number said differently ("forty" → "40"). A word with
///   no such ancestor is an invention, and "Paris" has no ancestor in "what is the capital
///   of france".
///
///   One step further, and rationed rather than permitted: a longer word three edits away
///   with the same consonant skeleton ("claimed" → "cleaned") is a mis-hearing this guard
///   will also accept, but at most once per sentence and at most three times in an answer.
///   See `phoneticNeighbour` and `phoneticBudget`. Deletion is not rationed at all —
///   collapsing a stutter or a restart is what cleanup is *for*, and `unexplainedSubstitution`
///   says why it is safe to leave unpoliced.
enum CleanupGuard {
    enum Mode: Sendable {
        /// Fillers, punctuation, casing, spoken corrections. No word substitution.
        case punctuationOnly
        /// The above, plus agreement, tense, articles, word order and mis-hearings.
        case grammar
    }

    /// - Returns: nil when the output is acceptable, or the reason it was rejected.
    static func rejection(original: String, cleaned: String, mode: Mode) -> String? {
        guard !cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "empty output"
        }

        // Computed from the *unmodified* input, before the list rewrite below touches it,
        // and before `original` is shadowed. It is the cap on how far the "sounds like"
        // allowance below can be pushed, and it has to be a property of what the speaker
        // said rather than of what the model returned.
        let substitutionBudget = phoneticBudget(
            sentences: SentenceChunker.sentences(in: original).count
        )

        // Turning a spoken enumeration into a list is layout, not content — but every check
        // below counts words, and a list changes the words on both sides of the comparison.
        // Measured against Apple's on-device model on 2026-09-20: "Start the list. The signed
        // contract. The invoice. The delivery date. Close the list." came back as a perfectly
        // correct three-line list and was rejected with "invented number: 1", so the user got
        // the prose back and no log said why. Symmetrically, "first point milk, second point
        // eggs…" loses six scaffolding words on the way to three list lines and failed the
        // length floor at 0.33.
        //
        // So when the output *is* a list, the scaffolding comes off both sides first: the
        // line markers the model wrote, and the enumeration words the speaker said. Gated on
        // the output being a list, so no ordinary sentence is judged any differently than it
        // was before.
        // Both sides, or neither. Stripping the enumeration words from the input alone was
        // asymmetric, and the asymmetry had teeth: an intro sentence that legitimately
        // stays prose in front of the list ("Open up this first thing first.") keeps its
        // ordinal in the output while the input has had it removed, so the word looks
        // brand new and the answer is rejected with "invented number: first". Nothing was
        // invented — the guard deleted the ancestor and then complained it was missing.
        let rendersList = listLineCount(cleaned) >= 2
        let original = rendersList ? removingEnumerationWords(original) : original
        let cleaned = rendersList
            ? removingEnumerationWords(removingListMarkers(cleaned))
            : cleaned

        let originalTokens = contentWords(original, mode: mode)
        let cleanedTokens = contentWords(cleaned, mode: mode)
        guard !originalTokens.isEmpty else { return "no content words in the input" }

        // 1. Invented content. The single strongest signal that the model answered rather
        //    than transformed.
        let originalCounts = counts(originalTokens)
        let cleanedCounts = counts(cleanedTokens)
        let novel = cleanedTokens.filter { originalCounts[$0] == nil }
        let dropped = originalTokens.filter { cleanedCounts[$0] == nil }

        switch mode {
        case .punctuationOnly:
            // Re-spelling a spoken ordinal as the digit that starts a list line is not an
            // invention, and treating it as one is why punctuation-only cleanup could never
            // produce a list: "First point, milk. Second point, eggs. Third point, bread."
            // rendered as "1. Milk / 2. Eggs / 3. Bread" has three novel tokens — 1, 2 and 3 —
            // each of which is a number the speaker said, in words. The grammar branch below
            // has always allowed exactly this trade for numbers; the strict branch rejected
            // the whole answer and fell back to prose, silently, on every list.
            //
            // Deliberately the *narrow* version of that rule: a novel number is forgiven only
            // when a number of the same value was dropped. An invented quantity still fails,
            // and every non-numeric novel word still fails, which is what keeps "Paris"
            // catchable in this mode.
            let droppedValues = Set(dropped.compactMap(numericValue))
            let unexplained = novel.filter { word in
                guard let value = numericValue(word) else { return true }
                return !droppedValues.contains(value)
            }
            if !unexplained.isEmpty {
                return "invented words: \(unexplained.prefix(5).joined(separator: ", "))"
            }
        case .grammar:
            if let reason = unexplainedSubstitution(
                novel: novel,
                dropped: dropped,
                // Every word of the input, stop words included, and not the filtered
                // token list. "Did the speaker say this word in some form" is a question
                // about what was said; the stop list exists to decide what is *policed*,
                // and answering the first question with it rejected "the list never gets
                // triggered" because "get" had been filtered out before anything could
                // claim it.
                spoken: allWords(original),
                phoneticBudget: substitutionBudget
            ) {
                return reason
            }
            // Losing a number is as bad as inventing one: "check localhost three thousand"
            // must not come back as "check localhost". Stated as "all of them", not "any of
            // them", because re-spelling legitimately merges words — "three thousand"
            // becomes one token, and counting tokens would fail that.
            if !originalTokens.compactMap(numericValue).isEmpty,
               cleanedTokens.compactMap(numericValue).isEmpty {
                return "dropped every number that was spoken"
            }
            // A rewrite is not a repair. Even when every new word is traceable, replacing a
            // quarter of the content words means the model rebuilt the sentence rather than
            // fixing it. Re-spelled numbers don't count against it — "forty" to "40" is one
            // token changing shape, not the sentence being rewritten.
            let rewritten = novel.filter { numericValue($0) == nil }
            let budget = max(3, originalTokens.count / 4)
            if rewritten.count > budget {
                return "rewrote \(rewritten.count) of \(originalTokens.count) content words "
                    + "(budget \(budget))"
            }
        }

        // 2. Length sanity, as a backstop for the case where the model obeys an injected
        //    instruction using only words from the input ("write the word banana" →
        //    "Banana").
        //
        //    Measured against the *filler-discounted* input, not the raw one. A raw ratio
        //    conflates "the model truncated my sentence" with "the input was 80% filler and
        //    was legitimately cut in half" — with a raw denominator those two land at 0.14
        //    and 0.21, too close to separate. Discounting fillers on both sides pushes the
        //    real cleanups to 0.6–1.0 and leaves the failures below 0.2. The output
        //    side is discounted the same way: a discourse marker the model kept
        //    ("Okay, go for it.") is filler in the denominator and must not count as
        //    content in the numerator, or an unchanged transcript fails its own ratio.
        let cleanedSpoken = cleanedTokens.count { !fillerWords(for: mode).contains($0) }
        let ratio = Double(cleanedSpoken) / Double(max(1, spokenWordCount(original, mode: mode)))
        // Grammar repair inserts articles and restores dropped subjects, so the ceiling is
        // a little higher than for punctuation alone. The floor is unchanged: nothing
        // legitimate removes two thirds of what was said.
        let ceiling = mode == .grammar ? 1.7 : 1.5
        guard ratio >= 0.35, ratio <= ceiling else {
            return String(format: "length ratio %.2f", ratio)
        }

        // 3. A model that starts explaining itself has stopped being a text processor.
        let lowered = cleaned.lowercased()
        if let tell = prefixTells.first(where: { lowered.hasPrefix($0) }) {
            return "commentary prefix: \(tell)"
        }
        return nil
    }

    static func accepts(original: String, cleaned: String, mode: Mode) -> Bool {
        rejection(original: original, cleaned: cleaned, mode: mode) == nil
    }

    /// What survived the guard when the answer as a whole did not.
    struct Salvage: Sendable, Equatable {
        /// The model's sentences, with the ones that failed put back as they were spoken.
        let text: String
        let rejectedSentences: Int
        let totalSentences: Int

        /// For the per-run record. No jargon: the person reading this does not know what a
        /// guard is, and should not have to.
        var plainReason: String {
            "\(rejectedSentences) of \(totalSentences) sentences changed too much to trust, "
                + "so those were used as spoken"
        }
    }

    /// One more chance at a finer grain, for an answer `rejection` has already turned down.
    ///
    /// All-or-nothing is the reason this user's dictations came out untouched. Measured on
    /// their own transcript, 2026-09-20: the model wrote "there **are** some lags" — the
    /// exact repair they had asked for and could not get — and three sentences later
    /// rewrote "it doesn't show on the notch" as "it does not **appear** on the notch". One
    /// unexplained word, and the whole answer went in the bin, correct plural included, and
    /// the raw ASR was typed instead.
    ///
    /// Cleanup is local to a sentence, so a verdict can be too. When the answer still has
    /// the same number of sentences as the input, each pair is judged on its own and only
    /// the sentences that fail are put back as spoken. A model that merged or split
    /// sentences cannot be aligned this way and keeps the whole-answer verdict, and so does
    /// one where every sentence passes on its own — if the finer grain cannot say *which*
    /// sentence was the problem, it has not learned anything the aggregate did not know,
    /// and the aggregate is the more suspicious of the two.
    ///
    /// - Returns: nil when there is nothing to salvage; the caller then falls back exactly
    ///   as it did before.
    static func salvage(original: String, cleaned: String, mode: Mode) -> Salvage? {
        let sources = SentenceChunker.sentences(in: original)
        let candidates = SentenceChunker.sentences(in: cleaned)
        guard sources.count > 1 else { return nil }
        guard let pairs = aligned(sources: sources, candidates: candidates) else { return nil }

        var kept: [String] = []
        var rejected = 0
        for (source, candidate) in pairs {
            if rejection(original: source, cleaned: candidate, mode: mode) == nil {
                kept.append(candidate)
            } else {
                kept.append(source)
                rejected += 1
            }
        }
        guard rejected > 0, rejected < pairs.count else { return nil }

        var text = ""
        for piece in kept {
            if text.isEmpty {
                text = piece
            } else if text.hasSuffix("\n") {
                // A paragraph break the speaker made survives the seam.
                text += piece
            } else {
                text += " " + piece
            }
        }
        return Salvage(
            text: text,
            rejectedSentences: rejected,
            totalSentences: pairs.count
        )
    }

    // MARK: - Aligning two sentence splits

    /// Pairs each spoken sentence with the model's version of it.
    ///
    /// Equal counts is the easy case and used to be the *only* case: anything else returned
    /// nil, the salvage was abandoned, and the whole chunk's grammar went in the bin over
    /// one bad clause. But splitting a run-on in two and joining two fragments into one are
    /// among the repairs the model is asked for by name, so "the counts differ" was firing
    /// precisely on the answers that had done the most work.
    ///
    /// When they differ, the longer split is grouped into runs against the shorter one, each
    /// piece going to the sentence it shares the most content words with, and every anchor
    /// guaranteed at least one piece. A split that cannot be grouped that way — the model
    /// returned a paragraph for five sentences, or five for a paragraph — is not an
    /// alignment problem and still gives up, because a verdict on a pair that is not a pair
    /// is worse than no verdict.
    static func aligned(sources: [String], candidates: [String]) -> [(String, String)]? {
        guard !sources.isEmpty, !candidates.isEmpty else { return nil }
        if sources.count == candidates.count { return Array(zip(sources, candidates)) }
        // A wild disagreement about how many sentences were said is a different failure and
        // not one alignment should paper over.
        let larger = max(sources.count, candidates.count)
        let smaller = min(sources.count, candidates.count)
        guard larger <= smaller * 2 else { return nil }

        if candidates.count > sources.count {
            guard let runs = grouped(candidates, against: sources) else { return nil }
            return Array(zip(sources, runs))
        }
        guard let runs = grouped(sources, against: candidates) else { return nil }
        return Array(zip(runs, candidates))
    }

    /// `many` split into `anchors.count` consecutive runs, greedily.
    private static func grouped(_ many: [String], against anchors: [String]) -> [String]? {
        guard many.count > anchors.count, anchors.count > 1 else { return nil }
        var runs: [[String]] = Array(repeating: [], count: anchors.count)
        var slot = 0
        for (index, piece) in many.enumerated() {
            while slot + 1 < anchors.count, !runs[slot].isEmpty {
                // Move on when staying would starve the anchors still to come, or when the
                // next anchor is simply the better home for this piece.
                let wouldStarve = (many.count - index) <= (anchors.count - slot - 1)
                let fitsNext = overlap(piece, anchors[slot + 1]) > overlap(piece, anchors[slot])
                guard wouldStarve || fitsNext else { break }
                slot += 1
            }
            runs[slot].append(piece)
        }
        guard !runs.contains(where: \.isEmpty) else { return nil }
        return runs.map { $0.joined(separator: " ") }
    }

    /// How many content words two pieces of text have in common. Crude on purpose: the
    /// question is only which of two neighbouring sentences a fragment came out of.
    private static func overlap(_ a: String, _ b: String) -> Int {
        let left = Set(contentWords(a, mode: .grammar))
        let right = Set(contentWords(b, mode: .grammar))
        return left.intersection(right).count
    }

    // MARK: - List layout

    /// Lines that begin with a list marker: "1. ", "2) ", "- ", "* ", "• ".
    static func listLineCount(_ text: String) -> Int {
        text.split(separator: "\n", omittingEmptySubsequences: true).count { line in
            line.range(of: Self.listMarkerPattern, options: [.regularExpression]) != nil
        }
    }

    private static let listMarkerPattern = #"^\s*(?:\d{1,2}[.)]|[-*\#u{2022}])\s+"#

    /// The same markers, taken off. What is left is the item text.
    private static func removingListMarkers(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let range = line.range(of: Self.listMarkerPattern, options: [.regularExpression])
                else { return String(line) }
                return String(line[range.upperBound...])
            }
            .joined(separator: "\n")
    }

    /// The words a speaker uses to *ask* for a list, which the list itself replaces.
    ///
    /// Deliberately the same shapes `SpokenStructure` recognises, and deliberately narrow:
    /// "one" through "ten" only count when a counting word introduces them ("number one",
    /// "point three"), so a spoken quantity is never mistaken for scaffolding.
    private static func removingEnumerationWords(_ text: String) -> String {
        var result = text
        for pattern in [
            #"\b(?:number|point|item|step)\s+(?:one|two|three|four|five|six|seven|eight|nine|ten)\b"#,
            #"\b(?:first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth)(?:ly)?(?:\s+(?:point|item|step|thing))?\b"#,
            #"\b(?:start|begin|open|close|end)\s+(?:the\s+|a\s+|an\s+)?(?:bulleted\s+|bullet\s+|numbered\s+)?list\b"#,
        ] {
            result = result.replacingOccurrences(
                of: pattern,
                with: " ",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return result
    }

    // MARK: - Substitution

    /// Every novel word has to be accounted for by a word that disappeared.
    ///
    /// ## What this function is and is not policing
    ///
    /// It only ever looks at words the output *added*. Words the output *removed* are not
    /// checked here at all, and that is deliberate rather than an oversight: deleting a
    /// repeated or restarted span — "in the formatting, in the settings of the formatting"
    /// down to one attempt, "cle uh clean" down to "clean" — is subtractive, which is the
    /// one thing cleanup is unambiguously allowed to do. A collapsed duplicate does not
    /// even reach `dropped`, because membership is by word and the word survives. The only
    /// bound on deletion is the length-ratio floor in `rejection`, which is there to catch
    /// truncation and summarising, not repair.
    ///
    /// Invention is the other direction and stays rejected: a content word with no ancestor
    /// among the words that disappeared is the model writing rather than transforming.
    private static func unexplainedSubstitution(
        novel: [String],
        dropped: [String],
        spoken: [String],
        phoneticBudget: Int
    ) -> String? {
        guard !novel.isEmpty else { return nil }

        let droppedNumbers = dropped.compactMap(numericValue)
        var unclaimed = dropped
        var phoneticUsed = 0
        let spokenWords = Set(spoken)

        for word in novel {
            if let value = numericValue(word) {
                // A number may be re-spelled, never introduced. Same value, or a
                // multi-word number ("three thousand", "two thirty") collapsed into one.
                if droppedNumbers.contains(value) || droppedNumbers.count >= 2 { continue }
                return "invented number: \(word)"
            }
            if let index = unclaimed.firstIndex(where: { related($0, word) }) {
                unclaimed.remove(at: index)
                continue
            }
            // Another form of a word the speaker *did* say, whether or not that word also
            // disappeared. This is the whole of "fix grammar and spelling", and the guard
            // could not do it.
            //
            // Measured on this user's 2026-09-20T20:47:25Z dictation: "we need multiple
            // time" came back correctly as "multiple times" and was rejected with "invented
            // word: times" — because membership in `dropped` is by word, and "time" was
            // still in the answer two sentences earlier ("takes a lot of time"). The
            // ancestor was there; it had simply not been *removed*, so nothing could claim
            // it. An inflection costs no budget, because inflecting a word that was spoken
            // cannot introduce a fact: "trigger" to "triggered" is a tense, "file" to
            // "files" is a number, and neither of them is Paris.
            if spokenWords.contains(where: { inflection(of: $0, is: word) }) { continue }
            // The second tier, and the only place this guard got looser. `related` is
            // capped at two edits, which is one short of the repair this user's transcript
            // needed most: "could have claimed the text" is "cleaned", three edits away and
            // unmistakable from the sentence around it. Allowing it unbounded would let a
            // model walk away from the transcript one plausible word at a time, so it is
            // rationed rather than permitted — see `phoneticBudget`.
            if let index = unclaimed.firstIndex(where: { phoneticNeighbour($0, word) }) {
                phoneticUsed += 1
                if phoneticUsed > phoneticBudget {
                    return "substituted \(phoneticUsed) similar-sounding words "
                        + "(budget \(phoneticBudget))"
                }
                unclaimed.remove(at: index)
                continue
            }
            return "invented word: \(word)"
        }
        return nil
    }

    /// How many "sounds like it" swaps one answer may make.
    ///
    /// One per sentence, and never more than three however long the hold was. The per
    /// sentence half is what `salvage` enforces for free — it judges each pair on its own,
    /// so a sentence there is allowed exactly one — and the ceiling is what stops a
    /// ninety-second dictation from accumulating a dozen individually-plausible swaps into
    /// a paragraph the speaker never said.
    static func phoneticBudget(sentences: Int) -> Int {
        min(max(1, sentences), 3)
    }

    /// Two words the recogniser could plausibly have swapped that `related` is deliberately
    /// too narrow to see.
    ///
    /// Three conditions, all required, and each one is there to stop this becoming a general
    /// licence to substitute:
    ///
    ///  - six letters or more, so three edits is still a small fraction of the word;
    ///  - three edits at most overall;
    ///  - the same consonant skeleton to within one edit, which is the cheap stand-in for
    ///    "sounds like it".
    ///
    /// "claimed"/"cleaned" is `clmd`/`clnd` and passes. The two that must not: "show"/
    /// "appear" is `shw`/`pr` — the unexplained rewrite `CleanupRouter.salvageFailures`
    /// depends on still being caught — and "sarah"/"rebecca" is `srh`/`rbc`, a swapped name.
    static func phoneticNeighbour(_ a: String, _ b: String) -> Bool {
        guard max(a.count, b.count) >= 6 else { return false }
        guard editDistance(a, b) <= 3 else { return false }
        return editDistance(consonantSkeleton(a), consonantSkeleton(b)) <= 1
    }

    /// The word's consonants, with runs collapsed: "cleaned" is `clnd`, "letter" is `ltr`.
    ///
    /// Not phonetics, and not pretending to be. It is the part of a word a recogniser is
    /// least likely to get wrong, which makes two words that agree on it and differ by at
    /// most three letters far more likely to be one word heard twice than two words.
    private static func consonantSkeleton(_ word: String) -> String {
        var result = ""
        for character in word.lowercased() where !"aeiou".contains(character) {
            if result.last != character { result.append(character) }
        }
        return result
    }

    /// Two words the recogniser could plausibly have confused, or two forms of one word.
    ///
    /// Deliberately narrow. "walks"/"works" differ by a letter and are a mis-hearing;
    /// "fixes"/"fix" share a stem and are an agreement fix; "paris"/"what" are neither,
    /// which is the case that matters.
    static func related(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        // Irregular inflection, which spelling cannot see: "go"/"went" and "person"/
        // "people" are one edit apart in meaning and five apart in letters. Without this
        // table, fixing a tense — which is half of what the user asked for — is rejected
        // for every verb English declines irregularly.
        if let left = irregularLemmas[a], let right = irregularLemmas[b], left == right {
            return true
        }
        let shorter = a.count <= b.count ? a : b
        let longer = a.count <= b.count ? b : a
        // Inflection: same stem, a suffix of at most three letters ("fix"/"fixes",
        // "team"/"teams", "develop"/"developed").
        if shorter.count >= 3, longer.hasPrefix(shorter), longer.count - shorter.count <= 3 {
            return true
        }
        // Mis-hearing. Two edits, or one for a word short enough that two would let almost
        // anything through. "walks"/"works" is two substitutions and is the case this rule
        // exists for; "paris"/"what" is five and is the case it exists to stop.
        //
        // The cliff used to sit at four letters, which made the rule disagree with itself:
        // "walks"/"works" was a mis-hearing and "walk"/"work" — the same mis-hearing, one
        // letter shorter — was an invention. Measured on this user's own transcript,
        // 2026-09-20: "why doesn't it walk faster" came back correctly as "work" and the
        // whole cleanup was thrown away for it. Two edits out of four letters is not a
        // looser bar than two out of five, so the cliff is at three.
        let budget = longer.count <= 3 ? 1 : 2
        return editDistance(a, b) <= budget
    }

    /// Whether `candidate` is another grammatical form of `spoken` — the same word,
    /// declined.
    ///
    /// Strictly morphological, and that is the point. `related` is an *edit distance*, which
    /// is a measure of how a recogniser mishears; this is a measure of how English inflects,
    /// and the two want opposite treatments. A mis-hearing has to consume the word it
    /// replaced, because two words that merely look alike can mean entirely different
    /// things. An inflection does not: "time"/"times", "trigger"/"triggered",
    /// "polish"/"polished" and "file"/"files" are one word in two shapes, and turning one
    /// into the other is exactly what the speaker asked for when they turned grammar repair
    /// on.
    ///
    /// Everything here is a *suffix* rule against a closed list. It will not accept
    /// "test"/"testing" from "tests", it will not accept a prefix, and it will not accept a
    /// derivation that changes the part of speech beyond the listed endings — so the words
    /// this guard exists to catch ("paris", "rebecca", "appear", "cancel") reach it and are
    /// still refused.
    static func inflection(of spoken: String, is candidate: String) -> Bool {
        if spoken == candidate { return true }
        // Irregular, which no suffix rule can see: "is"/"was", "has"/"had", "go"/"went".
        if let left = irregularLemmas[spoken], let right = irregularLemmas[candidate],
           left == right {
            return true
        }
        let shorter = spoken.count <= candidate.count ? spoken : candidate
        let longer = spoken.count <= candidate.count ? candidate : spoken
        guard shorter.count >= 3, longer.count > shorter.count else { return false }

        func hasRegularEnding(after base: String) -> Bool {
            guard longer.hasPrefix(base) else { return false }
            return regularEndings.contains(String(longer.dropFirst(base.count)))
        }
        // "time"/"times", "trigger"/"triggered", "improve"/"improved".
        if hasRegularEnding(after: shorter) { return true }
        // Consonant doubling: "stop"/"stopped", "run"/"running".
        if let last = shorter.last, !"aeiouwxy".contains(last),
           hasRegularEnding(after: shorter + String(last)) {
            return true
        }
        // A dropped silent "e": "use"/"using", "improve"/"improving".
        if shorter.hasSuffix("e"), hasRegularEnding(after: String(shorter.dropLast())) {
            return true
        }
        // "y" to "ies"/"ied": "try"/"tried", "copy"/"copies".
        if shorter.hasSuffix("y") {
            let base = String(shorter.dropLast())
            if longer == base + "ies" || longer == base + "ied" { return true }
        }
        return false
    }

    /// The endings English adds to a word without making it a different word. Deliberately
    /// short: every entry is a licence for the model to write something the speaker did not
    /// say, so the list stops at inflection and never reaches derivation ("-ness", "-ment",
    /// "-ly" all change what the word *is*).
    private static let regularEndings: Set<String> = [
        "s", "es", "d", "ed", "ing", "en", "n",
    ]

    /// Standard Levenshtein, two rows.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    // MARK: - Numbers

    /// The value a token denotes, whether it was spoken or written. nil for non-numbers.
    ///
    /// Ordinals fold onto their cardinal ("twelfth" and "12th" are both 12) because the
    /// only question being asked is whether the output names a quantity the input did not.
    static func numericValue(_ word: String) -> Int? {
        if let direct = Int(word.filter(\.isNumber)), word.contains(where: \.isNumber) {
            return direct
        }
        return numberWords[word]
    }

    private static let numberWords: [String: Int] = {
        var map: [String: Int] = [
            // "one" is deliberately absent. Spoken English uses it as a pronoun and a
            // determiner at least as often as a quantity — "the one I sent", "blocker one",
            // "in one sentence" — so treating it as a number makes the dropped-number rule
            // fire on sentences that never contained a quantity. The digit 1 still counts.
            "zero": 0, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
            "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
            "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17,
            "eighteen": 18, "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40,
            "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
            "hundred": 100, "thousand": 1_000, "million": 1_000_000,
        ]
        let ordinals: [String: Int] = [
            "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6,
            "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10, "eleventh": 11,
            "twelfth": 12, "thirteenth": 13, "fourteenth": 14, "fifteenth": 15,
            "sixteenth": 16, "seventeenth": 17, "eighteenth": 18, "nineteenth": 19,
            "twentieth": 20, "thirtieth": 30, "fortieth": 40,
        ]
        map.merge(ordinals) { current, _ in current }
        return map
    }()

    // MARK: - Irregular forms

    /// Every listed form mapped to one canonical stem, so two forms of the same word can be
    /// recognised as the same word.
    ///
    /// Only irregulars are here. Regular inflection ("develop"/"developed", "team"/"teams")
    /// is already caught by the shared-prefix rule above, and listing it would be a
    /// dictionary rather than a table.
    private static let irregularLemmas: [String: String] = {
        let families: [[String]] = [
            // The three English declines most violently, and the three a grammar repair
            // touches most often. They are stop words in `.grammar` mode and so never
            // reach the novelty test as tokens — they are here because `inflection` is
            // asked about words in their raw, unfiltered form.
            ["be", "am", "is", "are", "was", "were", "been", "being"],
            ["have", "has", "having", "had"],
            ["do", "does", "doing", "did", "done"],
            ["go", "goes", "going", "went", "gone"],
            ["buy", "buys", "buying", "bought"],
            ["take", "takes", "taking", "took", "taken"],
            ["see", "sees", "seeing", "saw", "seen"],
            ["come", "comes", "coming", "came"],
            ["give", "gives", "giving", "gave", "given"],
            ["make", "makes", "making", "made"],
            ["say", "says", "saying", "said"],
            ["think", "thinks", "thinking", "thought"],
            ["know", "knows", "knowing", "knew", "known"],
            ["find", "finds", "finding", "found"],
            ["tell", "tells", "telling", "told"],
            ["become", "becomes", "becoming", "became"],
            ["leave", "leaves", "leaving", "left"],
            ["feel", "feels", "feeling", "felt"],
            ["bring", "brings", "bringing", "brought"],
            ["begin", "begins", "beginning", "began", "begun"],
            ["keep", "keeps", "keeping", "kept"],
            ["hold", "holds", "holding", "held"],
            ["write", "writes", "writing", "wrote", "written"],
            ["stand", "stands", "standing", "stood"],
            ["hear", "hears", "hearing", "heard"],
            ["mean", "means", "meaning", "meant"],
            ["meet", "meets", "meeting", "met"],
            ["run", "runs", "running", "ran"],
            ["pay", "pays", "paying", "paid"],
            ["sit", "sits", "sitting", "sat"],
            ["speak", "speaks", "speaking", "spoke", "spoken"],
            ["lead", "leads", "leading", "led"],
            ["grow", "grows", "growing", "grew", "grown"],
            ["lose", "loses", "losing", "lost"],
            ["fall", "falls", "falling", "fell", "fallen"],
            ["send", "sends", "sending", "sent"],
            ["build", "builds", "building", "built"],
            ["understand", "understands", "understanding", "understood"],
            ["draw", "draws", "drawing", "drew", "drawn"],
            ["break", "breaks", "breaking", "broke", "broken"],
            ["spend", "spends", "spending", "spent"],
            ["rise", "rises", "rising", "rose", "risen"],
            ["drive", "drives", "driving", "drove", "driven"],
            ["wear", "wears", "wearing", "wore", "worn"],
            ["choose", "chooses", "choosing", "chose", "chosen"],
            ["seek", "seeks", "seeking", "sought"],
            ["throw", "throws", "throwing", "threw", "thrown"],
            ["catch", "catches", "catching", "caught"],
            ["deal", "deals", "dealing", "dealt"],
            ["win", "wins", "winning", "won"],
            ["forget", "forgets", "forgetting", "forgot", "forgotten"],
            ["teach", "teaches", "teaching", "taught"],
            ["eat", "eats", "eating", "ate", "eaten"],
            ["sell", "sells", "selling", "sold"],
            ["fight", "fights", "fighting", "fought"],
            ["sleep", "sleeps", "sleeping", "slept"],
            ["feed", "feeds", "feeding", "fed"],
            ["hang", "hangs", "hanging", "hung"],
            ["shoot", "shoots", "shooting", "shot"],
            ["stick", "sticks", "sticking", "stuck"],
            ["wake", "wakes", "waking", "woke", "woken"],
            ["shake", "shakes", "shaking", "shook", "shaken"],
            ["freeze", "freezes", "freezing", "froze", "frozen"],
            ["steal", "steals", "stealing", "stole", "stolen"],
            ["person", "people", "persons"],
            ["child", "children"],
            ["man", "men"],
            ["woman", "women"],
            ["foot", "feet"],
            ["tooth", "teeth"],
            ["mouse", "mice"],
            ["life", "lives"],
            ["leaf", "leaves"],
            ["knife", "knives"],
            ["wife", "wives"],
        ]
        var map: [String: String] = [:]
        for family in families {
            guard let stem = family.first else { continue }
            for form in family { map[form] = stem }
        }
        return map
    }()

    // MARK: - Tokens

    /// Lowercased alphanumeric words, minus the function words that a cleanup pass
    /// legitimately shuffles.
    ///
    /// Contractions are expanded first, not merely split on. Splitting turns "hasn't" into
    /// "hasn" + "t", and "hasn" matches nothing in a transcript that said "has not" — so
    /// contracting a phrase, which is exactly the kind of repair this formatter exists to
    /// make, was rejected as an invented word. Measured: the C13 eval case produced a
    /// perfectly good rewrite and the guard threw it away over "hasn".
    static func contentWords(_ text: String, mode: Mode) -> [String] {
        let ignored = stopWords(for: mode)
        return allWords(text).filter { !ignored.contains($0) }
    }

    /// The same tokenizing, with nothing filtered out. What the speaker said, as words.
    static func allWords(_ text: String) -> [String] {
        expandContractions(text.lowercased())
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    /// Rewrites contractions into the words they stand for, so a contracted form and a
    /// spoken-out form tokenize the same way.
    ///
    /// The irregular three come first: "won't" is not "wo" + not, and "can't" is one word
    /// with the "n" shared. Everything after that is the regular suffix set. The possessive
    /// "'s" is dropped rather than expanded, because it is genuinely ambiguous — "it's" is
    /// "it is" and "sarah's" is neither — and a stray "s" token would look invented.
    static func expandContractions(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "\u{2019}", with: "'")
        for (contraction, expansion) in [
            ("won't", "will not"),
            ("can't", "can not"),
            ("shan't", "shall not"),
        ] {
            result = result.replacingOccurrences(of: contraction, with: expansion)
        }
        for (suffix, expansion) in [
            ("n't", " not"),
            ("'ll", " will"),
            ("'re", " are"),
            ("'ve", " have"),
            ("'m", " am"),
            ("'d", " would"),
            ("'s", ""),
        ] {
            result = result.replacingOccurrences(of: suffix, with: expansion)
        }
        return result
    }

    private static func counts(_ words: [String]) -> [String: Int] {
        words.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }

    static func stopWords(for mode: Mode) -> Set<String> {
        mode == .grammar ? grammarStopWords : punctuationStopWords
    }

    /// The original list, unchanged. Deliberately small: every word here is one the guard
    /// stops policing, so it only covers words a punctuation pass may genuinely insert or
    /// drop while re-punctuating.
    private static let punctuationStopWords: Set<String> = [
        "a", "am", "an", "are", "the", "and", "or", "but", "so", "then", "not", "cannot",
        "is", "was", "were", "will", "would", "have", "has", "had",
        "s", "t", "re", "ll", "ve", "d", "m",
    ]

    /// The punctuation list plus the classes a *grammar* fix legitimately inserts, drops or
    /// swaps: auxiliaries, pronouns, prepositions and determiners ("what you need *for* me"
    /// → "*from* me"). Nouns and verbs are still policed, which is what keeps "Paris"
    /// catchable.
    private static let grammarStopWords: Set<String> = [
        // determiners and conjunctions
        "a", "an", "the", "and", "or", "but", "so", "then", "not", "cannot", "no", "nor",
        "if", "because", "while", "though", "although", "that", "this", "these", "those",
        // auxiliaries and copulas
        "is", "am", "are", "was", "were", "be", "been", "being", "will", "would", "shall",
        "should", "can", "could", "may", "might", "must", "have", "has", "had", "do",
        "does", "did", "get", "got",
        // pronouns
        "i", "me", "my", "mine", "we", "us", "our", "ours", "you", "your", "yours",
        "he", "him", "his", "she", "her", "hers", "it", "its", "they", "them", "their",
        "theirs", "there", "here",
        // prepositions and particles
        //
        // A closed list, and the reason it can be one: a preposition carries relation
        // rather than fact, so inserting or swapping one cannot add a claim to the
        // transcript. How *many* may be inserted is not policed here and does not need to
        // be — the length-ratio ceiling below is the cap, and a model that added enough
        // function words to move that number has done something other than fix grammar.
        "in", "on", "at", "to", "from", "for", "of", "with", "by", "about", "into",
        "onto", "over", "under", "up", "down", "out", "off", "as", "than", "through",
        "between", "before", "after", "during", "without", "within", "against",
        "across", "around", "along", "upon", "near", "since", "until", "per", "via",
        "toward", "towards",
        // contraction tails
        "s", "t", "re", "ll", "ve", "d", "m",
    ]

    /// Content words minus conversational filler — an estimate of how much the speaker
    /// actually *said*, used as the denominator for the length check.
    private static func spokenWordCount(_ text: String, mode: Mode) -> Int {
        contentWords(text, mode: mode).count { !fillerWords(for: mode).contains($0) }
    }

    /// Broader than `RuleBasedFormatter`'s strip list on purpose. This set only affects the
    /// guard's denominator — it never removes anything from the user's text — so it can
    /// afford to be aggressive about discourse markers that the LLM legitimately deletes.
    private static func fillerWords(for mode: Mode) -> Set<String> {
        // The grammar list drops the words its stop list already removed — "i", "you" and
        // "of" are filtered out before this set is consulted — and adds nothing, so the
        // denominator means the same thing in both modes.
        mode == .grammar ? grammarFillerWords : punctuationFillerWords
    }

    private static let punctuationFillerWords: Set<String> = [
        "um", "uh", "erm", "uhm", "hmm", "mhm", "like", "basically", "actually", "literally",
        "just", "really", "okay", "ok", "well", "right", "anyway", "i", "mean", "you", "know",
        "kind", "sort", "of", "stuff", "thing", "things",
    ]

    private static let grammarFillerWords: Set<String> = [
        "um", "uh", "erm", "uhm", "hmm", "mhm", "like", "basically", "actually", "literally",
        "just", "really", "okay", "ok", "well", "right", "anyway", "mean", "know",
        "kind", "sort", "stuff", "thing", "things", "yeah",
    ]

    private static let prefixTells = [
        "here's the cleaned", "here is the cleaned", "cleaned transcript",
        "here's the corrected", "here is the corrected", "corrected transcript",
        "sure,", "certainly,", "of course,", "i cannot", "i can't", "as an ai",
    ]

    // MARK: - Self-test

    /// Both directions of the grammar loosening, with no model in the loop.
    ///
    /// Pure text in, a list of complaints out, in well under a millisecond — so it is wired
    /// into `--selftest-cleanup-router` rather than into the model suite, and a regression
    /// here is caught by a build rather than by a dictation.
    ///
    /// The fixtures on the accept side are this user's own transcripts from runs.jsonl,
    /// 2026-09-20: a restart the model kept twice, and a mis-hearing it left in. Both were
    /// *accepted* by the guard in the state they shipped in — the guard was only half the
    /// problem — so the point of asserting them is that they stay accepted now that the
    /// prompt actually asks for the repair. The reject side is the reason any of this is
    /// dangerous: invention, a changed number, a changed name, a sentence replaced
    /// wholesale, and the chain of individually-plausible swaps that a budget exists to stop.
    static func selfTestFailures() -> [String] {
        var failures: [String] = []

        func expect(
            _ name: String,
            _ original: String,
            _ cleaned: String,
            mode: Mode,
            accepted: Bool
        ) {
            let verdict = rejection(original: original, cleaned: cleaned, mode: mode)
            switch (accepted, verdict) {
            case (true, .some(let reason)):
                failures.append("\(name): expected the repair to be accepted, got \(reason)")
            case (false, .none):
                failures.append("\(name): expected a rejection, the answer was accepted")
            default:
                break
            }
        }

        // 1. The restart. "in the formatting" restarted as "in the settings of the
        //    formatting", and both attempts were typed. Resolving it removes words and adds
        //    none, which is the shape the guard must never stand in the way of.
        let restart = "Also in the formatting in the settings of the formatting, the user is "
            + "not able to scroll through the app. So can you check that for us?"
        expect(
            "restart-resolved",
            restart,
            "Also, in the formatting settings, the user is not able to scroll through the "
                + "app. Can you check that for us?",
            mode: .grammar,
            accepted: true
        )
        // Same repair, no substitution in it, so strict mode may take it too: a restart is
        // subtractive and subtractive is exactly what punctuation-only cleanup is for.
        // Asserted rather than assumed, because the day it starts failing here is the day
        // S1-mini's output starts getting thrown away for tidying a stutter.
        expect(
            "restart-resolved-strict",
            restart,
            "Also, in the formatting settings, the user is not able to scroll through the "
                + "app. Can you check that for us?",
            mode: .punctuationOnly,
            accepted: true
        )
        expect(
            "repetition-collapsed",
            "we we need to to check the the database connection again",
            "We need to check the database connection again.",
            mode: .grammar,
            accepted: true
        )

        // 2. The mis-hearing and the run-on. "could have claimed the text" is "cleaned",
        //    three edits away — one more than `related` allows, which is why the repair was
        //    unreachable even when the model made it.
        let misheard = "But you see we keep the same, we did not properly cle clean the "
            + "text. For example, I said formatting in the setting of the formatting could "
            + "have claimed the text properly as an issue that the model is not able to "
            + "properly clean the text and also format it top check."
        let repaired = "But you see, we keep the same. We did not properly clean the text. "
            + "For example, I said formatting in the settings of the formatting could have "
            + "cleaned the text properly. The issue is that the model is not able to "
            + "properly clean the text and also format it to check."
        expect("misheard-and-run-on", misheard, repaired, mode: .grammar, accepted: true)
        // ...and strict mode has not moved: "cleaned" and "settings" are both content words
        // the input did not contain, which is all punctuation-only cleanup needs to know.
        expect(
            "misheard-and-run-on-strict",
            misheard,
            repaired,
            mode: .punctuationOnly,
            accepted: false
        )
        expect(
            "strict-still-accepts-punctuation",
            "um so we need to check the database again",
            "We need to check the database again.",
            mode: .punctuationOnly,
            accepted: true
        )

        // 3. The budget. One plausible swap in a sentence is a repair; two is a model
        //    rewriting the sentence a word at a time and calling each step plausible.
        expect(
            "one-phonetic-swap",
            "The model claimed the text properly.",
            "The model cleaned the text properly.",
            mode: .grammar,
            accepted: true
        )
        expect(
            "one-phonetic-swap-strict",
            "The model claimed the text properly.",
            "The model cleaned the text properly.",
            mode: .punctuationOnly,
            accepted: false
        )
        expect(
            "phonetic-chain-in-one-sentence",
            "The model claimed the text and claimed the images.",
            "The model cleaned the text and cleaned the images.",
            mode: .grammar,
            accepted: false
        )

        // 4. Invention, in the four shapes that reach a document and look correct.
        expect(
            "invented-clause",
            "The build is green.",
            "The build is green and the tests are passing.",
            mode: .grammar,
            accepted: false
        )
        expect(
            "changed-number",
            "We need forty units by Friday.",
            "We need fifty units by Friday.",
            mode: .grammar,
            accepted: false
        )
        expect(
            "changed-name",
            "Send the deck to Sarah before the meeting.",
            "Send the deck to Rebecca before the meeting.",
            mode: .grammar,
            accepted: false
        )
        expect(
            "sentence-replaced-wholesale",
            "Check localhost three thousand.",
            "Paris is lovely this time of year.",
            mode: .grammar,
            accepted: false
        )

        // 5. `CleanupRouter.salvageFailures` asserts this exact pair, and the loosening
        //    above must not have touched it. Repeated here so the claim is provable from
        //    inside this file, without a router run: "show" to "appear" is six edits and a
        //    different consonant skeleton, so it is an unexplained rewrite in both tiers.
        let lags = "Also, there is some lags between when the user is recording. "
            + "When the animation shows, it doesn't show on the notch. "
            + "I don't know what's happening, so you need to make sure that the user can "
            + "see that the computer is actually recording."
        let lagsCleaned = "Also, there are some lags between when the user is recording. "
            + "When the animation shows, it does not appear on the notch. "
            + "I do not know what is happening, so you need to make sure that the user can "
            + "see that the computer is actually recording."
        expect("salvage-fixture-whole", lags, lagsCleaned, mode: .grammar, accepted: false)
        if let salvaged = salvage(original: lags, cleaned: lagsCleaned, mode: .grammar) {
            if salvaged.rejectedSentences != 1 {
                failures.append(
                    "salvage-fixture: expected one sentence to be put back, got "
                        + "\(salvaged.rejectedSentences) of \(salvaged.totalSentences)"
                )
            }
            if salvaged.text.contains("there is some lags") {
                failures.append("salvage-fixture: an agreement repair was thrown away")
            }
            if !salvaged.text.contains("it doesn't show on the notch") {
                failures.append("salvage-fixture: an unexplained rewrite was kept")
            }
        } else {
            failures.append("salvage-fixture: a rejected answer salvaged nothing")
        }

        // The same, one tier up: a sentence that earned the new allowance is kept while the
        // invention beside it is put back.
        let mixed = "The model claimed the text properly. We should ship it on Friday."
        let mixedCleaned = "The model cleaned the text properly. We should cancel it on Friday."
        expect("mixed-answer-whole", mixed, mixedCleaned, mode: .grammar, accepted: false)
        if let salvaged = salvage(original: mixed, cleaned: mixedCleaned, mode: .grammar) {
            if !salvaged.text.contains("cleaned the text") {
                failures.append("mixed-answer: the phonetic repair was thrown away")
            }
            if !salvaged.text.contains("ship it on Friday") {
                failures.append("mixed-answer: an invented verb survived salvage")
            }
        } else {
            failures.append("mixed-answer: nothing was salvaged from a one-bad-sentence answer")
        }

        // 6. The scaffolding has to come off both sides or neither. An intro sentence that
        //    stays prose in front of a rendered list keeps its ordinal, and the input has
        //    had that ordinal stripped as enumeration scaffolding — so a purely rearranged
        //    list was rejected with "invented number: first".
        expect(
            "list-intro-keeps-its-ordinal",
            "Okay, a few things. Open up this first thing first. First, fix the graph. "
                + "Second, tidy the skills page. Third, check the settings.",
            "Okay, a few things. Open up this first thing first.\n\n1. Fix the graph\n"
                + "2. Tidy the skills page\n3. Check the settings",
            mode: .grammar,
            accepted: true
        )

        // 7. Inflection. Every one of these is a sentence from this user's dictation of
        //    2026-09-20T20:47:25Z, and every one of them was refused — "multiple times" by
        //    name, in the record, as an invented word. The ancestor is in the input in each
        //    case; what was missing was any way for a new *form* to claim a word that had
        //    not been deleted.
        expect(
            "plural-of-a-word-still-in-the-answer",
            "Triggering the agent takes a lot of time. I said hey we need multiple time, "
                + "but in never trigger it.",
            "Triggering the agent takes a lot of time. I said we need it multiple times, "
                + "but it never triggers.",
            mode: .grammar,
            accepted: true
        )
        expect(
            "tense-of-a-word-still-in-the-answer",
            "Sometimes it doesn't trigger at all. I said hey we need multiple time, but in "
                + "never trigger it.",
            "Sometimes it does not trigger at all. I said we need it multiple times, but it "
                + "never triggered it.",
            mode: .grammar,
            accepted: true
        )
        expect(
            "contraction-expanded",
            "he's not have doesn't have access to the file",
            "He does not have access to the files.",
            mode: .grammar,
            accepted: true
        )
        expect(
            "contraction-contracted",
            "It does not know me and it does not have access to the files.",
            "It doesn't know me and it doesn't have access to the files.",
            mode: .grammar,
            accepted: true
        )
        expect(
            "participle-of-a-spoken-verb",
            "we still far away again from from getting this thing polish",
            "We are still far away from getting this thing polished.",
            mode: .grammar,
            accepted: true
        )
        expect(
            "agreement-on-a-word-that-stayed",
            "The list never get triggered, the formatting doesn't go through.",
            "The list never gets triggered and the formatting does not go through.",
            mode: .grammar,
            accepted: true
        )
        // ...and the other direction, with the same shape. An inflection is free; a word
        // that is not one of these is still an invention however ordinary it looks.
        expect(
            "inflection-does-not-license-a-new-noun",
            "I said hey we need multiple time, but in never trigger it.",
            "I said we need multiple retries, but it never triggered.",
            mode: .grammar,
            accepted: false
        )
        expect(
            "inflection-does-not-license-a-new-verb",
            "You should check the agent conversation log.",
            "You should delete the agent conversation log.",
            mode: .grammar,
            accepted: false
        )
        expect(
            "inflection-does-not-license-a-new-clause",
            "We need to focus on the agent now.",
            "We need to focus on the agent now because the release is on Friday.",
            mode: .grammar,
            accepted: false
        )
        // A derivation is not an inflection: "improve" to "improvement" changes what the
        // word is, and the endings list stops short of it on purpose.
        if inflection(of: "improve", is: "improvement") {
            failures.append("\"improve\"/\"improvement\" is being treated as an inflection")
        }
        for (spoken, form) in [
            ("time", "times"), ("trigger", "triggered"), ("trigger", "triggers"),
            ("file", "files"), ("polish", "polished"), ("get", "gets"),
            ("is", "are"), ("has", "had"), ("do", "does"), ("go", "went"),
            ("stop", "stopped"), ("improve", "improving"), ("try", "tried"),
        ] where !inflection(of: spoken, is: form) {
            failures.append("\"\(spoken)\"/\"\(form)\" is not recognised as one word declined")
        }
        for (spoken, form) in [
            ("paris", "france"), ("show", "appear"), ("sarah", "rebecca"),
            ("ship", "cancel"), ("tests", "testing"), ("agent", "agenda"),
        ] where inflection(of: spoken, is: form) {
            failures.append("\"\(spoken)\"/\"\(form)\" is being treated as one word declined")
        }

        // 8. One bad sentence must not cost the good ones, even when the model changed how
        //    many sentences there are. Splitting a run-on is a repair the prompt asks for by
        //    name, and it used to be the thing that made a salvage impossible.
        let runOn = "The list never get triggered the formatting doesn't go through. "
            + "Can you check what's happening?"
        let split = "The list never gets triggered. The formatting does not go through. "
            + "Can you investigate what is happening?"
        if let salvaged = salvage(original: runOn, cleaned: split, mode: .grammar) {
            if !salvaged.text.contains("never gets triggered") {
                failures.append("split-sentences: a repair was thrown away with the bad clause")
            }
            if !salvaged.text.contains("Can you check what's happening?") {
                failures.append("split-sentences: an invented verb survived salvage")
            }
        } else {
            failures.append(
                "split-sentences: a model that split a run-on could not be salvaged at all"
            )
        }
        if aligned(sources: ["One.", "Two.", "Three."], candidates: ["Everything."]) != nil {
            failures.append("three sentences were aligned against one")
        }

        // 9. The two words the whole `related` cliff is calibrated on.
        if !related("walk", "work") {
            failures.append("\"walk\"/\"work\" is no longer recognised as a mis-hearing")
        }
        if related("paris", "what") {
            failures.append("\"paris\"/\"what\" is being treated as a mis-hearing")
        }
        if !phoneticNeighbour("claimed", "cleaned") {
            failures.append("\"claimed\"/\"cleaned\" is not recognised as a mis-hearing")
        }
        if phoneticNeighbour("show", "appear") {
            failures.append("\"show\"/\"appear\" is being treated as a mis-hearing")
        }
        if phoneticBudget(sentences: 1) != 1 {
            failures.append("a single sentence is allowed more than one similar-sounding swap")
        }
        if phoneticBudget(sentences: 40) != 3 {
            failures.append("a long transcript is allowed more than three swaps")
        }
        return failures
    }
}

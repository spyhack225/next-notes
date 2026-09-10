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
            if !novel.isEmpty {
                return "invented words: \(novel.prefix(5).joined(separator: ", "))"
            }
        case .grammar:
            if let reason = unexplainedSubstitution(novel: novel, dropped: dropped) {
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
        //    real cleanups to 0.6–1.0 and leaves the failures below 0.2.
        let ratio = Double(cleanedTokens.count) / Double(max(1, spokenWordCount(original, mode: mode)))
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

    // MARK: - Substitution

    /// Every novel word has to be accounted for by a word that disappeared.
    private static func unexplainedSubstitution(novel: [String], dropped: [String]) -> String? {
        guard !novel.isEmpty else { return nil }

        let droppedNumbers = dropped.compactMap(numericValue)
        var unclaimed = dropped

        for word in novel {
            if let value = numericValue(word) {
                // A number may be re-spelled, never introduced. Same value, or a
                // multi-word number ("three thousand", "two thirty") collapsed into one.
                if droppedNumbers.contains(value) || droppedNumbers.count >= 2 { continue }
                return "invented number: \(word)"
            }
            guard let index = unclaimed.firstIndex(where: { related($0, word) }) else {
                return "invented word: \(word)"
            }
            unclaimed.remove(at: index)
        }
        return nil
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
        let budget = longer.count <= 4 ? 1 : 2
        return editDistance(a, b) <= budget
    }

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
    /// legitimately shuffles. Contractions are split so "isn't" matches "isn t".
    static func contentWords(_ text: String, mode: Mode) -> [String] {
        let ignored = stopWords(for: mode)
        return text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !ignored.contains($0) }
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
        "in", "on", "at", "to", "from", "for", "of", "with", "by", "about", "into",
        "onto", "over", "under", "up", "down", "out", "off", "as", "than", "through",
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
}

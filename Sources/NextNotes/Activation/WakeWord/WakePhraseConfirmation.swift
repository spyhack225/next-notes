import Foundation

/// “Did that person say the wake phrase?”, answered from a transcript rather than
/// from the keyword lattice.
///
/// Two jobs.
///
/// 1. **Second stage for the audio spotter.** Loosening the spotter so a French-accented
///    “Hey Will” actually fires also lets “hey Bill” and “I will send you the file”
///    through. Scoring the transcript of the same short window by phonetic distance
///    throws those back out without another acoustic model.
/// 2. **First stage for the transcript path.** `WakeWordDetector` used to require the
///    phrase as a literal substring. The dictation ASR transcribed this user's “Hey
///    Will” as “hey we need”, which is not a substring of anything, so the meeting and
///    dictation wake paths could never fire for him. Phonetically “hey we need” sits
///    well inside the accept band.
///
/// The long-sentence rule is what keeps this honest. The check is meant to run on a
/// short window — about a second and a half of audio — so an utterance that is much
/// longer than the phrase was continuous speech, not someone addressing the agent.
/// “hey we need” is accepted; “hey we need to talk about the budget” is not.
enum WakePhraseConfirmation {
    struct Result: Sendable, Equatable {
        /// Close enough to act on.
        var accepted: Bool
        /// 0…1. 1 is a phone-for-phone match. Shown in the Settings test so a person
        /// can see *how close* an attempt landed instead of just “it did not fire”.
        var closeness: Double
        /// Plain words for why, for the Settings test and the log.
        var reason: String
        /// Whatever followed the phrase, so “Hey Will, open Chrome” keeps its request.
        var remainder: String
        /// How many leading words the phrase consumed. Lets a caller slice the phrase
        /// off the *original* text and keep its punctuation and capitals.
        var matchedWords: Int = 0
    }

    /// Accept at or above this closeness. Chosen so the accent variants of the phrase
    /// clear it and ordinary speech that merely starts with “hey” does not; the
    /// self-test pins both sides.
    ///
    /// Measured against the model's own 126k-word lexicon: “hey will” 1.00,
    /// “ey will” 1.00, “hey we'll” 0.92, “a will” 0.75, “hey we need” 0.72,
    /// “hey weal” 0.67 — against “hey there” 0.64, “i will send you the file” 0.60,
    /// “hello” 0.32.
    static let acceptedCloseness = 0.65

    /// At or above this, the words themselves were heard and the phrase opens the
    /// utterance — so whatever follows is the request, however long. Below it the match
    /// was a sound-alike, and a sound-alike buried in a long sentence is not an address.
    ///
    /// The gap between this and `acceptedCloseness` is where the judgement lives:
    /// “hey we need” and “hey we need to talk about the budget” score identically
    /// (0.90), and only their length tells them apart.
    static let certainCloseness = 0.95

    /// How many words longer than the phrase a *marginal* match may be and still count
    /// as someone addressing the agent.
    static let extraWordsAllowed = 2

    /// How many accent variants of the phrase the scorer compares against.
    ///
    /// More than the spotter writes to `keywords.txt`, deliberately. The spotter is
    /// capped by its decoder beam — past four pronunciations they evict each other and
    /// recall falls — and nothing here competes for a beam, so the scorer can afford
    /// the whole set and stay at least as forgiving as the ears in front of it.
    static let variantDepth = 6

    /// `phrase` is the configured wake phrase. `transcript` is what was heard in the
    /// window. `lookup` resolves a word to phones; the default is the model's lexicon.
    static func check(
        transcript: String,
        phrase: String,
        lookup: (String) -> [String]? = { WakeWordPhoneLexicon.phones(for: $0) ?? WakeWordKeywords.fallbackPhones(for: $0) }
    ) -> Result {
        let heardWords = words(in: transcript)
        let phraseWords = words(in: phrase)
        guard !heardWords.isEmpty, !phraseWords.isEmpty else {
            return Result(accepted: false, closeness: 0, reason: "Nothing was heard.", remainder: "")
        }

        let phrasePhones = phraseWords.flatMap { phones(for: $0, lookup: lookup) }
        guard !phrasePhones.isEmpty else {
            return Result(accepted: false, closeness: 0, reason: "The phrase has no pronunciation.", remainder: "")
        }

        // Score against the accent-tolerant pronunciations as well as the canonical
        // one. Without this a dropped /h/ — the commonest feature of the accent this
        // was reported from — costs a whole phone and lands “ey will” under the bar.
        let targets = [phrasePhones] + WakeWordVariants
            .variants(forPhones: phrasePhones, depth: variantDepth)
            .map(\.phones)

        // The phrase has to open the utterance. Someone who says the agent's name in
        // the middle of a sentence is talking about it, not to it.
        var best = (closeness: 0.0, end: 0)
        let widest = min(heardWords.count, phraseWords.count + extraWordsAllowed)
        for length in 1...widest {
            let window = Array(heardWords[0..<length])
            let windowPhones = window.flatMap { phones(for: $0, lookup: lookup) }
            guard !windowPhones.isEmpty else { continue }
            let score = targets.map { closeness(windowPhones, $0) }.max() ?? 0
            if score > best.closeness { best = (score, length) }
        }

        let remainder = heardWords.dropFirst(best.end).joined(separator: " ")

        if best.closeness < acceptedCloseness {
            return Result(
                accepted: false,
                closeness: best.closeness,
                reason: "That did not sound like “\(phrase)”.",
                remainder: ""
            )
        }
        if best.closeness < certainCloseness,
           heardWords.count > phraseWords.count + extraWordsAllowed {
            return Result(
                accepted: false,
                closeness: best.closeness,
                reason: "It sounded close, but it came inside a longer sentence.",
                remainder: ""
            )
        }
        return Result(
            accepted: true,
            closeness: best.closeness,
            reason: "Heard “\(phrase)”.",
            remainder: remainder,
            matchedWords: best.end
        )
    }

    // MARK: - Phonetic distance

    /// 1 − (weighted edit distance ÷ the longer sequence). Substitutions inside a
    /// confusion class cost less than a swap across classes, which is what makes an
    /// accented vowel cheap and a different consonant expensive.
    static func closeness(_ lhs: [String], _ rhs: [String]) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        let distance = editDistance(lhs, rhs)
        let span = Double(max(lhs.count, rhs.count))
        return max(0, 1 - distance / span)
    }

    static func editDistance(_ lhs: [String], _ rhs: [String]) -> Double {
        var previous = (0...rhs.count).map(Double.init)
        var current = [Double](repeating: 0, count: rhs.count + 1)
        for i in 1...lhs.count {
            current[0] = Double(i)
            for j in 1...rhs.count {
                let swap = previous[j - 1] + substitutionCost(lhs[i - 1], rhs[j - 1])
                current[j] = min(swap, previous[j] + 1, current[j - 1] + 1)
            }
            swap(&previous, &current)
        }
        return previous[rhs.count]
    }

    /// 0 for the same phone ignoring stress, 0.4 within a confusion class, 1 otherwise.
    static func substitutionCost(_ lhs: String, _ rhs: String) -> Double {
        let left = bare(lhs)
        let right = bare(rhs)
        if left == right { return 0 }
        for group in confusable where group.contains(left) && group.contains(right) {
            return 0.4
        }
        return 1
    }

    private static func bare(_ phone: String) -> String {
        guard let last = phone.last, last.isNumber else { return phone }
        return String(phone.dropLast())
    }

    /// Phones that an accent routinely swaps for one another.
    private static let confusable: [Set<String>] = [
        // Front and central vowels — the “will / weel / well” family.
        ["IH", "IY", "EH", "EY", "AE"],
        // Back vowels.
        ["UH", "UW", "OW", "AO", "AA", "AH", "ER"],
        // Glides and liquids: the end of “will” lives here.
        ["W", "L", "R", "Y"],
        // /w/–/v/–/b/, a common L2 substitution.
        ["W", "V", "B"],
        // Nasals. “will” heard as “win” or “wim” lands here.
        ["N", "M", "NG", "L"],
        // Breathy onsets: a dropped /h/ against a glottal or velar.
        ["HH", "K", "G"],
        // Sibilants.
        ["S", "Z", "SH", "ZH", "CH", "JH"],
        ["T", "D", "TH", "DH", "P", "B"],
    ]

    // MARK: - Words

    static func words(in text: String) -> [String] {
        text.precomposedStringWithCanonicalMapping
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "’" })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// Phones for one word. A word with no lexicon entry still has to be comparable —
    /// otherwise an ASR mis-hearing would simply vanish from the distance — so it is
    /// spelled out, reading the common English digraphs as their phone first. These
    /// pseudo-phones are for scoring only and never reach `keywords.txt`, where
    /// invented ARPAbet aborts the sherpa dylib.
    static func phones(for word: String, lookup: (String) -> [String]?) -> [String] {
        let trimmed = word.trimmingCharacters(in: CharacterSet(charactersIn: "'’"))
        if let known = lookup(trimmed), !known.isEmpty { return known }
        if let known = lookup(word), !known.isEmpty { return known }
        return spelledOut(trimmed)
    }

    /// Letter-by-letter phones, longest digraph first. “ey” is the ASR's usual spelling
    /// of a dropped-/h/ “hey”, and reading it as two letters instead of one vowel was
    /// enough to push that attempt under the bar.
    static func spelledOut(_ word: String) -> [String] {
        let letters = Array(word.uppercased())
        var phones: [String] = []
        var index = 0
        while index < letters.count {
            if index + 1 < letters.count,
               let digraph = digraphs[String(letters[index...(index + 1)])] {
                phones.append(digraph)
                index += 2
                continue
            }
            phones.append(String(letters[index]))
            index += 1
        }
        return phones
    }

    private static let digraphs: [String: String] = [
        "EY": "EY", "AY": "EY", "AI": "EY", "EE": "IY", "EA": "IY", "IE": "IY",
        "OO": "UW", "OU": "AW", "OW": "OW", "OA": "OW", "OI": "OY", "OY": "OY",
        "TH": "TH", "SH": "SH", "CH": "CH", "PH": "F", "WH": "W", "CK": "K",
        "NG": "NG", "LL": "L", "SS": "S", "TT": "T", "EI": "EY",
    ]
}

import Foundation

/// Turns a spoken phrase into the phone+ppinyin line this zipformer KWS model wants.
///
/// The archive's own `keywords.txt` is ARPAbet for English (`HH EY1 … @HEY_NEXT`) and
/// pinyin-with-tones for Chinese. English phones come from the model's bundled `en.phone`
/// (CMU dictionary, ~126k words) — the same file sherpa's `text2token --lexicon` uses —
/// so a user can pick almost any English wake phrase once the keyword model is downloaded.
///
/// Unknown English words must **not** be written as spaced Latin letters: sherpa treats
/// those as ARPAbet tokens, aborts inside `SherpaOnnxCreateKeywordSpotter`, and the whole
/// Next Notes process exits with code 255 and no crash report.
enum WakeWordKeywords {
    /// `nil` when the phrase cannot be safely encoded for this model.
    static func line(for phrase: String) -> String? {
        guard let tokens = phones(forPhrase: phrase) else { return nil }
        return "\(tokens.joined(separator: " ")) @\(display(for: phrase))\n"
    }

    /// Every line this phrase should put in `keywords.txt`: the canonical pronunciation
    /// first, then the accent variants `tuning` asks for, each carrying its own
    /// `#threshold` so a looser match is still held to a stricter bar.
    ///
    /// All the lines share one `@display`, so whichever fires reports the same phrase.
    static func file(for phrase: String, tuning: WakeWordTuning) -> String? {
        guard let base = phones(forPhrase: phrase) else { return nil }
        let name = display(for: phrase)
        var text = "\(base.joined(separator: " ")) @\(name)\n"
        for variant in WakeWordVariants.variants(forPhones: base, depth: tuning.variantDepth) {
            let threshold = String(format: "%.2f", tuning.variantThreshold)
            text += "\(variant.phones.joined(separator: " ")) #\(threshold) @\(name)\n"
        }
        return text
    }

    /// The pronunciations this phrase is listening for, with the reason for each. Used
    /// by the Settings test so a person can see what the app is actually matching.
    static func pronunciations(for phrase: String, tuning: WakeWordTuning) -> [(phones: [String], rule: String)] {
        guard let base = phones(forPhrase: phrase) else { return [] }
        return [(base, "as written")]
            + WakeWordVariants.variants(forPhones: base, depth: tuning.variantDepth)
            .map { ($0.phones, $0.rule) }
    }

    /// A keywords file whose lines each carry their **own** display name, so a fired
    /// keyword says which pronunciation matched.
    ///
    /// Only the Settings test uses this, and only against a scratch path. The live
    /// file keeps one shared display name: the agent should not care how the phrase
    /// was pronounced, and the test should.
    static func diagnosticFile(
        for phrase: String,
        tuning: WakeWordTuning
    ) -> (text: String, rules: [String: String])? {
        let listed = pronunciations(for: phrase, tuning: tuning)
        guard !listed.isEmpty else { return nil }
        let name = display(for: phrase)
        var text = ""
        var rules: [String: String] = [:]
        for (index, entry) in listed.enumerated() {
            let tag = "\(name)__V\(index)"
            rules[tag] = entry.rule
            text += "\(entry.phones.joined(separator: " ")) @\(tag)\n"
        }
        return (text, rules)
    }

    /// Flat ARPAbet for the whole phrase, or nil if any word is unknown.
    static func phones(forPhrase phrase: String) -> [String]? {
        let words = phrase.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var tokens: [String] = []
        for word in words {
            guard let wordPhones = phones(for: word) else { return nil }
            tokens.append(contentsOf: wordPhones)
        }
        return tokens.isEmpty ? nil : tokens
    }

    private static func display(for phrase: String) -> String {
        phrase.replacingOccurrences(of: " ", with: "_").uppercased()
    }

    /// Whether every word has a phone encoding this spotter will accept without aborting.
    static func canEncode(_ phrase: String) -> Bool {
        line(for: phrase) != nil
    }

    /// English words with no lexicon entry. Used by Settings to name the problem.
    static func unknownWords(in phrase: String) -> [String] {
        phrase.split(whereSeparator: { $0.isWhitespace }).compactMap { word in
            phones(for: String(word)) == nil ? String(word) : nil
        }
    }

    private static func phones(for word: String) -> [String]? {
        // Preferred path: the downloaded CMU lexicon beside the keyword model.
        if let fromFile = WakeWordPhoneLexicon.phones(for: word) {
            return fromFile
        }
        // Tiny offline fallback so Settings validation and `--selftest-wake` still work
        // before the model is downloaded, and so the default “Hey Next” always encodes.
        let key = word
            .trimmingCharacters(in: .punctuationCharacters)
            .lowercased()
        if let known = fallbackLexicon[key] { return known }
        // Chinese custom phrases need partial-pinyin (pypinyin); we do not ship that, so
        // non-ASCII without a lexicon hit is refused rather than written as raw characters.
        return nil
    }

    /// The small built-in table on its own, for callers that want a pronunciation
    /// without the on-disk lexicon — the phonetic scorer runs before any download.
    static func fallbackPhones(for word: String) -> [String]? {
        fallbackLexicon[word.trimmingCharacters(in: .punctuationCharacters).lowercased()]
    }

    /// Enough English for the default phrase when `en.phone` is not on disk yet.
    private static let fallbackLexicon: [String: [String]] = [
        "hey": ["HH", "EY1"],
        "hi": ["HH", "AY1"],
        "hello": ["HH", "AH0", "L", "OW1"],
        "next": ["N", "EH1", "K", "S", "T"],
        "notes": ["N", "OW1", "T", "S"],
        "note": ["N", "OW1", "T"],
        "will": ["W", "IH1", "L"],
        "ok": ["OW1", "K", "EY1"],
        "okay": ["OW1", "K", "EY1"],
        "please": ["P", "L", "IY1", "Z"],
        "listen": ["L", "IH1", "S", "AH0", "N"],
        "wake": ["W", "EY1", "K"],
        "computer": ["K", "AH0", "M", "P", "Y", "UW1", "T", "ER0"],
    ]
}

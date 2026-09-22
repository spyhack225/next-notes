import Foundation

/// Accent-tolerant pronunciations of the wake phrase.
///
/// The keyword spotter matches a phone sequence, not a word. One canonical ARPAbet
/// spelling of “Hey Will” is `HH EY1 W IH1 L`, which is what a General American
/// speaker produces — and only that. Measured on 90 synthesised clips of the phrase
/// across 15 voices and three speech rates (`say -v … -r 150/190/230`), the single
/// canonical line fired on 49 of them, and on **none** of the six French-voiced clips.
/// That is the shape of the user's report: it works sometimes, and for some people
/// almost never.
///
/// These rules add the pronunciations an L2 English speaker actually produces. They
/// are deliberately few and ordered: every extra line competes for the decoder's beam,
/// so past a handful recall stops improving and false accepts keep climbing.
///
/// Every variant is built from phones the lexicon already produced. Nothing here
/// invents ARPAbet out of Latin letters — that is what used to abort the sherpa dylib.
enum WakeWordVariants {
    struct Variant: Sendable, Equatable {
        /// ARPAbet phones for this pronunciation.
        var phones: [String]
        /// Why this pronunciation exists, in words a person can read in Settings.
        var rule: String
    }

    /// Shortest sequence we will accept as a keyword. Three phones is short enough to
    /// fire on ordinary speech, so a rule that shrinks the phrase below four is dropped.
    static let minimumPhones = 4

    /// Accent-tolerant pronunciations of `base`, most useful first, excluding `base`.
    ///
    /// `depth` caps the list. Zero returns nothing — the conservative end of the
    /// Sensitivity slider spots only the canonical pronunciation.
    static func variants(forPhones base: [String], depth: Int) -> [Variant] {
        guard depth > 0, base.count >= minimumPhones else { return [] }

        var built: [Variant] = []
        var seen: Set<[String]> = [base]

        func add(_ phones: [String], _ rule: String) {
            guard phones.count >= minimumPhones, !seen.contains(phones) else { return }
            seen.insert(phones)
            built.append(Variant(phones: phones, rule: rule))
        }

        let noH = droppingLeadingH(base)
        add(noH, "dropped the h — “ey will”")
        add(droppingFinalLiquid(base), "softened the last consonant — “hey wi”")
        add(tensingLastVowel(base), "tense vowel — “hey weel”")
        add(loweringLastVowel(base), "open vowel — “hey well”")
        if noH != base {
            add(droppingFinalLiquid(noH), "dropped the h and the last consonant")
            add(tensingLastVowel(noH), "dropped the h, tense vowel")
        }
        add(replacingW(base, with: "V"), "w said as v")

        return Array(built.prefix(depth))
    }

    // MARK: - Rules

    /// French and many West-African Englishes drop word-initial /h/. This is the single
    /// most useful variant for the reported accent.
    static func droppingLeadingH(_ phones: [String]) -> [String] {
        guard phones.first == "HH" else { return phones }
        return Array(phones.dropFirst())
    }

    /// A final /l/ or /r/ is often vocalised away, so the phrase ends on its vowel.
    static func droppingFinalLiquid(_ phones: [String]) -> [String] {
        guard let last = phones.last, last == "L" || last == "R" else { return phones }
        return Array(phones.dropLast())
    }

    /// Languages without lax vowels substitute the nearest tense one: “will” → “weel”.
    static func tensingLastVowel(_ phones: [String]) -> [String] {
        mappingLastVowel(phones, using: ["IH": "IY", "EH": "EY", "UH": "UW", "AE": "EH", "AH": "AA"])
    }

    /// The other direction, which some speakers produce: “will” → “well”.
    static func loweringLastVowel(_ phones: [String]) -> [String] {
        mappingLastVowel(phones, using: ["IH": "EH", "IY": "IH", "EH": "AE", "UW": "UH"])
    }

    /// Some speakers realise English /w/ closer to /v/.
    static func replacingW(_ phones: [String], with replacement: String) -> [String] {
        guard let index = phones.firstIndex(of: "W") else { return phones }
        var copy = phones
        copy[index] = replacement
        return copy
    }

    /// Rewrites the last vowel, keeping its ARPAbet stress digit.
    private static func mappingLastVowel(_ phones: [String], using map: [String: String]) -> [String] {
        guard let index = phones.lastIndex(where: { isVowel($0) }) else { return phones }
        let phone = phones[index]
        let stress = phone.last.flatMap { $0.isNumber ? String($0) : nil } ?? ""
        let bare = stress.isEmpty ? phone : String(phone.dropLast())
        guard let replacement = map[bare] else { return phones }
        var copy = phones
        copy[index] = replacement + stress
        return copy
    }

    /// ARPAbet vowels are exactly the phones whose first two letters are a vowel nucleus.
    static func isVowel(_ phone: String) -> Bool {
        let bare = phone.hasSuffix("0") || phone.hasSuffix("1") || phone.hasSuffix("2")
            ? String(phone.dropLast())
            : phone
        return vowelNuclei.contains(bare)
    }

    private static let vowelNuclei: Set<String> = [
        "AA", "AE", "AH", "AO", "AW", "AY", "EH", "ER", "EY",
        "IH", "IY", "OW", "OY", "UH", "UW",
    ]
}

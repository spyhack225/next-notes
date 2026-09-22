import Foundation

/// The local wake-phrase record. Audio never leaves the device.
struct WakeWordConfiguration: Sendable, Equatable, Codable {
    var phrase: String
    var sensitivity: Double
    var listenWhileSleeping: Bool

    static let defaultPhrase = "Hey Next"

    @MainActor
    static var current: WakeWordConfiguration {
        WakeWordConfiguration(
            phrase: Settings.shared.wakePhrase,
            sensitivity: Settings.shared.wakeSensitivity,
            listenWhileSleeping: Settings.shared.listenWhileSleeping
        )
    }

    /// NFC, collapsed whitespace, no leading/trailing junk. A phrase that cannot be said
    /// is refused rather than written into the keyword file.
    static func normalize(_ raw: String) -> String {
        raw.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func validatedPhrase() -> String? {
        let phrase = Self.normalize(self.phrase)
        guard phrase.count >= 3, phrase.split(separator: " ").count <= 6 else { return nil }
        guard WakeWordKeywords.canEncode(phrase) else { return nil }
        return phrase
    }

    /// What the Sensitivity slider resolves to: threshold, how many accent variants to
    /// listen for, and how wide the decoder's beam has to be to hold them.
    var tuning: WakeWordTuning { .forSensitivity(sensitivity) }

    /// The local model writes the keyword into `keywords.txt`. Same shape, user-configurable.
    /// Falls back to the default phrase when the user's choice cannot be encoded safely —
    /// never invent ARPAbet from Latin letters (that aborts the sherpa dylib).
    ///
    /// One line per pronunciation: the phrase as written, then the accent-tolerant
    /// variants, which is what makes the phrase reachable for a speaker the canonical
    /// ARPAbet does not describe.
    var keywordsFileContents: String {
        let phrase = validatedPhrase() ?? Self.defaultPhrase
        return WakeWordKeywords.file(for: phrase, tuning: tuning)
            ?? WakeWordKeywords.file(for: Self.defaultPhrase, tuning: tuning)!
    }
}

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
        return phrase
    }

    /// Qwen writes the keyword into `keywords.txt`. Same shape, user-configurable.
    var keywordsFileContents: String {
        WakeWordKeywords.line(for: validatedPhrase() ?? Self.defaultPhrase)
    }
}

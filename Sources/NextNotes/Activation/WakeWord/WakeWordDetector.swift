import Foundation

/// Local phrase spotting. The keyword model is optional; the transcript spotter always
/// runs, which is what meeting command-capture needs.
enum WakeWordDetector {
    struct Detection: Sendable, Equatable {
        var phrase: String
        var remainder: String
        var confidence: Double
        var range: Range<String.Index>
    }

    static func spot(in text: String, configuration: WakeWordConfiguration) -> Detection? {
        guard let phrase = configuration.validatedPhrase() else { return nil }
        let haystack = text.precomposedStringWithCanonicalMapping
        let needle = phrase.precomposedStringWithCanonicalMapping
        guard let range = haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return nil
        }
        let after = haystack[range.upperBound...]
            .trimmingCharacters(in: CharacterSet(charactersIn: ",.!? ").union(.whitespacesAndNewlines))
        let tightness = Double(needle.count) / Double(max(haystack.count, 1))
        let confidence = min(1, 0.55 + tightness + (configuration.sensitivity - 0.5) * 0.2)
        return Detection(phrase: phrase, remainder: after, confidence: confidence, range: range)
    }

    /// Meeting command capture: only the microphone track can authorise, and only after
    /// the configured phrase.
    static func command(in segment: TranscriptSegment, configuration: WakeWordConfiguration) -> Detection? {
        guard segment.source == .mic else { return nil }
        return spot(in: segment.text, configuration: configuration)
    }
}

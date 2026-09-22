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
        if let range = haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) {
            let after = haystack[range.upperBound...]
                .trimmingCharacters(in: CharacterSet(charactersIn: ",.!? ").union(.whitespacesAndNewlines))
            let tightness = Double(needle.count) / Double(max(haystack.count, 1))
            let confidence = min(1, 0.55 + tightness + (configuration.sensitivity - 0.5) * 0.2)
            return Detection(phrase: phrase, remainder: after, confidence: confidence, range: range)
        }
        return spotPhonetically(in: haystack, phrase: phrase, configuration: configuration)
    }

    /// The transcript rarely spells the phrase the way it was configured. This user's
    /// “Hey Will” came back from the dictation ASR as “hey we need”, which is not a
    /// substring of anything, so requiring the literal text meant the meeting and
    /// dictation wake paths could never fire for him at all.
    ///
    /// Only an utterance that *opens* with something phonetically close counts, and
    /// only a short one — the rules live in `WakePhraseConfirmation`, so the same
    /// judgement backs the Settings test and the spotter's second stage.
    private static func spotPhonetically(
        in haystack: String,
        phrase: String,
        configuration: WakeWordConfiguration
    ) -> Detection? {
        let result = WakePhraseConfirmation.check(transcript: haystack, phrase: phrase)
        guard result.accepted, result.matchedWords > 0 else { return nil }
        guard let range = rangeOfLeadingWords(result.matchedWords, in: haystack) else { return nil }
        let after = haystack[range.upperBound...]
            .trimmingCharacters(in: CharacterSet(charactersIn: ",.!? ").union(.whitespacesAndNewlines))
        // A sound-alike is never as sure as the words themselves; cap it below the
        // literal path so the Settings test can still tell them apart.
        let confidence = min(0.95, result.closeness)
        return Detection(phrase: phrase, remainder: after, confidence: confidence, range: range)
    }

    /// Range covering the first `count` words of `text`, keeping its original spelling.
    private static func rangeOfLeadingWords(_ count: Int, in text: String) -> Range<String.Index>? {
        var seen = 0
        var index = text.startIndex
        var end: String.Index?
        var insideWord = false
        while index < text.endIndex {
            let isWordCharacter = text[index].isLetter || text[index] == "'" || text[index] == "’"
            if isWordCharacter, !insideWord {
                insideWord = true
                seen += 1
            } else if !isWordCharacter, insideWord {
                insideWord = false
                if seen == count { end = index; break }
            }
            index = text.index(after: index)
        }
        if end == nil, insideWord, seen == count { end = text.endIndex }
        guard let end else { return nil }
        return text.startIndex..<end
    }

    /// Meeting command capture: only the microphone track can authorise, and only after
    /// the configured phrase.
    static func command(in segment: TranscriptSegment, configuration: WakeWordConfiguration) -> Detection? {
        guard segment.source == .mic else { return nil }
        return spot(in: segment.text, configuration: configuration)
    }
}

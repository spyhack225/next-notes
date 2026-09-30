import Foundation

/// The cleanup pass between raw transcription and injection.
///
/// This is where Wispr Flow actually earns its keep — raw STT output is full of filler
/// words, missing punctuation, and spoken corrections. Swapping in an LLM-backed
/// formatter (Apple Foundation Models or S1-mini, both on-device)
/// is the point of keeping this behind a protocol.
protocol TextFormatter: Sendable {
    func format(_ raw: String) async -> String
}

/// Deterministic, zero-latency cleanup. Good enough to be useful on its own and always
/// the fallback when a model-backed formatter is unavailable or times out.
struct RuleBasedFormatter: TextFormatter {
    /// Standalone filler words, stripped only when surrounded by word boundaries.
    /// "heu"/"euh" are the French hesitation equivalents of "um"/"uh".
    private static let fillers = ["um", "uh", "erm", "uhm", "hmm", "mhm", "heu", "euh"]

    /// Words where an immediate double is never intentional emphasis in dictation:
    /// articles, prepositions, pronouns, auxiliaries, conjunctions and question words.
    /// Content-word doubles ("very very", "no no", "ha ha") are deliberately kept —
    /// they carry emphasis or emotion, and collapsing them would remove meaning.
    /// A triple repeat of any word ("the the the", "how how how") is always a stutter:
    /// measured in runs.jsonl 2026-09-20T15:17:32Z, 2026-09-23T03:10:18Z and
    /// 2026-09-29T15:10:48Z, where the model left all three in place.
    private static let repeatableFunctionWords = [
        "the", "a", "an",
        "to", "of", "in", "on", "at", "by", "with", "from", "as", "into", "onto",
        "over", "under", "between", "before", "after", "during", "without", "within",
        "against", "across", "around", "along", "upon", "since", "until", "via", "per",
        "and", "or", "but", "nor", "for", "yet",
        "i", "me", "my", "we", "us", "our", "you", "your", "he", "him", "his",
        "she", "her", "it", "its", "they", "them", "their",
        "is", "are", "was", "were", "be", "been", "being", "am",
        "have", "has", "had", "do", "does", "did",
        "will", "would", "shall", "should", "may", "might", "must", "can", "could",
        "that", "this", "these", "those", "which", "who", "whom", "whose", "what",
        "how", "where", "when", "why", "whether",
        "there", "here", "then", "than", "if", "else",
    ]

    /// Spoken punctuation people actually use mid-dictation.
    private static let spokenPunctuation: [(String, String)] = [
        ("new paragraph", "\n\n"),
        ("new line", "\n"),
        ("open paren", " ("),
        ("close paren", ") "),
    ]

    func format(_ raw: String) async -> String {
        apply(raw)
    }

    /// The same pass, without the hop. The protocol has no reason to be async and the work
    /// never suspends, so the incremental-cleanup session — which runs this on every partial
    /// while the key is still down and needs the answer inside an actor — calls it directly.
    /// One implementation, so the text a pre-cleaned group is matched against is written by
    /// the same code as the text the key-up pass matches it against. (D-12.)
    func apply(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return text }

        text = stripFillers(from: text)
        text = applySpokenPunctuation(to: text)
        text = collapseRepeats(in: text)
        text = collapseWhitespace(in: text)
        text = capitalizeSentences(in: text)
        text = ensureTerminalPunctuation(in: text)

        return text
    }

    private func stripFillers(from text: String) -> String {
        var result = text
        for filler in Self.fillers {
            // Match the filler as a whole word, plus a trailing comma if the ASR added one.
            let pattern = "(?i)(?<![\\w'])\(filler)\\b,?"
            result = result.replacingOccurrences(
                of: pattern,
                with: "",
                options: .regularExpression
            )
        }
        return result
    }

    private func applySpokenPunctuation(to text: String) -> String {
        var result = text
        for (phrase, replacement) in Self.spokenPunctuation {
            result = result.replacingOccurrences(
                of: "(?i)\\b\(phrase)\\b",
                with: replacement,
                options: .regularExpression
            )
        }
        return result
    }

    /// Collapses stuttered repeats left by the recogniser, after fillers are gone.
    ///
    /// Two passes, both strictly subtractive and both confined to one line, so no
    /// sentence boundary is ever crossed and no emphasis is ever touched:
    /// - three or more of any word ("the the the", "how how how") collapse to one;
    /// - two of a function word ("we we", "to to", "the the") collapse to one.
    /// A double content word ("very very", "no no") is kept on purpose.
    private func collapseRepeats(in text: String) -> String {
        var result = text.replacingOccurrences(
            of: "(?i)\\b([\\w']+)(?:[ \\t]+\\1){2,}\\b",
            with: "$1",
            options: .regularExpression
        )
        let words = Self.repeatableFunctionWords.joined(separator: "|")
        result = result.replacingOccurrences(
            of: "(?i)\\b(\(words))(?:[ \\t]+\\1)+\\b",
            with: "$1",
            options: .regularExpression
        )
        return result
    }

    private func collapseWhitespace(in text: String) -> String {
        text
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " +([,.!?;:])", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func capitalizeSentences(in text: String) -> String {
        var result = ""
        var capitalizeNext = true

        for character in text {
            if capitalizeNext, character.isLetter {
                result.append(Character(character.uppercased()))
                capitalizeNext = false
            } else {
                result.append(character)
                if ".!?\n".contains(character) { capitalizeNext = true }
            }
        }
        return result
    }

    private func ensureTerminalPunctuation(in text: String) -> String {
        guard let last = text.last, last.isLetter || last.isNumber else { return text }
        return text + "."
    }

    /// Pinned without a model: stutter collapses, emphasis survives, fillers go.
    /// Runs inside `--selftest-cleanup-router`, which needs no model and no permission.
    static func selfTestFailures() -> [String] {
        let formatter = RuleBasedFormatter()
        let cases: [(id: String, input: String, want: String)] = [
            ("triple-any", "improved the the the quality", "Improved the quality."),
            (
                "function-doubles",
                "we we need to to check the the database connection again",
                "We need to check the database connection again."
            ),
            (
                "triple-how",
                "how how how can we make sure",
                "How can we make sure."
            ),
            (
                "filler-then-repeat",
                "read the uh the internal agents",
                "Read the internal agents."
            ),
            ("french-filler", "heu I have done the documentation", "I have done the documentation."),
            // Emotion and emphasis are not stutter and must survive.
            ("emphasis-kept", "that was very very good", "That was very very good."),
            ("no-no-kept", "No no, I disagree", "No no, I disagree."),
            // Repeats across a sentence boundary are a restart for the model, not a
            // word stutter: collapsing them here would join two sentences.
            ("restart-kept", "It started, it started the meeting", "It started, it started the meeting."),
        ]
        var failures: [String] = []
        for test in cases {
            let got = formatter.apply(test.input)
            if got != test.want {
                failures.append(
                    "RuleBasedFormatter.\(test.id): got \(got.debugDescription), "
                        + "want \(test.want.debugDescription)"
                )
            }
        }
        return failures
    }
}

/// No-op formatter, for comparing raw engine output against the cleanup pass.
struct PassthroughFormatter: TextFormatter {
    func format(_ raw: String) async -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

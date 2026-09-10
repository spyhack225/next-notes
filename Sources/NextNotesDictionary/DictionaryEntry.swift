import Foundation

/// One thing the dictionary knows.
///
/// Two kinds, because the two jobs are genuinely different:
///
/// - `.term` — a word or phrase the engine should know exists: "Anthropic", "Vercel".
///   Feeds engine biasing only; it has no "wrong" spelling to correct.
/// - `.correction` — a mapping: when you hear X, write Y. "cloud code" → "Claude Code".
///   Feeds both biasing (on Y, the correct form) and the correction pass (X → Y).
public struct DictionaryEntry: Identifiable, Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case term
        case correction
    }

    public var id: UUID
    public var kind: Kind

    /// The correct text. For `.term` this is the word itself; for `.correction` it's Y —
    /// what gets written. Either way this is what the engine gets biased toward.
    public var write: String

    /// For `.correction` only: the X in "when you hear X". Empty for `.term`.
    public var hear: String

    /// Disabled entries stay in the file but stop affecting anything, so you can test
    /// whether a rule is helping without deleting it.
    public var isEnabled: Bool

    public init(id: UUID = UUID(), kind: Kind, write: String, hear: String = "", isEnabled: Bool = true) {
        self.id = id
        self.kind = kind
        self.write = write
        self.hear = hear
        self.isEnabled = isEnabled
    }

    public static func term(_ word: String) -> DictionaryEntry {
        DictionaryEntry(kind: .term, write: word)
    }

    public static func correction(hear: String, write: String) -> DictionaryEntry {
        DictionaryEntry(kind: .correction, write: write, hear: hear)
    }

    /// How this entry reads in the plain-text file.
    public var fileLine: String {
        let body = kind == .correction ? "\(hear) -> \(write)" : write
        return isEnabled ? body : "# off: \(body)"
    }
}

/// A reason an entry looks likely to fire on text you didn't mean it to.
///
/// Surfaced in the UI when an entry is added — the spec's "warn me if an entry looks like
/// it would match something common". Never blocks; you may genuinely want to rewrite a
/// common word, and it's your dictionary.
public struct DictionaryWarning: Identifiable, Sendable {
    public var id: String { message }
    public let message: String

    /// Ordinary English words that would fire constantly if used as a whole trigger.
    /// Deliberately short — this catches the obvious foot-guns, not every possible one.
    private static let common: Set<String> = [
        "a", "about", "all", "also", "and", "any", "are", "as", "at", "back", "be", "because",
        "but", "by", "call", "can", "case", "check", "class", "close", "cloud", "code", "come",
        "could", "data", "day", "did", "do", "does", "down", "each", "even", "file", "find",
        "first", "for", "from", "get", "give", "go", "good", "great", "group", "had", "has",
        "have", "he", "her", "here", "him", "his", "how", "if", "in", "into", "is", "it",
        "its", "just", "key", "know", "like", "line", "list", "look", "make", "man", "many",
        "may", "me", "more", "most", "my", "need", "new", "no", "not", "now", "number", "of",
        "off", "on", "one", "only", "open", "or", "other", "our", "out", "over", "page",
        "part", "people", "point", "put", "read", "right", "run", "said", "same", "say",
        "see", "set", "she", "should", "show", "side", "so", "some", "state", "still", "such",
        "take", "team", "test", "than", "that", "the", "their", "them", "then", "there",
        "these", "they", "thing", "think", "this", "time", "to", "two", "type", "up", "us",
        "use", "user", "very", "want", "was", "way", "we", "well", "were", "what", "when",
        "where", "which", "who", "will", "with", "word", "work", "would", "year", "you",
        "your",
    ]

    /// - Returns: warnings for `entry`, or empty if it looks safe.
    public static func check(_ entry: DictionaryEntry) -> [DictionaryWarning] {
        // Only the trigger side can misfire. A `.term` is never matched against text.
        guard entry.kind == .correction else { return [] }

        let trigger = entry.hear.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trigger.isEmpty else { return [] }

        var warnings: [DictionaryWarning] = []
        let words = trigger.lowercased().split(whereSeparator: { $0 == " " || $0 == "-" })

        if words.count == 1, let only = words.first {
            if common.contains(String(only)) {
                warnings.append(DictionaryWarning(
                    message: "“\(trigger)” is an ordinary word. This will rewrite every use of it, "
                        + "not just the ones you mean. Consider a longer phrase."
                ))
            } else if only.count <= 3 {
                warnings.append(DictionaryWarning(
                    message: "“\(trigger)” is very short and will match often. Consider a longer phrase."
                ))
            }
        }

        if entry.write.trimmingCharacters(in: .whitespacesAndNewlines)
            .caseInsensitiveCompare(trigger) == .orderedSame {
            warnings.append(DictionaryWarning(
                message: "This rewrites “\(trigger)” to itself, so it will never change anything."
            ))
        }

        return warnings
    }
}

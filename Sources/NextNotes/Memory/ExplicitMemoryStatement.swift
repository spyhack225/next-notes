import Foundation

/// P4-07 groundwork: bounded recognition of facts in a committed, addressed user turn.
/// This function supplies neither provenance nor permission and performs no write.
/// Callers must exclude meeting/remote/tool text and use the existing guarded memory writer.
enum ExplicitMemoryStatement {
    /// `userName` is retained for the roadmap's interface. It is not evidence of a fact
    /// and never substitutes a name into a sentence the person did not say.
    static func extract(_ text: String, userName: String) -> [String] {
        _ = userName
        // Quoted/reported material is not a statement by its enclosing speaker. Apostrophes
        // inside contractions and names are ordinary text; quotation marks are refused.
        guard !text.contains(where: { "\"“”«»`".contains($0) }),
              !text.contains("‘"),
              text.range(of: #"(?:^|\s)'[^']+'(?:\s|$|[.!?])"#,
                         options: .regularExpression) == nil else { return [] }

        // Reuse the existing action producer on the entire utterance, before splitting.
        // A compound command it refuses must not be converted into partial save actions.
        if !hasExcludedWords(text), let call = AgentDirectIntent.memorySaveCall(text),
           let payload = call.arguments["text"], (5...160).contains(payload.count) {
            return [punctuated(payload)]
        }
        if matches(#"^(?:\s*)(?:please\s+)?(?:(?:can|could|would)\s+you\s+)?remember\b"#, text) {
            return []
        }

        var facts: [String] = []
        for sentence in sentences(text) {
            guard !sentence.contains("?"), !hasExcludedWords(sentence) else { continue }
            // Split only before another supported subject. Names such as Research and
            // Development stay intact; arbitrary trailing objectives never become facts.
            let clauses = sentence.replacingOccurrences(
                of: #"\s+and\s+(?=(?:i(?:['’]m|\s+am|\s+live|\s+work)|my\s+|call\s+me\s+))"#,
                with: "\n", options: [.regularExpression, .caseInsensitive])
            for raw in clauses.split(separator: "\n") {
                let clause = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
                guard let fact = fact(in: clause), !facts.contains(fact) else { continue }
                facts.append(fact)
            }
        }
        return facts
    }

    private static func fact(in raw: String) -> String? {
        let clause = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".! "))
        guard !clause.isEmpty, clause.count <= 300, !hasExcludedWords(clause),
              clause.range(of: #"\b(?:then|but|also|according|says|said)\b"#,
                           options: [.regularExpression, .caseInsensitive]) == nil else { return nil }

        if let name = capture(#"^call\s+me\s+(.+)$"#, clause), isName(name) {
            // The literal imperative cannot pass MemoryGuard.isDeclarative. Only the
            // subject changes; the supplied name remains exact and provenance-checked.
            return "The user's name is \(name)."
        }
        if let name = capture(#"^my\s+name\s+is\s+(.+)$"#, clause), isName(name) {
            return punctuated(clause)
        }
        let relations = "brother|sister|wife|husband|partner|dad|father|mum|mom|mother|son|daughter|boss|manager|assistant|cofounder|co-founder"
        if let name = capture("^my\\s+(?:\(relations))\\s+is\\s+(.+)$", clause), isName(name) {
            return punctuated(clause)
        }
        if matches(#"^i(?:['’]m|\s+am)\s+(?:(?:the|a|an)\s+)?[\p{L}][\p{L}\p{N} &'’/-]*\s+(?:of|at)\s+[\p{L}\p{N}][\p{L}\p{N} &'’/-]*$"#, clause),
           safePayload(clause) { return punctuated(clause) }
        if matches(#"^i\s+(?:live\s+in|work\s+(?:at|for))\s+[\p{L}\p{N}][\p{L}\p{N} &'’/-]*$"#, clause),
           safePayload(clause) { return punctuated(clause) }
        return nil
    }

    private static func safePayload(_ clause: String) -> Bool {
        // An additional pronoun/objective needs interpretation; leave it to the planner.
        !matches(#"\b(?:you|your|he|she|they|we|our)\b|\band\s+(?:send|open|delete|remember|book|tell|run)\b"#, clause)
    }

    private static func hasExcludedWords(_ text: String) -> Bool {
        matches(#"\b(?:not|no|never|if|unless|when|maybe|might|would|could|was|were)\b|n['’]t\b|\bused\s+to\b"#, text)
    }

    private static func isName(_ text: String) -> Bool {
        let words = text.split(separator: " ")
        guard (1...4).contains(words.count), text.count <= 100 else { return false }
        // A capitalized proper name is required, rather than treating "happy" or
        // "going to school" as somebody's name. Lowercase ASR names remain unsupported.
        return words.allSatisfy { word in
            word.first?.isUppercase == true && word.allSatisfy {
                $0.isLetter || $0 == "'" || $0 == "’" || $0 == "-"
            }
        }
    }

    private static func punctuated(_ text: String) -> String {
        var fact = text.trimmingCharacters(in: CharacterSet(charactersIn: ".! "))
        if let first = fact.first { fact.replaceSubrange(fact.startIndex...fact.startIndex, with: String(first).uppercased()) }
        return fact + "."
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func capture(_ pattern: String, _ text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    private static func sentences(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for index in text.indices {
            let character = text[index]
            current.append(character)
            let next = text.index(after: index)
            // An internal dot is part of the payload, not a sentence end. The bounded
            // fact grammar refuses it; do not silently truncate an organisation/domain.
            let terminalPeriod = character == "."
                && (next == text.endIndex || text[next].isWhitespace)
            if terminalPeriod || "!?;\n\r".contains(character) {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}

import Foundation

/// Transcript-only matching: normalization is never persisted as meeting evidence.
/// Indices remain in the original string so the proposal owns speech, not model prose.
enum MeetingEvidenceMatcher {
    private struct Unit { let text: Character; let range: Range<String.Index> }
    private struct Token { let value: String; let range: Range<String.Index> }
    private static let stopWords: Set<String> = ["a", "an", "the", "can", "could", "would", "you", "me", "we", "i", "it", "is", "are", "to", "of", "by", "for", "and", "please"]

    static func normalize(_ value: String) -> String { String(units(value).map(\.text)) }

    static func match(quote: String, in transcript: String) -> String? {
        let normalized = normalize(quote)
        guard normalized.count >= 12 else { return nil }
        // Literal speech already owns its punctuation. Preserve the complete original
        // span before normalized matching so existing proposal consumers keep it exactly.
        if let range = transcript.range(of: quote, options: .caseInsensitive),
           negationCompatible(quote: quote, range: range, transcript: transcript) {
            return String(transcript[range])
        }
        let source = units(transcript)
        let body = String(source.map(\.text))
        if let found = body.range(of: normalized) {
            let lower = body.distance(from: body.startIndex, to: found.lowerBound)
            let upper = body.distance(from: body.startIndex, to: found.upperBound)
            let range = source[lower].range.lowerBound..<source[upper - 1].range.upperBound
            if negationCompatible(quote: quote, range: range, transcript: transcript) {
                return String(transcript[range])
            }
        }
        // Only content tokens take part in the 90% LCS. Punctuation (including hyphens)
        // delimits tokens; apostrophes remain part of a word. The maximum source window
        // is quote content length +25%, never an unbounded whole-transcript alignment.
        let quoteWords = tokens(quote).map(\.value)
        let sourceWords = tokens(transcript)
        if !quoteWords.isEmpty, sourceWords.count >= quoteWords.count {
            for start in 0...(sourceWords.count - quoteWords.count) {
                guard Array(sourceWords[start..<(start + quoteWords.count)].map(\.value)) == quoteWords else { continue }
                let range = sourceWords[start].range.lowerBound..<sourceWords[start + quoteWords.count - 1].range.upperBound
                if negationCompatible(quote: quote, range: range, transcript: transcript) { return String(transcript[range]) }
            }
        }
        let wanted = tokens(quote).filter { !stopWords.contains($0.value) }.map(\.value)
        let speech = tokens(transcript).filter { !stopWords.contains($0.value) }
        guard !wanted.isEmpty, speech.count >= Int(ceil(Double(wanted.count) * 0.9)) else { return nil }
        let required = Int(ceil(Double(wanted.count) * 0.9))
        let width = max(wanted.count, Int(floor(Double(wanted.count) * 1.25)))
        let firstPossible = Set(wanted.prefix(wanted.count - required + 1))
        for start in speech.indices where firstPossible.contains(speech[start].value) {
            let end = min(speech.count, start + width)
            var row = Array(repeating: 0, count: wanted.count + 1)
            for index in start..<end {
                var diagonal = 0
                for column in 1...wanted.count {
                    let previous = row[column]
                    row[column] = speech[index].value == wanted[column - 1]
                        ? diagonal + 1 : max(row[column], row[column - 1])
                    diagonal = previous
                }
                if row[wanted.count] >= required {
                    let range = speech[start].range.lowerBound..<speech[index].range.upperBound
                    if negationCompatible(quote: quote, range: range, transcript: transcript) {
                        return String(transcript[range])
                    }
                }
            }
        }
        return nil
    }

    private static func canonical(_ character: Character) -> String {
        switch character {
        case "’", "‘", "ʼ": return "'"
        case "“", "”", "«", "»": return "\""
        default: return String(character).lowercased()
        }
    }

    private static func units(_ text: String) -> [Unit] {
        var result: [Unit] = []
        var space = false
        for index in text.indices {
            let next = text.index(after: index)
            let value = canonical(text[index])
            if text[index].isWhitespace {
                if !result.isEmpty { space = true }
                continue
            }
            let accepted = value.filter { $0.isLetter || $0.isNumber || $0 == "'" }
            guard !accepted.isEmpty else { continue }
            if space { result.append(Unit(text: " ", range: index..<next)); space = false }
            for character in accepted { result.append(Unit(text: character, range: index..<next)) }
        }
        return result
    }

    private static func tokens(_ text: String) -> [Token] {
        var result: [Token] = []
        var start: String.Index?
        var word = ""
        for index in text.indices {
            let value = canonical(text[index])
            if value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "'" }) {
                if start == nil { start = index }
                word += value
            } else if let lower = start {
                result.append(Token(value: word, range: lower..<index)); start = nil; word = ""
            }
        }
        if let lower = start { result.append(Token(value: word, range: lower..<text.endIndex)) }
        return result
    }

    private static func hasNegation(_ text: String) -> Bool {
        tokens(text).contains { ["not", "never", "no"].contains($0.value) || $0.value.hasSuffix("n't") }
    }

    private static func negationCompatible(quote: String, range: Range<String.Index>, transcript: String) -> Bool {
        // An omitted negation before an exact substring is as unsafe as one omitted by
        // LCS. Inspect the containing speech clause; never substitute the brief/notes.
        let delimiters: Set<Character> = [".", "!", "?", "\n", ";"]
        var lower = range.lowerBound
        while lower > transcript.startIndex {
            let previous = transcript.index(before: lower)
            if delimiters.contains(transcript[previous]) { break }
            lower = previous
        }
        var upper = range.upperBound
        while upper < transcript.endIndex && !delimiters.contains(transcript[upper]) { upper = transcript.index(after: upper) }
        return hasNegation(String(transcript[lower..<upper])) == hasNegation(quote)
    }
}

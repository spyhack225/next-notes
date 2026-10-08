import Foundation
enum PrefixContract {
    static func remainder(of text: String, afterPrefix prefix: String) -> String? {
        let target = Array(squeeze(prefix))
        if target.isEmpty { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        var matched = 0
        var index = text.startIndex
        // Match the same whitespace contract squeeze() applies to the saved prefix.
        while index < text.endIndex, text[index].isWhitespace {
            index = text.index(after: index)
        }
        while index < text.endIndex, matched < target.count {
            let character = text[index]
            if character.isWhitespace || character.isNewline {
                guard target[matched] == " " else { return nil }
                repeat { index = text.index(after: index) }
                while index < text.endIndex && text[index].isWhitespace
                matched += 1
                continue
            }
            guard character == target[matched] else { return nil }
            matched += 1
            index = text.index(after: index)
        }
        guard matched == target.count else { return nil }
        // A prefix can finish at a word boundary; it cannot consume part of a revised word.
        if index < text.endIndex, let last = target.last,
           (last.isLetter || last.isNumber),
           (text[index].isLetter || text[index].isNumber) { return nil }
        return String(text[index...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One space per run of whitespace, and no leading or trailing space.
    private static func squeeze(_ text: String) -> String {
        var out = ""
        for character in text {
            if character.isWhitespace || character.isNewline {
                if !out.isEmpty, !out.hasSuffix(" ") { out.append(" ") }
            } else {
                out.append(character)
            }
        }
        while out.hasSuffix(" ") { out.removeLast() }
        return out
    }

}

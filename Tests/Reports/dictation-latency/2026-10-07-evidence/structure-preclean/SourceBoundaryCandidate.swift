import Foundation
enum SourceBoundaryCandidate {
    static func end(of prefix: String, in text: String, from start: String.Index) -> String.Index? {
        let target = Array(squeeze(prefix))
        if target.isEmpty { return start }
        var matched = 0
        var index = start
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
        return index
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


    // Source positions are validated before any model answer is joined. No find/search
    // through revised text, target normalization, additional model request or await.
    static func separators(in text: String, groups: [String]) -> [String]? {
        var index = text.startIndex
        var separators: [String] = []
        for (offset, group) in groups.enumerated() {
            let whitespace = index
            while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
            if offset > 0 {
                let gap = String(text[whitespace..<index])
                separators.append(gap.contains("\n") ? gap : " ")
            }
            guard let matchedEnd = Self.end(of: group, in: text, from: index) else { return nil }
            index = matchedEnd
        }
        let whitespace = index
        while index < text.endIndex, text[index].isWhitespace { index = text.index(after: index) }
        let gap = String(text[whitespace..<index])
        separators.append(gap.contains("\n") ? gap : " ")
        return separators
    }
    static func joined(_ pieces: [String], separators: [String]) -> String {
        var out = ""
        for (offset, piece) in pieces.enumerated() {
            guard !piece.isEmpty else { continue }
            if !out.isEmpty, !out.hasSuffix("\n") {
                out += separators.indices.contains(offset - 1) ? separators[offset - 1] : " "
            }
            out += piece
        }
        return out
    }
}

import Foundation

/// Splits a long transcript into sentence groups, so a minute of speech is several small
/// model calls instead of one that misses its deadline.
///
/// ## The failure this removes
///
/// Both cleanup engines have a ceiling and both used to hand the whole utterance to it at
/// once. `S1MiniFormatter` capped every transcript at eight seconds regardless of length, and
/// `S1MiniRuntime` refuses an input over 1,600 tokens outright; `FoundationModelFormatter`
/// grows its deadline with the input but stops at twelve seconds and 1,200 response tokens.
/// Measured on this Mac from `metrics.jsonl`: a 19.6 s dictation cleaned in 3.2 s and a 98.3 s
/// one took 7.1 s — so a two-minute hold was already inside a second of the S1 ceiling, and
/// past it the whole pass fails and the *raw* transcript is typed. That is exactly the
/// "long dictations come out with ASR errors in them" report: not a worse cleanup, no cleanup.
///
/// Giving up is also the wrong shape of failure. A transcript is a sequence of sentences and
/// cleanup is local to each of them, so losing one group to a timeout should cost that
/// paragraph and not the utterance.
///
/// ## Why sentence groups and not a fixed token count
///
/// Cutting mid-sentence would hand the model half a clause and ask it to repair the grammar
/// of something that is not a sentence — which is how a chunked pass invents an ending. The
/// split is therefore always on a sentence terminator, and a single sentence longer than the
/// budget is passed whole rather than cut.
enum SentenceChunker {

    /// Groups of whole sentences, each at most `maxWords` words unless one sentence is
    /// longer than that on its own.
    static func chunks(_ text: String, maxWords: Int) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard wordCount(trimmed) > maxWords else { return [trimmed] }

        var groups: [String] = []
        var current = ""
        var currentWords = 0

        for sentence in sentences(in: trimmed) {
            let words = wordCount(sentence)
            if currentWords > 0, currentWords + words > maxWords {
                groups.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
                currentWords = 0
            }
            // A paragraph break inside the transcript is kept, so the model is not handed a
            // run-on where the speaker changed topic.
            if !current.isEmpty { current += sentence.hasPrefix("\n") ? "" : " " }
            current += sentence
            currentWords += words
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { groups.append(tail) }
        return groups
    }

    static func wordCount(_ text: String) -> Int {
        text.split { $0.isWhitespace || $0.isNewline }.count
    }

    /// Sentence split that keeps the terminator, and keeps a blank line as its own boundary.
    ///
    /// Shared with `CleanupGuard.salvage`, which judges a rejected answer sentence by
    /// sentence: the two must agree on where a sentence ends or the pairs it lines up are
    /// not pairs.
    static func sentences(in text: String) -> [String] {
        // UTF-8 offsets are grapheme boundaries for ASCII except CRLF. Preserve
        // the existing grapheme path for that pair and every non-ASCII passage.
        guard !text.utf8.contains(where: { $0 >= 128 || $0 == 13 }) else {
            return graphemeSentences(in: text)
        }
        let bytes = text.utf8
        var result: [String] = []
        var start = bytes.startIndex
        var index = start
        var previousNewline = false
        while index < bytes.endIndex {
            let byte = bytes[index]
            let next = bytes.index(after: index)
            let boundary: Bool
            if byte == 46 || byte == 33 || byte == 63 {
                if next == bytes.endIndex {
                    boundary = true
                } else {
                    let following = bytes[next]
                    boundary = following == 32 || (9...13).contains(following)
                }
            } else {
                boundary = byte == 10 && previousNewline
            }
            if boundary {
                result.append(String(text[start..<next]))
                start = next
                previousNewline = false
            } else {
                previousNewline = byte == 10
            }
            index = next
        }
        let tail = text[start...]
        if !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(String(tail))
        }
        return result.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func graphemeSentences(in text: String) -> [String] {
        var result: [String] = []
        var current = ""
        let iterator = Array(text)
        var index = 0
        while index < iterator.count {
            let character = iterator[index]
            current.append(character)
            if ".!?".contains(character) {
                // Not a boundary inside "3.5" or "e.g." — a terminator is only one when what
                // follows is whitespace or the end.
                let next = index + 1 < iterator.count ? iterator[index + 1] : " "
                if next.isWhitespace || next.isNewline {
                    result.append(current)
                    current = ""
                }
            } else if character == "\n", current.hasSuffix("\n\n") {
                result.append(current)
                current = ""
            }
            index += 1
        }
        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(current)
        }
        return result.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

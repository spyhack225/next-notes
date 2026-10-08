import Foundation
enum LiveDictationText {
    /// Whether there is anything worth opening a card for. Whitespace is not words.
    static func hasWords(_ transcript: String) -> Bool {
        !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The end of `transcript`, at most `limit` characters plus a leading ellipsis, opening on
    /// a whole word where one starts close enough to the cut.
    ///
    /// Shortened here rather than only with `.truncationMode(.head)`: head truncation of a
    /// multi-line `Text` is the layout engine's call, and a two-line card has to show the
    /// newest words whatever it decides. The view still truncates from the head as the
    /// backstop for a run of wide glyphs.
    static func tail(
        _ transcript: String,
        limit: Int,
        slack: Int = DS.LiveText.wordBoundarySlack
    ) -> String {
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard limit > 0 else { return text }
        var cut = text.suffix(limit)
        guard cut.startIndex != text.startIndex else { return text }
        if let space = cut.prefix(slack).firstIndex(where: \.isWhitespace) {
            cut = cut[cut.index(after: space)...]
        }
        return "\u{2026}" + cut.trimmingCharacters(in: .whitespaces)
    }
}

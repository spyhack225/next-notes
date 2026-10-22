import Foundation

/// What a hold is doing right now, in the words both heads-up surfaces use.
///
/// The bottom capsule and the notch island used to answer this separately and differently:
/// the capsule said "Finishing…" for everything after key-up, the island said
/// "Transcribing" — and neither could say that the words were already heard and only being
/// tidied, because the controller did not publish which half of its tail it was in. It now
/// does (`DictationController.finishingStage`), and this is the one mapping from that to a
/// label and an orb, so the two surfaces cannot drift apart again.
///
/// Each orb is the table's own meaning: `listening` while one voice is heard, `working`
/// while audio is turned into text, `composing` while the model writes the cleaned-up
/// sentence. Red is not here — the recording dot is drawn beside the orb by each surface.
enum LiveDictationStage: Equatable {
    /// Key held, the microphone not open yet. Brief since the pre-roll (D-02).
    case gettingReady
    /// The microphone is open and the words are arriving.
    case listening
    /// Key up; the speech engine is finishing the text.
    case writing
    /// The text is heard; the cleanup pass is tidying it before it is typed.
    case tidying

    static func of(
        _ state: DictationController.State,
        isCapturing: Bool,
        finishing: DictationController.FinishingStage
    ) -> LiveDictationStage? {
        switch state {
        case .listening: .listening
        case .starting: isCapturing ? .listening : .gettingReady
        case .finishing: finishing == .tidying ? .tidying : .writing
        case .idle, .error: nil
        }
    }

    /// Plain words, said the way a person would say them out loud.
    var label: String {
        switch self {
        case .gettingReady: "Getting ready\u{2026}"
        case .listening: "Listening\u{2026}"
        case .writing: "Writing it out\u{2026}"
        case .tidying: "Tidying up\u{2026}"
        }
    }

    var orb: OrbGeometry.State {
        switch self {
        case .listening: .listening
        // Unchanged from before the stage existed: the brief wait for the microphone has
        // always worn the work orb on both surfaces.
        case .gettingReady, .writing: .working
        case .tidying: .composing
        }
    }
}

/// The live words, cut to what fits in two lines with the newest words kept.
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

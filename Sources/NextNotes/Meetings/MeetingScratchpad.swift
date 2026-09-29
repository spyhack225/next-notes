import Foundation

/// One thing the person typed themselves during a meeting. Never model-written,
/// never rewritten by anything except the person: that is the whole point of it.
///
/// It lives in its own file beside `notes.md` rather than inside it, because the notes
/// are rewritten by every generation pass and a hand-written line must survive all of
/// them untouched. `NotesService` folds these lines into the notes *after* the model has
/// finished, so the block is always the person's and never something a summary can
/// paraphrase away.
struct MeetingScratchNote: Identifiable, Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case line, document }

    var id: UUID = UUID()
    var text: String
    var at: Date
    var isPinned: Bool
    var kind: Kind
    /// The rich editor's lossless page. `text` remains Markdown for notes.md and search.
    var richHTML: String?

    init(text: String, at: Date = Date(), isPinned: Bool = false, kind: Kind = .line,
         richHTML: String? = nil) {
        self.text = text
        self.at = at
        self.isPinned = isPinned
        self.kind = kind
        self.richHTML = richHTML
    }

    private enum CodingKeys: String, CodingKey { case id, text, at, isPinned, kind, richHTML }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        text = try values.decode(String.self, forKey: .text)
        at = try values.decode(Date.self, forKey: .at)
        isPinned = try values.decode(Bool.self, forKey: .isPinned)
        kind = try values.decodeIfPresent(Kind.self, forKey: .kind) ?? .line
        richHTML = try values.decodeIfPresent(String.self, forKey: .richHTML)
    }

    /// How many notes one meeting keeps.
    ///
    /// A four-hour call is thousands of lines and the oldest is the least useful, so the
    /// file holds the most recent `maxStored` and the cap is applied on write. Without
    /// it the file grows for as long as the person is willing to type, which is the one
    /// thing a meeting of unbounded length would do to it.
    static let maxStored = 200

    /// The note collapsed to one line, for recall rows and search. Pure.
    ///
    /// Collapses newlines and runs of whitespace — a bullet can only hold one line, and
    /// a row that wraps to four is a row nobody can scan. Hand-rolled rather than
    /// `split`/`joined`: `split` drops empty subsequences by default, so a doubled space
    /// would silently become a single space and a run of them would vanish entirely.
    var singleLine: String {
        var out = ""
        out.reserveCapacity(text.count)
        var pendingSpace = false
        for character in text {
            if character.isWhitespace {
                // Leading whitespace is dropped rather than turned into a space: the
                // pending flag is only set once something has been written.
                pendingSpace = !out.isEmpty
                continue
            }
            if pendingSpace {
                out.append(" ")
                pendingSpace = false
            }
            out.append(character)
        }
        return out
    }
}

/// The two halves of a meeting's notes document, and the one rule that keeps them apart.
///
/// Pure, so `NotesService` and `--selftest-meeting-scratchpad` decide the same way: the
/// hand-written lines always go first, under one heading, and a generated document that
/// already carries that heading has it removed before the two are joined. A document can
/// therefore never contain two "Your notes" sections, and merging twice is the same as
/// merging once — which is what makes it safe to run on every generation pass.
enum ScratchNotesMerger {
    /// The heading a person's own lines go under.
    ///
    /// Plain words, and the one string the strip below looks for, so what is written and
    /// what is recognised can never drift apart.
    static let heading = "Your notes"

    /// The marker makes the boundary unambiguous even when a person's page contains an
    /// empty heading or its own horizontal rule. The rule remains visible in rendered notes;
    /// the comment is invisible and only used when a later save replaces the manual block.
    private static let boundary = "<!-- next-notes-manual-boundary -->"
    private static let separator = "---\n\(boundary)"

    /// The block a person's lines become: the heading, then one `- ` bullet each, pinned
    /// notes first because a line somebody pinned mid-meeting is the one they will look
    /// for after it. The rest stay in the order they were typed.
    ///
    /// `""` for nothing to say — including notes that are only whitespace, which would
    /// otherwise render as a bare `- ` for the person to read and delete.
    static func markdown(_ notes: [MeetingScratchNote]) -> String {
        var pinned: [String] = []
        var rest: [String] = []
        var pages: [String] = []
        for note in notes {
            let line = note.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if note.kind == .document {
                pages.append(line)
                continue
            }
            // A note can contain Shift-Return line breaks, including a whole document
            // the person chose to keep. Indent continuation lines under the same bullet
            // so the notes page preserves those breaks without creating extra entries.
            let bullet = "- " + line.replacingOccurrences(of: "\n", with: "\n  ")
            if note.isPinned {
                pinned.append(bullet)
            } else {
                rest.append(bullet)
            }
        }
        let sections = [pinned, rest]
            .filter { !$0.isEmpty }
            .map { $0.joined(separator: "\n") }
        let content = sections + pages
        guard !content.isEmpty else { return "" }
        return (["## \(heading)"] + content).joined(separator: "\n\n")
    }

    /// The hand-written block, the generated notes, and one horizontal rule between them.
    ///
    /// Either side alone is returned on its own, so a meeting with no notes of its own is
    /// not given an empty section and a meeting with no generated notes is not given a
    /// rule. The generated side has any pre-existing `## Your notes` section removed
    /// first, which is the only reason a second pass cannot leave two of them in the file.
    static func merged(manual: String, generated: String) -> String {
        let hand = trimmed(manual)
        let written = withoutManualSection(trimmed(generated))
        guard !hand.isEmpty else { return written }
        guard !written.isEmpty else { return hand }
        return ([hand, separator, written]).joined(separator: "\n\n")
    }

    // MARK: - The strip

    /// `document` with the hand-written block taken out.
    ///
    /// It ends at the block's own horizontal rule when there is one — that is what a
    /// previous merge wrote, and finding it is what makes a second pass a no-op. Failing
    /// that it ends at the next level-2 heading, or at the end of the document, so a
    /// section the model wrote by hand goes whole rather than leaving its prose behind
    /// under a heading that is no longer there. Older documents used a bare `##` as the
    /// separator; recognise it only when no explicit marker exists.
    private static func withoutManualSection(_ document: String) -> String {
        let lines = document.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard let start = lines.firstIndex(where: { trimmed($0) == "## \(heading)" }) else {
            return document
        }
        // A person's freeform page may contain headings and rules of its own. The explicit
        // marker is the only reliable boundary for a page written by this version.
        let end: Int
        if let marker = ((start + 1)..<lines.count).first(where: { trimmed(lines[$0]) == boundary }) {
            end = marker + 1
        } else if let rule = ((start + 1)..<lines.count).first(where: { isRule(lines[$0]) }) {
            end = rule + 1
        } else {
            end = ((start + 1)..<lines.count).first(where: { isSectionHeading(lines[$0]) })
                ?? lines.count
        }
        // The blank lines that separated the block from what follows are not its own.
        var after = end
        while after < lines.count, trimmed(lines[after]).isEmpty { after += 1 }
        return (Array(lines[..<start]) + Array(lines[after...])).joined(separator: "\n")
    }

    private static func isRule(_ line: String) -> Bool {
        let text = trimmed(line)
        return !text.isEmpty && text.allSatisfy { $0 == "#" }
    }

    private static func isSectionHeading(_ line: String) -> Bool {
        trimmed(line).hasPrefix("## ")
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

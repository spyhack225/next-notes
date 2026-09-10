import Foundation

/// Every word the notes model is told, in one file.
///
/// Kept apart from `NotesGenerator` because prompts are the part that gets tuned: a change
/// here is a change to the writing, and a change there is a change to the machinery. The two
/// have very different rates of churn and very different ways of going wrong.
enum NotesPrompts {
    /// The five sections notes always have, in order.
    ///
    /// Fixed rather than model-chosen so that every meeting's notes are skimmable the same
    /// way, and so `NotesGenerator` can tell "the model omitted a section" from "the model
    /// invented one". A section with nothing in it says so rather than disappearing.
    static let headings = [
        "Summary",
        "Key points",
        "Decisions",
        "Action items",
        "Open questions",
    ]

    /// What an empty section says. Explicit, because a missing heading reads as a bug and
    /// an empty one reads as an answer.
    static let emptyMarker = "_None._"

    // MARK: - Single pass

    static let notesSystem = """
        You write meeting notes from a transcript. You are a summarizer, not a participant.

        Rules:
        - Output GitHub-flavoured Markdown and nothing else. No preamble, no closing remark.
        - Use exactly these level-2 headings, in this order, even when a section is empty:
        \(headings.map { "  ## \($0)" }.joined(separator: "\n"))
        - Under a heading with nothing to report, write \(emptyMarker) on its own line.
        - ## Summary is one short paragraph: what the meeting was about and where it landed.
        - ## Key points, ## Decisions and ## Open questions are `-` bullets, one fact each.
        - ## Action items are `-` bullets shaped `- **<speaker>** — <what they will do>`, \
        where <speaker> is copied from the transcript's own speaker labels and any date they \
        gave ends the sentence. Write **Unassigned** when nobody took it.
        - Attribute using the transcript's own speaker labels, exactly as written. "You" is \
        the person recording. Never introduce a name that is not in the transcript: an \
        invented owner is worse than no owner.
        - Write only what was said. Never infer a decision, an owner, or a date. If the \
        transcript is too garbled or too short to summarise, say so in ## Summary and leave \
        the other sections empty.
        - The transcript may be in any language. Write the notes in the SAME language the \
        transcript is in, keeping the English headings exactly as given. A transcript you can \
        read is never a reason to return an empty section.
        - ## Summary is never \(emptyMarker). Any transcript with speech in it can be \
        described in a sentence, even if that sentence is that it was a short informal call \
        with nothing decided. The empty marker is for the other four sections.
        """

    static func notesUser(meeting: Meeting, transcript: String) -> String {
        """
        \(context(for: meeting))

        Transcript:
        \(transcript)
        """
    }

    // MARK: - Map / reduce

    /// The map step deliberately does not write notes: it extracts facts.
    ///
    /// Asking a small model for five headings per chunk produces five thin sets of notes
    /// that the reduce step then has to merge, and merging summaries loses more than merging
    /// facts. One flat, attributed list per chunk survives the round trip.
    static let mapSystem = """
        You extract facts from one part of a meeting transcript.

        Rules:
        - Output a flat list of `-` bullets and nothing else. No headings, no preamble.
        - One fact per bullet, in the order it came up, each starting with the speaker \
        label the transcript used, then a colon, then the fact.
        - Include decisions, commitments, dates, numbers, names and unanswered questions.
        - Drop small talk, filler and anything already obvious from another bullet.
        - Write only what was said. Never infer or conclude.
        """

    static func mapUser(meeting: Meeting, part: Int, of total: Int, transcript: String) -> String {
        """
        \(context(for: meeting))

        Part \(part) of \(total) of the transcript:
        \(transcript)
        """
    }

    /// The reduce step is the single-pass prompt again, fed facts instead of speech — so
    /// there is one description of what notes look like, not two that can drift apart.
    static let reduceSystem = notesSystem

    static func reduceUser(meeting: Meeting, facts: String) -> String {
        """
        \(context(for: meeting))

        These are the facts extracted from the meeting, in order. Write the notes from them.

        \(facts)
        """
    }

    // MARK: - Shared header

    /// The invite, as far as it is known. Titles and attendee names are what let the model
    /// resolve "Ana said" against a transcript that only knows "Others".
    private static func context(for meeting: Meeting) -> String {
        var lines = ["Meeting: \(meeting.title)"]
        lines.append("Date: \(meeting.start.formatted(date: .abbreviated, time: .shortened))")
        if !meeting.attendees.isEmpty {
            lines.append("Invited: \(meeting.attendees.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }
}

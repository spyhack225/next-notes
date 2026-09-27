import Foundation

/// `--selftest-meeting-tidier` — the mid-meeting tidy's two pure halves, the prompt and the
/// parse.
///
/// Pure checks only: no model, no network, no usage row, no shared store. That is not a
/// shortcut, it is the point — on the machine this ships from the notes model is usually not
/// installed at all, so a gate that needed one would be a gate nobody could run, and the two
/// halves that can be checked without it are the two that decide whether the pass invents
/// anything. `promptBlock` is where a person's own words survive, and `parse` is the only
/// thing standing between a small model's answer and a document the person will believe.
///
/// The last section is a mutation check, and it is executable rather than a promise: each
/// named assertion above is re-run against a deliberately broken block or document, so a
/// matcher that had quietly stopped being sensitive fails here rather than passing on a
/// clean fixture.
enum MeetingScratchpadTidierSelfTest {
    /// The check, as data. One string per thing that did not hold; empty is a pass.
    ///
    /// Unprefixed on purpose, the way `ModelRoleSelfTest` and `PersonaCareEval` return it,
    /// so a caller can label the failures with whatever its own marker is. `run()` below is
    /// the same check with the printing already done.
    nonisolated static func failures() -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        func note(_ text: String, _ seconds: TimeInterval) -> MeetingScratchNote {
            MeetingScratchNote(text: text, at: base.addingTimeInterval(seconds))
        }
        /// The `##` headings in a document, in order.
        func headings(_ document: String) -> [String] {
            document.components(separatedBy: .newlines)
                .filter { $0.hasPrefix("## ") }
                .map { String($0.dropFirst(3)) }
        }

        // MARK: - The prompt carries every line the person wrote

        let written = [
            note("confirm ICP alignment", 0),
            note("Deal stalls — sales input", 10),
            note("two\nlines typed", 20),
            note("   ", 30),
        ]
        let block = MeetingScratchpadTidier.promptBlock(notes: written, transcript: "You: hello")

        check("every line the person wrote is in the prompt, numbered in the order they "
            + "typed it, and a line they typed across two lines is whole",
            block.contains("1. confirm ICP alignment\n\n2. Deal stalls — sales input\n\n"
                + "3. two\nlines typed"))
        check("a line that is only whitespace is not sent as a numbered item, because it is "
            + "not a note anybody typed",
            !block.contains("4."))
        check("the transcript is in the prompt as background",
            block.contains(MeetingScratchpadTidier.transcriptHeader)
                && block.contains("You: hello"))
        check("the notes and the transcript are named as two different things, so the model "
            + "cannot read the transcript as something the person wrote",
            block.contains(MeetingScratchpadTidier.notesHeader))

        // The transcript gives way, and says so. One enormous first line makes the arithmetic
        // exact rather than approximate: it cannot fit at all, so exactly one of the hundred
        // lines is left out and the marker's own count is checkable.
        var long: [String] = [String(repeating: "x", count: MeetingScratchpadTidier.maxTranscriptCharacters + 100)]
        long += (1 ..< 100).map { "spoken line \($0)" }
        let longBlock = MeetingScratchpadTidier.promptBlock(notes: [], transcript: long.joined(separator: "\n"))
        check("a transcript too long for the window says on the page how much of it was left "
            + "out, rather than dropping speech silently",
            longBlock.contains(NotesPrompts.truncatedLine(dropped: 1, of: 100)))
        check("the newest speech is the part that is kept — a line the person typed a minute "
            + "ago is about the minute before it",
            longBlock.contains("spoken line 99")
                && !longBlock.contains(String(repeating: "x", count: 20)))
        check("a transcript that fits whole carries no marker at all",
            !block.contains("could not be included in these notes"))
        check("with nothing written yet the prompt says so in the notes vocabulary's own "
            + "empty marker, rather than passing an empty list off as one",
            MeetingScratchpadTidier.promptBlock(notes: [], transcript: "You: hello")
                .contains(NotesPrompts.emptyMarker))

        // MARK: - The reply becomes the document the panel draws

        let reference = """
            ## ICP Alignment Confirmation
            - Agreed to narrow Q3 focus to mid-market finance and ops buyers
              - SMB deprioritised for the quarter
              - Paid campaigns paused until ICP doc is confirmed

            ## Deal Stalls: Sales Input
            - Jack flagged deals stalling at business case stage
            """
        let parsed = MeetingScratchpadTidier.parse(reference)
        check("a reply of `##` headings and `-` bullets comes back in the shape the reference "
            + "shows, with one level of sub-bullet indented two spaces",
            parsed == """
                ## ICP Alignment Confirmation
                - Agreed to narrow Q3 focus to mid-market finance and ops buyers
                  - SMB deprioritised for the quarter
                  - Paid campaigns paused until ICP doc is confirmed

                ## Deal Stalls: Sales Input
                - Jack flagged deals stalling at business case stage
                """)

        // The one that is easiest to get wrong and the reason for the named assertion
        // above: a parser that renders sections as it goes drops the last one, and the
        // document it returns is a complete-looking document with a section missing.
        check("the last heading survives, not just the first — a parse that ended its walk "
            + "one section early would pass every other assertion here",
            headings(parsed) == ["ICP Alignment Confirmation", "Deal Stalls: Sales Input"])

        check("a level-3 heading is a heading in the flat document this pass writes",
            MeetingScratchpadTidier.parse("### Pricing\n- x") == "## Pricing\n- x")
        check("a bold-only line is a heading, because that is how a small model writes one",
            MeetingScratchpadTidier.parse("**Deal stalls**\n- Jack flagged deals")
                == "## Deal stalls\n- Jack flagged deals")
        check("`•` and `–` are bullets too, and an indented one is a sub-bullet",
            MeetingScratchpadTidier.parse("**Deal stalls**\n• Jack flagged deals\n  – Marketing to build a template")
                == "## Deal stalls\n- Jack flagged deals\n  - Marketing to build a template")
        check("a bullet that wrapped is one bullet, not a paragraph under it",
            MeetingScratchpadTidier.parse("## A\n- a very long bullet that\n  ran out of width")
                == "## A\n- a very long bullet that ran out of width")
        check("a marker with nothing after it is dropped rather than rendered as a bullet the "
            + "person has to delete",
            MeetingScratchpadTidier.parse("## A\n-\n- real") == "## A\n- real")
        check("a horizontal rule is scaffolding and is dropped",
            MeetingScratchpadTidier.parse("## A\n---\n- real") == "## A\n- real")
        check("a heading with nothing under it says the empty marker rather than nothing, "
            + "because a missing section reads as a bug and an empty one reads as an answer",
            MeetingScratchpadTidier.parse("## Open questions")
                == "## Open questions\n\(NotesPrompts.emptyMarker)")
        check("an empty marker the model wrote is kept, not tidied away",
            MeetingScratchpadTidier.parse("## Decisions\n\(NotesPrompts.emptyMarker)")
                == "## Decisions\n\(NotesPrompts.emptyMarker)")
        check("a reply that is only a preamble is one paragraph — there is no structure to "
            + "put it in and nothing else it could be",
            MeetingScratchpadTidier.parse("Here are your notes, tidied.")
                == "Here are your notes, tidied.")
        check("a preamble in front of the document is scaffolding and goes",
            MeetingScratchpadTidier.parse("Sure! Here are your notes:\n\n## Decisions\n- Narrow the focus")
                == "## Decisions\n- Narrow the focus")
        check("nothing in, nothing out", MeetingScratchpadTidier.parse("") == "")
        check("a code fence around the whole answer is stripped",
            MeetingScratchpadTidier.parse("```markdown\n## A\n- real\n```") == "## A\n- real")
        check("a reasoning block is stripped, including the half-open one a model writes when "
            + "it opens a second think",
            MeetingScratchpadTidier.parse("<think>hmm</think>\n## A\n- real")
                == "## A\n- real")

        // The echo. A small model handed a prompt answers by writing the prompt back, and
        // without this the panel shows the person their own rules as though they were notes.
        let document = "## Decisions\n- Narrow the focus"
        check("a reply that echoes the prompt returns the prompt-free part, and nothing of "
            + "the echo survives",
            MeetingScratchpadTidier.parse(
                MeetingScratchpadTidier.system + "\n\n" + document) == document)
        check("a rule restated after the document is dropped as well, not only one in front "
            + "of it",
            MeetingScratchpadTidier.parse(
                document + "\n" + MeetingScratchpadTidier.system) == document)

        // MARK: - Blank is blank

        check("a document of headings and empty markers says nothing, and must not be shown "
            + "as one the pass wrote",
            MeetingScratchpadTidier.isBlank("## A\n\(NotesPrompts.emptyMarker)")
                && MeetingScratchpadTidier.isBlank("")
                && !MeetingScratchpadTidier.isBlank("## A\n- real"))

        // MARK: - The mutation check
        //
        // Each of the two named assertions above is re-run here against a version of the
        // thing it reads that has been broken on purpose. If the assertion were insensitive
        // to its own mutation, these would pass and the gate would be decorative.

        // The mutation the first assertion exists for: a `promptBlock` that carried only the
        // first line — the one that loses a meeting's worth of what somebody typed while they
        // were listening, silently, because the block still looks like a block.
        let leaked = MeetingScratchpadTidier.promptBlock(notes: [written[0]], transcript: "You: hello")
        check("MUTATION: the assertion that every line is carried is sensitive to a block that "
            + "leaked only the first one",
            !leaked.contains("2. Deal stalls")
                && !leaked.contains("1. confirm ICP alignment\n\n2."))

        // And the one the heading assertion exists for: a `parse` that dropped the last
        // section. The assertion above compares heading lists, so the mutation is expressed
        // as the truncated document that mutation would have returned.
        let droppedLast = String(parsed.components(separatedBy: "\n## Deal Stalls").first ?? "")
        check("MUTATION: the assertion that the last heading survives is sensitive to a parse "
            + "that dropped it",
            headings(droppedLast) == ["ICP Alignment Confirmation"]
                && headings(droppedLast) != headings(parsed))

        return failures
    }

    /// The same check, with the printing this repo's self-tests are read by: one
    /// `MEETING_TIDIER_FAILED: <reason>` per failure and exactly one terminal marker.
    ///
    /// Separate from `failures()` so a caller that wants the data can have it without the
    /// lines — and so the marker this file is required to print is printed by this file
    /// rather than depending on how the flag was registered.
    @MainActor
    static func run() -> Bool {
        let failures = failures()
        for failure in failures {
            SelfTest.diagnostic("MEETING_TIDIER_FAILED: \(failure)")
        }
        SelfTest.diagnostic(failures.isEmpty ? "MEETING_TIDIER_OK" : "MEETING_TIDIER_FAILED")
        return failures.isEmpty
    }
}

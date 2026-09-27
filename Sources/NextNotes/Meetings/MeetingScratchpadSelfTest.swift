import Foundation

/// `--selftest-meeting-scratchpad` — the lines a person typed themselves during a
/// meeting, and the block they become inside `notes.md`.
///
/// No model, no microphone, no network, no usage log. Every meeting lives in
/// `MeetingStore.isolated()`, so the run never touches the owner's real `Meetings/`, and
/// the knowledge index answers `meetingChanged` from its own temporary store with the
/// feature off — so the writes below index nothing.
///
/// It asserts the things an eye cannot check twice: that the file round-trips in the order
/// the lines were typed, that the cap keeps the most recent rather than the first, that a
/// write is the thing a view observes, and that merging twice cannot produce a document
/// with two "Your notes" sections in it.
@MainActor
enum MeetingScratchpadSelfTest {
    @discardableResult
    static func run() -> Bool {
        print("MEETING_SCRATCHPAD: hand-written notes")
        var failures: [String] = []

        func expect(_ condition: Bool, _ message: String) {
            if condition {
                SelfTest.diagnostic("  ok   \(message)")
            } else {
                SelfTest.diagnostic("  FAIL \(message)")
                failures.append(message)
            }
        }

        let fm = FileManager.default

        /// The store writes dates in ISO 8601, and the file is the record: a format that
        /// decodes here but not in `MeetingStore` would be a file whose lines vanish on the
        /// next read, so the test reads it the way production does.
        let iso8601: JSONDecoder = {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return decoder
        }()

        /// The file itself, read past `scratchpad(for:)` so the assertion is about what was
        /// written rather than about what the store hands back.
        func onDisk(_ store: MeetingStore, _ id: UUID) -> [MeetingScratchNote] {
            let url = store.directory(for: id).appendingPathComponent(MeetingStore.scratchpadFile)
            guard let data = try? Data(contentsOf: url) else { return [] }
            return (try? iso8601.decode([MeetingScratchNote].self, from: data)) ?? []
        }

        func seed(_ store: MeetingStore, _ title: String) -> Meeting {
            let meeting = Meeting(title: title, start: Date(), status: .recording)
            store.save(meeting)
            return store.meeting(id: meeting.id) ?? meeting
        }

        // MARK: - a. One note, one line.

        do {
            expect(MeetingScratchNote(text: "confirm ICP alignment").singleLine
                == "confirm ICP alignment", "a single line comes back unchanged")
            expect(MeetingScratchNote(text: "  Q3  messaging\nrollout,\t are teams ready?  ")
                .singleLine == "Q3 messaging rollout, are teams ready?",
                "newlines and doubled spaces collapse to one space, and it is trimmed")
            expect(MeetingScratchNote(text: "").singleLine == "", "nothing in, nothing out")
            expect(MeetingScratchNote(text: "\n\t  \n").singleLine == "",
                "a note that is only whitespace collapses to nothing, not to spaces")
        }

        // MARK: - b. The block a person reads.

        do {
            expect(ScratchNotesMerger.markdown([]) == "", "no notes render nothing at all")
            expect(ScratchNotesMerger.markdown([MeetingScratchNote(text: "   ")]) == "",
                "a blank line renders no bullet, so there is no `- ` to read and delete")

            let block = ScratchNotesMerger.markdown([
                MeetingScratchNote(text: "normal one", at: Date(timeIntervalSince1970: 10)),
                MeetingScratchNote(text: "pinned one", at: Date(timeIntervalSince1970: 20),
                                   isPinned: true),
                MeetingScratchNote(text: "normal two", at: Date(timeIntervalSince1970: 30)),
                MeetingScratchNote(text: "pinned two", at: Date(timeIntervalSince1970: 40),
                                   isPinned: true),
            ])
            expect(block == """
                ## Your notes

                - pinned one
                - pinned two

                - normal one
                - normal two
                """, "pinned lines come first, the rest keep the order they were typed, "
                + "one blank line between the two groups (got \(block.debugDescription))")

            let onlyRest = ScratchNotesMerger.markdown([
                MeetingScratchNote(text: "one"),
                MeetingScratchNote(text: "two"),
            ])
            expect(onlyRest == "## Your notes\n\n- one\n- two",
                "with nothing pinned there is one group, not an empty first one")

            let one = MeetingScratchNote(text: "two\nlines\ntyped")
            expect(ScratchNotesMerger.markdown([one])
                == "## Your notes\n\n- two lines typed",
                "a note that spans lines is still one bullet")
        }

        // MARK: - c. The round trip through the real file.

        do {
            let store = MeetingStore.isolated()
            let meeting = seed(store, "Scratchpad seed")
            let base = Date(timeIntervalSince1970: 1_700_000_000)

            let before = store.scratchpadRevision
            // Saved out of order on purpose: what the person gets back is when they typed
            // it, not the order a call site happened to build the array in.
            store.saveScratchpad([
                MeetingScratchNote(text: "third", at: base.addingTimeInterval(30)),
                MeetingScratchNote(text: "first", at: base),
                MeetingScratchNote(text: "second", at: base.addingTimeInterval(10)),
            ], for: meeting.id)
            expect(store.scratchpadRevision > before,
                "a write bumps scratchpadRevision (\(before) → \(store.scratchpadRevision))")
            expect(store.scratchpadRevision == before + 1,
                "one write is one bump, not a whole batch")

            let afterWrite = store.scratchpadRevision
            let read = store.scratchpad(for: meeting.id)
            expect(store.scratchpadRevision == afterWrite,
                "reading does not bump the revision — the write is the signal a view waits for")
            expect(read.map(\.text) == ["first", "second", "third"],
                "the read is ordered by when each line was typed (got \(read.map(\.text)))")
            expect(onDisk(store, meeting.id).map(\.text) == ["first", "second", "third"],
                "the file on disk holds the same three lines, dates included")
            expect(read.map(\.id) == onDisk(store, meeting.id).map(\.id),
                "every line keeps its own identity across the file")

            // Pinning, added last on purpose: the file is in typed order, so a pinned line
            // that is not first in the file is what proves the reordering is the merger's
            // doing rather than the store's.
            store.saveScratchpad(read + [
                MeetingScratchNote(text: "pinned last", at: base.addingTimeInterval(40),
                                   isPinned: true)
            ], for: meeting.id)
            let withPin = store.scratchpad(for: meeting.id)
            expect(withPin.map(\.text) == ["first", "second", "third", "pinned last"],
                "the file keeps them in the order they were typed")
            expect(withPin.last?.isPinned == true, "pinning survives the file")
            let bullets = ScratchNotesMerger.markdown(withPin)
                .split(separator: "\n")
                .filter { $0.hasPrefix("- ") }
                .map(String.init)
            expect(bullets == ["- pinned last", "- first", "- second", "- third"],
                "pinned first is the block's rule alone, not the file's order (\(bullets))")

            let url = store.directory(for: meeting.id)
                .appendingPathComponent(MeetingStore.scratchpadFile)
            expect(fm.fileExists(atPath: url.path),
                "the file is a sibling of notes.md, inside this meeting's own folder")

            // Two lines inside the same instant. The tie-break is the file's own order, so
            // the list cannot shuffle itself under the person typing.
            let tieA = MeetingScratchNote(text: "tie a", at: base)
            let tieB = MeetingScratchNote(text: "tie b", at: base)
            store.saveScratchpad([tieA, tieB], for: meeting.id)
            expect(store.scratchpad(for: meeting.id).map(\.text) == ["tie a", "tie b"],
                "two lines typed in the same instant keep their order, on every read")
        }

        // MARK: - d. The cap keeps the most recent.

        do {
            let store = MeetingStore.isolated()
            let meeting = seed(store, "Cap seed")
            let base = Date(timeIntervalSince1970: 1_700_000_000)
            let extra = 25
            let written = (0 ..< (MeetingScratchNote.maxStored + extra)).map {
                MeetingScratchNote(text: "line \($0)", at: base.addingTimeInterval(Double($0)))
            }
            store.saveScratchpad(written, for: meeting.id)

            let kept = store.scratchpad(for: meeting.id)
            expect(kept.count == MeetingScratchNote.maxStored,
                "\(written.count) lines are capped to \(MeetingScratchNote.maxStored) "
                + "(got \(kept.count))")
            expect(kept.first?.text == "line \(extra)",
                "the cap drops the oldest (\(kept.first?.text ?? "nil"))")
            expect(kept.last?.text == "line \(MeetingScratchNote.maxStored + extra - 1)",
                "the newest line is the one kept (\(kept.last?.text ?? "nil"))")
            expect(onDisk(store, meeting.id).count == MeetingScratchNote.maxStored,
                "the file itself is capped, so it cannot grow without bound")
        }

        // MARK: - e. The merge is idempotent and cannot double the heading.

        do {
            let manual = ScratchNotesMerger.markdown([
                MeetingScratchNote(text: "confirm ICP alignment"),
                MeetingScratchNote(text: "Q3 messaging rollout, are teams ready?",
                                   isPinned: true),
            ])
            let generated = """
                ## Summary

                A short meeting about the quarter.

                ## Decisions

                - Narrow the focus to mid-market.
                """

            let once = ScratchNotesMerger.merged(manual: manual, generated: generated)
            expect(once.hasPrefix("## Your notes"),
                "the hand-written block comes first, not after the model's own notes")
            expect(once.hasSuffix(generated),
                "the generated notes come last, byte for byte")
            expect(once == "## Your notes\n\n- Q3 messaging rollout, are teams ready?\n\n- confirm ICP alignment\n\n##\n\n\(generated)",
                "the block, a horizontal rule, then the notes (got \(once.debugDescription))")

            let twice = ScratchNotesMerger.merged(manual: manual, generated: once)
            expect(twice == once,
                "merging an already-merged document changes nothing")
            let thrice = ScratchNotesMerger.merged(manual: manual, generated: twice)
            expect(thrice == once, "and a third pass changes nothing either")

            // A document that already carries the heading — a model that wrote its own
            // "Your notes" section, or a document merged by an earlier pass.
            let already = """
                ## Your notes

                - something the model said

                ## Summary

                A short meeting about the quarter.

                ## Decisions

                - Narrow the focus to mid-market.
                """
            let cleaned = ScratchNotesMerger.merged(manual: manual, generated: already)
            expect(!cleaned.contains("something the model said"),
                "the pre-existing section's contents go with its heading")
            expect(cleaned.components(separatedBy: "## Your notes").count == 2,
                "a merged document holds exactly one \(ScratchNotesMerger.heading) section "
                + "(\(cleaned.components(separatedBy: "## Your notes").count - 1) found)")
            expect(cleaned.contains("## Summary") && cleaned.contains("## Decisions"),
                "the rest of the generated document survives the strip")
            expect(ScratchNotesMerger.merged(manual: manual, generated: cleaned) == cleaned,
                "and it is already the merged document, so re-merging is a no-op")

            // The heading of a section that is not ours, and one written as prose rather
            // than bullets, so the strip cannot be a bullet-only trick.
            let prose = """
                ## Summary

                A short meeting.

                ## Your notes

                A paragraph the model wrote under the heading.

                ## Decisions

                - Narrow the focus.
                """
            let fromProse = ScratchNotesMerger.merged(manual: manual, generated: prose)
            expect(!fromProse.contains("A paragraph the model wrote"),
                "a section written as prose is removed whole, not left under a missing heading")
            expect(fromProse.components(separatedBy: "## Your notes").count == 2,
                "still exactly one section")
            expect(fromProse.contains("## Decisions"), "and the section after it survives")

            // Either side alone.
            expect(ScratchNotesMerger.merged(manual: manual, generated: "   \n\n") == manual,
                "with no generated notes the hand-written block stands alone, with no rule")
            expect(ScratchNotesMerger.merged(manual: "", generated: generated) == generated,
                "with no hand-written lines the notes are untouched")
            expect(ScratchNotesMerger.merged(manual: "", generated: "") == "",
                "neither side is an empty document")
        }

        // MARK: - f. The folder holds the record and the scratchpad, nothing else.

        do {
            let store = MeetingStore.isolated()
            let meeting = seed(store, "Folder seed")
            store.saveScratchpad([MeetingScratchNote(text: "one line")], for: meeting.id)
            let names = ((try? fm.contentsOfDirectory(
                atPath: store.directory(for: meeting.id).path
            )) ?? []).sorted()
            expect(names == [MeetingStore.recordFile, MeetingStore.scratchpadFile],
                "a hand-written line writes one file beside the record and nothing else "
                + "(\(names))")
        }

        for failure in failures { SelfTest.diagnostic("MEETING_SCRATCHPAD_FAILED: \(failure)") }
        SelfTest.diagnostic(failures.isEmpty ? "MEETING_SCRATCHPAD_OK" : "MEETING_SCRATCHPAD_FAILED")
        return failures.isEmpty
    }
}

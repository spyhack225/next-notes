import Foundation

/// Tidies the fragments a person typed *during* a meeting into a document they can read.
///
/// **Not a second notes pipeline.** `NotesService` reads the whole transcript and runs after
/// the meeting, and it owns `notes.md`. This one runs while the meeting is still going, over
/// the handful of lines the person typed themselves while they were listening, and its
/// output appears only under the panel's own heading until the person chooses to keep it —
/// which is one pinned `MeetingScratchNote`, and from there the ordinary merge into
/// `notes.md` at the end. Nothing here writes `notes.md`, opens the knowledge index, or
/// assembles a Related-context brief, so there is no graph or cloud-consent gate to add: for
/// the same reason `NotesGenerator.mapUser` never sees the brief, a fact this app already
/// knows comes back from a "shape what the person wrote" prompt as something they wrote.
///
/// Two failures are worth more than a document. With no provider it says so and the caller
/// disables its button; an answer that ran out of allowance is `.cutShort` rather than a
/// document that reads as finished. A tidier that invents structure from nothing is worse
/// than one that admits it has no model.
enum MeetingScratchpadTidier {
    /// What a pass produced, in the four shapes the caller has to tell apart.
    ///
    /// The model-written and the cut-short cases are separate values rather than a flag on
    /// one, because they are different claims about the same text: "here is your document"
    /// and "here is most of your document" cannot both be true, and the panel says which.
    enum Outcome: Equatable, Sendable {
        /// Markdown the model produced, complete.
        case wrote(String)
        /// The model ran out of allowance. The text is real and it is incomplete.
        case cutShort(String)
        /// Why no model could be reached, in a sentence a person can read.
        case noModel(String)
        case failed(String)
    }

    /// The usage row's feature name.
    ///
    /// Its own string rather than one of the `meeting.notes.*` cases, because
    /// `--usage-report` groups by it and this pass must not be counted as the notes pass: a
    /// different reader, a different input, a different moment in the meeting. `UsageRecord`
    /// takes the feature as a `String` precisely so a row can say what it is.
    nonisolated static let feature = "meeting.scratchpad.tidy"

    /// How much room the document may take.
    ///
    /// Small on purpose. A tidy of a page of somebody's own lines is a dozen bullets, and
    /// the pass runs while a meeting is still being recorded on a Mac that is also
    /// transcribing it — so an allowance scaled to the transcript would be an allowance
    /// paid for by the meeting.
    nonisolated static let answerTokens = 1_024

    /// How much of what was said rides along as background.
    ///
    /// The tail, not the head: a line the person typed a minute ago is about the minute
    /// before it. Whatever does not fit is left out **with a marker** — the same
    /// `NotesPrompts` line the notes pass uses when it drops a part, because it is the same
    /// claim.
    nonisolated static let maxTranscriptCharacters = 2_400

    /// Everything the model is told. Pure, and the same string `parse` strips an echo of.
    static let system = """
        You tidy a person's own meeting notes into a short document they can read.

        Rules:
        - Output GitHub-flavoured Markdown and nothing else. No preamble, no closing remark.
        - Give each group of related notes its own heading, marked with two `#` characters, \
        named for what the notes are about in a few words.
        - Under a heading write `-` bullets, one idea each, keeping the person's own words \
        wherever you can.
        - A detail of the bullet above it is a sub-bullet, indented two spaces.
        - Under a heading with nothing to report, write \(NotesPrompts.emptyMarker) on its \
        own line.
        - The notes are the source of truth. Add no fact, name, number, owner or conclusion \
        that is not in them, and never merge two of the person's lines into a claim their \
        writer did not make.
        - What was said is background. Use it to tell which line means which, never as \
        content, and never as something the person wrote.
        - Write in the same language the notes are in.
        """

    /// What the model is asked, over the person's lines and the tail of the meeting.
    ///
    /// Pure, so the self-test can check the one property that matters without a model: every
    /// line the person wrote is in here, whole, and nothing is dropped without saying so.
    ///
    /// The notes are **never** shortened. A person who typed a line during a meeting cannot
    /// type it again, and a tidy that quietly kept half of it is a tidy that lost their
    /// words — so the transcript is the thing that gives way, and it says how much of it did.
    nonisolated static func promptBlock(notes: [MeetingScratchNote], transcript: String) -> String {
        var sections: [String] = []

        // A line that is only whitespace is skipped rather than sent: there is nothing in it
        // to tidy, and a numbered item with no words reads to a model as a numbered item
        // whose words were lost. It is not a note anyone typed, which is why dropping it
        // needs no marker.
        let said = notes.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let list = said.enumerated()
            .map { "\($0.offset + 1). \($0.element.text)" }
            .joined(separator: "\n\n")
        sections.append(
            said.isEmpty
                ? "\(Self.notesHeader)\n\(NotesPrompts.emptyMarker)"
                : "\(Self.notesHeader), in the order they were written:\n\n\(list)"
        )

        let speech = bounded(transcript)
        sections.append(speech.text.isEmpty
            ? "\(Self.transcriptHeader)\n\(NotesPrompts.emptyMarker)"
            : "\(Self.transcriptHeader)\n\n\(speech.text)")

        return sections.joined(separator: "\n\n")
    }

    /// The two block labels. Named rather than typed twice, because `parse` looks for the
    /// same words when a model echoes the prompt back.
    nonisolated static let notesHeader = "The person's own notes"
    nonisolated static let transcriptHeader = "What was said in the meeting so far"

    // MARK: - The pass

    /// Tidies `notes`, with `segments` as background. Off the main actor, cancellable, and
    /// it never keeps a model resident: the runtime unloads itself after its own idle window
    /// exactly as it does for the notes pass, which is the whole of "frees the runtime the
    /// way `NotesService` does" — there is nothing to call and nothing to add.
    @discardableResult
    static func run(
        meeting: Meeting,
        notes: [MeetingScratchNote],
        segments: [TranscriptSegment],
        provider: (any LLMProvider)?
    ) async -> Outcome {
        // The caller resolves the role's provider and disables its button when there is
        // none, so this is a guard rather than the ordinary path. The sentence is the one
        // the notes pass uses for the same absence, because it is the same absence.
        guard let provider else {
            Log.llm.info("scratchpad tidy: no model available for the meeting panel")
            return .noModel(NotesError.noProvider.localizedDescription)
        }

        let user = promptBlock(
            notes: notes,
            transcript: segments.plainText(speakerNames: meeting.speakerNames)
        )
        let began = Date()

        // Detached because a person is dictating a meeting on the same machine and the
        // panel is the thing they are looking at: a pass that began on the main actor would
        // put a token count's worth of stall in front of the first keystroke. The handler
        // is what makes cancelling the panel's task actually stop the model rather than
        // leave it decoding into a result nobody will read.
        let work = Task.detached(priority: .userInitiated) { () -> Outcome in
            await Self.pass(provider: provider, user: user, meetingID: meeting.id, began: began)
        }
        let outcome = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        LatencyTrace.record(.meetingNotes, seconds: Date().timeIntervalSince(began),
                             note: "scratchpad tidy \(outcomeName(outcome))")
        return outcome
    }

    private static func pass(
        provider: any LLMProvider,
        user: String,
        meetingID: UUID,
        began: Date
    ) async -> Outcome {
        do {
            try Task.checkCancellation()
            let completion = try await provider.complete(
                system: system, user: user, maxTokens: answerTokens
            )
            try Task.checkCancellation()

            let document = parse(completion.text)
            let systemTokens = (try? await provider.countTokens(Self.system)) ?? 0
            let userTokens = (try? await provider.countTokens(user)) ?? 0
            let promptTokens = systemTokens + userTokens
            record(
                provider: provider, meetingID: meetingID, began: began,
                promptTokens: promptTokens, completionTokens: completion.generatedTokens,
                finishReason: completion.finishedByLimit ? "length" : "stop",
                truncated: completion.finishedByLimit, error: nil
            )
            Log.llm.info("""
                scratchpad tidy · \(provider.displayModelName, privacy: .public) · \
                \(completion.generatedTokens, privacy: .public) tokens in \
                \(Int(completion.duration), privacy: .public)s\
                \(completion.finishedByLimit ? " (cut short)" : "", privacy: .public)
                """)
            // An answer of only headings and empty markers is a complete document that says
            // nothing, and showing it as a tidy would be the pass claiming work it did not do.
            guard !isBlank(document) else {
                return .failed("There was nothing in your notes to tidy.")
            }
            return completion.finishedByLimit ? .cutShort(document) : .wrote(document)
        } catch is CancellationError {
            // The panel's task was cancelled, so nobody is waiting for this. The caller
            // checks its own cancellation before it shows anything, which is why this
            // carries a sentence rather than a case of its own.
            return .failed("The tidy pass stopped before it finished.")
        } catch {
            record(
                provider: provider, meetingID: meetingID, began: began,
                promptTokens: nil, completionTokens: nil,
                finishReason: "error", truncated: nil, error: error
            )
            Log.llm.error("scratchpad tidy failed: \(error.localizedDescription, privacy: .public)")
            // The one error worth naming in words: a prompt this Mac cannot hold is a
            // person's own notes being too many, and a raw provider message would be a
            // sentence about a window they cannot see.
            if NotesGenerator.isContextOverflow(error) {
                return .failed("Your notes are too long to tidy in one go. Keep the ones that "
                    + "matter and try again.")
            }
            return .failed("Your notes could not be tidied just now.")
        }
    }

    /// One `meeting.scratchpad.tidy` row, built directly rather than through
    /// `ModelPassRecorder` for the reason `UsageRecord.feature` is a `String`: the recorder
    /// takes a `UsageFeature` case, and the nearest one would file this pass under the
    /// notes model's own row, which is the one thing `--usage-report` must not be able to
    /// get wrong. Nothing in the row is the person's text — the notes went into the model
    /// call and stayed there.
    private static func record(
        provider: any LLMProvider,
        meetingID: UUID,
        began: Date,
        promptTokens: Int?,
        completionTokens: Int?,
        finishReason: String,
        truncated: Bool?,
        error: Error?
    ) {
        let total = Int(Date().timeIntervalSince(began) * 1_000)
        UsageLog.shared.record(UsageRecord(
            v: 1,
            id: UUID(),
            ts: Date(),
            feature: feature,
            pass: "single",
            round: nil,
            provider: ModelPassRecorder.usageProvider(for: provider.id).rawValue,
            modelID: provider.displayModelName,
            locality: provider.id == .openRouter ? "cloud" : "local",
            requestedRole: ModelRole.meetingNotes.rawValue,
            requestedModel: provider.displayModelName,
            fallbackReason: nil,
            warm: nil,
            loadMs: nil,
            promptTokens: promptTokens,
            cachedTokens: nil,
            completionTokens: completionTokens,
            reasoningTokens: nil,
            countsEstimated: provider.id == .appleFoundation ? true : nil,
            ttftMs: nil,
            totalMs: total,
            tokensPerSec: Self.tokensPerSecond(completionTokens, total),
            finishReason: finishReason,
            truncated: truncated,
            toolsProposed: nil,
            toolsExecuted: nil,
            errorClass: error.map { UsageErrorClass.classify($0).rawValue },
            errorMessage: error.map { UsageLog.sanitise($0.localizedDescription) },
            audioSeconds: nil,
            realtimeFactor: nil,
            stages: nil,
            counts: nil,
            turnID: nil,
            conversationID: nil,
            workID: nil,
            revision: nil,
            meetingID: meetingID,
            dictationRunID: nil,
            scheduleID: nil
        ))
    }

    private static func tokensPerSecond(_ tokens: Int?, _ milliseconds: Int) -> Double? {
        guard let tokens, milliseconds > 0, tokens > 0 else { return nil }
        return Double(tokens) / (Double(milliseconds) / 1_000)
    }

    private static func outcomeName(_ outcome: Outcome) -> String {
        switch outcome {
        case .wrote: "wrote"
        case .cutShort: "cut-short"
        case .noModel: "no-model"
        case .failed: "failed"
        }
    }

    // MARK: - The transcript's share of the window

    /// The tail of `transcript`, with a marker whenever anything was left out.
    ///
    /// Whole lines rather than a character cut, so a line is never half a sentence in the
    /// prompt, and the marker counts the same "parts" the notes pass counts.
    private static func bounded(_ transcript: String) -> (text: String, dropped: Int, total: Int) {
        let lines = transcript.components(separatedBy: .newlines)
        let kept = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !kept.isEmpty else { return ("", 0, 0) }

        var tail: [String] = []
        var used = 0
        for line in kept.reversed() {
            // `+ 1` for the newline this line costs in the joined result.
            let cost = line.count + 1
            guard used + cost <= maxTranscriptCharacters else { break }
            tail.append(line)
            used += cost
        }
        tail.reverse()
        let dropped = kept.count - tail.count
        guard dropped > 0 else { return (tail.joined(separator: "\n"), 0, kept.count) }
        let marker = NotesPrompts.truncatedLine(dropped: dropped, of: kept.count)
        return ((tail.joined(separator: "\n") + "\n\n" + marker), dropped, kept.count)
    }

    // MARK: - The reply

    /// A model answer as the document the panel shows.
    ///
    /// Pure, and the reason the self-test exists: the interesting failures are all shapes of
    /// text — a fence, a `<think>` block, a preamble, an echoed prompt, a bold heading, a
    /// sub-bullet written with an en dash — and none of them can be checked with a model,
    /// which on the machine this ships from is usually not there at all.
    ///
    /// The output shape is the one the reference shows and the one `MarkdownView` draws: a
    /// heading line, `- ` bullets, and one level of sub-bullet indented two spaces. Nothing
    /// is invented: a heading with no body under it gets the empty marker rather than a
    /// sentence, and a line that is only a bullet marker is dropped rather than rendered as
    /// a bullet the person has to delete.
    nonisolated static func parse(_ reply: String) -> String {
        let lines = cleanedLines(reply)

        // Everything before the first heading or bullet is scaffolding: "Sure — here are
        // your notes:", and on a small model the prompt's own rules. It is dropped only when
        // there is structure to drop it in front of, because a reply with no structure at all
        // is one paragraph — there is nothing else it could be, and dropping it would lose
        // the only thing the model said. Spaces rather than newlines are what make it one.
        guard let first = lines.firstIndex(where: { $0.structured }) else {
            return lines.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var sections: [Section] = []
        // Where the bullet the next line might continue is, or nil after a heading and after
        // any unindented prose. Tracking the index rather than the text's shape means a
        // sub-bullet continues the same way a top-level one does.
        var openBullet: Int?
        for line in lines[first...] {
            if let heading = line.heading {
                sections.append(Section(heading: heading, body: []))
                openBullet = nil
                continue
            }
            if sections.isEmpty {
                // A bullet before any heading: its own unnamed section, kept rather than
                // promoted to a heading the model did not write.
                sections.append(Section(heading: nil, body: []))
            }
            let section = sections.count - 1
            if let text = line.bullet {
                // One level of nesting, because the document is flat and the panel draws one
                // level. A third level is folded onto the second rather than dropped.
                sections[section].body.append((line.indented ? "  - " : "- ") + text)
                openBullet = sections[section].body.count - 1
            } else {
                // A wrapped bullet line belongs to the bullet above it. Rendering it as its
                // own paragraph would break the list in half for a line the model merely ran
                // out of width on.
                if line.indented, let index = openBullet {
                    sections[section].body[index] += " " + line.text
                } else {
                    sections[section].body.append(line.text)
                    openBullet = nil
                }
            }
        }

        return sections.map { section -> String in
            var out: [String] = []
            if let heading = section.heading { out.append("## \(heading)") }
            if section.body.isEmpty {
                out.append(NotesPrompts.emptyMarker)
            } else {
                out.append(contentsOf: section.body)
            }
            return out.joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }

    /// True when a document says nothing: no heading, no bullet, and nothing but the empty
    /// marker. Mirrors `NotesFormatter.isBlank`, because it is the same judgement about a
    /// different document — a complete document of empty sections must not be shown as a
    /// document the pass wrote.
    nonisolated static func isBlank(_ document: String) -> Bool {
        document
            .components(separatedBy: .newlines)
            .allSatisfy { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty
                    || trimmed == NotesPrompts.emptyMarker
                    || trimmed.hasPrefix("## ")
            }
    }

    private struct Section {
        var heading: String?
        var body: [String]
    }

    /// One classified source line.
    private struct Line {
        /// The heading's words, nil when this line is not a heading.
        var heading: String?
        /// The bullet's words, nil when this line is not a bullet.
        var bullet: String?
        /// Anything else: prose, the empty marker, a stray `---`.
        var text: String
        /// Whether the line was indented in the reply, which is how a sub-bullet and a
        /// wrapped bullet line are told from a top-level one.
        var indented: Bool
        var structured: Bool { heading != nil || bullet != nil }
    }

    private static func cleanedLines(_ reply: String) -> [Line] {
        // A hybrid reasoning model's block, and the fence models wrap markdown in.
        let stripped = NotesFormatter.stripCodeFence(NotesFormatter.stripThinking(reply))
        // An echo of the prompt is the model writing the rules back at us. Dropping the
        // prompt's own lines by text is the only version of this that cannot drift: the set
        // is read out of `system`, so a reworded rule is dropped the day it is reworded.
        let echo = Set(
            system.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        )
        return stripped.components(separatedBy: .newlines).compactMap { raw in
            let text = raw.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty, !echo.contains(text), !isRule(text) else { return nil }
            let indented = raw.first == " " || raw.first == "\t"
            if let heading = heading(in: text) { return Line(heading: heading, bullet: nil,
                                                            text: text, indented: indented) }
            if let bullet = bullet(in: raw) { return Line(heading: nil, bullet: bullet,
                                                          text: text, indented: indented) }
            return Line(heading: nil, bullet: nil, text: text, indented: indented)
        }
    }

    /// A horizontal rule in any of the spellings GitHub-flavoured Markdown accepts. Dropped
    /// rather than kept: a rule between two sections is scaffolding, and the document the
    /// panel shows has no use for one.
    private static func isRule(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let marks = Set("#*-_")
        return text.allSatisfy { marks.contains($0) }
    }

    /// A heading however the model chose to mark one up: `## Decisions`, `### Decisions`, or
    /// a bare `**Decisions**`.
    ///
    /// Every level comes back as `##`, because the document this pass writes is flat — one
    /// level of heading, which is what the panel draws and what a person skims — and a level
    /// that reads as smaller than a section the reader has not met yet is a shape the app
    /// does not have.
    private static func heading(in text: String) -> String? {
        var body = text
        if body.hasPrefix("#") {
            body = String(body.drop(while: { $0 == "#" }))
        } else if body.hasPrefix("**"), body.count > 4, body.hasSuffix("**") {
            body = String(body.dropFirst(2).dropLast(2))
        } else {
            return nil
        }
        let name = body
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "#: "))
            .trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// A bullet, in any of the marks a model reaches for, with the words after it.
    ///
    /// A doubled mark is not a bullet — `**Bold**` is a heading and `--` is a rule — and a
    /// marker with nothing after it is not a bullet either, because rendering it would put
    /// an empty line in the document for the person to notice.
    private static func bullet(in raw: String) -> String? {
        let marks: Set<Character> = ["-", "*", "+", "\u{2022}", "\u{2013}", "\u{00B7}"]
        var index = raw.startIndex
        while index < raw.endIndex, raw[index] == " " || raw[index] == "\t" {
            index = raw.index(after: index)
        }
        guard index < raw.endIndex, marks.contains(raw[index]) else { return nil }
        let mark = raw[index]
        var rest = raw[raw.index(after: index)...]
        if rest.first == mark { return nil }
        while let first = rest.first, first.isWhitespace {
            rest = rest.dropFirst()
        }
        let text = rest.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }
}

import SwiftUI

/// The meeting panel's Notes section: the surface you write on by hand while the meeting
/// runs, and the one place a tidy of what you wrote appears.
///
/// Three decisions are load-bearing, and none of them is the layout.
///
/// **The composer's Return adds.** A person taking notes mid-meeting is looking at the
/// meeting, not at this pane, and a field that swallows what they typed until they find the
/// button loses it. So Return saves the line and leaves the caret exactly where it was —
/// copied from `AgentView`'s composer, which solved the same problem the same way — and
/// Shift-Return is the line break.
///
/// **The result appears underneath, and never instead.** The tidied document is a separate
/// card under the person's own lines, and keeping it is a separate, explicit act. That is
/// the same rule the rest of the app follows about unreviewed text: nothing the model wrote
/// is saved until the person says so. So "Keep this" appends the document to the scratchpad
/// as one pinned `MeetingScratchNote`, which is how it reaches `notes.md` — through the merge
/// `NotesService` already owns, at the end of the meeting.
///
/// **The rows are not a `List`.** The Dictation screen's list is deliberately non-selectable,
/// and a `List` here would be that same trade in the one place it costs the most: copy is how
/// a person gets a single fragment out of a set of notes, and a caret where a row should be
/// is a note they cannot copy. So the rows are a stack, and the text in them is selectable.
struct MeetingConsoleNotesSection: View {
    let session: MeetingSession

    @State private var draft = ""
    @State private var result: Tidy?
    @State private var problem: String?
    @State private var saveProblem: String?
    @State private var isTidying = false
    @State private var isKept = false
    @State private var pass: Task<Void, Never>?
    @FocusState private var composerFocused: Bool

    /// The tidied document, and the two claims the panel has to make about it: who wrote it
    /// and whether it is the whole of what they asked for.
    private struct Tidy {
        let document: String
        let writer: String
        let isCutShort: Bool
    }

    // MARK: - What the panel is doing

    /// The three answers, in the sheet's own words.
    ///
    /// `.writingNotes` while the tidy pass runs, because that pass *is* the model writing
    /// prose and the status row has to say so. `.transcribing` while the meeting is
    /// recording and nothing is being tidied, because a meeting that is still recording is
    /// two tracks being braided into one transcript. `.idle` otherwise — and `nil` for no
    /// orb is `MeetingConsoleActivity`'s own answer, so a panel at rest draws no shape at
    /// all.
    var activity: MeetingConsoleActivity {
        if isTidying { return .writingNotes }
        return session.isRecording ? .transcribing : .idle
    }

    // MARK: - The primary action

    /// The pill the panel draws over its content, in the two states it has.
    ///
    /// Disabled with a help that says *which* of the two things it needs is missing, rather
    /// than a dead button: a person who cannot tell why a button is grey will press it
    /// again, and one who is told "no note of yours yet" knows exactly what to do.
    var floatingAction: AnyView? {
        let canRun = !isTidying && hasSomethingToWorkFrom
        return AnyView(
            Button(action: tidy) {
                HStack(spacing: DS.Space.s) {
                    if isTidying {
                        // The same job the status row above is reporting, at badge size — and
                        // *still*, which is the whole point. The sheet's `LabeledOrb` is the
                        // one animating shape on this screen; a second live canvas naming the
                        // same pass would be two orbs for one job, and the reference's pill
                        // spinner is a shape the panel already draws elsewhere.
                        ThinkingOrb(state: .composing, size: DS.Size.orbBadge, isAnimated: false)
                    } else {
                        Image(systemName: "sparkles")
                    }
                    Text(isTidying ? "Writing the notes" : "Write the notes")
                        .font(DS.Font.callout)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canRun)
            .help(pillHelp)
            .animation(DS.Motion.consoleSectionChange, value: isTidying)
        )
    }

    /// Why the pill is or is not available, in one sentence naming what is missing.
    private var pillHelp: String {
        if isTidying { return "Turning your own lines into a tidied document." }
        if !hasSomethingToWorkFrom {
            return "Write a note of your own first."
        }
        return "Turn your own lines into a tidied document. Your lines are not changed."
    }

    /// The transcript is background for the tidier, never source material for new notes.
    /// With no line of the person's own, there is nothing this pass may write.
    private var hasSomethingToWorkFrom: Bool {
        !notes.isEmpty
    }

    // MARK: - Body

    var body: some View {
        // One read of the file for the whole pass, and the revision read is what registers
        // the dependency: `scratchpad(for:)` opens the file on every call, so there is no
        // cache to observe and `scratchpadRevision` is the only signal that a line landed.
        let notes = self.notes
        return VStack(alignment: .leading, spacing: DS.Space.section) {
            MeetingConsoleSectionHeader(section: .notes, subtitle: headerSubtitle, accessory: accessory(notes))
            if let problem {
                ProblemBanner(
                    message: problem,
                    retryTitle: "Try again",
                    retry: tidy,
                    dismiss: { self.problem = nil }
                )
            }
            if let saveProblem {
                ProblemBanner(message: saveProblem) { self.saveProblem = nil }
            }
            if notes.isEmpty, result == nil, !session.isRecording {
                emptyState
            } else {
                composer
                if !notes.isEmpty { lines(notes) }
                if let result { tidied(result) }
            }
        }
        // The panel closed: the model is decoding into a result nobody will read, and
        // `run`'s cancellation handler exists to stop it rather than to let it finish.
        .onDisappear {
            pass?.cancel()
            // Stop or a rail change removes this view, including its @State draft. Save a
            // line that was still in the field rather than making Return the only exit.
            saveDraft(refocus: false)
        }
    }

    /// One plain sentence, and never a claim that something is being worked on.
    ///
    /// This carries the empty state while the meeting is recording, which is the only time
    /// the panel is really empty: the `OrbUnavailableView` below is reserved for a panel with
    /// no meeting to hear, because a `breathing` orb beside the status row's `weaving` would
    /// be two animating orbs naming two different things on one screen. The reassurance that
    /// a person's own line is kept as written is the part a person mid-meeting actually needs,
    /// so it lives here rather than only in the orb state.
    private var headerSubtitle: String? {
        notes.isEmpty
            ? "Type anything you want to remember. It is yours, and it is kept as you write it."
            : nil
    }

    /// The count, or nothing. A chip that reads "0" is a piece of chrome saying nothing,
    /// and the empty state below already says there is nothing.
    private func accessory(_ notes: [MeetingScratchNote]) -> AnyView? {
        guard !notes.isEmpty else { return nil }
        return AnyView(
            StatusChip(
                text: notes.count == 1 ? "1 note" : "\(notes.count) notes",
                color: DS.Color.info,
                systemImage: "note.text"
            )
        )
    }

    /// Nothing at all — no line, no tidied document, and no meeting to hear.
    ///
    /// The orb is `breathing`, which is the vocabulary's word for "nothing here yet", and it
    /// is the only shape on the panel while this is what is drawn: `activity` is `.idle`
    /// here, so the sheet's status row has no orb of its own to put beside it. Widening
    /// this to "no note typed yet" would put a second animating orb on a screen whose status
    /// row is already saying the meeting is being braided together.
    private var emptyState: some View {
        OrbUnavailableView(
            .breathing,
            title: "Nothing written yet",
            message: "Type anything you want to remember while the meeting goes. It is yours, "
                + "and it is kept exactly as you write it.",
            // The panel already carries a field behind the whole content column; a second
            // one inside the empty state is the same texture drawn twice.
            hasField: false
        )
    }

    // MARK: - The composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            TextField("Type a note and press Return…", text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .frame(height: DS.Size.meetingConsoleNoteEditorHeight)
                .focused($composerFocused)
                .help("Return saves this line and leaves the cursor here. "
                    + "Shift-Return starts a new line.")
                // Plain Return adds; anything else is the text field's own newline. Copied
                // from `AgentView`'s composer, which is the other place a person types into
                // a panel they are not looking at.
                .onKeyPress(phases: .down) { press in
                    guard press.key == .return else { return .ignored }
                    if press.modifiers.contains(.shift)
                        || press.modifiers.contains(.option)
                        || press.modifiers.contains(.control) {
                        return .ignored
                    }
                    addNote()
                    return .handled
                }
            HStack {
                Spacer(minLength: DS.Space.s)
                Button(action: addNote) {
                    Label("Add", systemImage: "plus")
                }
                .disabled(trimmedDraft.isEmpty)
                .help("Save this line and keep the cursor in the field")
            }
        }
    }

    // MARK: - The person's own lines

    /// Pinned first, then the rest in the order they were typed — the same order
    /// `ScratchNotesMerger` writes them into the notes in, so what is read here and what
    /// lands at the end of the meeting are the same list.
    private func lines(_ notes: [MeetingScratchNote]) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            ForEach(ordered(notes)) { note in
                line(note)
            }
        }
    }

    private func line(_ note: MeetingScratchNote) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            Text(note.at, style: .time)
                .font(DS.Font.timestamp)
                .foregroundStyle(DS.Color.textTertiary)
            // Selectable, and multi-line: a line somebody typed across two lines is still
            // one line of theirs, and the view does not get to reflow it.
            Text(note.text)
                .font(DS.Font.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: DS.Space.xs) {
                Button {
                    setPinned(!note.isPinned, on: note)
                } label: {
                    Image(systemName: note.isPinned ? "pin.fill" : "pin")
                }
                .buttonStyle(.borderless)
                .help(note.isPinned ? "Unpin this line" : "Keep this line at the top")
                .accessibilityLabel(note.isPinned ? "Unpin this line" : "Pin this line")

                Button {
                    delete(note)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete this line")
                .accessibilityLabel("Delete this line")
            }
            .font(DS.Font.caption)
            .foregroundStyle(DS.Color.textSecondary)
        }
        .padding(.vertical, DS.Space.xs)
    }

    // MARK: - The tidied document

    private func tidied(_ tidy: Tidy) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                HStack(spacing: DS.Space.s) {
                    StatusChip(
                        text: "Written by \(tidy.writer)",
                        color: DS.Color.info,
                        systemImage: "sparkles"
                    )
                    // The one chip here that is not about who wrote it. A document that
                    // stopped mid-way is real and incomplete, and reading it as a finished
                    // one is the claim this whole feature is built not to make.
                    if tidy.isCutShort {
                        StatusChip(
                            text: "Cut short",
                            color: DS.Color.warning,
                            systemImage: "exclamationmark.triangle"
                        )
                    }
                    Spacer(minLength: DS.Space.s)
                    CopyButton(text: tidy.document, title: "Copy", help: "Copy these notes")
                }
                MarkdownView(markdown: tidy.document)
                HStack {
                    if isKept {
                        StatusChip(
                            text: "Added to your notes",
                            color: DS.Color.success,
                            systemImage: "checkmark"
                        )
                    } else {
                        Button("Keep this", action: keep)
                            .help("Add these notes to your own lines, where they will be "
                                + "kept with the meeting")
                    }
                    Spacer(minLength: DS.Space.s)
                }
            }
        }
    }

    // MARK: - The pass

    private func tidy() {
        guard !isTidying, hasSomethingToWorkFrom else { return }
        pass?.cancel()
        isTidying = true
        problem = nil
        isKept = false
        // The provider is resolved *before* the task starts so the button's disabled state
        // and the pass agree: one resolution, and the role that owns the notes model is the
        // one that answers, exactly as `NotesService` resolves it.
        let meeting = session.meeting
        let notes = self.notes
        let segments = session.segments
        pass = Task { @MainActor in
            let provider = await ModelRoleStore.shared.provider(for: .meetingNotes)
            let outcome = await MeetingScratchpadTidier.run(
                meeting: meeting, notes: notes, segments: segments, provider: provider
            )
            // A cancelled pass has nobody waiting for it: the panel closed, or a newer pass
            // started. Saying so would put a problem on screen for something the person did.
            guard !Task.isCancelled else { return }
            isTidying = false
            pass = nil
            // The name can only be absent if the pass answered without one, which
            // `run` refuses to do — the fallback is here so a chip can never read
            // "Written by " with nothing after it.
            let writer = provider?.displayModelName ?? "the assistant"
            switch outcome {
            case .wrote(let document):
                result = Tidy(document: document, writer: writer, isCutShort: false)
            case .cutShort(let document):
                result = Tidy(document: document, writer: writer, isCutShort: true)
            case .noModel(let why), .failed(let why):
                result = nil
                problem = why
            }
        }
    }

    // MARK: - Writing

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The line the person just typed, saved whole.
    ///
    /// `text` rather than `singleLine`, because a line they pressed Return inside is one
    /// note of theirs and this is not the place to reflow it. Focus goes back to the field
    /// afterwards, so the next line can be typed without a click.
    private func addNote() {
        saveDraft(refocus: true)
    }

    private func saveDraft(refocus: Bool) {
        let text = trimmedDraft
        guard !text.isEmpty else { return }
        var existing = notes
        existing.append(MeetingScratchNote(text: text))
        guard save(existing) else { return }
        draft = ""
        if refocus { composerFocused = true }
    }

    private func setPinned(_ pinned: Bool, on note: MeetingScratchNote) {
        var existing = notes
        guard let index = existing.firstIndex(where: { $0.id == note.id }) else { return }
        existing[index].isPinned = pinned
        _ = save(existing)
    }

    private func delete(_ note: MeetingScratchNote) {
        _ = save(notes.filter { $0.id != note.id })
    }

    /// The tidied document, kept. One pinned multi-line note rather than a document of
    /// them, so the merge at the end of the meeting puts one block under one heading
    /// instead of re-heading the same words once per line.
    private func keep() {
        guard let document = result?.document else { return }
        var existing = notes
        existing.append(MeetingScratchNote(text: document, isPinned: true))
        if save(existing) { isKept = true }
    }

    /// Keep the editor and the previous file intact when a write fails. A note the person
    /// just typed must not disappear from the field before it has reached disk.
    private func save(_ notes: [MeetingScratchNote]) -> Bool {
        let id = session.meeting.id
        guard MeetingStore.shared.saveScratchpad(notes, for: id) else {
            saveProblem = "Your note couldn't be saved. Check that this Mac has free space, then try again."
            return false
        }
        saveProblem = nil
        // Stop may finish the meeting before this section disappears and saves its pending
        // draft. In that order the pipeline has already made notes.md, so fold the new line
        // into it now and refresh a detail view that may already be showing the page.
        if let status = MeetingStore.shared.meeting(id: id)?.status,
           (status == .summarizing || status == .extracting
                || status == .done || status.isFailure),
           !MeetingPipeline.saveManualNotesIfPresent(for: id, store: .shared) {
            NotesService.shared.reportSaveFailure(for: id)
            saveProblem = "Your note was saved, but the finished notes couldn't be updated."
        }
        return true
    }

    // MARK: - The store

    /// This meeting's hand-written lines, oldest first.
    private var notes: [MeetingScratchNote] {
        // Read for the dependency and not for the value — the one-word statement of which
        // store method is the observed one, the same reason `searchRevision` is.
        _ = MeetingStore.shared.scratchpadRevision
        return MeetingStore.shared.scratchpad(for: session.meeting.id)
    }

    /// Pinned first, the rest in the order they were typed.
    private func ordered(_ notes: [MeetingScratchNote]) -> [MeetingScratchNote] {
        notes.filter(\.isPinned) + notes.filter { !$0.isPinned }
    }
}

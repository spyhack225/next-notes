import SwiftUI

/// Window-owned work survives a trip to another section. It is cancelled when the window
/// closes, rather than when this section temporarily leaves the view hierarchy.
@MainActor
@Observable
final class MeetingConsoleNotesWork {
    struct Tidy {
        let document: String
        let writer: String
        let isCutShort: Bool
    }

    var result: Tidy?
    var problem: String?
    var isTidying = false
    var isKept = false
    @ObservationIgnored var pass: Task<Void, Never>?

    func cancel() {
        pass?.cancel()
        pass = nil
        isTidying = false
    }
}

/// The meeting panel's Notes section: the surface you write on by hand while the meeting
/// runs, and the one place a tidy of what you wrote appears.
///
/// The page is a single `.document` entry in the meeting's existing scratchpad. Editing
/// remains freeform in a rich editor. HTML preserves the page's formatting and Markdown
/// feeds the existing summary and notes.md path. Older captured lines stay below the page.
///
/// **The result appears underneath, and never instead.** The tidied document is a separate
/// card under the person's own lines, and keeping it is a separate, explicit act. That is
/// the same rule the rest of the app follows about unreviewed text: nothing the model wrote
/// is saved until the person says so. So "Keep this" appends the document to the scratchpad
/// as one pinned `MeetingScratchNote`, which is how it reaches `notes.md` — through the merge
/// `NotesService` already owns, at the end of the meeting.
///
/// **The rows are not a `List`.** Existing lines remain selectable and editable in place.
struct MeetingConsoleNotesSection: View {
    let session: MeetingSession
    let work: MeetingConsoleNotesWork

    @State private var document = ""
    @State private var documentHTML: String?
    @State private var documentID: UUID?
    @State private var isLoaded = false
    @State private var saveTask: Task<Void, Never>?
    @State private var editingNoteID: UUID?
    @State private var editingText = ""
    @State private var saveProblem: String?

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
        if work.isTidying { return .writingNotes }
        return session.isRecording ? .transcribing : .idle
    }

    // MARK: - The primary action

    /// Why the summary action is or is not available.
    private var pillHelp: String {
        if work.isTidying { return "Turning your own lines into a tidied document." }
        if !hasSomethingToWorkFrom {
            return "Write a note of your own first."
        }
        return "Turn your own lines into a tidied document. Your lines are not changed."
    }

    /// The transcript is background for the tidier, never source material for new notes.
    /// With no line of the person's own, there is nothing this pass may write.
    private var hasSomethingToWorkFrom: Bool {
        !notes.isEmpty || !document.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Body

    var body: some View {
        // One read of the file for the whole pass, and the revision read is what registers
        // the dependency: `scratchpad(for:)` opens the file on every call, so there is no
        // cache to observe and `scratchpadRevision` is the only signal that a line landed.
        let notes = self.notes
        return VStack(alignment: .leading, spacing: DS.Space.section) {
            MeetingConsoleSectionHeader(section: .notes, subtitle: headerSubtitle, accessory: accessory(notes))
            if let problem = work.problem {
                ProblemBanner(
                    message: problem,
                    retryTitle: "Try again",
                    retry: tidy,
                    dismiss: { work.problem = nil }
                )
            }
            if let saveProblem {
                ProblemBanner(message: saveProblem) { self.saveProblem = nil }
            }
            documentEditor
            let older = notes.filter { $0.kind == .line }
            if !older.isEmpty { lines(older) }
            if let result = work.result { tidied(result) }
        }
        .onAppear(perform: loadDocument)
        .onDisappear {
            saveTask?.cancel()
            saveDocument()
        }
        .preference(key: MeetingConsoleActivityPreference.self, value: activity)
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
        "Your own page. Write freely while the meeting continues."
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

    // MARK: - The page

    private var documentEditor: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                Text("Select text to format. Type / for blocks.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
                Spacer(minLength: DS.Space.s)
                Button(work.isTidying ? "Writing…" : "Write summary", systemImage: "sparkles", action: tidy)
                    .buttonStyle(.borderedProminent)
                    .disabled(work.isTidying || !hasSomethingToWorkFrom)
                    .help(pillHelp)
            }
            if isLoaded {
                MeetingRichEditor(html: documentHTML, markdown: document) { html, markdown in
                    documentHTML = html
                    document = markdown
                    scheduleSave()
                } onError: { message in
                    saveProblem = message
                }
                .frame(minHeight: DS.Size.meetingConsoleDocumentMinHeight)
                .background(DS.Color.content, in: RoundedRectangle(cornerRadius: DS.Radius.card))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.card)
                    .stroke(DS.Color.separator))
            }
            Text("Your page saves as you write. Use + beside a block to add another.")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
        }
    }

    private func loadDocument() {
        guard !isLoaded else { return }
        if let saved = notes.first(where: { $0.kind == .document }) {
            document = saved.text
            documentHTML = saved.richHTML
            documentID = saved.id
        }
        isLoaded = true
    }

    private func scheduleSave() {
        guard isLoaded else { return }
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            saveDocument()
        }
    }

    @discardableResult
    private func saveDocument() -> Bool {
        guard isLoaded else { return true }
        var current = notes
        let text = document
        let html = documentHTML
        if let index = current.firstIndex(where: { $0.id == documentID }) {
            if current[index].text == text && current[index].richHTML == html { return true }
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                current.remove(at: index)
            } else {
                current[index].text = text
                current[index].richHTML = html
            }
        } else {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
            let note = MeetingScratchNote(text: text, kind: .document, richHTML: html)
            documentID = note.id
            current.append(note)
        }
        return save(current)
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
        HStack(alignment: .top, spacing: DS.Space.s) {
            Text(note.at, style: .time)
                .font(DS.Font.timestamp)
                .foregroundStyle(DS.Color.textTertiary)
            if editingNoteID == note.id {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    TextEditor(text: $editingText)
                        .font(DS.Font.body)
                        .frame(height: DS.Size.meetingConsoleNoteEditorHeight)
                    HStack(spacing: DS.Space.s) {
                        Button("Save") { update(note) }
                            .buttonStyle(.borderedProminent)
                        Button("Cancel") { editingNoteID = nil }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(note.text)
                    .font(DS.Font.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: DS.Space.xs) {
                Button {
                    editingNoteID = note.id
                    editingText = note.text
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("Edit this note")
                .accessibilityLabel("Edit this note")
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

    private func tidied(_ tidy: MeetingConsoleNotesWork.Tidy) -> some View {
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
                    if work.isKept {
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
        guard !work.isTidying, hasSomethingToWorkFrom else { return }
        saveTask?.cancel()
        guard saveDocument() else { return }
        work.pass?.cancel()
        work.isTidying = true
        work.problem = nil
        work.isKept = false
        // The provider is resolved *before* the task starts so the button's disabled state
        // and the pass agree: one resolution, and the role that owns the notes model is the
        // one that answers, exactly as `NotesService` resolves it.
        let meeting = session.meeting
        let notes = self.notes
        let segments = session.segments
        work.pass = Task { @MainActor in
            let provider = await ModelRoleStore.shared.provider(for: .meetingNotes)
            let outcome = await MeetingScratchpadTidier.run(
                meeting: meeting, notes: notes, segments: segments, provider: provider
            )
            // A cancelled pass has nobody waiting for it: the panel closed, or a newer pass
            // started. Saying so would put a problem on screen for something the person did.
            guard !Task.isCancelled else { return }
            work.isTidying = false
            work.pass = nil
            // The name can only be absent if the pass answered without one, which
            // `run` refuses to do — the fallback is here so a chip can never read
            // "Written by " with nothing after it.
            let writer = provider?.displayModelName ?? "the assistant"
            switch outcome {
            case .wrote(let document):
                work.result = MeetingConsoleNotesWork.Tidy(
                    document: document, writer: writer, isCutShort: false)
            case .cutShort(let document):
                work.result = MeetingConsoleNotesWork.Tidy(
                    document: document, writer: writer, isCutShort: true)
            case .noModel(let why), .failed(let why):
                work.result = nil
                work.problem = why
            }
        }
    }

    // MARK: - Writing

    private func setPinned(_ pinned: Bool, on note: MeetingScratchNote) {
        var existing = notes
        guard let index = existing.firstIndex(where: { $0.id == note.id }) else { return }
        existing[index].isPinned = pinned
        _ = save(existing)
    }

    private func update(_ note: MeetingScratchNote) {
        var existing = notes
        guard let index = existing.firstIndex(where: { $0.id == note.id }) else { return }
        existing[index].text = editingText
        if save(existing) { editingNoteID = nil }
    }

    private func delete(_ note: MeetingScratchNote) {
        _ = save(notes.filter { $0.id != note.id })
    }

    /// The tidied document, kept. One pinned multi-line note rather than a document of
    /// them, so the merge at the end of the meeting puts one block under one heading
    /// instead of re-heading the same words once per line.
    private func keep() {
        guard let document = work.result?.document else { return }
        var existing = notes
        existing.append(MeetingScratchNote(text: document, isPinned: true))
        if save(existing) { work.isKept = true }
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

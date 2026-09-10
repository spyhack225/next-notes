import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One finished meeting: what it was, what it produced, and what to do about it.
///
/// Notes come first in the picker because they are the point of recording a meeting; the
/// transcript is the evidence behind them; the actions are what the meeting asked for, and
/// they come last because nothing there should be approved before the notes have been read.
struct MeetingDetailView: View {
    let meeting: Meeting

    @State private var store = MeetingStore.shared
    @State private var notesService = NotesService.shared
    @State private var diarization = DiarizationService.shared
    @State private var agent = AgentService.shared
    @State private var settings = Settings.shared
    @State private var tab = Tab.notes
    @State private var isConfirmingDelete = false
    @State private var isExporting = false
    @State private var isRenamingSpeakers = false

    private enum Tab: String, CaseIterable, Identifiable {
        case notes
        case transcript
        /// What the agent has offered to do about this meeting. Last because it is the only
        /// one that can change something outside Speechify, and because a meeting usually
        /// gets read before it gets acted on.
        case actions

        var id: String { rawValue }
        var title: String {
            switch self {
            case .notes: "Notes"
            case .transcript: "Transcript"
            case .actions: "Actions"
            }
        }
    }

    /// Reading `diarization.revision` is what re-evaluates this view when a clustering pass
    /// rewrites the transcript's speaker labels: `MeetingStore` caches transcripts, and
    /// nothing observes that cache.
    private var segments: [TranscriptSegment] {
        _ = diarization.revision
        return store.transcript(for: meeting.id)
    }

    /// The generated labels a rename sheet would list, in the order they were assigned.
    private var speakerLabels: [String] { MeetingDiarizer.labels(in: segments) }

    /// Read once per meeting rather than in `body`: notes are a file, and a computed
    /// property here would re-read it on every keystroke of the picker.
    @State private var notes: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            picker
            Divider()
            // Above the content rather than inside the empty state: a Regenerate that failed
            // on a meeting that already has notes leaves the previous model's notes on
            // screen, and without a banner the only thing the user sees is the spinner going
            // away and nothing changing.
            if let problem = notesService.problem(for: meeting.id) {
                ProblemBanner(
                    message: problem,
                    retryTitle: "Write again",
                    retry: canWriteNotes ? { notesService.summarize(meeting) } : nil
                ) {
                    notesService.clearProblem(for: meeting.id)
                }
            }
            if let problem = diarization.problem(for: meeting.id) {
                ProblemBanner(
                    message: problem,
                    retryTitle: "Identify again",
                    retry: canIdentifySpeakers ? { diarization.identifySpeakers(in: meeting) } : nil
                ) {
                    diarization.clearProblem(for: meeting.id)
                }
            }
            if let problem = agent.problem(for: meeting.id) {
                ProblemBanner(
                    message: problem,
                    retryTitle: "Review again",
                    retry: agent.isReady ? { agent.review(meeting, force: true) } : nil
                ) {
                    agent.clearProblem(for: meeting.id)
                }
            }
            if diarization.isRunning(meeting.id) {
                identifyingSpeakers
            }
            content
        }
        // The switch between Notes and Transcript is a change of subject, not a redraw:
        // it, the banners and the progress strip all move on the same spring.
        .animation(DS.Motion.fluid, value: tab)
        .animation(DS.Motion.fluid, value: isWritingNotes)
        .animation(DS.Motion.fluid, value: diarization.isRunning(meeting.id))
        // Keyed on the revision as well as the meeting: `notes.md` is a file, so a
        // regeneration that rewrites it changes nothing this view observes.
        .task(id: notesKey) { notes = store.notes(for: meeting.id) }
        .confirmationDialog(
            "Delete \u{201c}\(meeting.title)\u{201d}?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { store.delete(meeting) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The transcript, notes and any recorded audio are deleted. This can't be undone.")
        }
        .sheet(isPresented: $isRenamingSpeakers) {
            SpeakerNamesSheet(
                labels: speakerLabels,
                suggestions: meeting.attendees,
                initialNames: meeting.speakerNames
            ) { names in
                var renamed = meeting
                renamed.speakerNames = names
                store.save(renamed)
            }
        }
        .fileExporter(
            isPresented: $isExporting,
            document: TextDocument(text: exportText, contentType: exportType),
            contentType: exportType,
            defaultFilename: exportName
        ) { result in
            if case .failure(let error) = result {
                Log.meeting.error("export failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.m) {
                // The heading carries the meeting's state as a shape, so the pane says what
                // it is doing before anyone reads the chip below it. `lineLimit` is on the
                // heading rather than inside it: the only text here that can run to two
                // lines is the title, since no subtitle is passed.
                SectionHeading(
                    title: meeting.title,
                    orb: meeting.status.orb,
                    orbSize: DS.Size.orbSmall,
                    isOrbAnimated: isHeaderOrbAnimated
                )
                .lineLimit(2)
                Spacer()
                actions
            }

            HStack(spacing: DS.Space.s) {
                Text(meeting.start.formatted(date: .abbreviated, time: .shortened))
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
                if let duration = meeting.duration {
                    Text(duration.counterText)
                        .font(DS.Font.timestamp)
                        .foregroundStyle(DS.Color.textTertiary)
                }
                if meeting.status != .done {
                    StatusChip(text: meeting.status.displayName, color: meeting.status.chipColor)
                }
                if case .failed(let reason) = meeting.status {
                    Text(reason)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.warning)
                        .lineLimit(1)
                }
            }

            if let url = meeting.conferenceURL {
                Link(destination: url) {
                    Label(url.host() ?? url.absoluteString, systemImage: "video")
                        .font(DS.Font.caption)
                }
            }

            if !meeting.attendees.isEmpty {
                // Wraps rather than scrolls: an invite with a dozen people should push the
                // transcript down a line, not hide half the room behind a scroll bar.
                FlowLayout(spacing: DS.Space.xs) {
                    ForEach(meeting.attendees, id: \.self) { attendee in
                        StatusChip(text: attendee, systemImage: "person")
                    }
                }
            }
        }
        .padding(DS.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The page's texture rather than a second orb. A header band is exactly what
        // `DottedField` is for — it is drawn once and then costs nothing, where a backdrop
        // orb here would be a second canvas competing with the one the heading already has.
        .dottedField(opacity: DS.Opacity.fieldFaint, fade: .top)
    }

    /// Which view owns this pane's one animating orb.
    ///
    /// `writingNotes` and the diarizing strip each draw the orb for the job they are
    /// reporting on, and they draw it larger and beside the progress. While either is up,
    /// the heading's mark is still: the same word twice, on two canvases, is a redundancy
    /// and a battery cost rather than emphasis.
    private var isHeaderOrbAnimated: Bool {
        meeting.status.isActive && !isWritingNotes && !diarization.isRunning(meeting.id)
    }

    private var actions: some View {
        HStack(spacing: DS.Space.s) {
            CopyButton(text: copyText, help: "Copy \(tab.title.lowercased()) to clipboard")

            Menu {
                ForEach(LLMProviderID.allCases) { provider in
                    Button(regenerateTitle(provider)) {
                        // Switch to Notes first: the progress this starts is only visible
                        // there, and starting it from the Transcript tab otherwise looks
                        // like the button did nothing.
                        tab = .notes
                        notesService.summarize(meeting, using: provider)
                    }
                }
            } label: {
                Label("Regenerate", systemImage: "arrow.triangle.2.circlepath")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(!canWriteNotes)
            .help("Write the notes again with a chosen model")

            Menu {
                Button("Identify speakers") { diarization.identifySpeakers(in: meeting) }
                    .disabled(!canIdentifySpeakers)
                Button("Rename speakers…") { isRenamingSpeakers = true }
                    .disabled(speakerLabels.isEmpty)
                Divider()
                Button("Export…") { isExporting = true }
                    .disabled(exportText.isEmpty)
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([store.directory(for: meeting.id)])
                }
                if let audio = store.audioURL(for: meeting) {
                    Button("Reveal Recording") {
                        NSWorkspace.shared.activateFileViewerSelecting([audio])
                    }
                }
                Divider()
                Button("Delete…", role: .destructive) { isConfirmingDelete = true }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var picker: some View {
        Picker("View", selection: $tab) {
            ForEach(Tab.allCases) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.s)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .notes:
            if isWritingNotes {
                writingNotes
            } else if let notes, !notes.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Space.m) {
                        MarkdownView(markdown: notes)
                        if let model = meeting.notesModel {
                            Text("Written by \(model)")
                                .font(DS.Font.caption)
                                .foregroundStyle(DS.Color.textTertiary)
                        }
                    }
                    .padding(DS.Space.l)
                    // Notes are prose, and a detail pane on a wide display is far wider
                    // than a line anyone wants to read. Nothing else goes behind them: a
                    // dotted field under long-form text is texture in the way of reading.
                    .frame(maxWidth: DS.Size.readingWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                OrbUnavailableView(
                    emptyOrb,
                    title: "No notes",
                    message: notesPlaceholder
                )
            }
        case .transcript:
            if segments.isEmpty {
                OrbUnavailableView(
                    emptyOrb,
                    title: "No transcript",
                    message: transcriptPlaceholder
                )
            } else {
                TranscriptView(segments: segments, speakerNames: meeting.speakerNames)
            }
        case .actions:
            MeetingActionsView(meeting: meeting)
        }
    }

    /// The `.summarizing` state, with whatever the generator last said it was doing.
    ///
    /// A meeting summarised in one pass has no measurable progress — it is one generation
    /// of unknown length — so the bar is indeterminate until the map step gives it a
    /// fraction to show.
    private var writingNotes: some View {
        VStack(spacing: DS.Space.m) {
            // An orb rather than a spinner, because this wait is minutes long and a spinner
            // that has been turning for four minutes tells you nothing you didn't know a
            // second in. The determinate bar still appears underneath once the map step has
            // a fraction to report.
            ThinkingOrb(state: .composing, isInline: false)
            if let fraction = notesService.step(for: meeting.id)?.fraction {
                ProgressView(value: fraction)
                    .frame(width: DS.Size.progressWidth)
            }
            Text(notesService.step(for: meeting.id)?.message ?? MeetingStatus.summarizing.displayName)
                .font(DS.Font.callout)
                .foregroundStyle(DS.Color.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dottedField(opacity: DS.Opacity.fieldFaint)
    }

    /// The orb an empty tab shows: the state of whatever is standing between the user and
    /// the thing that is missing, not the emptiness itself.
    ///
    /// A transcript that is empty because the recording is still being transcribed shows
    /// `working`, not a shrug — the tab is then telling the same story as the heading and
    /// the list row, in the same shape. Once nothing is running, the cause is simply that
    /// there is nothing yet, which is `breathing`.
    private var emptyOrb: OrbGeometry.State { meeting.status.orb ?? .breathing }

    /// The `.diarizing` state. Progress is a real fraction here — the segmentation model
    /// works through the recording in fixed chunks and says how many it has done — so the
    /// bar is determinate from the first one.
    private var identifyingSpeakers: some View {
        HStack(spacing: DS.Space.m) {
            // `solving` means diarization and only diarization, so this strip is where a
            // person learns that shape. At the inline size, because it can overlap with
            // the notes orb — a user can ask for speakers while a regeneration runs — and
            // twenty points of inline tuning is a tenth of the dots of the one below it.
            LabeledOrb(
                state: .solving,
                title: MeetingStatus.diarizing.displayName,
                size: DS.Size.orbInline
            )
            ProgressView(value: diarization.fraction(for: meeting.id) ?? 0)
                .frame(width: DS.Size.progressWidth)
            Spacer()
        }
        .padding(.horizontal, DS.Space.l)
        .padding(.vertical, DS.Space.s)
        .background(DS.Color.groupedFill)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var isWritingNotes: Bool { notesService.isRunning(meeting.id) }

    private var canWriteNotes: Bool { !isWritingNotes && !segments.isEmpty }

    /// Speakers can only be identified while the recording still exists — the transcript
    /// alone has nothing to cluster.
    private var canIdentifySpeakers: Bool {
        !diarization.isRunning(meeting.id)
            && !segments.isEmpty
            && store.audioURL(for: meeting) != nil
    }

    /// The key `.task` watches: the meeting, plus every write of any `notes.md`.
    private var notesKey: String { "\(meeting.id)-\(notesService.revision)" }

    private func regenerateTitle(_ provider: LLMProviderID) -> String {
        provider == settings.notesProvider
            ? "\(provider.displayName) (default)"
            : provider.displayName
    }

    /// Says why there is nothing to read. A failure is not one of the cases: that is the
    /// banner's job, and it belongs there whether or not there are older notes underneath.
    private var notesPlaceholder: String {
        switch meeting.status {
        case .recording, .transcribing: return "Notes are written once the recording is transcribed."
        case .failed(let reason): return reason
        default:
            return segments.isEmpty
                ? "There is nothing in this transcript to write notes from."
                : "Nothing has been written yet. Regenerate writes notes from the transcript."
        }
    }

    private var transcriptPlaceholder: String {
        switch meeting.status {
        case .recording: "Speech appears here as each window of audio is transcribed."
        case .transcribing: "Finishing the last windows of audio…"
        case .diarizing: "Telling the speakers apart…"
        case .failed(let reason): reason
        default: "Nothing was recognised in this recording."
        }
    }

    // MARK: - Export

    private var copyText: String {
        switch tab {
        case .notes: notes ?? ""
        case .transcript: segments.plainText(speakerNames: meeting.speakerNames)
        // Nothing on the Actions tab is text the user would want on the clipboard: the
        // proposals are questions and the records are links, both of which have their own
        // buttons.
        case .actions: ""
        }
    }

    private var exportText: String { copyText }

    private var exportType: UTType {
        tab == .notes ? TextDocument.markdown : .plainText
    }

    private var exportName: String {
        let date = meeting.start.formatted(.iso8601.year().month().day())
        return "\(date) \(meeting.title) \(tab.title)"
    }
}

/// The document `fileExporter` needs. Text either way; the content type decides whether the
/// saved file is `.md` or `.txt`.
struct TextDocument: FileDocument {
    static let markdown = UTType(filenameExtension: "md") ?? .plainText
    static var readableContentTypes: [UTType] { [.plainText, markdown] }

    let text: String
    let contentType: UTType

    init(text: String, contentType: UTType = .plainText) {
        self.text = text
        self.contentType = contentType
    }

    init(configuration: ReadConfiguration) throws {
        let data = configuration.file.regularFileContents ?? Data()
        text = String(decoding: data, as: UTF8.self)
        contentType = configuration.contentType
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

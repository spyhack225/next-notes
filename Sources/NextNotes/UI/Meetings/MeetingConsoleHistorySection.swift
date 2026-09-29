import SwiftUI

/// The meeting panel's History section: the meetings before this one, and the reason each
/// one is in the list.
///
/// Four questions, one query (`MeetingRecall`), and a hard rule underneath all of them —
/// **a filter that cannot answer says so instead of answering a different question.** Two
/// of the four are a pass over the person's own meeting folders and answer on a Mac with
/// every switch off; the other two need something turned on in Settings, and the empty
/// state says which switch and where it lives rather than returning a list it cannot
/// explain.
///
/// The rows are the slice. A list of meetings that cannot say why it is here reads exactly
/// like a confident answer, and a person in the middle of a meeting has no way to tell the
/// two apart — so every row carries the one sentence the query wrote for it, and that
/// sentence is the only coloured thing in the row.
struct MeetingConsoleHistorySection: View {
    let session: MeetingSession

    @State private var store = MeetingStore.shared
    @State private var settings = Settings.shared
    @State private var navigation = NavigationState.shared
    @State private var filter: MeetingRecallFilter = .recent
    /// The rows, and the question they were asked under. Carrying the filter with them is
    /// what makes a stale answer undrawable rather than merely unlikely.
    @State private var answer: Answer?
    /// Non-zero while a `hits` call is in flight. A ticket rather than a flag: two runs
    /// overlap whenever the key changes mid-query, and a plain `Bool` cleared by whichever
    /// finished last would drop the status row to idle over a search that is still going.
    @State private var runTicket = 0
    @Environment(\.dismiss) private var dismiss

    /// What the query answered, and what it was asked. The filter is not decoration: it is
    /// the check that keeps the previous question's rows off a screen now wearing the new
    /// question's heading.
    private struct Answer: Equatable {
        let filter: MeetingRecallFilter
        let hits: [MeetingRecallHit]
    }

    /// Everything that changes what the answer would be.
    ///
    /// `status` rather than the whole meeting, and that is not a shortcut: a live session
    /// rewrites its meeting on every transcript write and ticks `elapsed` every second, so
    /// a key built from either would restart this query sixty times a minute. The *status*
    /// is the part that changes the question — diarization and speaker renames add people to
    /// the meeting being asked about, and "the same people" is measured against that.
    ///
    /// `searchRevision` is the indexer's own signal that a batch of search text has landed,
    /// and `stored` is `MeetingStore`'s: two of the four filters are a pass over that array,
    /// so a meeting arriving or leaving changes them without any switch moving.
    private struct QueryKey: Equatable {
        let meetingID: UUID
        let status: MeetingStatus
        let filter: MeetingRecallFilter
        let revision: Int
        let stored: Int
        let indexOn: Bool
        let graphOn: Bool
    }

    /// How many rows the panel asks for.
    ///
    /// More than fits at 520pt and more than anybody scrolls through, which is the point:
    /// this is a shortlist, and the fourth-most-recent meeting is one click away on the
    /// Meetings list, which is the screen built for browsing. It also bounds the two SQL
    /// answers, which over-fetch per row.
    private static let rowLimit = 20

    // MARK: - What the panel is showing

    /// `.lookingBack` while a search is running, and nothing else.
    ///
    /// The clause is about work happening *now*, so it is true from the frame the person
    /// picks a different question rather than from the frame the task happens to start —
    /// which is also why the wait below reads from the same predicate as this does, so the
    /// status row and the pane never disagree about whether a search is up.
    var activity: MeetingConsoleActivity {
        isRefreshing ? .lookingBack : .idle
    }

    /// Nothing here acts: History reads the person's own library and the meeting they are
    /// in is not something this section can change. The panel's one floating action belongs
    /// to the section that has one to offer.

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            MeetingConsoleSectionHeader(
                section: .history,
                // The four filters ask four different questions, and somebody who has just
                // switched between them deserves to see which one is being answered.
                subtitle: filter.question,
                accessory: AnyView(filterMenu)
            )
            content
        }
        .task(id: queryKey) { await search() }
        // The panel's own curve for changing what it is about. Without it a switch of
        // filter cuts from one list to another with nothing in between, which reads as a
        // jump rather than as an answer to a new question.
        .animation(DS.Motion.consoleSectionChange, value: filter)
    }

    // MARK: - The filter

    /// The question being asked, named on a control rather than spread across four labels.
    ///
    /// A segmented `Picker` was the first shape and it does not fit: the panel is 520pt
    /// wide with a 168pt rail, so the content column is about 344pt, and "Same people",
    /// "Same topic" and "Related" side by side truncate all three. A menu is also the
    /// reference's own answer to this — a dropdown whose items each carry a glyph.
    ///
    /// The options are a `Picker` inside the `Menu` rather than four `Button`s, which is
    /// `FormattingSettingsTab`'s shape: the trigger carries the current question's own
    /// symbol, the options keep their words, and the inline picker draws the checkmark
    /// against the selected one. A `Button`'s label is flattened to a title and a single
    /// image on macOS, so a tick drawn beside the text is the part that would be lost —
    /// and the tick is the part this control has to have.
    private var filterMenu: some View {
        Menu {
            Picker("Look back by", selection: $filter) {
                ForEach(MeetingRecallFilter.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label(filter.title, systemImage: filter.symbol)
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help(filter.help)
    }

    // MARK: - The list, and the four answers when there isn't one

    /// Four states, in the order a person can reach them, and each one its own sentence.
    ///
    /// A library with nothing in it comes before everything else because it is not a
    /// verdict about the filter at all: telling somebody whose search is switched off that
    /// they have no earlier meetings is a true sentence in the wrong place, and the switch
    /// is the wrong thing to send them to fix.
    @ViewBuilder
    private var content: some View {
        if others.isEmpty {
            // A stage, so the orb for one: nothing recorded *yet*, which is the same
            // answer the Meetings list gives a machine on its first recording.
            OrbUnavailableView(
                .breathing,
                title: "No earlier meetings",
                message: "Once you have recorded a second meeting, the ones before this one turn up here.",
                // The panel already carries a field behind the whole content column; a
                // second one inside the empty state is the same texture drawn twice.
                hasField: false
            )
        } else if availability != .ready {
            switchedOff
        } else if isRefreshing {
            looking
        } else if shown.isEmpty {
            nothingFound
        } else {
            rows
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, hit in
                if index > 0 { Divider() }
                row(hit)
            }
        }
    }

    /// One earlier meeting, and the sentence that says why it is here.
    ///
    /// The date and the title are ordinary ink; `why` is the accent, and it is the only
    /// coloured thing in the row. That is the whole emphasis budget for a screen the
    /// person is reading in the middle of a meeting, and it is spent on the part they
    /// cannot work out for themselves.
    private func row(_ hit: MeetingRecallHit) -> some View {
        Button {
            open(hit)
        } label: {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(hit.title)
                    .font(DS.Font.headline)
                    .foregroundStyle(DS.Color.text)
                    .lineLimit(1)

                Text(hit.at.formatted(date: .abbreviated, time: .omitted))
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)

                // Capped rather than clipped: a notes heading can be a whole sentence, and
                // a row that grows to fit one makes the list below it a column of guesses.
                Text(hit.why)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.accent)
                    .lineLimit(DS.Size.meetingConsoleHistoryPreviewLines)

                // Only the filters that are about people carry names, and `FlowLayout`
                // rather than a row of them because a meeting with six attendees in it is
                // three names on the first line and one on the second.
                if !hit.people.isEmpty {
                    FlowLayout(spacing: DS.Space.s) {
                        ForEach(hit.people, id: \.self) { person in
                            SpeakerLabel(name: person, color: DS.Color.speaker(named: person))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, DS.Space.xxs)
            // The token's height is the floor rather than the box, so the three filters
            // that carry no names keep the same rhythm as the one that does.
            .frame(minHeight: DS.Size.meetingConsoleHistoryRowHeight, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens that meeting")
    }

    // MARK: - The empty states

    /// The filter's own switch is off, so it cannot answer and will not answer something
    /// else instead.
    private var switchedOff: some View {
        OrbUnavailableView(
            // `connecting`, not `breathing`, and `MeetingActionsView` is the precedent: a
            // capability that is switched off is a connection that has not been made yet,
            // which is exactly what `connecting` means everywhere else in the app.
            .connecting,
            title: "\(filter.title) is off",
            message: offMessage,
            hasField: false
        ) {
            // The house way into Settings, and the one `MeetingActionsView` and the menu
            // bar both use. A button beats a sentence telling somebody where to click.
            SettingsLink { Text("Settings\u{2026}") }
        }
    }

    /// `MeetingRecall`'s sentence, and the one sentence this file adds to it.
    ///
    /// `reasonUnavailable` names Settings and the Agent screen, which is true and is where
    /// the switch is — but that screen is one long pane of switches, and the row that turns
    /// searching on cannot be quoted here without saying a word this app does not put in
    /// front of anybody. So the added sentence describes the switch instead of naming it.
    ///
    /// The obvious pointer, "the Search screen in the sidebar", is the one thing that
    /// cannot be used: `Sidebar.visibleSections` drops the Search row while the index is
    /// off, which is exactly the state this sentence is written for. So each case names
    /// something that *is* on screen — the control for one, a sidebar row for the other.
    /// One answer to that question stays in the query layer; the pointer is added here
    /// rather than by editing it.
    private var offMessage: String {
        let pointer: String
        switch availability {
        case .needsIndex:
            pointer = "It is the switch that puts your meetings' transcripts and notes into search."
        case .needsGraph:
            // Unlike Search, the Graph row is always drawn, so this one can name a place.
            pointer = "The map it builds is the Graph screen in the sidebar."
        case .ready:
            pointer = ""
        }
        return MeetingRecall.reasonUnavailable(availability) + "\n\n" + pointer
    }

    /// The wait, with no orb of its own.
    ///
    /// `.lookingBack` is the orb for this work and the sheet's status row is already
    /// drawing it beside "Looking through earlier meetings", so an empty state here would
    /// put a second animating canvas on one screen naming the same thing twice. One line of
    /// type says what this pass is doing; the mark beside it belongs to the panel.
    private var looking: some View {
        Text("Checking your earlier meetings\u{2026}")
            .font(DS.Font.emptyStateMessage)
            .foregroundStyle(DS.Color.textSecondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: DS.Size.emptyStateWidth)
            .frame(maxWidth: .infinity, minHeight: DS.Size.emptyStateMinHeight, alignment: .center)
    }

    /// The query answered, and the answer is empty — which is not the same as the filter
    /// being unavailable, and must not be dressed as it.
    private var nothingFound: some View {
        OrbUnavailableView(
            // `searching` by cause: a search ran and found nothing, which is the same
            // absence the Search screen gives an empty result set.
            .searching,
            title: "Nothing to show",
            message: emptyAnswer,
            hasField: false
        )
    }

    /// One sentence per filter, because the four questions have four different reasons for
    /// coming back empty and a shared sentence would be one the person cannot check. For
    /// two of them it is also the wrong claim: this filter asks about the words in *this*
    /// meeting's name, not about the whole library.
    private var emptyAnswer: String {
        switch filter {
        case .recent:
            "There is nothing else in your meetings yet."
        case .samePeople:
            "No other meeting had anyone from this one in it."
        case .sameTopic:
            "None of your other meetings used the same words as this one's name."
        case .related:
            "Nothing in the map connects to this meeting yet."
        }
    }

    // MARK: - The state the four states are decided from

    /// A search is up, or the rows on screen belong to a question that is no longer on
    /// screen. The second half is what makes the answer honest at the instant the filter
    /// changes, rather than one runloop turn later.
    private var isRefreshing: Bool {
        runTicket != 0 || answer?.filter != filter
    }

    /// The rows to draw. Empty while they belong to another question, which is how a
    /// previous filter's answer is kept off a screen wearing the new filter's heading for
    /// even one frame.
    private var shown: [MeetingRecallHit] {
        guard let answer, answer.filter == filter else { return [] }
        return answer.hits
    }

    /// Whether this filter can answer at all right now, from the two switches and nothing
    /// else.
    ///
    /// Read off `Settings` rather than off `KnowledgeIndexer.settings`, which is a computed
    /// property over the same two `UserDefaults` keys: the indexer cannot be observed, so a
    /// view reading it would keep saying "switched off" after the switch was turned on
    /// until the panel was opened again. The decision itself is not repeated here —
    /// `MeetingRecall.availability` is a pure function of the pair and is the only place
    /// that owns which filter needs what.
    private var availability: MeetingRecall.Availability {
        MeetingRecall.availability(indexEnabled: settings.knowledgeIndexEnabled,
                                   graphEnabled: settings.knowledgeGraphEnabled,
                                   filter: filter)
    }

    /// The meetings this one is being asked about, from the store rather than from the
    /// query. `MeetingRecall` leaves the current meeting out of every answer, so this is
    /// the same exclusion — and it is what tells an empty library apart from a filter that
    /// matched nothing, which are different sentences and different orbs.
    private var others: [Meeting] {
        store.meetings.filter { $0.id != session.meeting.id }
    }

    private var queryKey: QueryKey {
        QueryKey(meetingID: session.meeting.id, status: session.meeting.status, filter: filter,
                 revision: store.searchRevision, stored: store.meetings.count,
                 indexOn: settings.knowledgeIndexEnabled,
                 graphOn: settings.knowledgeGraphEnabled)
    }

    // MARK: - The query

    /// The one query, cancellable, and never applied twice.
    ///
    /// `.task(id:)` is the cancellable form the house already uses on the search screen: a
    /// new `queryKey` cancels the run in flight, so switching filters abandons the answer
    /// being fetched rather than racing it onto the screen. `MeetingRecall.hits` is
    /// `async` and unisolated and its SQL is already detached, so the wait is a query and
    /// at most an embedder — never a block on the main actor, which matters here because
    /// this panel is over a meeting that is still running.
    private func search() async {
        let ticket = runTicket + 1
        runTicket = ticket
        defer { if runTicket == ticket { runTicket = 0 } }

        let found = await MeetingRecall.hits(
            meeting: session.meeting,
            filter: filter,
            indexer: KnowledgeIndexer.shared,
            store: store,
            limit: Self.rowLimit
        )
        // A cancelled run has nothing to say, and a run that was overtaken by a different
        // question has nothing to draw. The rows it would have written are the previous
        // filter's, and they are already undrawable.
        guard !Task.isCancelled, filter == queryKey.filter else { return }
        answer = Answer(filter: filter, hits: found)
    }

    /// What a row is for: that meeting, opened at its first second.
    ///
    /// `at: 0` rather than the overload without a time, because a `transcriptFocus` is how
    /// a row's position becomes a jump and its token means a second press on the same row
    /// moves again; the plain overload is the one a result uses to open a meeting's notes.
    ///
    /// **The panel closes, and asking for it is the honest thing to do.** It is presented
    /// by `MeetingLiveView` as a sheet, so the moment this lands `MeetingsView` is showing
    /// the meeting that was tapped, the live view goes out of the hierarchy, and the sheet
    /// that was attached to it goes with it. The panel would close either way; dismissing
    /// makes the order deterministic instead of a side effect of somebody else's layout
    /// pass. The recording carries on regardless — the session is the controller's, not the
    /// panel's — and the live meeting is the first row of the Meetings list when the
    /// person wants it back. It happens on a tap and on nothing else: not on a filter
    /// change, not on a re-run, not when the meeting finishes.
    private func open(_ hit: MeetingRecallHit) {
        navigation.show(meeting: hit.meetingID, at: 0)
        dismiss()
    }
}

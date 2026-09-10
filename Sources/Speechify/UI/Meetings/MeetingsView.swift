import SwiftUI

/// The Meetings section: a list of meetings beside the one you're looking at.
///
/// A second list inside the window's detail column rather than a third navigation column,
/// because the window's sidebar already owns the app's top-level navigation and nesting a
/// `NavigationSplitView` inside another one gives up control of both columns' widths.
struct MeetingsView: View {
    @State private var controller = MeetingController.shared
    @State private var store = MeetingStore.shared
    @State private var navigation = NavigationState.shared
    @State private var calendar = CalendarService.shared
    @State private var scheduler = MeetingScheduler.shared
    @State private var selection: MeetingSelection?
    @State private var query = ""

    var body: some View {
        HSplitView {
            list
                .frame(
                    minWidth: DS.Size.meetingListMin,
                    idealWidth: DS.Size.meetingListIdeal,
                    maxWidth: DS.Size.sidebarMax
                )
            detail
                .frame(minWidth: DS.Size.meetingDetailMin, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(SidebarSection.meetings.title)
        // Across everything a meeting holds, not just its title: the thing you remember
        // about a call three weeks later is a sentence someone said, and a search that only
        // matched "Weekly sync" would never find it.
        .searchable(text: $query, prompt: Text("Search meetings"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                recordButton
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let problem = controller.problem {
                ProblemBanner(message: problem) { controller.dismissProblem() }
            }
        }
        .task { store.reload() }
        // Reading every transcript and every notes file is what searching the whole library
        // costs, and doing it inside `body` on the first keystroke freezes the field being
        // typed into. It is built once, off the main actor, the moment there is a query.
        .task(id: searchIndexKey) {
            if isSearching { await store.prepareSearchIndex() }
        }
        .task { await calendar.refresh() }
        // A meeting that starts anywhere — the menu bar, and from Phase 3 the scheduler —
        // opens itself here, so the section is never showing a stale meeting while another
        // one records. When the session ends, the selection moves from the live slot onto
        // the id it just vacated: the meeting you have been recording is still the one
        // worth looking at, and `selectedMeetingID` is already that id, so nothing else
        // would move it off the empty state.
        .onChange(of: controller.session?.meeting.id) { previous, id in
            if id != nil {
                selection = .live
            } else if let previous, selection == .live {
                selection = .meeting(previous)
            }
        }
        .onChange(of: navigation.selectedMeetingID) { _, id in
            guard let id else { return }
            selection = controller.session?.meeting.id == id ? .live : .meeting(id)
        }
        .onChange(of: selection) { _, value in
            if case .meeting(let id) = value { navigation.selectedMeetingID = id }
        }
        .onAppear {
            if selection == nil {
                selection = controller.session != nil
                    ? .live
                    : navigation.selectedMeetingID.map(MeetingSelection.meeting)
            }
        }
        .animation(DS.Motion.standard, value: controller.isRecording)
    }

    // MARK: - List

    private var live: Meeting? { controller.session?.meeting }

    /// What the calendar says is coming, whether or not Speechify has claimed it yet.
    private var upcomingEvents: [MeetingEvent] {
        let now = Date()
        return calendar.upcoming.filter { event in
            guard event.end > now, !event.isAllDay else { return false }
            // A calendar entry is a title and a time; there is nothing else in it to match,
            // so searching narrows it on the one field it has.
            return !isSearching || event.title.localizedCaseInsensitiveContains(query)
        }
    }

    /// Armed meetings whose calendar entry is no longer in the window — a moved or deleted
    /// event, or one that simply aged past the look-ahead. Shown so an armed recording is
    /// never invisible.
    /// Meetings already represented by a calendar row above — the armed ones, whose status
    /// the event row shows as a chip.
    private var claimedIDs: Set<UUID> {
        Set(upcomingEvents.compactMap { scheduler.meeting(for: $0)?.id })
    }

    private var upcomingMeetings: [Meeting] {
        let claimed = claimedIDs
        return store.meetings.filter { meeting in
            guard !claimed.contains(meeting.id) else { return false }
            switch meeting.status {
            case .scheduled, .armed: return meeting.start > Date()
            default: return false
            }
        }
        .filter { store.matches($0, query: query) }
        .sorted { $0.start < $1.start }
    }

    private var isSearching: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What makes the index build: the field having anything in it, and the library gaining
    /// a meeting while it does. Not the query itself — the haystacks don't depend on it.
    private var searchIndexKey: Int { isSearching ? store.meetings.count : 0 }

    /// Everything Upcoming doesn't already account for. Both halves of that section have to
    /// be subtracted, not just the meetings it lists: an armed meeting folded into its
    /// calendar row would otherwise appear a second time down here, filed under Past while
    /// it hasn't happened yet.
    private var past: [Meeting] {
        let liveID = live?.id
        let shownAbove = claimedIDs.union(upcomingMeetings.map(\.id))
        return store.meetings.filter {
            $0.id != liveID && !shownAbove.contains($0.id) && store.matches($0, query: query)
        }
    }

    private var list: some View {
        List(selection: $selection) {
            if let live {
                Section("Live") {
                    MeetingRow(meeting: live, isLive: true, elapsed: controller.elapsed)
                        .tag(MeetingSelection.live)
                }
            }

            if !upcomingEvents.isEmpty || !upcomingMeetings.isEmpty {
                Section("Upcoming") {
                    // Calendar entries are not selectable: there is nothing to show in the
                    // detail column until one has been recorded, and the row already
                    // carries both things worth doing with it.
                    ForEach(upcomingEvents) { event in
                        UpcomingEventRow(
                            event: event,
                            meeting: scheduler.meeting(for: event),
                            willRecord: scheduler.willAutoRecord(event)
                        )
                        .selectionDisabled()
                    }
                    ForEach(upcomingMeetings) { meeting in
                        MeetingRow(meeting: meeting)
                            .tag(MeetingSelection.meeting(meeting.id))
                    }
                }
            }

            if !past.isEmpty {
                Section("Past") {
                    ForEach(past) { meeting in
                        MeetingRow(meeting: meeting)
                            .tag(MeetingSelection.meeting(meeting.id))
                            .contextMenu {
                                Button("Delete", role: .destructive) { delete(meeting) }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        // Meetings move between the three sections as they are armed, recorded and
        // finished. Springing that is what makes a row look like it moved rather than like
        // one disappeared and another appeared somewhere else.
        .animation(DS.Motion.fluid, value: live?.id)
        .animation(DS.Motion.fluid, value: past.map(\.id))
        .animation(DS.Motion.fluid, value: upcomingMeetings.map(\.id))
        .overlay {
            if isSearching, upcomingEvents.isEmpty, upcomingMeetings.isEmpty, past.isEmpty {
                ContentUnavailableView.search(text: query)
            } else if store.meetings.isEmpty, upcomingEvents.isEmpty, live == nil {
                ContentUnavailableView(
                    "No meetings",
                    systemImage: SidebarSection.meetings.systemImage,
                    description: Text("Record one to get a transcript of both sides.")
                )
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .live:
            if let session = controller.session {
                MeetingLiveView(session: session)
            } else {
                placeholder
            }
        case .meeting(let id):
            if let meeting = store.meeting(id: id) {
                MeetingDetailView(meeting: meeting)
                    .id(meeting.id)
            } else {
                placeholder
            }
        case nil:
            placeholder
        }
    }

    /// Two different absences, and they want different answers.
    ///
    /// A library with meetings in it is waiting for a choice — `breathing`, the screen at
    /// rest. An empty one is waiting for a first recording, so it takes `weaving`: the orb
    /// for the thing the toolbar button is offering to start.
    ///
    /// This pane carries the orb rather than the list's own overlay because the orb is 96pt
    /// and the list column is two hundred; and because only one of the two may animate.
    @ViewBuilder
    private var placeholder: some View {
        if store.meetings.isEmpty, live == nil {
            OrbUnavailableView(
                .weaving,
                title: "No meetings yet",
                message: "Record one to get a transcript of both sides."
            )
        } else {
            OrbUnavailableView(
                .breathing,
                title: "No meeting selected",
                message: "Pick a meeting, or record one now."
            )
        }
    }

    // MARK: - Actions

    /// Three states, not two: between Stop and the last Parakeet window there are seconds
    /// where the session still exists but is no longer recording, and a button offering to
    /// record then only produces "a meeting is already being recorded".
    private var recordButton: some View {
        Button {
            Task {
                if controller.isRecording {
                    await controller.stop()
                } else {
                    await controller.startAdHoc()
                }
            }
        } label: {
            Label(recordTitle, systemImage: recordSymbol)
        }
        .buttonStyle(.borderedProminent)
        .tint(controller.isRecording ? DS.Color.record : DS.Color.accent)
        .disabled(controller.isFinishing)
        .help(recordHelp)
    }

    private var recordTitle: String {
        if controller.isFinishing { return "Finishing\u{2026}" }
        return controller.isRecording ? "Stop" : "Record meeting now"
    }

    private var recordSymbol: String {
        if controller.isFinishing { return "hourglass" }
        return controller.isRecording ? "stop.fill" : "record.circle"
    }

    private var recordHelp: String {
        if controller.isFinishing { return "Transcribing the last of the recording" }
        return controller.isRecording
            ? "Stop recording this meeting"
            : "Record what you and the others say"
    }

    private func delete(_ meeting: Meeting) {
        if selection == .meeting(meeting.id) { selection = nil }
        if navigation.selectedMeetingID == meeting.id { navigation.selectedMeetingID = nil }
        withAnimation(DS.Motion.standard) { store.delete(meeting) }
    }
}

/// What the detail column is showing. The live meeting is not addressed by id: it becomes a
/// past meeting the moment it stops, and the selection should follow it rather than empty.
enum MeetingSelection: Hashable {
    case live
    case meeting(UUID)
}

/// One meeting in the list.
private struct MeetingRow: View {
    let meeting: Meeting
    var isLive = false
    var elapsed: TimeInterval = 0

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.orbGap) {
            // The column is reserved whether or not there is a shape to put in it. A
            // finished meeting has no orb, and titles that jumped left on every row that
            // finished would make the list harder to scan rather than easier — the busy
            // rows are supposed to be the ones that stand out.
            MeetingStatusOrb(status: isLive ? .recording : meeting.status)

            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(meeting.title)
                    .font(DS.Font.headline)
                    .lineLimit(1)

                if isLive {
                    RecordingIndicator(elapsed: elapsed, compact: true)
                } else {
                    HStack(spacing: DS.Space.s) {
                        Text(meeting.start.formatted(date: .abbreviated, time: .shortened))
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.textSecondary)
                        if let duration = meeting.duration {
                            Text(duration.counterText)
                                .font(DS.Font.timestamp)
                                .foregroundStyle(DS.Color.textTertiary)
                        }
                    }
                }

                if meeting.status != .done, !isLive {
                    StatusChip(text: meeting.status.displayName, color: meeting.status.chipColor)
                }
            }
        }
        .padding(.vertical, DS.Space.xxs)
    }
}

/// One calendar entry that hasn't been recorded yet.
///
/// Two controls, because there are exactly two questions worth asking about a meeting that
/// hasn't started: will it record itself, and should it start right now. The toggle writes
/// a permanent per-event answer, which beats the global switch in either direction; the
/// button ignores the lead time entirely.
private struct UpcomingEventRow: View {
    let event: MeetingEvent
    let meeting: Meeting?
    let willRecord: Bool

    @State private var settings = Settings.shared
    @State private var scheduler = MeetingScheduler.shared
    @State private var controller = MeetingController.shared

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.orbGap) {
            // Only the entries Speechify has actually claimed get a mark. `breathing` means
            // waiting on purpose, and an event the checkbox has been turned off for is not
            // waiting for anything — so the orb here is the same answer the checkbox gives,
            // readable a whole column away.
            MeetingStatusOrb(state: isClaimed ? .breathing : nil)

            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                HStack(spacing: DS.Space.s) {
                    Text(event.title)
                        .font(DS.Font.headline)
                        .lineLimit(1)
                    if event.conferenceURL != nil {
                        Image(systemName: "video")
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.textSecondary)
                    }
                }

                HStack(spacing: DS.Space.s) {
                    Text(event.start.formatted(date: .omitted, time: .shortened))
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                    Text(event.calendarName)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textTertiary)
                        .lineLimit(1)
                }

                if meeting?.status == .armed {
                    StatusChip(text: MeetingStatus.armed.displayName, color: DS.Color.info)
                }

                HStack(spacing: DS.Space.s) {
                    Toggle("Record", isOn: recordBinding)
                        .toggleStyle(.checkbox)
                        .font(DS.Font.caption)
                    Spacer(minLength: DS.Space.xs)
                    Button("Record now") {
                        Task { await scheduler.recordNow(event) }
                    }
                    .buttonStyle(.link)
                    .disabled(controller.session != nil)
                }
            }
        }
        .padding(.vertical, DS.Space.xxs)
    }

    /// Whether this calendar entry is going to become a recording.
    private var isClaimed: Bool { willRecord || meeting?.status == .armed }

    /// Writing an explicit answer rather than clearing back to the heuristic: the user
    /// touching this control *is* the answer, and a toggle that silently reverts to
    /// whatever the rule decides is a toggle that doesn't work.
    ///
    /// Ticking it back on has to lift this launch's skip as well as write the override,
    /// because the skip is checked first: without that, the box would snap straight back
    /// off and the meeting the user just asked for would never be armed.
    private var recordBinding: Binding<Bool> {
        Binding(
            get: { willRecord },
            set: { isOn in
                settings.setAutoRecordOverride(isOn, forEvent: event.overrideKey)
                if isOn {
                    scheduler.unskip(event)
                } else {
                    scheduler.skip(event)
                }
            }
        )
    }
}

extension MeetingStatus {
    /// Status colours are text colours, never the meter palette.
    var chipColor: Color {
        switch self {
        case .scheduled, .armed: DS.Color.info
        case .recording: DS.Color.record
        case .transcribing, .diarizing, .summarizing: DS.Color.accent
        case .done: DS.Color.success
        case .failed: DS.Color.warning
        }
    }
}

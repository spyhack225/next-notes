import AppKit
import Foundation
import Observation

/// Turns calendar entries into recordings without being asked twice.
///
/// One clock, ticking every thirty seconds, doing four things in order: arm what is about
/// to start, start what is armed, stop what has run past its end, and clean up what never
/// got the chance. Everything it decides is derived from `CalendarService.upcoming` and the
/// meetings already on disk, so a relaunch mid-meeting picks up exactly where it left off
/// rather than re-arming an event that has already been recorded.
///
/// The rule underneath all of it: a meeting is armed once. An event that produced a
/// `Meeting` — finished, failed or skipped — is never claimed again, because the second
/// recording of a meeting is always the wrong one.
@MainActor
@Observable
final class MeetingScheduler {
    static let shared = MeetingScheduler()

    /// Thirty seconds is half the shortest useful lead time, so an event is never armed
    /// more than half a minute late, and it costs one pass over a cached array.
    static let tickInterval: TimeInterval = 30
    /// How long past the scheduled end to keep recording. Meetings overrun; five minutes
    /// catches the "one last thing" without recording the next hour of an empty room.
    static let overrunGrace: TimeInterval = 5 * 60
    /// Stop a scheduled recording after this much silence on both tracks. The case it
    /// exists for is a call that ended without anyone touching Speechify.
    static let silenceTimeout: TimeInterval = 10 * 60
    /// How long an armed meeting may wait for a busy session before it is written off.
    static let armedGrace: TimeInterval = 10 * 60

    /// Events the user said no to, in memory, so a veto applies without a round trip to
    /// `Settings`.
    ///
    /// It is a cache, not the record: every refusal is also written to
    /// `Settings.meetingAutoRecordOverrides`, which survives a relaunch. The key is per
    /// *occurrence*, so declining today's stand-up says nothing about tomorrow's.
    private(set) var skipped: Set<String> = []

    private let store: MeetingStore
    private let controller: MeetingController
    private let calendar: CalendarService

    private var tick: Task<Void, Never>?

    init(
        store: MeetingStore = .shared,
        controller: MeetingController = .shared,
        calendar: CalendarService = .shared
    ) {
        self.store = store
        self.controller = controller
        self.calendar = calendar
    }

    // MARK: - Lifecycle

    func start() {
        guard tick == nil else { return }

        Notifications.shared.observe { [weak self] action in
            self?.handle(action)
        }

        tick = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.runOnce()
                try? await Task.sleep(for: .seconds(Self.tickInterval))
            }
        }
        Log.meeting.info("meeting scheduler running")
    }

    func stop() {
        tick?.cancel()
        tick = nil
    }

    /// One pass. Separated from the loop so the self-test can run it directly.
    func runOnce(now: Date = Date()) async {
        armDueEvents(now: now)
        await startArmedMeetings(now: now)
        await stopFinishedMeeting(now: now)
    }

    // MARK: - Queries the UI asks

    /// The armed meeting created for this event, if there is one.
    func meeting(for event: MeetingEvent) -> Meeting? {
        store.meetings.first {
            $0.calendarEventID == event.id && $0.providerID == event.providerID.rawValue
        }
    }

    /// Whether this event will be recorded on its own, as things stand.
    func willAutoRecord(_ event: MeetingEvent) -> Bool {
        guard !skipped.contains(event.overrideKey) else { return false }
        return Self.shouldAutoRecord(
            event,
            globallyEnabled: Settings.shared.meetingsAutoRecord,
            override: Settings.shared.autoRecordOverride(forEvent: event.overrideKey)
        )
    }

    /// Records an upcoming event right now, whatever its lead time says.
    @discardableResult
    func recordNow(_ event: MeetingEvent) async -> Bool {
        skipped.remove(event.overrideKey)
        IslandState.shared.clearArmed(event)
        // Only an armed meeting is reused. One that already ran is a finished recording
        // with a transcript in it, and starting a session on it would overwrite both.
        let existing = meeting(for: event)
        // A meeting still in flight is not a question any more, however stale the card that
        // asked it. Arming a second one for the same event would save a duplicate that the
        // next tick writes off as "another meeting was being recorded", and leave that
        // failure in the list for good.
        if let existing, existing.status.isActive { return false }
        let meeting = existing?.status == .armed
            ? existing!
            : arm(event, now: Date(), announce: false)
        Notifications.shared.withdrawMeetingArmed(meetingID: meeting.id)
        return await controller.start(meeting: meeting)
    }

    /// Takes back a refusal, so an event that was skipped can be armed again.
    ///
    /// Without this the veto outlives the answer: `willAutoRecord` consults `skipped`
    /// first, so an event the user skipped and then changed their mind about would keep
    /// reporting "no" however explicitly they said yes, until the next launch.
    func unskip(_ event: MeetingEvent) {
        skipped.remove(event.overrideKey)
    }

    /// Refuses one occurrence: the armed meeting is removed and the event is not claimed
    /// again this launch.
    func skip(_ event: MeetingEvent) {
        skipped.insert(event.overrideKey)
        IslandState.shared.clearArmed(event)
        guard let meeting = meeting(for: event), meeting.status == .armed else { return }
        Notifications.shared.withdrawMeetingArmed(meetingID: meeting.id)
        store.delete(meeting)
    }

    // MARK: - The four things a tick does

    /// Creates the `Meeting` and announces it, `leadMinutes` before the start time.
    private func armDueEvents(now: Date) {
        let settings = Settings.shared
        let lead = TimeInterval(settings.meetingLeadMinutes) * 60

        for event in calendar.upcoming {
            guard willAutoRecord(event) else { continue }
            // Already claimed — including by a meeting that failed. Re-arming a failure
            // would restart a recording the user has already seen go wrong.
            guard meeting(for: event) == nil else { continue }
            // Inside the window: past the lead time, not past the end.
            guard now >= event.start.addingTimeInterval(-lead), now < event.end else { continue }

            _ = arm(event, now: now, announce: true)
        }
    }

    /// Starts anything armed whose time has come, and writes off anything that missed it.
    private func startArmedMeetings(now: Date) async {
        for meeting in store.meetings where meeting.status == .armed {
            let scheduledEnd = meeting.end ?? meeting.start.addingTimeInterval(Self.armedGrace)

            // Too late: either the meeting is over, or a session that was already running
            // held on past the point where recording the rest would be worth anything.
            if now >= scheduledEnd.addingTimeInterval(Self.armedGrace) {
                var missed = meeting
                missed.status = .failed(
                    controller.session == nil
                        ? "Speechify wasn't running when this meeting started."
                        : "Another meeting was being recorded when this one started."
                )
                store.save(missed)
                Notifications.shared.withdrawMeetingArmed(meetingID: meeting.id)
                IslandState.shared.clearArmed(meetingID: meeting.id)
                continue
            }

            guard now >= meeting.start else { continue }
            // One session at a time. `MeetingController` refuses a second one anyway; not
            // asking keeps its problem banner for things the user did.
            guard controller.session == nil else { continue }

            // The banner and the island asked the same question; the meeting starting is
            // the answer, so both come down together.
            Notifications.shared.withdrawMeetingArmed(meetingID: meeting.id)
            IslandState.shared.clearArmed(meetingID: meeting.id)
            let started = await controller.start(meeting: meeting)
            if started {
                Log.meeting.info("""
                    auto-started "\(meeting.title, privacy: .public)" from \
                    \(meeting.providerID ?? "calendar", privacy: .public)
                    """)
            } else {
                // A start can fail before the session has written any status at all — a
                // denied microphone throws from its first guard — and the meeting is then
                // still armed, so the next tick tries again, and the next: one refusal
                // becomes the same problem banner every thirty seconds for the length of
                // the meeting. Recording the failure is what makes "claimed once" hold for
                // starting as well as for arming.
                var failed = meeting
                failed.status = .failed(
                    controller.problem ?? "This meeting couldn't start recording."
                )
                store.save(failed)
                Log.meeting.error("""
                    couldn't auto-start "\(meeting.title, privacy: .public)"; \
                    not retrying this meeting
                    """)
            }
        }
    }

    /// Stops a scheduled recording that has outlived its meeting.
    ///
    /// Only ever a calendar-backed one: an ad-hoc recording was started by hand and is
    /// stopped by hand, and a silence rule applied to it would cut off the deliberately
    /// quiet recording someone left running on purpose.
    private func stopFinishedMeeting(now: Date) async {
        guard let session = controller.session, session.isRecording else { return }
        guard session.meeting.calendarEventID != nil else { return }

        let overran = session.meeting.end.map { now >= $0.addingTimeInterval(Self.overrunGrace) }
            ?? false
        let silent = now.timeIntervalSince(session.lastSpeechAt) >= Self.silenceTimeout
        guard overran || silent else { return }

        Log.meeting.info("""
            auto-stopping "\(session.meeting.title, privacy: .public)" — \
            \(overran ? "past its end time" : "silent for ten minutes", privacy: .public)
            """)
        await controller.stop()
    }

    // MARK: - Internals

    @discardableResult
    private func arm(_ event: MeetingEvent, now: Date, announce: Bool) -> Meeting {
        // `end` carries the *scheduled* end at this point, which is what the auto-stop
        // rule reads. `MeetingSession` overwrites both ends when the recording really
        // starts and stops.
        let meeting = Meeting(
            title: event.title,
            start: event.start,
            end: event.end,
            calendarEventID: event.id,
            providerID: event.providerID.rawValue,
            attendees: event.attendees,
            conferenceURL: event.conferenceURL,
            calendarName: event.calendarName,
            status: .armed
        )
        store.save(meeting)

        if announce {
            Notifications.shared.postMeetingArmed(meeting: meeting, startsAt: event.start)
            // The same question, in the place the user is already looking. The banner
            // reaches them in another app; the island reaches them at the top of the screen
            // they are looking at, and either answer takes both down.
            IslandState.shared.announceArmed(event)
            Log.meeting.info("""
                armed "\(event.title, privacy: .public)" starting \
                \(event.start.timeIntervalSince(now).rounded(), privacy: .public)s from now
                """)
        }
        return meeting
    }

    private func handle(_ action: Notifications.Action) {
        switch action {
        case .recordNow(let id):
            guard let meeting = store.meeting(id: id), meeting.status == .armed else { return }
            Task { await controller.start(meeting: meeting) }
        case .skip(let id):
            guard let meeting = store.meeting(id: id), meeting.status == .armed else { return }
            if let key = Self.overrideKey(of: meeting) {
                skipped.insert(key)
                // Written through to the persisted override as well, not just held for this
                // launch. The armed meeting is deleted a line below, so an in-memory refusal
                // leaves nothing on disk saying no: quitting before the start time — which
                // is exactly what someone who just declined to record a meeting might do —
                // brought the app back up, re-armed it, and recorded the meeting anyway.
                // `overrideKey` is per *occurrence*, so this refuses today's instance
                // without touching the rest of a recurring series.
                Settings.shared.setAutoRecordOverride(false, forEvent: key)
            }
            store.delete(meeting)
        case .open(let id):
            NavigationState.shared.show(meeting: id)
            AppDelegate.showMainWindow()
        case .approveProposal, .dismissProposal:
            // Not the scheduler's business. Phase 7's agent registers its own observer.
            break
        }
    }

    /// The override key a meeting came from, reassembled from what it stored.
    private static func overrideKey(of meeting: Meeting) -> String? {
        guard let providerID = meeting.providerID, let eventID = meeting.calendarEventID else {
            return nil
        }
        return "\(providerID):\(eventID)"
    }

    /// Whether an event is the kind worth recording.
    ///
    /// Pure and static so `--selftest-calendar` can exercise the decision against invented
    /// events without a calendar, a clock, or a microphone.
    ///
    /// An explicit per-event answer wins over everything except the two hard exclusions:
    /// an all-day block is not a meeting, and an invitation the user declined is not
    /// theirs to record. Otherwise it takes a conference link or at least one other
    /// attendee — the two things that distinguish a meeting from a reminder.
    static func shouldAutoRecord(
        _ event: MeetingEvent,
        globallyEnabled: Bool,
        override: Bool?
    ) -> Bool {
        guard !event.isAllDay else { return false }
        guard event.isOrganizerOrSelfAccepted else { return false }
        if let override { return override }
        guard globallyEnabled else { return false }
        return event.conferenceURL != nil || !event.attendees.isEmpty
    }
}

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
    /// exists for is a call that ended without anyone touching Next Notes.
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
    private let calls: CallDetector

    private var tick: Task<Void, Never>?

    /// Detected-call notifications, in the order they arrived, one at a time.
    ///
    /// Answering one suspends — retiring a call that is being recorded drains the last
    /// transcription windows out of the session, which takes seconds — and the detector goes
    /// on sampling while it does. Given a task each, two notifications interleaved: the
    /// older one resumed after the newer one had finished and wrote its own stale call over
    /// `handledCall`, so the newer call's armed meeting and island card were left with
    /// nothing that would ever take them down. It also put two `controller.stop()` calls on
    /// one session, the second clearing `MeetingController.session` while the first was
    /// still draining it.
    private var callWork: Task<Void, Never>?

    /// The detected call the scheduler has already answered for.
    ///
    /// `CallDetector` reports a call the moment it settles and again when it changes or
    /// ends, and the answer to "is this a new call?" has to survive between those two — the
    /// armed meeting cannot be that record, because a call the user skipped has no meeting
    /// left and would otherwise be armed again on the next evaluation.
    private var handledCall: MeetingEvent?

    init(
        store: MeetingStore = .shared,
        controller: MeetingController = .shared,
        calendar: CalendarService = .shared,
        calls: CallDetector = .shared
    ) {
        self.store = store
        self.controller = controller
        self.calendar = calendar
        self.calls = calls
    }

    // MARK: - Lifecycle

    func start() {
        guard tick == nil else { return }

        Notifications.shared.observe { [weak self] action in
            self?.handle(action)
        }

        // The detector knows nothing about meetings and the scheduler owns every path that
        // makes one, so this is where the two are joined.
        calls.onChange = { [weak self] call in
            self?.enqueueCallChange(to: call)
        }

        forgetOrphanedCalls()

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
        calls.onChange = nil
        calls.stop()
        handledCall = nil
    }

    /// One pass. Separated from the loop so the self-test can run it directly.
    func runOnce(now: Date = Date()) async {
        syncCallDetection()
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
            // A detected call is armed as a *question*, and nothing on this clock may answer
            // it. A calendar meeting starts by itself because the user agreed to it in
            // advance; an ad-hoc call has had no such agreement, which is the whole reason
            // `callDetectionAutoRecord` defaults to off. Record now is the only thing that
            // starts one, and `callChanged` retires it when the call ends — so it is also
            // never written off for missing a start time it does not have.
            guard !meeting.isDetectedCall else { continue }
            let scheduledEnd = meeting.end ?? meeting.start.addingTimeInterval(Self.armedGrace)

            // Too late: either the meeting is over, or a session that was already running
            // held on past the point where recording the rest would be worth anything.
            if now >= scheduledEnd.addingTimeInterval(Self.armedGrace) {
                var missed = meeting
                missed.status = .failed(
                    controller.session == nil
                        ? "Next Notes wasn't running when this meeting started."
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

        // A detected call has no scheduled end — `end` is the instant it was noticed — so
        // the overrun rule would stop it five minutes in, every time. What ends one is the
        // detector seeing both flags go, which `callChanged` acts on. The silence rule stays
        // as the backstop for a call whose flags never drop.
        let overran = !session.meeting.isDetectedCall
            && (session.meeting.end.map { now >= $0.addingTimeInterval(Self.overrunGrace) } ?? false)
        let silent = now.timeIntervalSince(session.lastSpeechAt) >= Self.silenceTimeout
        guard overran || silent else { return }

        Log.meeting.info("""
            auto-stopping "\(session.meeting.title, privacy: .public)" — \
            \(overran ? "past its end time" : "silent for ten minutes", privacy: .public)
            """)
        await controller.stop()
    }

    // MARK: - Calls nobody put on a calendar

    /// Follows `Settings.callDetectionEnabled` from the tick rather than from an observer.
    ///
    /// The tick already exists and already runs every thirty seconds, which is a fine
    /// latency for a switch someone just flicked in a Settings window — and it means the
    /// detector's Core Audio subscription has exactly one owner instead of two.
    private func syncCallDetection() {
        if Settings.shared.callDetectionEnabled {
            calls.start()
        } else {
            calls.stop()
        }
    }

    /// Clears out armed detected calls left behind by a previous launch.
    ///
    /// The question one of them asks only makes sense while the call is still ringing, and
    /// nothing else will ever take it down: the tick refuses to start a detected call, and
    /// `retire` only fires for a call *this* process saw begin. Without this they pile up in
    /// the meetings list, one per call the app was quit during.
    private func forgetOrphanedCalls() {
        for meeting in store.meetings where meeting.isDetectedCall && meeting.status == .armed {
            Notifications.shared.withdrawMeetingArmed(meetingID: meeting.id)
            store.delete(meeting)
        }
    }

    /// The only entry point from `CallDetector`, and a queue of one.
    ///
    /// Chained rather than concurrent — see `callWork`. The chain makes the order the
    /// transitions arrive in the order they are acted on, so a call is always retired before
    /// the one that replaced it is armed, and `MeetingController` is never asked to stop one
    /// session while it starts another.
    private func enqueueCallChange(to call: CallDetector.CallActivity?) {
        let preceding = callWork
        callWork = Task { @MainActor [weak self] in
            await preceding?.value
            await self?.callChanged(to: call)
        }
    }

    /// A detected call began, ended, or turned out to be a different app.
    ///
    /// Runs on the main actor, once per transition rather than once per evaluation pass, and
    /// never beside another run of itself.
    private func callChanged(to call: CallDetector.CallActivity?, now: Date = Date()) async {
        let event = call.map(CallDetector.event(for:))
        if let previous = handledCall, previous.id != event?.id {
            await retire(previous)
        }
        handledCall = event
        guard let call, let event else { return }
        await answer(event, for: call, now: now)
    }

    /// Decides what to do about a call that has just settled, and does it.
    private func answer(_ event: MeetingEvent, for call: CallDetector.CallActivity, now: Date) async {
        let settings = Settings.shared
        let answer = call.bundleID.flatMap { settings.callAnswer(forApp: $0) }
        let decision = CallPolicy.armDecision(
            enabled: settings.callDetectionEnabled,
            answer: answer,
            readiness: CallPolicy.RecordingReadiness(hasMicrophone: Permissions.hasMicrophone),
            meetings: correlationWindows(),
            now: now
        )

        switch decision {
        case .attach:
            // Deliberately nothing. A meeting is already armed or already recording over
            // this stretch of clock, and a Zoom call that is on the calendar has to produce
            // one recording rather than two — so the existing meeting *is* the answer, and
            // the call simply joins it.
            Log.calls.info("""
                \(call.displayName, privacy: .public) is on a call that a meeting already \
                covers — not arming a second one
                """)
        case .decline(let reason):
            Log.calls.info("""
                not arming for \(call.displayName, privacy: .public) — \
                \(reason.explanation, privacy: .public)
                """)
        case .arm:
            await raise(event, for: call, answer: answer, now: now)
        }
    }

    private func raise(
        _ event: MeetingEvent,
        for call: CallDetector.CallActivity,
        answer: CallPolicy.AppAnswer?,
        now: Date
    ) async {
        guard !skipped.contains(event.overrideKey) else { return }
        guard meeting(for: event) == nil else { return }

        if CallPolicy.recordsWithoutAsking(
            bundleID: call.bundleID,
            autoRecord: Settings.shared.callDetectionAutoRecord,
            answer: answer
        ) {
            await recordNow(event)
            return
        }

        arm(
            event,
            now: now,
            announce: true,
            body: "\(call.displayName) is on a call. Record it?"
        )
    }

    /// The call this meeting was armed for has ended, or detection was switched off under
    /// it. Whatever was raised comes down with it.
    private func retire(_ event: MeetingEvent) async {
        IslandState.shared.clearArmed(event)
        skipped.remove(event.overrideKey)
        guard let meeting = meeting(for: event) else { return }

        if meeting.status.isActive {
            // This is the auto-stop rule for a detected call. A clock cannot say when a
            // call ends and the detector can, so the thing that noticed it start is the
            // thing that stops it.
            guard controller.session?.meeting.id == meeting.id else { return }
            Log.calls.info("""
                stopping "\(meeting.title, privacy: .public)" — the call has ended
                """)
            await controller.stop()
            return
        }

        guard meeting.status == .armed else { return }
        // Deleted rather than written off as failed: nothing went wrong. The user was asked
        // a question for as long as the call lasted and did not answer it, and a row in the
        // meetings list saying "Next Notes wasn't running" would be untrue as well as useless.
        Notifications.shared.withdrawMeetingArmed(meetingID: meeting.id)
        store.delete(meeting)
        Log.calls.info("""
            withdrew "\(meeting.title, privacy: .public)" — the call ended unanswered
            """)
    }

    /// Everything already in hand that a detected call could be the same event as.
    ///
    /// Detected calls are excluded: a call correlating with its own meeting would attach to
    /// itself and arm nothing, and one call overlapping the next is what `handledCall`
    /// already keeps straight.
    private func correlationWindows() -> [CallPolicy.MeetingWindow] {
        store.meetings.compactMap { meeting in
            guard !meeting.isDetectedCall else { return nil }
            guard meeting.status == .armed || meeting.status.isActive else { return nil }
            return CallPolicy.MeetingWindow(
                isActive: meeting.status.isActive,
                start: meeting.start,
                end: meeting.end
            )
        }
    }

    // MARK: - Internals

    @discardableResult
    private func arm(
        _ event: MeetingEvent,
        now: Date,
        announce: Bool,
        body: String? = nil
    ) -> Meeting {
        // `end` carries the *scheduled* end at this point, which is what the auto-stop
        // rule reads. `MeetingSession` overwrites both ends when the recording really
        // starts and stops.
        let meeting = Meeting(
            title: event.title,
            start: event.start,
            // A detected call gets no end at all, where a calendar event's `end` is the
            // scheduled one. `CallDetector.event(for:)` has nothing to put there but the
            // start, and a meeting whose end precedes its start reads back as a negative
            // duration for the whole time it is recording.
            end: event.providerID == .detectedCall ? nil : event.end,
            calendarEventID: event.id,
            providerID: event.providerID.rawValue,
            attendees: event.attendees,
            conferenceURL: event.conferenceURL,
            calendarName: event.calendarName,
            status: .armed
        )
        store.save(meeting)

        if announce {
            Notifications.shared.postMeetingArmed(
                meeting: meeting, startsAt: event.start, body: body
            )
            // The same question, in the place the user is already looking. The banner
            // reaches them in another app; the island reaches them at the top of the screen
            // they are looking at, and either answer takes both down.
            IslandState.shared.announceArmed(event)
            if event.providerID == .detectedCall {
                Log.calls.info("""
                    armed "\(event.title, privacy: .public)" — asking before recording
                    """)
            } else {
                Log.meeting.info("""
                    armed "\(event.title, privacy: .public)" starting \
                    \(event.start.timeIntervalSince(now).rounded(), privacy: .public)s from now
                    """)
            }
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
            // Not for a detected call: its key names one call at one instant, so the row
            // would be written and never read again, and `callAppAnswers` — keyed by the
            // app — is where a lasting "no" about calls belongs.
            if let key = Self.overrideKey(of: meeting), !meeting.isDetectedCall {
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

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
    /// Stop a scheduled recording after this much silence on both tracks. The case it
    /// exists for is a call that ended without anyone touching Next Notes.
    static let silenceTimeout: TimeInterval = 10 * 60
    /// How long an armed meeting may wait for a busy session before it is written off.
    static let armedGrace: TimeInterval = 10 * 60
    /// How often the audio-retention sweep runs (M-10). The tick already runs every
    /// thirty seconds, but the sweep reads the volume's free space and passes over
    /// every meeting, so it keeps its own cadence — and its first run, within a tick
    /// of launch, is the at-launch sweep. A meeting being resumed is active until its
    /// stage finishes, which is exactly what the sweep refuses to touch.
    static let retentionSweepInterval: TimeInterval = 30 * 60

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
    /// When the retention sweep last ran; nil until the first tick after start,
    /// which is the launch sweep.
    private var lastRetentionSweep: Date?

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

    /// The call that covered the running recording, and when it was last seen to end.
    ///
    /// M-11. A meeting a call started early stops shortly after that call goes rather than
    /// at the end of a schedule it never followed, and this is the pair the grace is
    /// measured against: cleared the moment the same call is reported live again, so a
    /// reconnect is one recording rather than two halves of one.
    private var coveringCallEnded: (id: String, at: Date)?

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
        // Meeting-starting triggers, whether or not the meeting is recorded: each applies its
        // own lead time, and an event seen on many ticks runs once. After the start above, so a
        // trigger with no lead sees the recording it would otherwise compete with for the GPU,
        // and runs on OpenRouter rather than the on-device model.
        AgentTriggerEvents.shared.meetingsUpcoming(calendar.upcoming, now: now)
        await stopFinishedMeeting(now: now)
        sweepAudioRetention(now: now)
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
    ///
    /// `coveringCallID` is the call this recording is happening for, when there is one
    /// (M-11): the event's own meeting, started early because the call settled first. The
    /// recording then ends with the call rather than with the schedule.
    @discardableResult
    func recordNow(_ event: MeetingEvent, coveringCallID: String? = nil) async -> Bool {
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
        var meeting = existing?.status == .armed
            ? existing!
            : arm(event, now: Date(), announce: false)
        if let coveringCallID, meeting.coveringCallID != coveringCallID {
            meeting = meeting.withCoveringCall(coveringCallID)
            store.save(meeting)
        }
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
            guard mayStartUnattended(meeting) else { continue }
            let scheduledEnd = meeting.end ?? meeting.start.addingTimeInterval(Self.armedGrace)

            // Too late: either the meeting is over, or a session that was already running
            // held on past the point where recording the rest would be worth anything.
            if now >= scheduledEnd.addingTimeInterval(Self.armedGrace) {
                guard let reason = Self.missedReason(running: controller.session?.meeting, meeting: meeting)
                else {
                    Log.meeting.info("""
                        "\(meeting.title, privacy: .public)" is the meeting already being \
                        recorded — not writing it off
                        """)
                    continue
                }
                var missed = meeting
                missed.status = .failed(
                    reason == .appWasNotRunning
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

    /// Releases temporary recordings past their 72-hour window (M-10), and — while
    /// the disk is nearly full — the oldest ones first. The first tick after start
    /// is the launch sweep; after that the sweep keeps to its own thirty-minute
    /// cadence inside the tick that is already running.
    private func sweepAudioRetention(now: Date) {
        if let last = lastRetentionSweep,
           now.timeIntervalSince(last) < Self.retentionSweepInterval {
            return
        }
        lastRetentionSweep = now
        store.sweepExpiredAudio(now: now)
    }

    /// Stops a scheduled recording that has outlived its meeting.
    ///
    /// Only ever a calendar-backed one: an ad-hoc recording was started by hand and is
    /// stopped by hand, and a silence rule applied to it would cut off the deliberately
    /// quiet recording someone left running on purpose.
    private func stopFinishedMeeting(now: Date) async {
        guard let session = controller.session, session.isRecording else { return }
        guard session.meeting.calendarEventID != nil else { return }

        // The hang-up, when this recording is the one that call started (M-11). Only that
        // call's ending counts: another call hanging up beside it says nothing about this
        // meeting, and a meeting whose call is still up has not ended at all.
        if CallPolicy.shouldStopAfterHangUp(
            coveringCallID: session.meeting.coveringCallID,
            endedCallID: coveringCallEnded?.id,
            endedAt: coveringCallEnded?.at,
            liveCallID: handledCall?.id,
            now: now
        ) {
            await stop(session, "the call that covered it has ended")
            return
        }

        // A detected call has no scheduled end — `end` is nil until the recording stops —
        // so the overrun rule declines it outright, which is the whole of the exemption
        // the plan keeps. What ends a call is the detector seeing both flags go, which
        // `retire` acts on; the silence rule below stays as the backstop for a call whose
        // flags never drop.
        let coveringEndedAt = coveringCallEnded.flatMap { ended in
            session.meeting.coveringCallID == ended.id ? ended.at : nil
        }
        if case .stop(let reason) = CallPolicy.overrunDecision(
            now: now,
            end: session.meeting.end,
            lastSpeechAt: session.lastSpeechAt,
            coveringCallEndedAt: coveringEndedAt
        ) {
            await stop(session, Self.overrunLogLine(reason))
            return
        }

        guard now.timeIntervalSince(session.lastSpeechAt) >= Self.silenceTimeout else { return }
        await stop(session, "silent for ten minutes")
    }

    private func stop(_ session: MeetingSession, _ why: String) async {
        Log.meeting.info("""
            auto-stopping "\(session.meeting.title, privacy: .public)" — \
            \(why, privacy: .public)
            """)
        await controller.stop()
    }

    /// The log line for an overrun, in the words a person would use for it.
    private static func overrunLogLine(_ reason: CallPolicy.OverrunDecision.Reason) -> String {
        switch reason {
        case .ceiling: "over an hour past its end"
        case .quiet: "past its end and nobody has spoken"
        case .callEnded: "past its end and the call has ended"
        }
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
            await retire(previous, now: now)
        }
        handledCall = event
        // The same call reported live again after a dip — a reconnect, a second device —
        // cancels the stop its hang-up had queued. `identity` is stable for the length of
        // one call, so this is the same meeting and not a new one.
        if let id = event?.id, coveringCallEnded?.id == id { coveringCallEnded = nil }
        guard let call, let event else { return }
        await answer(event, for: call, now: now)
        // "When a call starts…" triggers hear about it only now, once the call has been armed
        // or recorded, so a run sees that recording: the on-device model is ruled out while it records and the
        // run goes to OpenRouter, or is skipped with that reason when there is none. A call that settled within the detector's
        // first moments was already under way — most often across a relaunch, when it gets a
        // new `since` — and has had its run.
        if !calls.settledAtStart(call) {
            AgentTriggerEvents.shared.callStarted(call)
        } else {
            Log.calls.info("call settled right after detection started; call_started triggers not told")
        }
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
        // M-11: the call may be a meeting the user already has on their calendar rather
        // than an ad-hoc one, and the recording it produces should carry that meeting's
        // title and attendees — which is what the notes prompt resolves names from — rather
        // than "Zoom call" with nobody on it. Decided once, before the switch, because the
        // "already covered" branch needs it too: a meeting armed a moment ago still starts
        // on its own schedule, and the call is what will end it.
        let match = CallPolicy.calendarMatch(at: now, candidates: calendarCandidates())

        switch decision {
        case .attach:
            if case .startCalendar(let eventID) = match {
                stampCoveringCall(onEvent: eventID, for: call)
            }
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
            switch match {
            case .startCalendar(let eventID):
                await startCalendarEvent(eventID, for: call)
            case .askCalendar(let eventID):
                askAboutCalendarEvent(eventID, for: call, now: now)
            case .none:
                await raise(event, for: call, answer: answer, now: now)
            }
        }
    }

    /// The nearby events a settled call could be, and whether each is agreed to be
    /// recorded.
    ///
    /// Narrower than `calendar.upcoming` on purpose, because this list decides which
    /// meeting a call is filed under and a call two rooms away is not it. Out: an
    /// invitation the user declined, one they have said no to for this occurrence, an
    /// event that is not shaped like a meeting (no link and nobody else), and — inside
    /// `calendarMatch` — an all-day block, which is a day rather than a meeting.
    ///
    /// The global switch is deliberately not a filter. "Not automatically" is the state
    /// that asks, and the question this raises is about the right meeting rather than
    /// about an ad-hoc call beside it; a *stored* "no" is a refusal and stays out.
    func calendarCandidates() -> [CallPolicy.CalendarCandidate] {
        let settings = Settings.shared
        return calendar.upcoming.compactMap { event in
            guard event.isOrganizerOrSelfAccepted else { return nil }
            guard !skipped.contains(event.overrideKey) else { return nil }
            guard settings.autoRecordOverride(forEvent: event.overrideKey) != false else { return nil }
            guard event.conferenceURL != nil || !event.attendees.isEmpty else { return nil }
            return CallPolicy.CalendarCandidate(
                event: event,
                isAutoRecord: willAutoRecord(event)
            )
        }
    }

    /// The event behind an id from a `CalendarMatch`, which is the one the list above
    /// was built from.
    private func calendarEvent(_ eventID: String) -> MeetingEvent? {
        calendar.upcoming.first { $0.id == eventID }
    }

    /// The meeting a call covers starts now, under the event's own name.
    ///
    /// This is the whole of M-11's first rule. Joining six minutes early used to raise a
    /// second, ad-hoc question beside the real event's; answering it produced a recording
    /// titled "Zoom call" with no attendees, and the event's own armed meeting was then
    /// written off a quarter of an hour later as "Another meeting was being recorded when
    /// this one started" — a failure row for a meeting that was being recorded.
    private func startCalendarEvent(
        _ eventID: String,
        for call: CallDetector.CallActivity
    ) async {
        guard let event = calendarEvent(eventID) else { return }
        let started = await recordNow(event, coveringCallID: CallDetector.identity(of: call))
        guard started else {
            Log.calls.info("""
                \(call.displayName, privacy: .public) is on a call for \
                "\(event.title, privacy: .public)", but something is already recording
                """)
            return
        }
        Log.calls.info("""
            started "\(event.title, privacy: .public)" now — \
            \(call.displayName, privacy: .public) is on a call for it
            """)
    }

    /// The event is near and is not agreed, so the question is about **it** — the meeting
    /// with its title and its attendees — rather than about an ad-hoc call beside it.
    ///
    /// Armed and not started: `mayStartUnattended` keeps the tick off a meeting nobody
    /// has answered for, which is what makes asking the whole of the answer.
    private func askAboutCalendarEvent(
        _ eventID: String,
        for call: CallDetector.CallActivity,
        now: Date
    ) {
        guard let event = calendarEvent(eventID) else { return }
        guard meeting(for: event) == nil else { return }
        _ = arm(
            event,
            now: now,
            announce: true,
            body: "\(call.displayName) is on a call. Record it?"
        )
    }

    /// The call covering an armed meeting is this one, so the recording ends with the
    /// call rather than with the schedule. The tick still starts the meeting on time —
    /// joining inside the lead time is the ordinary case and needs no early start.
    private func stampCoveringCall(onEvent eventID: String, for call: CallDetector.CallActivity) {
        guard let event = calendarEvent(eventID),
              let meeting = meeting(for: event),
              meeting.status == .armed,
              meeting.coveringCallID == nil
        else { return }
        store.save(meeting.withCoveringCall(CallDetector.identity(of: call)))
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
    private func retire(_ event: MeetingEvent, now: Date = Date()) async {
        IslandState.shared.clearArmed(event)
        skipped.remove(event.overrideKey)
        // M-11: the meeting recording this call is the *event's own* meeting — a calendar
        // event started early because this call settled — so `meeting(for:)` below never
        // finds it, and the branch that stops a call recording would not run for it either.
        // It ends on the hang-up grace instead, which is measured from here and cancelled
        // by the same call coming back.
        noteCoveringCallEnded(event.id, now: now)
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

    /// The call covering the running recording has gone, and when.
    ///
    /// A no-op for every call that is not covering one — which today is every call, and
    /// after M-11 is the call a calendar meeting was started for. The recording is *not*
    /// stopped here: `CallPolicy.coveringCallGrace` holds it for a minute first, because a
    /// call that reconnects is one meeting and cutting it in half is worse than a minute
    /// of an empty room.
    private func noteCoveringCallEnded(_ callID: String, now: Date) {
        guard let session = controller.session,
              session.isRecording,
              session.meeting.coveringCallID == callID
        else { return }
        coveringCallEnded = (id: callID, at: now)
        Log.calls.info("""
            "\(session.meeting.title, privacy: .public)" is covered by a call that has \
            ended — stopping it in a minute unless the call comes back
            """)
    }

    /// Whether the tick may start this armed meeting without asking again.
    ///
    /// `armDueEvents` only arms an event `willAutoRecord` accepts, so an armed calendar
    /// meeting has almost always been agreed to in advance and the tick starting it on
    /// time is that agreement arriving rather than a new one. The exception is a meeting
    /// that exists only as a *question*: M-11 arms the event itself when a call lands near
    /// one that is not agreed, so the person is asked about the right thing — and that one
    /// waits for the answer, exactly as a detected call does.
    ///
    /// An event no longer in the calendar counts as agreed. Stranding a recording nobody
    /// can start, with no question left to answer it, is the worse failure.
    private func mayStartUnattended(_ meeting: Meeting) -> Bool {
        guard !meeting.isDetectedCall else { return false }
        guard let id = meeting.calendarEventID, let provider = meeting.providerID else { return true }
        guard let event = calendar.upcoming.first(where: {
            $0.id == id && $0.providerID.rawValue == provider
        }) else { return true }
        return willAutoRecord(event)
    }

    /// Why an armed meeting missed its window, or `nil` to write nothing at all.
    enum MissedReason: Sendable, Equatable {
        case appWasNotRunning
        case anotherMeetingWasRecording
    }

    /// Pure, so `--selftest-calendar` states the rule rather than the wiring: the session
    /// in the way may be this meeting's own recording, started early by the call that
    /// covers it, and that is the answer to the question rather than a conflict. Writing
    /// a failure row for a meeting that is being recorded is the false row this case
    /// exists to prevent.
    static func missedReason(running: Meeting?, meeting: Meeting) -> MissedReason? {
        guard let running else { return .appWasNotRunning }
        guard !running.isSameMeeting(as: meeting) else { return nil }
        return .anotherMeetingWasRecording
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
            guard var meeting = store.meeting(id: id), meeting.status == .armed else { return }
            // M-11: the person answered "yes" to a meeting whose call is still up, so that
            // call is what ends the recording. A detected call is left out — it already has
            // the call's own end-of-call rule, and stamping it here would give one meeting
            // two ways to be the same call.
            if let live = calls.current, meeting.coveringCallID == nil, !meeting.isDetectedCall {
                meeting = meeting.withCoveringCall(CallDetector.identity(of: live))
                store.save(meeting)
            }
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
        case .approveProposal, .dismissProposal, .openSchedule, .readScheduleAloud, .snoozeSchedule,
             .reviewRoutineDraft, .approveRoutineDraft:
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

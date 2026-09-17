import AppKit
import CoreGraphics
import Foundation
import Observation

/// What the scheduler reads from Settings, snapshotted per pass so a self-test can fix it.
struct ScheduleSettingsSnapshot: Sendable {
    enum Speech: String, Sendable {
        case whenPresent
        case never
    }

    var enabled: Bool
    var quietStart: ScheduleLocalTime?
    var quietEnd: ScheduleLocalTime?
    var speech: Speech

    /// `Settings.agentSchedulesEnabled`, read from defaults for callers off the main actor.
    nonisolated static var defaultsEnabled: Bool {
        UserDefaults.standard.object(forKey: "agentSchedulesEnabled") as? Bool ?? true
    }

    @MainActor
    static func fromSettings() -> ScheduleSettingsSnapshot {
        let settings = Settings.shared
        return ScheduleSettingsSnapshot(
            enabled: settings.agentSchedulesEnabled,
            quietStart: ScheduleLocalTime.parse(settings.agentQuietHoursStart),
            quietEnd: ScheduleLocalTime.parse(settings.agentQuietHoursEnd),
            speech: Speech(rawValue: settings.agentRoutineSpeech) ?? .whenPresent
        )
    }

    /// Whether `date` falls inside quiet hours, read in `zone`. A window that crosses
    /// midnight (21:00–08:00) is the normal case. Equal ends mean no quiet hours.
    func isQuiet(_ date: Date, zone: TimeZone = .current) -> Bool {
        guard let start = quietStart, let end = quietEnd, start != end else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let now = ScheduleLocalTime(hour: parts.hour ?? 0, minute: parts.minute ?? 0)
        return start < end ? (start <= now && now < end) : (now >= start || now < end)
    }

    /// The first moment after `date` that quiet hours end.
    func quietEnd(after date: Date, zone: TimeZone = .current) -> Date {
        guard let end = quietEnd else { return date }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.nextDate(
            after: date,
            matching: DateComponents(hour: end.hour, minute: end.minute, second: 0),
            matchingPolicy: .nextTime
        ) ?? date.addingTimeInterval(3_600)
    }
}

/// The presence rule's inputs. Speaking first needs all of: the user touched the keyboard
/// or mouse in the last two minutes, no meeting is recording, no dictation is open, no call
/// is active, and the Agent is not already talking or listening.
@MainActor
protocol ScheduleEnvironment: AnyObject {
    var isUserPresent: Bool { get }
    var isRecording: Bool { get }
    /// Dictation holds the microphone: a spoken reminder would be typed into the document.
    var isDictating: Bool { get }
    var isCallActive: Bool { get }
    var isAgentBusy: Bool { get }
}

/// One reminder on its way to the user.
struct ScheduleDelivery: Sendable, Equatable {
    let scheduleID: UUID
    let title: String
    let body: String
    let missed: Bool
    let speak: Bool
    /// What is said, when `speak`.
    let spoken: String
    /// A routine's result is titled with the routine; a reminder says "Reminder".
    var kind: AgentSchedule.Kind = .reminder
}

@MainActor
protocol ScheduleDelivering: AnyObject {
    func deliver(_ delivery: ScheduleDelivery) async throws
    /// One notification about a schedule that keeps failing, or turned itself off.
    func notifyProblem(scheduleID: UUID, title: String, body: String)
    /// A routine prepared writes it did not run: one `agentRoutineApproval` notification
    /// each, with Review and Approve.
    func notifyDrafts(_ drafts: [RoutineDraft], scheduleTitle: String)
    func openSchedules()
    func speak(_ text: String)
}

enum ScheduleError: LocalizedError, Equatable {
    case notFound(String)
    case ambiguous(String)
    case invalid(String)
    case notAvailable(String)
    case couldNotSave

    var errorDescription: String? {
        switch self {
        case .notFound(let what): "No reminder matches \(what). Call schedule.list for the ids."
        case .ambiguous(let what): "More than one reminder matches \(what). Use the id from schedule.list."
        case .invalid(let reason): reason
        case .notAvailable(let reason): reason
        case .couldNotSave: "The reminder could not be saved; nothing was changed."
        }
    }
}

/// The fields a `schedule.update` may change: only what the user confirms. Nothing the
/// scheduler owns is expressible here.
struct ScheduleEdit: Sendable {
    var title: String?
    var prompt: String?
    var when: ScheduleWhen?
    /// `.some(nil)` clears the end date.
    var endsAt: Date??
    var delivery: AgentSchedule.Delivery?
    /// A routine's or trigger's model: auto, local or cloud. From the Routines view's editor.
    var model: AgentSchedule.ModelChoice?
    /// A trigger's event, lead time or filter.
    var trigger: ScheduleTrigger?
}

/// Runs reminders on time, shaped exactly like `MeetingScheduler`.
///
/// A thirty-second loop plus a pass on wake, and `runOnce(now:)` is the whole decision — it
/// rebuilds from `agent-schedules.json` every time, and is what `--selftest-schedule` drives
/// with a fake clock. The rules, in the order a pass applies them:
///
/// - **Claim, then dispatch.** `nextRunAt` advances and is saved before the delivery starts,
///   so a crash mid-delivery cannot fire the same slot twice. A delivery found `started` on
///   launch is recorded as interrupted once and never replayed.
/// - **Grace.** A slot found late within `min(max(interval / 2, 2 min), 2 h)` is delivered,
///   late. Beyond it a recurring schedule's backlog collapses into **one** catch-up, and a
///   one-shot is delivered as *Missed: …* — never silently dropped.
/// - **Every skipped slot is logged with a reason** in `agent-schedule-runs.jsonl`.
/// - **`endsAt` is enforced here**, not by a job meant to clean up other jobs.
/// - **Quiet hours defer delivery**, and a deferred delivery goes out when they end. A
///   reminder whose own time is inside quiet hours was set for then on purpose and is not held.
/// - **Failures escalate.** Retry after 1, 5, 15, then 60 minutes; one notification at 3
///   consecutive failures; at 10 the schedule turns itself off and says so.
///
/// Routines (R2) run here too, one at a time — there is one Metal GPU — through
/// `ScheduledRunner`: quiet hours hold a routine's *result*, not its run; a skipped slot
/// ("local model busy") is retried a minute later while still within grace; a failed run
/// escalates exactly like a failed reminder.
///
/// Triggers (R3) have no slot. `AgentTriggerEvents` publishes notes-ready, meeting-starting
/// and call-started occurrences; `handleTriggerEvents` claims each one per trigger — the key is
/// saved before the run starts, so an event published again, or a relaunch, never runs it
/// twice — and runs it through the same routine path: the same authority, budget, silence,
/// quiet hours, drafts and failure escalation. A skipped or failed trigger run is retried only
/// while its event is still worth acting on (`triggerDeadline`).
@MainActor
@Observable
final class AgentScheduler {
    static let shared = AgentScheduler(
        store: .shared,
        system: ScheduleNotifications.shared,
        deliverer: LiveScheduleDelivery(),
        environment: LiveScheduleEnvironment(),
        settings: { .fromSettings() },
        runner: ScheduledRunner(
            store: .shared,
            environment: LiveScheduledRunEnvironment(),
            tools: LiveScheduledToolRunner(),
            recorder: LiveScheduledRunRecorder())
    )

    static let tickInterval: TimeInterval = 30
    /// A registration with macOS is withdrawn this close to its slot, and the running app
    /// delivers the reminder itself. Longer than a tick, so a pass always lands in between.
    static let systemHandoverLead: TimeInterval = 45
    static let retryBackoff: [TimeInterval] = [60, 5 * 60, 15 * 60, 60 * 60]
    static let failureNotifyThreshold = 3
    static let failureDisableThreshold = 10
    static let snoozeInterval: TimeInterval = 10 * 60
    /// A routine skipped for a busy model tries again this much later, while within grace.
    static let skipRetryInterval: TimeInterval = 60
    static let skipRetryReason = "skipped"
    /// A meeting-starting trigger found this long after the start still runs; later, it is
    /// recorded as skipped once.
    nonisolated static let meetingStartingGrace: TimeInterval = 5 * 60
    /// How long a trigger's skipped or failed run is retried for its event.
    nonisolated static let notesReadyRetryWindow: TimeInterval = 2 * 60 * 60
    nonisolated static let callStartedRetryWindow: TimeInterval = 10 * 60

    let store: ScheduleStore
    private let system: ReminderSystemRegistering
    private let deliverer: ScheduleDelivering
    private let environment: ScheduleEnvironment
    private let settingsProvider: @MainActor () -> ScheduleSettingsSnapshot
    private let zoneProvider: () -> TimeZone
    private let runner: (any ScheduledRunning)?
    private let events: AgentTriggerEvents
    private var eventSubscription: UUID?

    private var tick: Task<Void, Never>?
    /// Passes run one at a time: the loop, a wake, and a macOS reminder firing in the
    /// foreground can all ask for one at once.
    private var passChain: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    /// When the previous pass ran. Nil before the first pass after launch — which is how a
    /// backlog is attributed to "Next Notes wasn't running" rather than to sleep.
    private(set) var lastPassAt: Date?
    /// When a pass first found reminders switched off, if they still are.
    private var turnedOffAt: Date?
    private var lastDeliveredText: [UUID: String] = [:]

    init(
        store: ScheduleStore,
        system: ReminderSystemRegistering,
        deliverer: ScheduleDelivering,
        environment: ScheduleEnvironment,
        settings: @escaping @MainActor () -> ScheduleSettingsSnapshot,
        timeZone: @escaping () -> TimeZone = { .current },
        runner: (any ScheduledRunning)? = nil,
        events: AgentTriggerEvents = .shared
    ) {
        self.runner = runner
        self.events = events
        self.store = store
        self.system = system
        self.deliverer = deliverer
        self.environment = environment
        settingsProvider = settings
        zoneProvider = timeZone
    }

    // MARK: - Lifecycle

    /// Called after `AgentService.start`. Reconciles with macOS first, then loops.
    func start() {
        guard tick == nil else { return }
        Notifications.shared.observe { [weak self] action in
            self?.handle(action)
        }
        listenForTriggerEvents()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in AgentScheduler.shared.requestPass() }
        }
        tick = Task { @MainActor [weak self] in
            await self?.enqueue { await self?.reconcile(now: Date()) }
            while !Task.isCancelled {
                guard let self else { return }
                await self.serialPass(now: Date())
                let sleep = self.secondsUntilNextPass(now: Date())
                try? await Task.sleep(for: .seconds(sleep))
            }
        }
        Log.app.info("agent scheduler running")
    }

    func stop() {
        tick?.cancel()
        tick = nil
        if let eventSubscription { events.unsubscribe(eventSubscription) }
        eventSubscription = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = nil
    }

    /// A pass now, queued behind any pass already running.
    func requestPass() {
        Task { @MainActor in await serialPass(now: Date()) }
    }

    /// macOS presented a registered reminder while the app was running. The banner was
    /// suppressed; this delivers it through the scheduler instead.
    func systemReminderFired(identifier: String) async {
        if let id = ScheduleNotifications.scheduleID(fromSystemIdentifier: identifier),
           var schedule = store.schedule(id: id) {
            schedule.systemRegisteredSlot = nil
            store.save(schedule)
        }
        await serialPass(now: Date())
    }

    private func serialPass(now: Date) async {
        await enqueue { [weak self] in await self?.runOnce(now: now) }
    }

    /// Runs `body` after every pass or edit already queued. Passes await macOS between reading
    /// a schedule and saving it, so a tool or Settings edit made in that window would be
    /// overwritten — or a deleted reminder re-inserted — if it did not wait its turn.
    private func serialized<T: Sendable>(_ body: @escaping @MainActor () async throws -> T) async throws -> T {
        let preceding = passChain
        let work = Task { @MainActor () async throws -> T in
            await preceding?.value
            return try await body()
        }
        passChain = Task { @MainActor in _ = try? await work.value }
        return try await work.value
    }

    private func enqueue(_ body: @escaping @MainActor () async -> Void) async {
        _ = try? await serialized { () async throws -> Bool in
            await body()
            return true
        }
    }

    /// Up to a tick, but no later than the next due slot, pending delivery, or the moment a
    /// macOS registration must be handed over — so the hand-off never rides on a late tick.
    private func secondsUntilNextPass(now: Date) -> Double {
        let upcoming = store.schedules.flatMap {
            [$0.nextRunAt, $0.systemRegisteredSlot.map { $0.addingTimeInterval(-Self.systemHandoverLead + 1) }]
                + $0.pendingDeliveries.map { Optional($0.notBefore) }
        }.compactMap { $0 }
        guard let soonest = upcoming.filter({ $0 > now }).min() else { return Self.tickInterval }
        return max(1, min(Self.tickInterval, soonest.timeIntervalSince(now) + 0.5))
    }

    // MARK: - Launch reconciliation

    /// Once at launch, before the first pass: interrupted deliveries, and what macOS did
    /// while the app was closed.
    func reconcile(now: Date) async {
        store.reload()
        let pending = await system.pendingScheduleIDs()
        let authorized = await system.isAuthorized()
        for original in store.schedules {
            var schedule = original
            if schedule.lastRun?.outcome == .started {
                let detail = schedule.kind == .reminder
                    ? "Next Notes quit while this reminder was being delivered; it was not repeated."
                    : "Next Notes quit while this \(schedule.kind.rawValue) was running; it was not repeated."
                record(&schedule, slot: nil, at: now, outcome: .interrupted, detail: detail)
            }
            guard schedule.kind == .reminder else {
                if schedule != original { store.save(schedule) }
                continue
            }
            if let slot = schedule.nextRunAt, slot <= now,
               schedule.systemRegisteredSlot == slot, authorized, !pending.contains(schedule.id) {
                // Registered, past, and no longer pending: macOS showed it.
                record(&schedule, slot: slot, at: now, outcome: .deliveredBySystem,
                       detail: "macOS delivered this while Next Notes was closed.")
                schedule.systemRegisteredSlot = nil
                let next = schedule.when.flatMap(RecurrenceRule.init).flatMap { $0.next(after: slot) }
                schedule.nextRunAt = bounded(next, by: schedule.endsAt)
                if schedule.nextRunAt == nil, schedule.isOneShot { schedule.enabled = false }
            } else if schedule.systemRegisteredSlot != nil, !pending.contains(schedule.id) {
                // Registered but gone and not delivered by macOS (no authorization, or
                // withdrawn): forget the registration so the next pass decides.
                schedule.systemRegisteredSlot = nil
            }
            if schedule != original { store.save(schedule) }
        }
        // Registrations for schedules that no longer exist.
        let known = Set(store.schedules.map(\.id))
        for id in pending where !known.contains(id) {
            system.withdraw(scheduleID: id)
        }
    }

    // MARK: - The pass

    /// One pass. Separated from the loop so the self-test can run it directly.
    func runOnce(now: Date) async {
        let settings = settingsProvider()
        store.reload()
        guard settings.enabled else {
            if turnedOffAt == nil { turnedOffAt = now }
            // Off means off even with the app closed: nothing stays registered with macOS.
            for original in store.schedules where original.systemRegisteredSlot != nil {
                var schedule = original
                system.withdraw(scheduleID: schedule.id)
                schedule.systemRegisteredSlot = nil
                store.save(schedule)
            }
            lastPassAt = now
            return
        }

        for id in store.schedules.map(\.id) {
            guard let schedule = store.schedule(id: id) else { continue }
            await process(schedule, now: now, settings: settings)
        }
        lastPassAt = now
        turnedOffAt = nil
    }

    private func process(_ original: AgentSchedule, now: Date, settings: ScheduleSettingsSnapshot) async {
        guard original.kind != .trigger else {
            await processTrigger(original, now: now, settings: settings)
            return
        }
        var schedule = original
        // A snooze the user pressed still goes out on a paused reminder; nothing else does.
        let snoozed = schedule.pendingDelivery?.reason == Self.snoozeReason
        guard schedule.enabled || snoozed, let when = schedule.when, let rule = RecurrenceRule(when) else {
            if schedule.systemRegisteredSlot != nil {
                system.withdraw(scheduleID: schedule.id)
                schedule.systemRegisteredSlot = nil
                store.save(schedule)
            }
            return
        }

        // 1. A delivery held back earlier.
        if let pending = schedule.pendingDelivery, pending.notBefore <= now {
            // Quiet hours hold what would be shown — a reminder, or a routine's finished
            // result — never a routine's retry, which only runs.
            let holdsDelivery = schedule.kind == .reminder || pending.text != nil
            if settings.isQuiet(now, zone: zoneProvider()), pending.reason != Self.snoozeReason, holdsDelivery {
                schedule.pendingDelivery?.notBefore = settings.quietEnd(after: now, zone: zoneProvider())
                store.save(schedule)
            } else {
                schedule.pendingDelivery = nil
                schedule.lastRun = ScheduleRunSummary(at: now, outcome: .started, detail: "Delivering")
                guard store.save(schedule) else { return }
                await dispatch(&schedule, slot: pending.slot, missed: pending.missed, now: now, settings: settings,
                               heldText: pending.text, ignoreQuiet: pending.reason == Self.snoozeReason)
            }
        }

        // 2. A due slot.
        if schedule.enabled, let due = schedule.nextRunAt, due <= now {
            await claimAndDeliver(&schedule, due: due, rule: rule, now: now, settings: settings)
        }

        // 3. The end date: passed, or no slot left before it.
        if let ends = schedule.endsAt, schedule.enabled, schedule.pendingDelivery == nil,
           ends <= now || (schedule.nextRunAt == nil && !schedule.isOneShot) {
            let endText = Self.stamp(ends, zone: rule.calendar.timeZone)
            schedule.enabled = false
            schedule.nextRunAt = nil
            record(&schedule, slot: nil, at: now, outcome: .ended,
                   detail: ends <= now
                       ? "Its end date (\(endText)) passed, so it turned itself off."
                       : "No time is left before its end date (\(endText)), so it turned itself off.")
        }
        // A finished one-shot has nothing left to do.
        if schedule.isOneShot, schedule.nextRunAt == nil, schedule.pendingDelivery == nil, schedule.enabled {
            schedule.enabled = false
        }

        await syncSystemRegistration(&schedule, now: now, settings: settings)
        if schedule != original { store.save(schedule) }
    }

    private func claimAndDeliver(
        _ schedule: inout AgentSchedule,
        due: Date,
        rule: RecurrenceRule,
        now: Date,
        settings: ScheduleSettingsSnapshot
    ) async {
        let horizon = min(now, schedule.endsAt ?? now)
        let slots = [due] + rule.occurrences(after: due, through: horizon)
        let deliveredSlot = slots[slots.count - 1]
        // A routine's catch-up is one run of its work, not a *Missed* notice.
        let missed = schedule.kind == .reminder && now.timeIntervalSince(deliveredSlot) > rule.grace

        // The hand-off pass was missed (the Mac slept, or App Nap held the timer) and macOS
        // already showed its registered banner: record that, advance, and do not show a copy.
        if schedule.systemRegisteredSlot == due,
           !(await system.pendingScheduleIDs()).contains(schedule.id),
           await system.isAuthorized() {
            record(&schedule, slot: due, at: now, outcome: .deliveredBySystem,
                   detail: "macOS delivered this before Next Notes took it over.")
            schedule.systemRegisteredSlot = nil
            schedule.nextRunAt = bounded(rule.next(after: max(now, due)), by: schedule.endsAt)
            store.save(schedule)
            return
        }

        // Claim: advance and save before anything is delivered.
        schedule.nextRunAt = bounded(rule.next(after: now), by: schedule.endsAt)
        schedule.lastRun = ScheduleRunSummary(at: now, outcome: .started, detail: "Delivering")
        if schedule.systemRegisteredSlot != nil {
            // The app delivers this one itself; macOS must not show it as well.
            system.withdraw(scheduleID: schedule.id)
            schedule.systemRegisteredSlot = nil
        }
        guard store.save(schedule) else {
            Log.app.error("couldn't claim a reminder slot; not delivering it this pass")
            return
        }

        let reason = skipReason(now: now)
        if slots.count > 1 {
            record(&schedule, slot: slots[0], at: now, outcome: .skipped,
                   detail: "\(slots.count - 1) earlier slot\(slots.count == 2 ? "" : "s") collapsed into one catch-up — \(reason).",
                   skippedSlots: slots.count - 1, summarize: false)
        }

        // Quiet hours hold the delivery, unless the reminder was set for this very time. A
        // routine runs regardless; `runRoutine` holds its result instead.
        let zone = zoneProvider()
        if schedule.kind == .reminder, settings.isQuiet(now, zone: zone), !settings.isQuiet(deliveredSlot, zone: zone) {
            let resume = settings.quietEnd(after: now, zone: zone)
            // A retry or snooze already held keeps its place; one held delivery at a time.
            if schedule.pendingDelivery == nil {
                schedule.pendingDelivery = SchedulePendingDelivery(
                    slot: deliveredSlot, notBefore: resume, missed: missed, reason: "quiet hours")
            }
            record(&schedule, slot: deliveredSlot, at: now, outcome: .deferred,
                   detail: "Quiet hours — held until \(Self.stamp(resume, zone: zone)).")
            store.save(schedule)
            return
        }
        if missed {
            let shortID = schedule.shortID
            Log.app.info("reminder \(shortID, privacy: .public) found beyond grace — \(reason, privacy: .public)")
        }
        await dispatch(&schedule, slot: deliveredSlot, missed: missed, now: now, settings: settings,
                       missedReason: missed ? reason : nil)
    }

    private func dispatch(
        _ schedule: inout AgentSchedule,
        slot: Date?,
        missed: Bool,
        now: Date,
        settings: ScheduleSettingsSnapshot,
        missedReason: String? = nil,
        outcome: ScheduleRunRecord.Outcome? = nil,
        heldText: String? = nil,
        ignoreQuiet: Bool = false,
        occurrence: ScheduleTriggerOccurrence? = nil
    ) async {
        if schedule.kind != .reminder {
            if let heldText {
                await deliverRoutineResult(&schedule, text: heldText, slot: slot, now: now, settings: settings,
                                           outcome: outcome ?? .completed, ignoreQuiet: ignoreQuiet)
                store.save(schedule)
            } else {
                await runRoutine(&schedule, slot: slot, now: now, settings: settings, forced: outcome,
                                 occurrence: occurrence)
            }
            return
        }
        let delivery = makeDelivery(for: schedule, slot: slot, missed: missed, now: now, settings: settings)
        do {
            try await deliverer.deliver(delivery)
            lastDeliveredText[schedule.id] = delivery.spoken
            schedule.consecutiveFailures = 0
            let result = outcome ?? (missed ? .missed : .delivered)
            var detail = delivery.body
            if let missedReason { detail += " — \(missedReason)" }
            if delivery.speak { detail += " (spoken)" }
            record(&schedule, slot: slot, at: now, outcome: result, detail: detail)
        } catch {
            fail(&schedule, slot: slot, missed: missed, now: now, error: error.localizedDescription)
        }
        store.save(schedule)
    }

    // MARK: - Routines

    /// Runs a routine through `ScheduledRunner`, delivers or holds what it found, notifies its
    /// drafts, and saves. `forced` is `.ranNow` for *Run now* and the test on creation: those
    /// are delivered at once and never escalate or retry.
    @discardableResult
    private func runRoutine(
        _ schedule: inout AgentSchedule,
        slot: Date?,
        now: Date,
        settings: ScheduleSettingsSnapshot,
        forced: ScheduleRunRecord.Outcome? = nil,
        occurrence: ScheduleTriggerOccurrence? = nil
    ) async -> ScheduledRunOutcome {
        guard let runner else {
            let result = ScheduledRunOutcome(status: .failed, text: "Routines can't run in this build.")
            if forced == nil {
                fail(&schedule, slot: slot, missed: false, now: now, error: result.text)
            } else {
                record(&schedule, slot: slot, at: now, outcome: .failed, detail: result.text)
            }
            store.save(schedule)
            return result
        }
        // A trigger's run is told what happened; the stored prompt is never changed.
        var runnable = schedule
        if schedule.kind == .trigger, let trigger = schedule.trigger {
            let event = occurrence ?? .test(for: trigger, at: now)
            runnable.prompt = schedule.prompt + "\n\n" + event.context(zone: zoneProvider())
        }
        let result = await runner.run(runnable, now: now)
        if !result.drafts.isEmpty {
            deliverer.notifyDrafts(result.drafts, scheduleTitle: schedule.title)
        }
        let draftNote = result.drafts.isEmpty ? ""
            : " \(result.drafts.count) draft\(result.drafts.count == 1 ? "" : "s") awaiting approval."
        let refusalNote = result.refusals.isEmpty ? "" : " Refused: " + result.refusals.joined(separator: " ")
        switch result.status {
        case .skipped:
            let zone = schedule.when.flatMap { TimeZone(identifier: $0.timeZone) } ?? zoneProvider()
            let retryAt = now.addingTimeInterval(Self.skipRetryInterval)
            if forced == nil, schedule.enabled, let occurrence, retryAt <= Self.triggerDeadline(for: occurrence) {
                // Queued beside anything another event left held: each event keeps its retry.
                schedule.pendingDeliveries.append(SchedulePendingDelivery(
                    slot: nil, notBefore: retryAt, missed: false, reason: Self.skipRetryReason, occurrence: occurrence))
                record(&schedule, slot: nil, at: now, outcome: .skipped,
                       detail: "Skipped — \(result.text). Trying again at \(Self.stamp(retryAt, zone: zone)).",
                       skippedSlots: 1)
            } else if forced == nil, schedule.enabled, let slot, let rule = schedule.when.flatMap(RecurrenceRule.init),
               retryAt <= slot.addingTimeInterval(rule.grace) {
                schedule.pendingDelivery = SchedulePendingDelivery(
                    slot: slot, notBefore: retryAt, missed: false, reason: Self.skipRetryReason)
                record(&schedule, slot: slot, at: now, outcome: .skipped,
                       detail: "Skipped — \(result.text). Trying again at \(Self.stamp(retryAt, zone: zone)).",
                       skippedSlots: 1)
            } else {
                record(&schedule, slot: slot, at: now, outcome: .skipped,
                       detail: "Skipped — \(result.text).", skippedSlots: slot == nil ? 0 : 1)
            }
        case .failed:
            if forced == nil {
                fail(&schedule, slot: slot, missed: false, now: now, error: result.text + refusalNote,
                     occurrence: schedule.kind == .trigger ? occurrence : nil)
            } else {
                record(&schedule, slot: slot, at: now, outcome: .failed, detail: result.text + refusalNote)
            }
        case .nothingToReport:
            schedule.consecutiveFailures = forced == nil ? 0 : schedule.consecutiveFailures
            record(&schedule, slot: slot, at: now, outcome: forced ?? .nothingToReport,
                   detail: "Ran, nothing to report." + draftNote + refusalNote)
        case .reported:
            if forced == nil { schedule.consecutiveFailures = 0 }
            await deliverRoutineResult(&schedule, text: result.text, slot: slot, now: now, settings: settings,
                                       outcome: forced ?? .completed, ignoreQuiet: forced != nil,
                                       note: draftNote + refusalNote)
        }
        store.save(schedule)
        return result
    }

    /// Shows a routine's result — or holds it until quiet hours end: the summary is ready in
    /// the morning.
    private func deliverRoutineResult(
        _ schedule: inout AgentSchedule,
        text: String,
        slot: Date?,
        now: Date,
        settings: ScheduleSettingsSnapshot,
        outcome: ScheduleRunRecord.Outcome,
        ignoreQuiet: Bool,
        note: String = ""
    ) async {
        let zone = zoneProvider()
        if !ignoreQuiet, settings.isQuiet(now, zone: zone) {
            let resume = settings.quietEnd(after: now, zone: zone)
            let held = SchedulePendingDelivery(slot: slot, notBefore: resume, missed: false, reason: "quiet hours", text: text)
            if schedule.kind == .trigger {
                // Two evening meetings are two results: both wait for the morning.
                schedule.pendingDeliveries.append(held)
            } else if schedule.pendingDelivery == nil {
                schedule.pendingDelivery = held
            }
            record(&schedule, slot: slot, at: now, outcome: .deferred,
                   detail: "Ran; quiet hours — the result is held until \(Self.stamp(resume, zone: zone))." + note)
            return
        }
        let delivery = makeDelivery(for: schedule, slot: slot, missed: false, now: now, settings: settings, text: text)
        do {
            try await deliverer.deliver(delivery)
            lastDeliveredText[schedule.id] = delivery.spoken
            record(&schedule, slot: slot, at: now, outcome: outcome,
                   detail: text + (delivery.speak ? " (spoken)" : "") + note)
        } catch {
            // The run succeeded; the retry shows the same result rather than running again.
            fail(&schedule, slot: slot, missed: false, now: now, error: error.localizedDescription, text: text)
        }
    }

    /// `text` is a finished result whose delivery failed; `occurrence`, a trigger run's event.
    private func fail(_ schedule: inout AgentSchedule, slot: Date?, missed: Bool, now: Date, error: String,
                      text: String? = nil, occurrence: ScheduleTriggerOccurrence? = nil) {
        let noun = schedule.kind == .reminder ? "Reminder" : schedule.kind == .trigger ? "Trigger" : "Routine"
        schedule.consecutiveFailures += 1
        let failures = schedule.consecutiveFailures
        record(&schedule, slot: slot, at: now, outcome: .failed, detail: error)
        if failures >= Self.failureDisableThreshold {
            schedule.enabled = false
            schedule.nextRunAt = nil
            schedule.pendingDeliveries = []
            if schedule.systemRegisteredSlot != nil {
                system.withdraw(scheduleID: schedule.id)
                schedule.systemRegisteredSlot = nil
            }
            deliverer.notifyProblem(
                scheduleID: schedule.id,
                title: "\(noun) turned off",
                body: "“\(schedule.title)” failed \(failures) times in a row and turned itself off. Last error: \(error)"
            )
            return
        }
        if failures == Self.failureNotifyThreshold {
            deliverer.notifyProblem(
                scheduleID: schedule.id,
                title: "A \(noun.lowercased()) keeps failing",
                body: "“\(schedule.title)” failed \(failures) times in a row: \(error)"
            )
        }
        let backoff = Self.retryBackoff[min(failures - 1, Self.retryBackoff.count - 1)]
        let retry = SchedulePendingDelivery(
            slot: slot, notBefore: now.addingTimeInterval(backoff), missed: missed, reason: "retry",
            text: text, occurrence: text == nil ? occurrence : nil)
        guard schedule.kind == .trigger else {
            schedule.pendingDelivery = retry
            return
        }
        // A trigger re-runs for its event only while the event is still worth acting on, and
        // its retry queues beside whatever another event left held.
        if text == nil {
            guard let occurrence, retry.notBefore <= Self.triggerDeadline(for: occurrence) else {
                let what = occurrence.map { " for “\($0.title)”" } ?? ""
                record(&schedule, slot: slot, at: now, outcome: .skipped,
                       detail: "Not retried\(what) — the next try would be too late to be useful.",
                       skippedSlots: 1, summarize: false)
                return
            }
        }
        schedule.pendingDeliveries.append(retry)
    }

    private func makeDelivery(
        for schedule: AgentSchedule,
        slot: Date?,
        missed: Bool,
        now: Date,
        settings: ScheduleSettingsSnapshot,
        text routineText: String? = nil
    ) -> ScheduleDelivery {
        let text = (routineText ?? schedule.prompt).trimmingCharacters(in: .whitespacesAndNewlines)
        let zone = schedule.when.flatMap { TimeZone(identifier: $0.timeZone) } ?? zoneProvider()
        let body: String
        let spoken: String
        if schedule.kind != .reminder {
            body = text
            spoken = "\(schedule.title): \(text)"
        } else if missed, let slot {
            body = "Missed: \(text) (due \(Self.stamp(slot, zone: zone)))"
            spoken = "You missed a reminder: \(text)"
        } else {
            body = text
            spoken = "Reminder: \(text)"
        }
        let speak = schedule.delivery == .notifyAndSpeak
            && settings.speech == .whenPresent
            && environment.isUserPresent
            && !environment.isRecording
            && !environment.isDictating
            && !environment.isCallActive
            && !environment.isAgentBusy
            && !settings.isQuiet(now, zone: zoneProvider())
        return ScheduleDelivery(
            scheduleID: schedule.id,
            title: schedule.kind != .reminder ? schedule.title : missed ? "Missed reminder" : "Reminder",
            body: body, missed: missed, speak: speak, spoken: spoken, kind: schedule.kind)
    }

    /// Why slots went by undelivered: the only three things that stop a pass from running.
    private func skipReason(now: Date) -> String {
        if turnedOffAt != nil { return "reminders were turned off in Settings" }
        guard let lastPassAt else { return "Next Notes wasn't running" }
        if now.timeIntervalSince(lastPassAt) > Self.tickInterval * 4 { return "the Mac was asleep" }
        return "the scheduler was late"
    }

    // MARK: - Triggers

    /// Subscribes to `AgentTriggerEvents`. Called by `start`; the self-test calls it alone.
    func listenForTriggerEvents() {
        guard eventSubscription == nil else { return }
        eventSubscription = events.subscribe { [weak self] occurrences in
            guard let self else { return }
            // No clock here: the batch may wait behind a run of several minutes.
            Task { @MainActor in await self.handleTriggerEvents(occurrences) }
        }
    }

    /// One published batch of events. Queued behind any pass or edit, like everything that
    /// reads a schedule and saves it. `now` is nil live — the clock is read when the queued work
    /// actually decides and runs — and a fixed fake clock in the self-test.
    func handleTriggerEvents(_ occurrences: [ScheduleTriggerOccurrence], now: Date? = nil) async {
        // Upcoming meetings are published every tick: unless some enabled trigger would act
        // on the event now — it has not handled it, and a meeting is inside its lead time —
        // no queue and no disk read. Every writer of schedules saves through this store, so
        // its copy is current; the queued dispatch decides again with a fresh read.
        let checkedAt = now ?? Date()
        let wanted = occurrences.filter { occurrence in
            store.schedules.contains { schedule in
                guard schedule.kind == .trigger, schedule.enabled, let trigger = schedule.trigger,
                      trigger.event == occurrence.event, !schedule.hasHandled(occurrence.key) else { return false }
                switch Self.triggerDecision(trigger, occurrence: occurrence, createdAt: schedule.createdAt, now: checkedAt) {
                case .ignore, .notYet: return false
                case .run, .tooLate: return true
                }
            }
        }
        guard !wanted.isEmpty else { return }
        await enqueue { [weak self] in await self?.dispatchTriggers(wanted, fixedNow: now) }
    }

    /// What a trigger does with one occurrence right now.
    enum TriggerDecision: Equatable {
        /// Not its event, its filter does not match, or it happened before the trigger existed.
        case ignore
        /// A meeting further off than this trigger's lead time: asked again next tick.
        case notYet
        case run
        /// Found too late to be worth running: claimed and recorded as skipped, once.
        case tooLate(String)
    }

    nonisolated static func triggerDecision(
        _ trigger: ScheduleTrigger, occurrence: ScheduleTriggerOccurrence, createdAt: Date, now: Date
    ) -> TriggerDecision {
        guard trigger.matches(occurrence) else { return .ignore }
        switch occurrence.event {
        case .meetingStarting:
            guard let start = occurrence.start else { return .ignore }
            // A meeting already under way when the trigger was made is not one it was for.
            guard start >= createdAt else { return .ignore }
            if now < start.addingTimeInterval(-TimeInterval(trigger.leadMinutes * 60)) { return .notYet }
            let ended = occurrence.end.map { now >= $0 } ?? false
            if ended || now >= start.addingTimeInterval(meetingStartingGrace) {
                return .tooLate("the meeting had already started when Next Notes saw it")
            }
            return .run
        case .meetingNotesReady, .callStarted:
            return occurrence.observedAt.addingTimeInterval(1) < createdAt ? .ignore : .run
        }
    }

    /// Until when a trigger's skipped or failed run is still worth trying again.
    nonisolated static func triggerDeadline(for occurrence: ScheduleTriggerOccurrence) -> Date {
        switch occurrence.event {
        case .meetingNotesReady:
            return occurrence.observedAt.addingTimeInterval(notesReadyRetryWindow)
        case .meetingStarting:
            return (occurrence.start ?? occurrence.observedAt).addingTimeInterval(meetingStartingGrace)
        case .callStarted:
            return occurrence.observedAt.addingTimeInterval(callStartedRetryWindow)
        }
    }

    private func dispatchTriggers(_ occurrences: [ScheduleTriggerOccurrence], fixedNow: Date?) async {
        let settings = settingsProvider()
        // Switched off means no event is claimed either: nothing runs later for it.
        guard settings.enabled else { return }
        store.reload()
        let triggers = store.schedules.filter { $0.kind == .trigger }.map(\.id)
        guard !triggers.isEmpty else { return }
        for occurrence in occurrences {
            for id in triggers {
                // Re-read each time: the run before this one saved.
                guard var schedule = store.schedule(id: id), schedule.enabled,
                      let trigger = schedule.trigger, !schedule.hasHandled(occurrence.key) else { continue }
                // Read here, not when the batch was published: the run before this one may
                // have taken minutes, and a meeting's grace is five.
                let now = fixedNow ?? Date()
                // Past its end date: the next pass turns it off and says so.
                if let ends = schedule.endsAt, ends <= now { continue }
                switch Self.triggerDecision(trigger, occurrence: occurrence, createdAt: schedule.createdAt, now: now) {
                case .ignore, .notYet:
                    continue
                case .tooLate(let reason):
                    schedule.markHandled(occurrence.key)
                    record(&schedule, slot: nil, at: now, outcome: .skipped,
                           detail: "Skipped “\(occurrence.title)” — \(reason).", skippedSlots: 1)
                    store.save(schedule)
                case .run:
                    // Claim, then dispatch: the key is on disk before the run starts.
                    schedule.markHandled(occurrence.key)
                    schedule.lastRun = ScheduleRunSummary(at: now, outcome: .started, detail: "Running")
                    guard store.save(schedule) else {
                        Log.app.error("couldn't claim a trigger event; not running it")
                        continue
                    }
                    await runRoutine(&schedule, slot: nil, now: now, settings: settings, occurrence: occurrence)
                }
            }
        }
    }

    /// A trigger's pass: what `process` does for a time slot, minus the slot — a held result,
    /// a retry for its event while the event is still worth acting on, and the end date.
    private func processTrigger(_ original: AgentSchedule, now: Date, settings: ScheduleSettingsSnapshot) async {
        var schedule = original
        let held = schedule.pendingDeliveries
        // A snooze the user pressed still goes out on a paused trigger; nothing else does.
        guard schedule.enabled || held.contains(where: { $0.reason == Self.snoozeReason }) else { return }

        // Every held item is its own event's: each is re-held, given up, or taken to run.
        let zone = zoneProvider()
        var kept: [SchedulePendingDelivery] = []
        var due: [SchedulePendingDelivery] = []
        for pending in held {
            let snooze = pending.reason == Self.snoozeReason
            if pending.notBefore > now || (!schedule.enabled && !snooze) {
                kept.append(pending)
            } else if pending.text != nil, settings.isQuiet(now, zone: zone), !snooze {
                var later = pending
                later.notBefore = settings.quietEnd(after: now, zone: zone)
                kept.append(later)
            } else if pending.text == nil, let occurrence = pending.occurrence, Self.triggerDeadline(for: occurrence) < now {
                record(&schedule, slot: nil, at: now, outcome: .skipped,
                       detail: "Not retried for “\(occurrence.title)” — it was too late to be useful.", skippedSlots: 1)
            } else if pending.text != nil || pending.occurrence != nil {
                due.append(pending)
            }
            // Otherwise nothing to show or run again (a snooze before any result): dropped.
        }
        if !due.isEmpty || kept != held {
            // Claim, then dispatch: what is not due yet is on disk before anything runs.
            schedule.pendingDeliveries = kept
            if !due.isEmpty { schedule.lastRun = ScheduleRunSummary(at: now, outcome: .started, detail: "Running") }
            guard store.save(schedule) else { return }
        }
        for pending in due {
            // A retry that failed for the last time turns the trigger off and clears what it
            // held; the rest of this batch must not run on a disabled trigger.
            guard schedule.enabled || pending.reason == Self.snoozeReason else { break }
            await dispatch(&schedule, slot: nil, missed: false, now: now, settings: settings,
                           heldText: pending.text, ignoreQuiet: pending.reason == Self.snoozeReason,
                           occurrence: pending.occurrence)
        }

        if let ends = schedule.endsAt, schedule.enabled, schedule.pendingDelivery == nil, ends <= now {
            schedule.enabled = false
            record(&schedule, slot: nil, at: now, outcome: .ended,
                   detail: "Its end date (\(Self.stamp(ends, zone: zoneProvider()))) passed, so it turned itself off.")
        }
        if schedule != original { store.save(schedule) }
    }

    // MARK: - macOS registration

    /// Keeps exactly the next slot registered with macOS, except in the last
    /// `systemHandoverLead` before it, when the running app takes it over.
    /// Nothing is registered while reminders are switched off in Settings.
    private func syncSystemRegistration(
        _ schedule: inout AgentSchedule, now: Date, settings: ScheduleSettingsSnapshot? = nil
    ) async {
        guard schedule.kind == .reminder else { return }
        let enabled = (settings ?? settingsProvider()).enabled
        let target: Date? = {
            guard enabled, schedule.enabled, let next = schedule.nextRunAt else { return nil }
            return next.timeIntervalSince(now) > Self.systemHandoverLead ? next : nil
        }()
        guard target != schedule.systemRegisteredSlot else { return }
        if let target {
            let accepted = await system.register(schedule, slot: target)
            schedule.systemRegisteredSlot = accepted ? target : nil
        } else {
            system.withdraw(scheduleID: schedule.id)
            schedule.systemRegisteredSlot = nil
        }
    }

    // MARK: - What the tools and the notification buttons call

    /// Saves a new reminder with its first slot computed. Throws when the rule has no future
    /// occurrence or the kind is not available yet.
    /// Whether reminders are switched on in Settings.
    var isEnabled: Bool { settingsProvider().enabled }

    @discardableResult
    func add(_ draft: AgentSchedule, now: Date) async throws -> AgentSchedule {
        try await serialized { [self] in try await addNow(draft, now: now) }
    }

    private func addNow(_ draft: AgentSchedule, now: Date) async throws -> AgentSchedule {
        if draft.kind == .trigger {
            guard let trigger = draft.trigger else {
                throw ScheduleError.invalid("A trigger needs an event: notes ready, a meeting starting, or a call starting.")
            }
            guard (0...ScheduleTrigger.maxLeadMinutes).contains(trigger.leadMinutes) else {
                throw ScheduleError.invalid("A lead time must be 0 to \(ScheduleTrigger.maxLeadMinutes) minutes.")
            }
            if let ends = draft.endsAt, ends <= now {
                throw ScheduleError.invalid("That trigger's end date has already passed.")
            }
            var schedule = draft
            schedule.when = nil
            schedule.allowedTools.removeAll { $0.hasPrefix("schedule.") }
            schedule.nextRunAt = nil
            schedule.lastRun = nil
            schedule.consecutiveFailures = 0
            schedule.systemRegisteredSlot = nil
            schedule.pendingDeliveries = []
            schedule.handledEventKeys = nil
            guard store.save(schedule) else { throw ScheduleError.couldNotSave }
            return schedule
        }
        guard let when = draft.when, let rule = RecurrenceRule(when) else {
            throw ScheduleError.invalid("A schedule needs a time and a known time zone.")
        }
        var schedule = draft
        // Runs cannot create schedules, whatever the caller built.
        schedule.allowedTools.removeAll { $0.hasPrefix("schedule.") }
        if schedule.kind == .reminder { schedule.allowedTools = [] }
        schedule.nextRunAt = bounded(rule.next(after: now), by: schedule.endsAt)
        schedule.lastRun = nil
        schedule.consecutiveFailures = 0
        schedule.systemRegisteredSlot = nil
        schedule.pendingDelivery = nil
        guard schedule.nextRunAt != nil else {
            throw ScheduleError.invalid(schedule.isOneShot
                ? "That time has already passed."
                : "That reminder would never fire before its end date.")
        }
        await syncSystemRegistration(&schedule, now: now)
        guard store.save(schedule) else { throw ScheduleError.couldNotSave }
        return schedule
    }

    @discardableResult
    func update(id: UUID, edit: ScheduleEdit, now: Date) async throws -> AgentSchedule {
        try await serialized { [self] in try await updateNow(id: id, edit: edit, now: now) }
    }

    private func updateNow(id: UUID, edit: ScheduleEdit, now: Date) async throws -> AgentSchedule {
        store.reload()
        guard var schedule = store.schedule(id: id) else { throw ScheduleError.notFound(id.uuidString) }
        if let title = edit.title { schedule.title = title }
        if let prompt = edit.prompt { schedule.prompt = prompt }
        if let delivery = edit.delivery { schedule.delivery = delivery }
        if let model = edit.model, schedule.kind != .reminder { schedule.model = model }
        if schedule.kind == .trigger {
            if let trigger = edit.trigger {
                guard (0...ScheduleTrigger.maxLeadMinutes).contains(trigger.leadMinutes) else {
                    throw ScheduleError.invalid("A lead time must be 0 to \(ScheduleTrigger.maxLeadMinutes) minutes.")
                }
                schedule.trigger = trigger
            }
            if let endsAt = edit.endsAt {
                if let ends = endsAt, ends <= now { throw ScheduleError.invalid("That end date has already passed.") }
                schedule.endsAt = endsAt
                schedule.enabled = true
            }
            schedule.plainEnglish = ScheduleToolExecutor.triggerSentence(for: schedule)
            guard store.save(schedule) else { throw ScheduleError.couldNotSave }
            return schedule
        }
        let timingChanged = edit.when != nil || edit.endsAt != nil
        if let when = edit.when { schedule.when = when }
        if let endsAt = edit.endsAt { schedule.endsAt = endsAt }
        if let when = schedule.when, let rule = RecurrenceRule(when) {
            schedule.plainEnglish = ScheduleToolExecutor.sentence(for: schedule, rule: rule, currentZone: zoneProvider())
            if timingChanged {
                let next = bounded(rule.next(after: now), by: schedule.endsAt)
                guard next != nil else {
                    throw ScheduleError.invalid(schedule.isOneShot
                        ? "That time has already passed."
                        : "That reminder would never fire before its end date.")
                }
                schedule.nextRunAt = next
                schedule.pendingDelivery = nil
                schedule.enabled = true
            }
        }
        if timingChanged || edit.prompt != nil, schedule.systemRegisteredSlot != nil {
            // The registered request carries the old slot or text.
            system.withdraw(scheduleID: schedule.id)
            schedule.systemRegisteredSlot = nil
        }
        await syncSystemRegistration(&schedule, now: now)
        guard store.save(schedule) else { throw ScheduleError.couldNotSave }
        return schedule
    }

    @discardableResult
    func pause(id: UUID, now: Date) async throws -> AgentSchedule {
        try await serialized { [self] in
            store.reload()
            guard var schedule = store.schedule(id: id) else { throw ScheduleError.notFound(id.uuidString) }
            schedule.enabled = false
            schedule.pendingDeliveries = []
            await syncSystemRegistration(&schedule, now: now)
            guard store.save(schedule) else { throw ScheduleError.couldNotSave }
            return schedule
        }
    }

    /// Picks up from now: slots that went by while paused are not caught up.
    @discardableResult
    func resume(id: UUID, now: Date) async throws -> AgentSchedule {
        try await serialized { [self] in try await resumeNow(id: id, now: now) }
    }

    private func resumeNow(id: UUID, now: Date) async throws -> AgentSchedule {
        store.reload()
        guard var schedule = store.schedule(id: id) else { throw ScheduleError.notFound(id.uuidString) }
        if schedule.kind == .trigger {
            // Picks up from now: events that went by while paused are not run.
            if let ends = schedule.endsAt, ends <= now {
                throw ScheduleError.invalid("That trigger's end date has passed.")
            }
            schedule.enabled = true
            schedule.consecutiveFailures = 0
            guard store.save(schedule) else { throw ScheduleError.couldNotSave }
            return schedule
        }
        guard let when = schedule.when, let rule = RecurrenceRule(when) else {
            throw ScheduleError.invalid("This schedule has no time to resume at.")
        }
        guard let next = bounded(rule.next(after: now), by: schedule.endsAt) else {
            throw ScheduleError.invalid(schedule.isOneShot
                ? "That reminder's time has already passed; set a new one."
                : "That reminder's end date has passed.")
        }
        schedule.enabled = true
        schedule.nextRunAt = next
        schedule.consecutiveFailures = 0
        await syncSystemRegistration(&schedule, now: now)
        guard store.save(schedule) else { throw ScheduleError.couldNotSave }
        return schedule
    }

    func remove(id: UUID) async throws {
        try await serialized { [self] () async throws -> Bool in
            store.reload()
            guard store.schedule(id: id) != nil else { throw ScheduleError.notFound(id.uuidString) }
            system.withdraw(scheduleID: id)
            guard store.remove(id: id) else { throw ScheduleError.couldNotSave }
            store.removeDrafts(for: id)
            return true
        }
    }

    /// Delivers now without moving the schedule's next slot.
    func runNow(id: UUID, now: Date) async throws -> ScheduleRunRecord? {
        try await serialized { [self] in
            store.reload()
            guard var schedule = store.schedule(id: id) else { throw ScheduleError.notFound(id.uuidString) }
            let settings = settingsProvider()
            await dispatch(&schedule, slot: nil, missed: false, now: now, settings: settings, outcome: .ranNow)
            return store.runs(for: id, limit: 1).last
        }
    }

    /// A routine's test run on creation: once, immediately and visibly, never escalating.
    /// The caller removes the routine when this fails.
    func testRun(id: UUID, now: Date) async throws -> ScheduledRunOutcome {
        try await serialized { [self] in
            store.reload()
            guard var schedule = store.schedule(id: id) else { throw ScheduleError.notFound(id.uuidString) }
            guard schedule.kind != .reminder else {
                return ScheduledRunOutcome(status: .nothingToReport, text: "")
            }
            return await runRoutine(&schedule, slot: nil, now: now, settings: settingsProvider(), forced: .ranNow)
        }
    }

    /// Approving a draft is the user's authority; the action executes now.
    @discardableResult
    func approveDraft(id: UUID, now: Date = Date(),
                      execute: RoutineDraftApproval.Executor = RoutineDraftApproval.liveExecutor) async throws -> RoutineDraft {
        try await RoutineDraftApproval.approve(id: id, store: store, now: now, execute: execute)
    }

    func dismissDraft(id: UUID, now: Date = Date()) {
        RoutineDraftApproval.dismiss(id: id, store: store, now: now)
    }

    /// Holds the reminder for ten minutes, then delivers it again, quiet hours or not — and
    /// even if the reminder is paused or finished: the user pressed Snooze on this one.
    func snooze(id: UUID, now: Date) async {
        await enqueue { [self] in
            store.reload()
            guard var schedule = store.schedule(id: id) else { return }
            // A routine's snooze shows its last result again; it does not re-run the work.
            let held: String? = schedule.kind != .reminder
                ? (lastDeliveredText[id].map { $0.replacingOccurrences(of: "\(schedule.title): ", with: "") }
                    ?? schedule.lastRun?.detail)
                : nil
            let snoozed = SchedulePendingDelivery(
                slot: nil, notBefore: now.addingTimeInterval(Self.snoozeInterval), missed: false,
                reason: Self.snoozeReason, text: held)
            if schedule.kind == .trigger {
                // Beside an event's retry or held result, never in place of it.
                schedule.pendingDeliveries.removeAll { $0.reason == Self.snoozeReason }
                schedule.pendingDeliveries.append(snoozed)
            } else {
                schedule.pendingDelivery = snoozed
            }
            record(&schedule, slot: nil, at: now, outcome: .deferred, detail: "Snoozed for 10 minutes.")
            store.save(schedule)
        }
    }

    static let snoozeReason = "snoozed"

    private func handle(_ action: Notifications.Action) {
        switch action {
        case .snoozeSchedule(let id):
            Task { @MainActor in await snooze(id: id, now: Date()) }
        case .readScheduleAloud(let id):
            // Pressing the button is presence enough.
            let text = lastDeliveredText[id]
                ?? store.schedule(id: id).map { $0.kind == .reminder ? "Reminder: \($0.prompt)" : "\($0.title): \($0.lastRun?.detail ?? "")" }
            if let text { deliverer.speak(text) }
        case .openSchedule, .reviewRoutineDraft:
            deliverer.openSchedules()
        case .approveRoutineDraft(let id):
            Task { @MainActor in
                do {
                    let draft = try await approveDraft(id: id)
                    IslandState.shared.showAgentReply("Approved: \(draft.title)")
                } catch {
                    IslandState.shared.showAgentReply("That draft did not run: \(error.localizedDescription)")
                }
            }
        case .recordNow, .skip, .open, .approveProposal, .dismissProposal:
            break
        }
    }

    // MARK: - Helpers

    private func bounded(_ date: Date?, by endsAt: Date?) -> Date? {
        guard let date else { return nil }
        if let endsAt, date > endsAt { return nil }
        return date
    }

    private func record(
        _ schedule: inout AgentSchedule,
        slot: Date?,
        at: Date,
        outcome: ScheduleRunRecord.Outcome,
        detail: String,
        skippedSlots: Int = 0,
        summarize: Bool = true
    ) {
        store.appendRun(ScheduleRunRecord(
            scheduleID: schedule.id, slot: slot, at: at, outcome: outcome,
            detail: detail, skippedSlots: skippedSlots))
        if summarize {
            schedule.lastRun = ScheduleRunSummary(at: at, outcome: outcome, detail: detail)
        }
    }

    nonisolated static func stamp(_ date: Date, zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "EEE d MMM HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - Production seams

@MainActor
final class LiveScheduleEnvironment: ScheduleEnvironment {
    /// Keyboard or mouse in the last two minutes. Reading the idle time needs no permission.
    var isUserPresent: Bool {
        guard let anyInput = CGEventType(rawValue: UInt32.max) else { return false }
        return CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput) < 120
    }

    var isRecording: Bool { MeetingController.shared.session != nil }
    var isDictating: Bool { AppDelegate.current?.controller.state.isActive ?? false }
    var isCallActive: Bool { CallDetector.shared.current != nil }
    var isAgentBusy: Bool {
        AgentSpeechSynthesizer.shared.isSpeaking || ActivationController.shared.mode != .idle
    }
}

@MainActor
final class LiveScheduleDelivery: ScheduleDelivering {
    /// Throws when macOS refuses the notification, so a delivery that never showed counts as
    /// a failure and escalates.
    func deliver(_ delivery: ScheduleDelivery) async throws {
        try await Notifications.shared.postAgentReminder(
            scheduleID: delivery.scheduleID, title: delivery.title, body: delivery.body)
        IslandState.shared.showAgentReply(delivery.kind != .reminder || delivery.missed
            ? "\(delivery.title): \(delivery.body)" : "Reminder: \(delivery.body)")
        if delivery.speak {
            // The synthesizer directly: no voice session, no microphone.
            AgentSpeechSynthesizer.shared.speak(delivery.spoken)
        }
    }

    func notifyProblem(scheduleID: UUID, title: String, body: String) {
        Notifications.shared.postAgentReminderProblem(scheduleID: scheduleID, title: title, body: body)
    }

    func openSchedules() {
        NavigationState.shared.showRoutines()
        AppDelegate.showMainWindow()
    }

    func speak(_ text: String) {
        AgentSpeechSynthesizer.shared.speak(text)
    }

    func notifyDrafts(_ drafts: [RoutineDraft], scheduleTitle: String) {
        for draft in drafts {
            Notifications.shared.postRoutineDraft(draft, scheduleTitle: scheduleTitle)
        }
    }
}

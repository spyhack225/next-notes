import Foundation

/// One piece of scheduled work: a reminder, a routine or a trigger (Part 3).
///
/// Stored in `agent-schedules.json`, deliberately apart from `agent-tasks.json`: the task
/// store fails every unfinished task on launch, which is right for tasks and fatal for
/// schedules.
///
/// The fields split in two. Everything down to `createdInSession` is what the user confirmed
/// and a `schedule.*` tool may set. `nextRunAt` and below are owned by `AgentScheduler` and
/// are never written from a model's arguments — a model-maintained state file drifts (lesson
/// 5), so the tools build these from code and the scheduler alone advances them.
struct AgentSchedule: Codable, Identifiable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        /// Says something at a time. Runs no tools.
        case reminder
        /// Runs the tool loop at a time. Part 3, phase R2.
        case routine
        /// Runs the tool loop after an event — notes ready, a meeting starting, a call. Phase R3.
        case trigger
    }

    enum ModelChoice: String, Codable, Sendable {
        case auto
        case local
        case cloud
    }

    enum Delivery: String, Codable, Sendable {
        case notify
        /// Also spoken, when the presence rule allows it (`ScheduleEnvironment`).
        case notifyAndSpeak
    }

    /// Hard limits per run — lesson 8. Parameters, not prompt text.
    struct Budget: Codable, Equatable, Sendable {
        var maxSeconds: Int
        var maxToolCalls: Int

        static let standard = Budget(maxSeconds: 180, maxToolCalls: 8)
    }

    let id: UUID
    var kind: Kind
    var title: String
    /// The sentence the user confirmed, rendered from the structured fields by code.
    var plainEnglish: String
    /// Self-contained instructions for a run; for a reminder, what to say.
    var prompt: String
    var when: ScheduleWhen?
    var trigger: ScheduleTrigger?
    /// Enforced by the scheduler — lesson 6.
    var endsAt: Date?
    /// Fixed at creation. Empty for a reminder.
    var allowedTools: [String]
    var model: ModelChoice
    var delivery: Delivery
    var budget: Budget
    var enabled: Bool
    let createdAt: Date
    var createdInSession: UUID?

    // MARK: Owned by the scheduler. Never written by a model — lesson 5.

    var nextRunAt: Date?
    var lastRun: ScheduleRunSummary?
    var consecutiveFailures: Int
    /// The slot currently handed to macOS as a calendar notification, if any. Lets launch
    /// tell "macOS already delivered this while the app was closed" from "nobody did".
    var systemRegisteredSlot: Date?
    /// A delivery held back by quiet hours or a snooze, delivered once `notBefore` passes.
    var pendingDelivery: SchedulePendingDelivery?
    /// A trigger's further held items, behind `pendingDelivery`: two events close together
    /// each keep their own held result or retry. Nil for reminders and routines, which hold
    /// one item — and always nil while `pendingDelivery` is (see `pendingDeliveries`).
    var queuedDeliveries: [SchedulePendingDelivery]?
    /// A trigger's claimed events, newest last: an event published twice runs once. Optional
    /// so schedules saved before triggers existed still decode.
    var handledEventKeys: [String]?

    init(
        id: UUID = UUID(),
        kind: Kind,
        title: String,
        plainEnglish: String,
        prompt: String,
        when: ScheduleWhen? = nil,
        trigger: ScheduleTrigger? = nil,
        endsAt: Date? = nil,
        allowedTools: [String] = [],
        model: ModelChoice = .auto,
        delivery: Delivery = .notifyAndSpeak,
        budget: Budget = .standard,
        enabled: Bool = true,
        createdAt: Date,
        createdInSession: UUID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.plainEnglish = plainEnglish
        self.prompt = prompt
        self.when = when
        self.trigger = trigger
        self.endsAt = endsAt
        self.allowedTools = allowedTools
        self.model = model
        self.delivery = delivery
        self.budget = budget
        self.enabled = enabled
        self.createdAt = createdAt
        self.createdInSession = createdInSession
        nextRunAt = nil
        lastRun = nil
        consecutiveFailures = 0
        systemRegisteredSlot = nil
        pendingDelivery = nil
        queuedDeliveries = nil
        handledEventKeys = nil
    }

    /// Everything held, oldest first: `pendingDelivery` then `queuedDeliveries`. Setting it
    /// keeps the two in step, so `pendingDelivery == nil` still means nothing is held.
    var pendingDeliveries: [SchedulePendingDelivery] {
        get { (pendingDelivery.map { [$0] } ?? []) + (queuedDeliveries ?? []) }
        set {
            pendingDelivery = newValue.first
            queuedDeliveries = newValue.count > 1 ? Array(newValue.dropFirst()) : nil
        }
    }

    /// The short id the tools accept and `schedule.list` prints.
    var shortID: String { String(id.uuidString.prefix(8)).lowercased() }

    var isOneShot: Bool {
        if case .once = when?.repeatRule { return true }
        return false
    }

    /// How many claimed event keys a trigger keeps. Older ones are events long past.
    static let handledEventLimit = 200

    func hasHandled(_ key: String) -> Bool {
        handledEventKeys?.contains(key) ?? false
    }

    mutating func markHandled(_ key: String) {
        var keys = handledEventKeys ?? []
        keys.removeAll { $0 == key }
        keys.append(key)
        if keys.count > Self.handledEventLimit { keys.removeFirst(keys.count - Self.handledEventLimit) }
        handledEventKeys = keys
    }
}

/// When a reminder or routine runs: wall-clock time plus an IANA zone, never a UTC instant
/// for a recurring job — both reference projects shipped timezone bugs from getting that wrong.
struct ScheduleWhen: Codable, Equatable, Sendable {
    enum Repeat: Codable, Equatable, Sendable {
        /// The one instant, computed from the wall-clock time in `timeZone` at creation.
        case once(Date)
        case daily
        /// Monday to Friday.
        case weekdays
        case weekly([ScheduleWeekday])
        /// Clamped to the last day of shorter months: `.monthly(day: 31)` is the last day.
        case monthly(day: Int)
    }

    var repeatRule: Repeat
    var time: ScheduleLocalTime
    var timeZone: String
}

struct ScheduleLocalTime: Codable, Equatable, Sendable, Comparable {
    var hour: Int
    var minute: Int

    var formatted: String { String(format: "%02d:%02d", hour, minute) }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.hour, lhs.minute) < (rhs.hour, rhs.minute)
    }

    /// "9", "09:30", "9.30", "9:30pm", "21:00". Nil for anything else.
    static func parse(_ raw: String) -> ScheduleLocalTime? {
        var text = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".", with: ":")
            .replacingOccurrences(of: " ", with: "")
        var meridiem: String?
        for suffix in ["am", "pm", "a", "p"] where text.hasSuffix(suffix) {
            meridiem = suffix.hasPrefix("a") ? "am" : "pm"
            text.removeLast(suffix.count)
            break
        }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count),
              let hourValue = Int(parts[0]),
              parts[0].count <= 2 else { return nil }
        var hour = hourValue
        let minute: Int
        if parts.count == 2 {
            guard parts[1].count == 2, let value = Int(parts[1]) else { return nil }
            minute = value
        } else {
            minute = 0
        }
        if let meridiem {
            guard (1...12).contains(hour) else { return nil }
            if meridiem == "am" { hour = hour == 12 ? 0 : hour }
            else { hour = hour == 12 ? 12 : hour + 12 }
        }
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return ScheduleLocalTime(hour: hour, minute: minute)
    }
}

/// `Calendar` weekday numbering: Sunday is 1.
enum ScheduleWeekday: Int, Codable, Sendable, CaseIterable, Comparable {
    case sunday = 1, monday, tuesday, wednesday, thursday, friday, saturday

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var name: String {
        switch self {
        case .sunday: "Sunday"
        case .monday: "Monday"
        case .tuesday: "Tuesday"
        case .wednesday: "Wednesday"
        case .thursday: "Thursday"
        case .friday: "Friday"
        case .saturday: "Saturday"
        }
    }

    /// "mon", "Monday", "tues", "thu". Nil for anything else.
    static func parse(_ raw: String) -> ScheduleWeekday? {
        let text = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2 else { return nil }
        return allCases.first { $0.name.lowercased().hasPrefix(text) || text.hasPrefix($0.name.lowercased().prefix(3)) }
    }
}

/// What a trigger waits for (phase R3). The filter is plain text matched against the meeting
/// title or attendees; `AgentTriggerEvents.swift` has the matching and the publishers.
enum ScheduleTrigger: Codable, Equatable, Sendable {
    case meetingNotesReady(filter: String?)
    case meetingStarting(leadMinutes: Int, filter: String?)
    case callStarted
}

/// The latest thing that happened to a schedule, for the list and the tools.
struct ScheduleRunSummary: Codable, Equatable, Sendable {
    var at: Date
    var outcome: ScheduleRunRecord.Outcome
    var detail: String
}

/// A delivery held back — by quiet hours or a snooze — and the text it will carry.
struct SchedulePendingDelivery: Codable, Equatable, Sendable {
    var slot: Date?
    var notBefore: Date
    var missed: Bool
    var reason: String
    /// A routine's finished result held back by quiet hours: delivered as is, never re-run.
    /// Nil for a reminder, and for a routine retry, which runs again.
    var text: String? = nil
    /// A trigger's retry: the event it runs for again. Nil for everything else.
    var occurrence: ScheduleTriggerOccurrence? = nil
}

/// One line of `agent-schedule-runs.jsonl`. Every slot leaves one, including the ones that
/// did not run and why — a schedule that fails quietly looks healthy.
struct ScheduleRunRecord: Codable, Equatable, Sendable, Identifiable {
    enum Outcome: String, Codable, Sendable {
        /// Claimed and dispatching. Only ever `lastRun`, saved before the delivery starts; a
        /// launch that finds it records `.interrupted` once and never replays the slot.
        case started
        /// Delivered on time, or late within grace.
        case delivered
        /// Found beyond grace and delivered as *Missed: …*.
        case missed
        /// Slots that were never delivered, collapsed into one catch-up.
        case skipped
        /// Held back by quiet hours or a snooze.
        case deferred
        /// macOS delivered the registered notification while the app was closed.
        case deliveredBySystem
        case failed
        /// Found running on launch: recorded as failed once, never replayed.
        case interrupted
        /// `endsAt` passed; the schedule disabled itself.
        case ended
        /// `schedule.run_now`, or a routine's test run on creation.
        case ranNow
        /// A routine ran and delivered its result.
        case completed
        /// A routine ran and its answer was exactly `NOTHING_TO_REPORT`: nothing delivered.
        case nothingToReport
    }

    let id: UUID
    let scheduleID: UUID
    /// The slot this concerns, when there is one.
    let slot: Date?
    let at: Date
    let outcome: Outcome
    let detail: String
    /// For `.skipped`: how many slots the line stands for.
    let skippedSlots: Int

    init(
        scheduleID: UUID,
        slot: Date?,
        at: Date,
        outcome: Outcome,
        detail: String,
        skippedSlots: Int = 0
    ) {
        id = UUID()
        self.scheduleID = scheduleID
        self.slot = slot
        self.at = at
        self.outcome = outcome
        self.detail = detail
        self.skippedSlots = skippedSlots
    }
}

/// A write a routine prepared and did not run (Part 3, authority 4).
///
/// Its receipt is in `waitingPermission`; the user approves it from the
/// `agentRoutineApproval` notification or the Routines view, and that approval is user
/// authority. Stored in `agent-routine-drafts.json` beside the schedules.
struct RoutineDraft: Codable, Equatable, Sendable, Identifiable {
    enum Status: String, Codable, Sendable {
        case awaitingApproval
        case approved
        case dismissed
        /// Approved, and the action then failed.
        case failed
    }

    let id: UUID
    let scheduleID: UUID
    /// The scheduled `AgentTask` that prepared it.
    let taskID: String
    /// The `ActionReceipt` left in `waitingPermission`.
    let receiptID: UUID
    let toolID: String
    let arguments: [String: String]
    let title: String
    let preview: String?
    let risk: AgentRisk
    let createdAt: Date
    var status: Status
    var result: String?
    var resolvedAt: Date?

    init(
        id: UUID = UUID(), scheduleID: UUID, taskID: String, receiptID: UUID, toolID: String,
        arguments: [String: String], title: String, preview: String?, risk: AgentRisk, createdAt: Date
    ) {
        self.id = id
        self.scheduleID = scheduleID
        self.taskID = taskID
        self.receiptID = receiptID
        self.toolID = toolID
        self.arguments = arguments
        self.title = title
        self.preview = preview
        self.risk = risk
        self.createdAt = createdAt
        status = .awaitingApproval
        result = nil
        resolvedAt = nil
    }
}

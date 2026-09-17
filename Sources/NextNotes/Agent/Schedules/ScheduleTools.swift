import Foundation

/// `schedule.list` / `create` / `update` / `pause` / `resume` / `remove` / `run_now`.
///
/// Reminders only in this phase. The model fills structured fields — a repeat word, a
/// 24-hour time, a date, weekday names, a day of the month — and code turns them into a
/// `ScheduleWhen`, renders the sentence the user hears, and leaves every scheduler-owned
/// field to `AgentScheduler`. Nothing a model writes reaches `nextRunAt`.
///
/// The descriptions carry the reference projects' rules, first words first because the
/// planner's compact catalogue cuts them at 85 characters: list before creating, restate and
/// wait for a yes, the prompt must stand alone. Runs can never create schedules: no
/// scheduled run is ever given a `schedule.*` tool.
///
/// The writes are `.modify`. `create`, `update`, `pause` and `resume` skip the permission
/// card only when `ScheduleConfirmation` finds, in code, that the user's own yes to the
/// restated sentence is behind the call and no tool output could have written it — the card
/// would otherwise ask twice. Anything short of that, and every `remove` and `run_now`, goes
/// through the normal card, whose preview is the sentence.
enum ScheduleToolCatalogue {
    static let ids: Set<String> = [
        "schedule.list", "schedule.create", "schedule.update", "schedule.pause",
        "schedule.resume", "schedule.remove", "schedule.run_now",
    ]

    /// The writes that may skip the card when `ScheduleConfirmation` passes.
    static let confirmableIDs: Set<String> = [
        "schedule.create", "schedule.update", "schedule.pause", "schedule.resume",
    ]

    private static let idParameter = WorkspaceTool.Parameter(name: "id", description: "the id from schedule.list")

    private static let timingParameters: [WorkspaceTool.Parameter] = [
        .init(name: "repeat", description: "once, daily, weekdays, weekly or monthly", isRequired: false),
        .init(name: "time", description: "24-hour HH:mm", isRequired: false),
        .init(name: "date", description: "YYYY-MM-DD, today or tomorrow; once only", isRequired: false),
        .init(name: "inMinutes", description: "minutes from now; once only", isRequired: false),
        .init(name: "days", description: "weekly: comma-separated weekday names", isRequired: false),
        .init(name: "day", description: "monthly: day of month 1-31; 31 means the last day", isRequired: false),
        .init(name: "endsOn", description: "YYYY-MM-DD last day, or none", isRequired: false),
        .init(name: "speak", description: "no to only notify", isRequired: false),
    ]

    static let all: [AgentTool] = [
        .native(
            namespace: .schedule,
            name: "list",
            description: "List reminders with ids, next time and the current time. Call before creating one.",
            risk: .read,
            title: "List reminders"
        ),
        .native(
            namespace: .schedule,
            name: "create",
            description: "Create a reminder only after the user said yes to your one-sentence restatement "
                + "of when and what. Call schedule.list first and update a matching reminder instead of "
                + "making a near-duplicate. text must stand alone: it is read later with no conversation.",
            risk: .modify,
            parameters: [
                .init(name: "title", description: "a few words"),
                .init(name: "text", description: "what to remind the user, standalone"),
                .init(name: "plainEnglish", description: "the sentence the user agreed to", isRequired: false),
            ] + timingParameters,
            executionMode: .immediate,
            title: "Set a reminder"
        ),
        .native(
            namespace: .schedule,
            name: "update",
            description: "Change a reminder's text, time, repeat or end date after the user agreed.",
            risk: .modify,
            parameters: [
                idParameter,
                .init(name: "title", description: "a few words", isRequired: false),
                .init(name: "text", description: "what to remind the user", isRequired: false),
            ] + timingParameters,
            executionMode: .immediate,
            title: "Change a reminder"
        ),
        .native(
            namespace: .schedule, name: "pause", description: "Pause a reminder without deleting it.",
            risk: .modify, parameters: [idParameter], executionMode: .immediate, title: "Pause a reminder"
        ),
        .native(
            namespace: .schedule, name: "resume", description: "Resume a paused reminder from now on.",
            risk: .modify, parameters: [idParameter], executionMode: .immediate, title: "Resume a reminder"
        ),
        .native(
            namespace: .schedule, name: "remove", description: "Delete a reminder the user asked to delete.",
            risk: .modify, parameters: [idParameter], executionMode: .immediate, title: "Delete a reminder"
        ),
        .native(
            namespace: .schedule, name: "run_now", description: "Deliver a reminder now, as a test.",
            risk: .modify, parameters: [idParameter], executionMode: .immediate, title: "Run a reminder now"
        ),
    ]
}

enum ScheduleToolExecutor {
    @MainActor
    static func run(
        _ tool: AgentTool,
        arguments: [String: String],
        scheduler: AgentScheduler = .shared,
        now: Date = Date(),
        timeZone: TimeZone = .current,
        sessionID: UUID? = nil
    ) async throws -> AgentToolResult {
        func argument(_ name: String) -> String {
            arguments[name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        let store = scheduler.store
        if tool.risk > .read, !scheduler.isEnabled {
            throw ScheduleError.notAvailable("Reminders are turned off in Settings.")
        }
        switch tool.name {
        case "list":
            store.reload()
            var lines = ["Now: \(AgentScheduler.stamp(now, zone: timeZone)) (\(timeZone.identifier))."]
            if store.schedules.isEmpty {
                lines.append("No reminders yet.")
            }
            for schedule in store.schedules {
                lines.append("- " + listLine(schedule, now: now))
            }
            return AgentToolResult(summary: lines.joined(separator: "\n"))

        case "create":
            try refuseInexpressible(arguments)
            let kind = argument("kind").lowercased()
            if !kind.isEmpty, kind != "reminder" {
                throw ScheduleError.notAvailable("Only reminders can be scheduled so far; routines and triggers come later.")
            }
            let text = firstNonEmpty(argument("text"), argument("prompt"), argument("title"))
            guard !text.isEmpty else { throw ScheduleError.invalid("A reminder needs text: what to remind the user.") }
            let when = try parseWhen(arguments, base: nil, now: now, timeZone: timeZone)
            var schedule = AgentSchedule(
                kind: .reminder,
                title: firstNonEmpty(argument("title"), String(text.prefix(40))),
                plainEnglish: "",
                prompt: text,
                when: when,
                endsAt: try parseEndsOn(argument("endsOn"), timeZone: timeZone) ?? nil,
                delivery: isNo(argument("speak")) ? .notify : .notifyAndSpeak,
                createdAt: now,
                createdInSession: sessionID
            )
            guard let rule = RecurrenceRule(when) else { throw ScheduleError.invalid("Unknown time zone.") }
            schedule.plainEnglish = sentence(for: schedule, rule: rule, currentZone: timeZone)
            if let existing = duplicate(of: schedule, in: store.schedules) {
                throw ScheduleError.invalid(
                    "A matching reminder already exists [\(existing.shortID)]: \(existing.plainEnglish) "
                        + "Use schedule.update to change it instead of creating another.")
            }
            let saved = try await scheduler.add(schedule, now: now)
            return confirmation("Saved", saved, store: store, zone: timeZone)

        case "update":
            let target = try resolve(argument("id"), in: store)
            try refuseInexpressible(arguments)
            var edit = ScheduleEdit()
            if !argument("title").isEmpty { edit.title = argument("title") }
            let text = firstNonEmpty(argument("text"), argument("prompt"))
            if !text.isEmpty { edit.prompt = text }
            let timingKeys = ["repeat", "time", "date", "inMinutes", "days", "day"]
            if timingKeys.contains(where: { !argument($0).isEmpty }) {
                edit.when = try parseWhen(arguments, base: target.when, now: now, timeZone: timeZone)
            }
            if !argument("endsOn").isEmpty { edit.endsAt = try parseEndsOn(argument("endsOn"), timeZone: timeZone) }
            if !argument("speak").isEmpty { edit.delivery = isNo(argument("speak")) ? .notify : .notifyAndSpeak }
            let saved = try await scheduler.update(id: target.id, edit: edit, now: now)
            return confirmation("Updated", saved, store: store, zone: timeZone)

        case "pause":
            let target = try resolve(argument("id"), in: store)
            let saved = try await scheduler.pause(id: target.id, now: now)
            return AgentToolResult(
                summary: "Paused: \(saved.plainEnglish)",
                reference: saved.id.uuidString,
                verification: store.schedule(id: saved.id)?.enabled == false ? "Schedule read back paused" : nil)

        case "resume":
            let target = try resolve(argument("id"), in: store)
            let saved = try await scheduler.resume(id: target.id, now: now)
            return confirmation("Resumed", saved, store: store, zone: timeZone)

        case "remove":
            let target = try resolve(argument("id"), in: store)
            try await scheduler.remove(id: target.id)
            return AgentToolResult(
                summary: "Deleted: \(target.plainEnglish)",
                reference: target.id.uuidString,
                verification: store.schedule(id: target.id) == nil ? "Schedule absent after delete" : nil)

        case "run_now":
            let target = try resolve(argument("id"), in: store)
            let run = try await scheduler.runNow(id: target.id, now: now)
            guard let run else { throw ScheduleError.couldNotSave }
            if run.outcome == .failed {
                throw ScheduleError.invalid("The test delivery failed: \(run.detail)")
            }
            return AgentToolResult(
                summary: "Delivered now: \(target.prompt)",
                reference: target.id.uuidString,
                verification: "Run recorded in agent-schedule-runs.jsonl")

        default:
            throw AgentError.unknownTool(tool.id)
        }
    }

    // MARK: - Sentences

    /// "Every weekday at 09:00, I'll remind you: stand up." Rendered from the fields, so what
    /// the user hears is what the scheduler will do.
    static func sentence(for schedule: AgentSchedule, rule: RecurrenceRule, currentZone: TimeZone = .current) -> String {
        var text = rule.describe(currentZone: currentZone)
        text = text.prefix(1).uppercased() + text.dropFirst()
        let what = schedule.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        var sentence = "\(text), I'll remind you: \(what)"
        if let ends = schedule.endsAt {
            sentence += " (until \(AgentScheduler.stamp(ends, zone: rule.calendar.timeZone)))"
        }
        if !sentence.hasSuffix(".") && !sentence.hasSuffix("?") && !sentence.hasSuffix("!") { sentence += "." }
        return sentence
    }

    @MainActor
    private static func confirmation(_ verb: String, _ saved: AgentSchedule, store: ScheduleStore, zone: TimeZone) -> AgentToolResult {
        let stored = store.schedule(id: saved.id)
        let next = saved.nextRunAt.map { " Next: \(AgentScheduler.stamp($0, zone: zone))." } ?? ""
        return AgentToolResult(
            summary: "\(verb): \(saved.plainEnglish)\(next)",
            reference: saved.id.uuidString,
            verification: stored?.nextRunAt == saved.nextRunAt && stored != nil
                ? "Schedule read back from agent-schedules.json" : nil)
    }

    private static func listLine(_ schedule: AgentSchedule, now: Date) -> String {
        let zone = schedule.when.flatMap { TimeZone(identifier: $0.timeZone) } ?? .current
        var parts = ["[\(schedule.shortID)] \(schedule.title) — \(schedule.plainEnglish)"]
        if !schedule.enabled {
            parts.append(schedule.isOneShot && schedule.nextRunAt == nil ? "done" : "paused")
        } else if let next = schedule.nextRunAt {
            parts.append("next \(AgentScheduler.stamp(next, zone: zone))")
        }
        if let last = schedule.lastRun {
            parts.append("last: \(last.outcome.rawValue) \(AgentScheduler.stamp(last.at, zone: zone))")
        }
        return parts.joined(separator: " | ")
    }

    // MARK: - Arguments

    private static func refuseInexpressible(_ arguments: [String: String]) throws {
        // Not the title: "Follow up on last Monday's call" names no rule.
        for key in ["plainEnglish", "repeat"] {
            if let value = arguments[key], let reason = RecurrenceRule.inexpressibleReason(in: value) {
                throw ScheduleError.invalid(reason)
            }
        }
    }

    /// Builds a `ScheduleWhen` from the tool arguments; missing pieces come from `base` on
    /// an update. Wall-clock time and the current IANA zone are what get stored.
    static func parseWhen(
        _ arguments: [String: String],
        base: ScheduleWhen?,
        now: Date,
        timeZone: TimeZone
    ) throws -> ScheduleWhen {
        func argument(_ name: String) -> String {
            arguments[name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let zoneID = base?.timeZone ?? timeZone.identifier
        if let zone = TimeZone(identifier: zoneID) { calendar.timeZone = zone }

        let repeatWord = argument("repeat").lowercased()
        let minutes = argument("inMinutes")
        let explicitTime: ScheduleLocalTime?
        if argument("time").isEmpty {
            explicitTime = nil
        } else {
            guard let parsed = ScheduleLocalTime.parse(argument("time")) else {
                throw ScheduleError.invalid("I couldn't read the time \"\(argument("time"))\"; use 24-hour HH:mm.")
            }
            explicitTime = parsed
        }
        let time = explicitTime ?? base?.time

        let kind: String
        switch repeatWord {
        case "": kind = !minutes.isEmpty || !argument("date").isEmpty ? "once" : baseKind(base) ?? "once"
        case "once", "one-time", "onetime", "none", "no", "never", "single": kind = "once"
        case "daily", "every day", "everyday", "day": kind = "daily"
        case "weekdays", "weekday", "every weekday", "workdays": kind = "weekdays"
        case "weekly", "every week", "week": kind = "weekly"
        case "monthly", "every month", "month": kind = "monthly"
        default:
            throw ScheduleError.invalid(RecurrenceRule.inexpressibleReason(in: "every other")!)
        }

        switch kind {
        case "once":
            if !minutes.isEmpty {
                guard let count = Int(minutes), (1...(60 * 24 * 60)).contains(count) else {
                    throw ScheduleError.invalid("inMinutes must be a whole number of minutes.")
                }
                // Whole minutes: macOS triggers carry no seconds, so the stored slot must not either.
                let seconds = now.timeIntervalSince1970 + Double(count * 60)
                let instant = Date(timeIntervalSince1970: (seconds / 60).rounded(.up) * 60)
                let parts = calendar.dateComponents([.hour, .minute], from: instant)
                return ScheduleWhen(repeatRule: .once(instant),
                                    time: ScheduleLocalTime(hour: parts.hour ?? 0, minute: parts.minute ?? 0),
                                    timeZone: calendar.timeZone.identifier)
            }
            guard let time else { throw ScheduleError.invalid("A one-time reminder needs a time or inMinutes.") }
            let dayStart: Date
            let dateText = argument("date").lowercased()
            switch dateText {
            case "":
                if case .once(let previous)? = base?.repeatRule {
                    dayStart = calendar.startOfDay(for: previous)
                } else {
                    // The next time that clock time comes round: today, or tomorrow.
                    let today = calendar.startOfDay(for: now)
                    let candidate = occurrence(time, onDayStarting: today, calendar: calendar)
                    dayStart = (candidate.map { $0 > now } ?? false)
                        ? today
                        : calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: today) ?? today)
                }
            case "today":
                dayStart = calendar.startOfDay(for: now)
            case "tomorrow":
                dayStart = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: now) ?? now)
            default:
                guard let day = parseDay(dateText, calendar: calendar) else {
                    throw ScheduleError.invalid("I couldn't read the date \"\(argument("date"))\"; use YYYY-MM-DD.")
                }
                dayStart = day
            }
            guard let instant = occurrence(time, onDayStarting: dayStart, calendar: calendar) else {
                throw ScheduleError.invalid("That date and time don't exist.")
            }
            guard instant > now else { throw ScheduleError.invalid("That time has already passed.") }
            return ScheduleWhen(repeatRule: .once(instant), time: time, timeZone: calendar.timeZone.identifier)

        case "daily", "weekdays":
            guard let time else { throw ScheduleError.invalid("A repeating reminder needs a time.") }
            return ScheduleWhen(repeatRule: kind == "daily" ? .daily : .weekdays, time: time,
                                timeZone: calendar.timeZone.identifier)

        case "weekly":
            guard let time else { throw ScheduleError.invalid("A weekly reminder needs a time.") }
            var days: [ScheduleWeekday] = []
            let raw = argument("days")
            if raw.isEmpty, case .weekly(let previous)? = base?.repeatRule {
                days = previous
            } else {
                let words = raw.lowercased()
                    .replacingOccurrences(of: " and ", with: ",")
                    .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" || $0 == ";" })
                for word in words {
                    guard let day = ScheduleWeekday.parse(String(word)) else {
                        throw ScheduleError.invalid("I couldn't read the weekday \"\(word)\".")
                    }
                    if !days.contains(day) { days.append(day) }
                }
            }
            guard !days.isEmpty else { throw ScheduleError.invalid("A weekly reminder needs days, e.g. monday,thursday.") }
            return ScheduleWhen(repeatRule: .weekly(days.sorted()), time: time, timeZone: calendar.timeZone.identifier)

        default: // monthly
            guard let time else { throw ScheduleError.invalid("A monthly reminder needs a time.") }
            let raw = argument("day").lowercased()
            let day: Int
            if raw.isEmpty, case .monthly(let previous)? = base?.repeatRule {
                day = previous
            } else if raw == "last" || raw == "last day" {
                day = 31
            } else {
                guard let value = Int(raw.filter(\.isNumber)), (1...31).contains(value) else {
                    throw ScheduleError.invalid("A monthly reminder needs a day of the month from 1 to 31.")
                }
                day = value
            }
            return ScheduleWhen(repeatRule: .monthly(day: day), time: time, timeZone: calendar.timeZone.identifier)
        }
    }

    private static func baseKind(_ base: ScheduleWhen?) -> String? {
        switch base?.repeatRule {
        case .once?: "once"
        case .daily?: "daily"
        case .weekdays?: "weekdays"
        case .weekly?: "weekly"
        case .monthly?: "monthly"
        case nil: nil
        }
    }

    /// End of the named day in the zone, or `.some(nil)` for "none".
    static func parseEndsOn(_ raw: String, timeZone: TimeZone) throws -> Date?? {
        let text = raw.lowercased()
        if text.isEmpty { return nil }
        if ["none", "never", "no"].contains(text) { return .some(nil) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let day = parseDay(text, calendar: calendar),
              let next = calendar.date(byAdding: .day, value: 1, to: day) else {
            throw ScheduleError.invalid("I couldn't read the end date \"\(raw)\"; use YYYY-MM-DD.")
        }
        return .some(next.addingTimeInterval(-1))
    }

    private static func parseDay(_ text: String, calendar: Calendar) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]), (1...31).contains(parts[2]) else { return nil }
        let components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard calendar.date(from: components) != nil,
              let date = calendar.date(from: components),
              calendar.component(.day, from: date) == parts[2] else { return nil }
        return calendar.startOfDay(for: date)
    }

    private static func occurrence(_ time: ScheduleLocalTime, onDayStarting day: Date, calendar: Calendar) -> Date? {
        calendar.nextDate(
            after: day.addingTimeInterval(-1),
            matching: DateComponents(hour: time.hour, minute: time.minute, second: 0),
            matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward)
    }

    /// The id from `schedule.list` (full, or a unique prefix of at least four characters), or
    /// a title matched exactly. Never a fragment of a title: "up" must not delete "Stand up".
    @MainActor
    static func resolve(_ raw: String, in store: ScheduleStore) throws -> AgentSchedule {
        store.reload()
        let text = raw.trimmingCharacters(in: CharacterSet(charactersIn: " []")).lowercased()
        guard !text.isEmpty else { throw ScheduleError.notFound("an empty id") }
        if let uuid = UUID(uuidString: text), let found = store.schedule(id: uuid) { return found }
        if text.count >= 4 {
            let byID = store.schedules.filter { $0.id.uuidString.lowercased().hasPrefix(text) }
            if byID.count == 1 { return byID[0] }
            if byID.count > 1 { throw ScheduleError.ambiguous("\"\(raw)\"") }
        }
        let byTitle = store.schedules.filter { $0.title.lowercased() == text }
        if byTitle.count == 1 { return byTitle[0] }
        if byTitle.count > 1 { throw ScheduleError.ambiguous("\"\(raw)\"") }
        throw ScheduleError.notFound("\"\(raw)\"")
    }

    /// Same time rule and the same words, or the same title on the same rule.
    static func duplicate(of candidate: AgentSchedule, in schedules: [AgentSchedule]) -> AgentSchedule? {
        func normal(_ text: String) -> String {
            text.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        return schedules.first { existing in
            existing.kind == candidate.kind && existing.enabled
                && existing.when == candidate.when
                && (normal(existing.prompt) == normal(candidate.prompt)
                    || normal(existing.title) == normal(candidate.title))
        }
    }

    private static func firstNonEmpty(_ values: String...) -> String {
        values.first { !$0.isEmpty } ?? ""
    }

    private static func isNo(_ value: String) -> Bool {
        ["no", "false", "0", "never", "off"].contains(value.lowercased())
    }
}

/// Whether a `schedule.*` write may skip the permission card: the code running the turn, not
/// the model, shows the user agreed to it.
///
/// Reminders are lasting and spoken, so one written from an email, page or document would be
/// an attacker's message read aloud every morning. The checks, all of which must pass:
///
/// 1. The call comes from the user's own conversation (`MemoryProvenance`, bound by the tool
///    loop), and no tool other than memory or schedule returned output earlier in this turn.
/// 2. For `create` and `update`, what the user said this turn is a yes — the answer to the
///    restated sentence — and the title and text pass `MemoryGuard`: words from tool output
///    or earlier Agent replies that the user never said, or an injection pattern, fail.
///
/// A failed check is not a refusal: the write goes to the normal card.
enum ScheduleConfirmation {
    static func problem(toolID: String, arguments: [String: String], provenance: MemoryProvenance?) -> String? {
        guard ScheduleToolCatalogue.confirmableIDs.contains(toolID) else {
            return "\(toolID) always asks."
        }
        guard let provenance, provenance.origin == .userConversation else {
            return "not from the user's own conversation."
        }
        guard !provenance.readToolOutputThisTurn else {
            return "tool output was read earlier in this turn."
        }
        guard toolID == "schedule.create" || toolID == "schedule.update" else { return nil }
        guard isAffirmative(provenance.userText.first ?? "") else {
            return "the user has not said yes to a restated reminder this turn."
        }
        let written = ["title", "text", "prompt"]
            .compactMap { arguments[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for value in written {
            if let finding = MemoryGuard.scan(value) { return finding.reason }
            if let problem = MemoryGuard.provenanceProblem(value, provenance: provenance) {
                return "the reminder text is not the user's words (\(problem.reason))."
            }
        }
        return nil
    }

    private static let yesWords: Set<String> = [
        "yes", "yeah", "yep", "yup", "sure", "ok", "okay", "correct", "confirm", "confirmed",
        "exactly", "perfect", "absolutely", "definitely", "affirmative",
    ]

    private static let yesPhrases = ["go ahead", "do it", "sounds good", "that's it", "that works", "set it"]

    static func isAffirmative(_ text: String) -> Bool {
        let lowered = text.lowercased().replacingOccurrences(of: "’", with: "'")
        let words = lowered.split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
        guard !words.isEmpty else { return false }
        // "No", "don't", "wait" cancel it even next to a yes.
        let refusals: Set<String> = ["no", "nope", "don't", "not", "wait", "cancel", "stop", "wrong"]
        if words.contains(where: refusals.contains) { return false }
        return words.contains(where: yesWords.contains) || yesPhrases.contains { lowered.contains($0) }
    }
}

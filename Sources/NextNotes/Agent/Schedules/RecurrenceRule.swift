import Foundation

/// Occurrences of a `ScheduleWhen`, computed with `Calendar` in the schedule's own zone.
///
/// No cron. A 4B model writes wrong cron, and cron has a trap even for people: with both
/// day-of-month and day-of-week set it matches *either*. The model fills structured fields;
/// this turns them into instants. The time of day is found with
/// `Calendar.nextDate(after:matching:matchingPolicy:)` on the candidate day, which is what
/// gets daylight saving right: a 02:30 that does not exist on the spring-forward day becomes
/// the next existing time, and a 01:30 that happens twice in autumn fires on the first.
struct RecurrenceRule: Sendable {
    let when: ScheduleWhen
    let calendar: Calendar

    init?(_ when: ScheduleWhen) {
        guard let zone = TimeZone(identifier: when.timeZone) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        self.when = when
        self.calendar = calendar
    }

    /// The first occurrence strictly after `date`, or nil when there is none (a one-shot
    /// whose moment has passed).
    func next(after date: Date) -> Date? {
        switch when.repeatRule {
        case .once(let instant):
            return instant > date ? instant : nil
        case .daily:
            return nextMatchingDay(after: date, limit: 3) { _ in true }
        case .weekdays:
            return nextMatchingDay(after: date, limit: 8) { (2...6).contains($0) }
        case .weekly(let days):
            let wanted = Set(days.map(\.rawValue))
            guard !wanted.isEmpty else { return nil }
            return nextMatchingDay(after: date, limit: 9) { wanted.contains($0) }
        case .monthly(let day):
            return nextMonthly(day: day, after: date)
        }
    }

    /// Occurrences in `(start, end]`, capped so a schedule last seen a year ago costs nothing.
    func occurrences(after start: Date, through end: Date, cap: Int = 500) -> [Date] {
        var found: [Date] = []
        var cursor = start
        while found.count < cap, let next = next(after: cursor), next <= end {
            found.append(next)
            cursor = next
        }
        return found
    }

    /// The nominal gap between occurrences, for the grace window. Zero for a one-shot.
    var nominalInterval: TimeInterval {
        let day: TimeInterval = 86_400
        switch when.repeatRule {
        case .once: return 0
        case .daily, .weekdays: return day
        case .weekly(let days):
            let sorted = Set(days.map(\.rawValue)).sorted()
            guard sorted.count > 1 else { return 7 * day }
            var gaps = zip(sorted, sorted.dropFirst()).map { $1 - $0 }
            gaps.append(sorted[0] + 7 - sorted[sorted.count - 1])
            return TimeInterval(gaps.min() ?? 7) * day
        case .monthly: return 28 * day
        }
    }

    /// `min(max(interval / 2, 2 min), 2 h)`: a slot found this late still runs, late.
    static func grace(forInterval interval: TimeInterval) -> TimeInterval {
        min(max(interval / 2, 2 * 60), 2 * 60 * 60)
    }

    var grace: TimeInterval { Self.grace(forInterval: nominalInterval) }

    // MARK: - Days

    /// The wall-clock time on the day that starts at `dayStart`, DST-correct.
    private func occurrence(onDayStarting dayStart: Date) -> Date? {
        calendar.nextDate(
            after: dayStart.addingTimeInterval(-1),
            matching: DateComponents(hour: when.time.hour, minute: when.time.minute, second: 0),
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        )
    }

    private func nextMatchingDay(after date: Date, limit: Int, matches: (Int) -> Bool) -> Date? {
        var day = calendar.startOfDay(for: date)
        for _ in 0..<limit {
            if matches(calendar.component(.weekday, from: day)),
               let candidate = occurrence(onDayStarting: day), candidate > date {
                return candidate
            }
            guard let following = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = calendar.startOfDay(for: following)
        }
        return nil
    }

    private func nextMonthly(day wanted: Int, after date: Date) -> Date? {
        guard (1...31).contains(wanted) else { return nil }
        let start = calendar.dateComponents([.year, .month], from: date)
        guard let firstOfMonth = calendar.date(from: start) else { return nil }
        for offset in 0..<14 {
            guard let month = calendar.date(byAdding: .month, value: offset, to: firstOfMonth),
                  let days = calendar.range(of: .day, in: .month, for: month) else { continue }
            var components = calendar.dateComponents([.year, .month], from: month)
            components.day = min(wanted, days.count)
            guard let dayDate = calendar.date(from: components),
                  let candidate = occurrence(onDayStarting: calendar.startOfDay(for: dayDate)) else { continue }
            if candidate > date { return candidate }
        }
        return nil
    }

    // MARK: - Words

    /// "every weekday at 09:00", "on Tuesday 16 September at 17:00". The time zone is named
    /// only when it is not the Mac's current one.
    func describe(currentZone: TimeZone = .current) -> String {
        let time = when.time.formatted
        let zoneSuffix = when.timeZone == currentZone.identifier ? "" : " (\(when.timeZone))"
        switch when.repeatRule {
        case .once(let instant):
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEEE d MMMM yyyy"
            return "on \(formatter.string(from: instant)) at \(time)\(zoneSuffix)"
        case .daily:
            return "every day at \(time)\(zoneSuffix)"
        case .weekdays:
            return "every weekday at \(time)\(zoneSuffix)"
        case .weekly(let days):
            let names = Set(days).sorted().map(\.name)
            let list = names.count <= 1 ? names.joined()
                : names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
            return "every \(list) at \(time)\(zoneSuffix)"
        case .monthly(let day):
            let dayText = day >= 31 ? "the last day" : "day \(day)" + (day > 28 ? " (or the last day)" : "")
            return "on \(dayText) of every month at \(time)\(zoneSuffix)"
        }
    }

    /// Why a sentence asks for something the fields cannot express, or nil. Refused in
    /// words rather than approximated: "every other Tuesday" is not "every Tuesday".
    static func inexpressibleReason(in sentence: String) -> String? {
        let text = sentence.lowercased()
        let patterns = [
            #"\bevery\s+other\b"#, #"\bevery\s+(second|third|fourth|2nd|3rd|4th)\b"#,
            #"\bevery\s+\d+\s*(minutes?|hours?|days?|weeks?|months?|years?)\b"#,
            #"\b(bi-?weekly|fortnight(ly)?|every\s+few)\b"#,
            #"\b(on\s+)?alternate\s+(days?|weeks?|months?|mondays?|tuesdays?|wednesdays?|thursdays?|fridays?|saturdays?|sundays?)\b"#,
            #"\bevery\s+(hour|minute)\b"#, #"\bhourly\b"#,
            #"\b(yearly|annually|every\s+year)\b"#,
            // "the first Monday of the month", "every last Friday" — not "last Monday's call".
            #"\b(every|each)\s+(first|second|third|fourth|last)\s+(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b"#,
            #"\b(first|second|third|fourth|last)\s+(monday|tuesday|wednesday|thursday|friday|saturday|sunday)s?\s+(of|in)\s+(the|every|each|a)\s+month\b"#,
        ]
        for pattern in patterns where text.range(of: pattern, options: .regularExpression) != nil {
            return "I can only repeat once, daily, on weekdays, weekly on chosen days, or monthly on one "
                + "day of the month — not a rule like that. Pick the closest of those, or set separate reminders."
        }
        return nil
    }
}

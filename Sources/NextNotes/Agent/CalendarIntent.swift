import Foundation

/// A calendar ask, parsed from the utterance. Same shape as `MailIntent` and
/// `ComputerIntent` — one table, no model.
enum CalendarIntent: Equatable {
    case agenda(date: String)

    var date: String {
        switch self {
        case .agenda(let date): date
        }
    }

    static func parse(_ raw: String) -> CalendarIntent? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let lowered = text.lowercased()
        guard isCalendarAsk(lowered) else { return nil }
        return .agenda(date: agendaDate(from: lowered))
    }

    /// “What’s on” alone used to steal mail (“what’s on my email”) and send it to
    /// `get_agenda`. A calendar ask names the calendar, a day, or a meeting.
    static func isCalendarAsk(_ lowered: String) -> Bool {
        if lowered.contains("calendar") || lowered.contains("agenda")
            || lowered.contains("schedule") {
            return true
        }
        if lowered.contains("tomorrow") && lowered.contains("meet") { return true }
        let askedWhatsOn = lowered.contains("what’s on") || lowered.contains("whats on")
            || lowered.contains("what is on")
        guard askedWhatsOn else { return false }
        return dayWords.contains { lowered.contains($0) }
    }

    static func agendaDate(from lowered: String) -> String {
        let calendar = Calendar.current
        let day: Date
        if lowered.contains("tomorrow") {
            day = calendar.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        } else {
            day = Date()
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: day)
    }

    private static let dayWords = [
        "today", "tomorrow", "calendar", "agenda", "schedule",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
    ]
}

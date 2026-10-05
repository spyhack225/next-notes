import EventKit
import Foundation

/// One calendar the Mac has, reduced to what a decision needs.
struct MacCalendarInfo: Sendable, Equatable {
    let id: String
    let title: String
    /// The account it lives under (`iCloud`, `Google`, …), as the Mac names it.
    let sourceTitle: String
    let isWritable: Bool
    /// Whether this looks like a calendar of a Google account. See `MacGoogle.looksLikeGoogle`.
    let looksGoogle: Bool
}

struct MacStoredEvent: Sendable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let notes: String
    let calendarID: String
}

enum MacCalendarAccess: Sendable, Equatable { case granted, notAsked, denied }

/// What the agent needs from the Mac's calendars, behind a seam so a self-test can answer it
/// with no calendar database and no grant. The live one is `EventKitMacCalendar`.
protocol MacCalendarStore: Sendable {
    func access() async -> MacCalendarAccess
    /// Asks the system once. A second ask after a refusal does nothing; the person is sent to
    /// System Settings by the caller.
    func requestAccess() async -> Bool
    func calendars() async -> [MacCalendarInfo]
    /// Every calendar the Mac has, not only Google's: a clash with a work or family calendar is
    /// still a clash.
    func agenda(from: Date, to: Date) async -> [MacAgendaItem]
    func events(calendarID: String, from: Date, to: Date) async -> [MacStoredEvent]
    func save(_ draft: MacEventDraft, calendarID: String) async throws -> String
    func event(id: String) async -> MacStoredEvent?
}

enum MacGoogle {
    /// Whether a calendar source is a Google account.
    ///
    /// EventKit gives no account type for "Google": a Google account added in Internet Accounts
    /// is a CalDAV source named after the account, `Google` unless the person renamed it. So the
    /// rule is the name, plus the one other thing a Google source shows — its calendars carry the
    /// address of a Google account. **Heuristic, not measured on a real account**; a wrong "no"
    /// refuses to create an event (safe), a wrong "yes" would put one on a calendar that is not
    /// Google's, which is why creating also asks for a writable calendar and says where it went.
    static func looksLikeGoogle(sourceTitle: String, isCalDAV: Bool, calendarTitles: [String]) -> Bool {
        let title = sourceTitle.lowercased()
        if title.contains("google") || title.contains("gmail") { return true }
        guard isCalDAV else { return false }
        return calendarTitles.contains {
            let lower = $0.lowercased()
            return lower.hasSuffix("@gmail.com") || lower.hasSuffix("@googlemail.com")
        }
    }

    /// The calendar a new event goes on: a writable Google calendar, the account's own (titled
    /// with its address) before a secondary one. Nil when there is none — and then nothing is
    /// created.
    static func creationTarget(in calendars: [MacCalendarInfo]) -> MacCalendarInfo? {
        let candidates = calendars.filter { $0.looksGoogle && $0.isWritable }
        return candidates.first { $0.title.contains("@") } ?? candidates.first
    }
}

/// The Mac's calendars, through EventKit.
///
/// An actor because `EKEventStore` is a live connection that two callers must not query at
/// once, and because `EKEvent` is a reference type that has no business leaving here.
actor EventKitMacCalendar: MacCalendarStore {
    static let shared = EventKitMacCalendar()
    private let store = EKEventStore()

    func access() -> MacCalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .granted
        case .notDetermined: .notAsked
        default: .denied
        }
    }

    func requestAccess() async -> Bool {
        await Permissions.requestCalendar()
    }

    func calendars() -> [MacCalendarInfo] {
        guard access() == .granted else { return [] }
        let all = store.calendars(for: .event)
        let titlesBySource = Dictionary(grouping: all, by: { $0.source?.sourceIdentifier ?? "" }).mapValues { $0.map(\.title) }
        return all.map { calendar in
            let source = calendar.source
            return MacCalendarInfo(
                id: calendar.calendarIdentifier,
                title: calendar.title,
                sourceTitle: source?.title ?? "",
                isWritable: calendar.allowsContentModifications,
                looksGoogle: MacGoogle.looksLikeGoogle(
                    sourceTitle: source?.title ?? "",
                    isCalDAV: source?.sourceType == .calDAV,
                    calendarTitles: titlesBySource[source?.sourceIdentifier ?? ""] ?? []))
        }
    }

    func agenda(from: Date, to: Date) -> [MacAgendaItem] {
        guard access() == .granted else { return [] }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        return store.events(matching: predicate)
            .compactMap { event -> MacAgendaItem? in
                guard let start = event.startDate, let end = event.endDate else { return nil }
                // A declined invitation is not on this person's day.
                if (event.attendees ?? []).contains(where: { $0.isCurrentUser && $0.participantStatus == .declined }) { return nil }
                return MacAgendaItem(title: event.title ?? "(no title)", start: start, end: end,
                                     isAllDay: event.isAllDay, calendar: event.calendar?.title ?? "Calendar")
            }
            .sorted { $0.start < $1.start }
    }

    func events(calendarID: String, from: Date, to: Date) -> [MacStoredEvent] {
        guard access() == .granted, let calendar = store.calendar(withIdentifier: calendarID) else { return [] }
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: [calendar])
        return store.events(matching: predicate).compactMap(Self.stored)
    }

    func save(_ draft: MacEventDraft, calendarID: String) throws -> String {
        guard let calendar = store.calendar(withIdentifier: calendarID) else { throw MacWorkspaceError.noGoogleCalendar }
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = draft.title
        event.startDate = draft.start
        event.endDate = draft.end
        if !draft.notes.isEmpty { event.notes = draft.notes }
        try store.save(event, span: .thisEvent, commit: true)
        return event.eventIdentifier ?? ""
    }

    func event(id: String) -> MacStoredEvent? {
        guard !id.isEmpty, let event = store.event(withIdentifier: id) else { return nil }
        return Self.stored(event)
    }

    private static func stored(_ event: EKEvent) -> MacStoredEvent? {
        guard let start = event.startDate, let end = event.endDate else { return nil }
        return MacStoredEvent(id: event.eventIdentifier ?? "", title: event.title ?? "", start: start, end: end,
                              notes: event.notes ?? "", calendarID: event.calendar?.calendarIdentifier ?? "")
    }
}

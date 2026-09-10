import Foundation

/// A single invented meeting, ninety seconds out.
///
/// The whole armed → notification → recording → done path is otherwise only reachable by
/// waiting for a real meeting on a real account, which makes every change to the scheduler
/// a twenty-minute experiment. `--fake-calendar` replaces every provider with this one, so
/// the flow can be watched end to end in under three minutes with nothing configured.
///
/// It replaces rather than joins the real providers on purpose: a test run must never
/// arm a recording of an actual meeting.
struct FakeCalendarProvider: CalendarProvider, Sendable {
    nonisolated var id: CalendarProviderID { .fake }

    /// Whether the process was launched with the flag.
    static var isEnabled: Bool {
        CommandLine.arguments.dropFirst().contains("--fake-calendar")
    }

    static let leadTime: TimeInterval = 90
    static let duration: TimeInterval = 300

    /// Fixed at construction. Recomputing it per refresh would move the start time forward
    /// every five minutes and the meeting would never actually begin.
    let start: Date
    let end: Date

    init(now: Date = Date()) {
        start = now.addingTimeInterval(Self.leadTime)
        end = start.addingTimeInterval(Self.duration)
    }

    func authorizationState() -> CalendarAuthorizationState { .authorized }

    @discardableResult
    func authorize() async -> CalendarAuthorizationState { .authorized }

    func events(from: Date, to: Date) async -> [MeetingEvent] {
        let event = MeetingEvent(
            id: "fake-meeting",
            providerID: .fake,
            title: "Fake meeting (--fake-calendar)",
            start: start,
            end: end,
            attendees: ["Test Attendee"],
            isOrganizerOrSelfAccepted: true,
            conferenceURL: URL(string: "https://meet.google.com/fake-test-room"),
            calendarName: "Test calendar",
            isAllDay: false
        )
        // Still range-filtered: the scheduler asks for a window, and an event that ignored
        // it would behave differently from every real provider.
        guard event.end > from, event.start < to else { return [] }
        return [event]
    }
}

import EventKit
import Foundation

/// The Mac's own calendars, through EventKit.
///
/// An actor because `EKEventStore` is a live connection to the calendar database that two
/// concurrent refreshes must not query at once, and because everything it returns
/// (`EKEvent`, `EKParticipant`) is a reference type that has no business leaving here —
/// only value-typed `MeetingEvent`s cross the boundary.
actor EventKitCalendarProvider: CalendarProvider {
    nonisolated var id: CalendarProviderID { .eventKit }

    /// One store for the life of the app. Creating one per refresh works, but each new
    /// store re-reads the whole calendar database and the change notification is posted
    /// per store, so a fresh one would never report a change.
    private let store = EKEventStore()

    func authorizationState() -> CalendarAuthorizationState {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .authorized
        case .notDetermined: .needsAuthorization
        // Write-only is what an app gets when it asks to add events but not read them.
        // Speechify only ever reads, so it is as useless here as an outright refusal.
        case .denied, .restricted, .writeOnly: .denied
        @unknown default: .denied
        }
    }

    @discardableResult
    func authorize() async -> CalendarAuthorizationState {
        if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
            do {
                _ = try await store.requestFullAccessToEvents()
            } catch {
                Log.calendar.error("EventKit access request failed: \(error.localizedDescription, privacy: .public)")
                return .failed(error.localizedDescription)
            }
        }
        return authorizationState()
    }

    func events(from: Date, to: Date) async throws -> [MeetingEvent] {
        guard authorizationState().isAuthorized else { return [] }

        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        return store.events(matching: predicate).compactMap { Self.meetingEvent(from: $0) }
    }

    // MARK: - Mapping

    private static func meetingEvent(from event: EKEvent) -> MeetingEvent? {
        guard let start = event.startDate, let end = event.endDate else { return nil }
        // An occurrence identifier distinguishes today's stand-up from tomorrow's; the
        // event identifier alone is the same for every occurrence of a recurring series,
        // so overrides and "already recorded" checks would apply to all of them at once.
        let identifier = event.calendarItemExternalIdentifier
            .map { "\($0)#\(Int(start.timeIntervalSince1970))" }
            ?? event.eventIdentifier
            ?? "\(event.title ?? "event")#\(Int(start.timeIntervalSince1970))"

        let participants = event.attendees ?? []
        // A declined invitation is not a meeting the user is in. Dropped here rather than
        // in the scheduler so it never reaches the Upcoming list either.
        if participants.contains(where: { $0.isCurrentUser && $0.participantStatus == .declined }) {
            return nil
        }

        let others = participants
            .filter { !$0.isCurrentUser }
            .compactMap { Self.displayName(of: $0) }

        let organizerIsUser = event.organizer?.isCurrentUser ?? true
        let selfAccepted = participants.first { $0.isCurrentUser }
            .map { $0.participantStatus != .declined } ?? true

        return MeetingEvent(
            id: identifier,
            providerID: .eventKit,
            title: event.title ?? "Untitled",
            start: start,
            end: end,
            attendees: others,
            isOrganizerOrSelfAccepted: organizerIsUser || selfAccepted,
            conferenceURL: conferenceURL(for: event),
            calendarName: event.calendar?.title ?? "Calendar",
            isAllDay: event.isAllDay
        )
    }

    /// macOS 12 gave `EKEvent` a real conferencing field, but only Apple's own integrations
    /// populate it — every third-party invitation still hides the link in a text field.
    private static func conferenceURL(for event: EKEvent) -> URL? {
        if let url = event.url, ConferenceURLDetector.isConference(url) { return url }
        return ConferenceURLDetector.detect(in: [
            event.location,
            event.notes,
            event.url?.absoluteString,
        ])
    }

    /// A participant's name, or the address behind it. `EKParticipant.url` is a `mailto:`
    /// URL, whose address is the whole string after the scheme rather than a host.
    private static func displayName(of participant: EKParticipant) -> String? {
        if let name = participant.name, !name.isEmpty { return name }
        let address = participant.url.absoluteString
            .replacingOccurrences(of: "mailto:", with: "")
        return address.isEmpty ? nil : address
    }
}

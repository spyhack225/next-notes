import Foundation

/// Where a calendar entry came from.
///
/// The raw value is what `Meeting.providerID` stores, so it is part of the on-disk format
/// and must not be renamed.
enum CalendarProviderID: String, Codable, Sendable, CaseIterable, Identifiable {
    case eventKit
    case google
    /// Only ever present when the app was launched with `--fake-calendar`.
    case fake

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .eventKit: "Apple Calendar"
        case .google: "Google Calendar"
        case .fake: "Test calendar"
        }
    }
}

/// One calendar entry, reduced to the parts that decide whether it is worth recording.
///
/// Deliberately not an `EKEvent` or a Google DTO: the scheduler compares entries from two
/// providers against each other, and it can only do that if both arrive in the same shape.
struct MeetingEvent: Identifiable, Sendable, Hashable {
    /// The provider's own identifier for this occurrence.
    let id: String
    let providerID: CalendarProviderID
    let title: String
    let start: Date
    let end: Date
    /// Everyone invited except the user. Empty means a solo block.
    let attendees: [String]
    /// The user organizes it, or has accepted it. A meeting the user only tentatively
    /// holds a slot for is still recorded; one they declined never is.
    let isOrganizerOrSelfAccepted: Bool
    let conferenceURL: URL?
    let calendarName: String
    let isAllDay: Bool

    /// The key `Settings.meetingAutoRecordOverrides` stores an answer under.
    ///
    /// Provider-qualified because two accounts can hand out the same opaque event id, and
    /// a shared id would silently apply one calendar's "never record this" to another's.
    var overrideKey: String { "\(providerID.rawValue):\(id)" }

    /// What dedupe matches on: the same meeting seen through two accounts has the same
    /// title and the same start minute, but rarely the same id.
    var identityKey: String {
        let title = self.title
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let minute = (start.timeIntervalSince1970 / 60).rounded()
        return "\(title)@\(Int(minute))"
    }
}

/// How much of a provider is usable right now.
enum CalendarAuthorizationState: Sendable, Equatable {
    /// Switched off in Settings, or missing the configuration it needs.
    case disabled(String)
    /// Switched on, never authorized. The Connect / Grant button applies here.
    case needsAuthorization
    case authorized
    /// Refused, and only System Settings or the provider's own account page can change it.
    case denied
    case failed(String)

    var isAuthorized: Bool { self == .authorized }

    var displayName: String {
        switch self {
        case .disabled: "Off"
        case .needsAuthorization: "Not connected"
        case .authorized: "Connected"
        case .denied: "Denied"
        case .failed: "Error"
        }
    }

    /// The sentence under the row, when there is one worth reading.
    var detail: String? {
        switch self {
        case .disabled(let reason): reason
        case .failed(let message): message
        case .needsAuthorization, .authorized, .denied: nil
        }
    }
}

/// One source of meetings.
///
/// Both implementations are actors: EventKit's store and the Google token refresh both
/// have state that two refreshes must not touch at once, and an actor is the cheapest way
/// to say so. Every requirement is `async` so an actor can satisfy it.
protocol CalendarProvider: Sendable {
    nonisolated var id: CalendarProviderID { get }
    func authorizationState() async -> CalendarAuthorizationState
    /// Asks for whatever this provider needs, showing a system prompt or a browser.
    @discardableResult
    func authorize() async -> CalendarAuthorizationState
    func events(from: Date, to: Date) async throws -> [MeetingEvent]
}

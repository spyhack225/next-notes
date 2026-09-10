import Foundation

// The wire shapes of the two Google endpoints this app talks to. Only the fields that are
// actually read are declared: Google returns dozens more per event, and decoding them
// would turn every future field addition into a decode failure.

/// `POST https://oauth2.googleapis.com/token` — the one snake_case payload here.
struct GoogleTokenResponse: Decodable, Sendable {
    let accessToken: String
    let expiresIn: Int
    /// Only present on the first exchange, and only when `access_type=offline` was asked
    /// for. A refresh never returns a new one, which is why the stored token is kept.
    let refreshToken: String?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
    }
}

/// The error body Google returns with a 4xx. Worth decoding: "invalid_grant" is the
/// difference between "try again" and "the user revoked us, sign in again".
struct GoogleErrorResponse: Decodable, Sendable {
    let error: String?
    let errorDescription: String?

    private enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

/// `GET /calendar/v3/users/me/calendarList`
struct GoogleCalendarList: Decodable, Sendable {
    let items: [GoogleCalendarListEntry]?
}

struct GoogleCalendarListEntry: Decodable, Sendable, Identifiable, Hashable {
    let id: String
    let summary: String?
    /// The account's own calendar. Shown first, because it is the one meetings land in.
    let primary: Bool?
    /// Whether the user has this calendar ticked in Google's own UI.
    let selected: Bool?

    var displayName: String { summary ?? id }
}

/// `GET /calendar/v3/calendars/{id}/events`
struct GoogleEventList: Decodable, Sendable {
    let items: [GoogleEvent]?
}

struct GoogleEvent: Decodable, Sendable {
    let id: String
    let status: String?
    let summary: String?
    let description: String?
    let location: String?
    let htmlLink: String?
    /// The legacy Meet link. Still populated for events created by older clients.
    let hangoutLink: String?
    let start: GoogleEventDateTime?
    let end: GoogleEventDateTime?
    let attendees: [GoogleAttendee]?
    let organizer: GoogleAttendee?
    let conferenceData: GoogleConferenceData?
}

/// Google sends either `dateTime` (a timed event) or `date` (an all-day one), never both.
/// Which one arrived is how all-day events are recognised.
struct GoogleEventDateTime: Decodable, Sendable {
    let dateTime: Date?
    let date: String?

    var isAllDay: Bool { dateTime == nil && date != nil }

    /// The instant this edge of the event falls on. All-day dates carry no time zone, so
    /// they are read as midnight local — which is where the calendar UI draws them.
    func resolved(calendar: Foundation.Calendar = .current) -> Date? {
        if let dateTime { return dateTime }
        guard let date else { return nil }
        var formatter = Date.ISO8601FormatStyle()
        formatter.timeZone = calendar.timeZone
        return try? formatter.year().month().day().parse(date)
    }
}

struct GoogleAttendee: Decodable, Sendable {
    let email: String?
    let displayName: String?
    /// `true` on exactly one attendee: the authenticated user.
    ///
    /// Google calls this field `self`, which Swift cannot expose as a property — `x.self`
    /// is the identity expression, and a backtick-escaped member is not reachable through
    /// it. Renamed here and mapped back by `CodingKeys`.
    let isSelf: Bool?
    let organizer: Bool?
    let responseStatus: String?

    var name: String? {
        if let displayName, !displayName.isEmpty { return displayName }
        return email
    }

    private enum CodingKeys: String, CodingKey {
        case email
        case displayName
        case isSelf = "self"
        case organizer
        case responseStatus
    }
}

struct GoogleConferenceData: Decodable, Sendable {
    let entryPoints: [GoogleConferenceEntryPoint]?
}

struct GoogleConferenceEntryPoint: Decodable, Sendable {
    /// "video", "phone", "sip" or "more". Only video is a link worth joining.
    let entryPointType: String?
    let uri: String?
}

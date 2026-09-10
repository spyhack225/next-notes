import Foundation

/// Google Calendar over its HTTP API.
///
/// An actor because the access token is shared mutable state: two refreshes starting at
/// once would each notice the token has expired and each spend a round trip replacing it,
/// and the loser would overwrite the winner's fresher token.
///
/// Nothing here reads `Settings` directly — it is `@MainActor`, and an actor that awaited
/// the main actor in the middle of a network call would serialise the UI behind Google.
/// `CalendarService` pushes the configuration in instead.
actor GoogleCalendarProvider: CalendarProvider {
    nonisolated var id: CalendarProviderID { .google }

    private var clientID = ""
    private var clientSecret = ""
    private var calendarIDs: [String] = []

    private var accessToken: String?
    private var accessTokenExpiry = Date.distantPast

    /// Applied before every refresh by `CalendarService`.
    func configure(clientID: String, clientSecret: String, calendarIDs: [String]) {
        if clientID != self.clientID || clientSecret != self.clientSecret {
            // A different client is a different grant. Holding on to the old access token
            // would keep the previous account's calendars appearing after a switch.
            accessToken = nil
            accessTokenExpiry = .distantPast
        }
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.calendarIDs = calendarIDs
    }

    func authorizationState() -> CalendarAuthorizationState {
        guard !clientID.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .disabled("Paste a Google Cloud OAuth client ID of type “Desktop app”.")
        }
        return GoogleTokenStore.hasRefreshToken ? .authorized : .needsAuthorization
    }

    @discardableResult
    func authorize() async -> CalendarAuthorizationState {
        do {
            _ = try await GoogleOAuthClient.signIn(clientID: clientID, clientSecret: clientSecret)
            accessToken = nil
            accessTokenExpiry = .distantPast
            Log.calendar.info("Google Calendar connected")
            return .authorized
        } catch {
            Log.calendar.error("Google sign-in failed: \(error.localizedDescription, privacy: .public)")
            return .failed(error.localizedDescription)
        }
    }

    func signOut() {
        GoogleTokenStore.clear()
        accessToken = nil
        accessTokenExpiry = .distantPast
    }

    /// The calendars on the account, for the checklist in Settings.
    func calendars() async throws -> [GoogleCalendarListEntry] {
        let list: GoogleCalendarList = try await get(
            "https://www.googleapis.com/calendar/v3/users/me/calendarList"
        )
        // Primary first, then alphabetical: the account's own calendar is the one that
        // matters, and everything else is a shared calendar the user recognises by name.
        return (list.items ?? []).sorted { left, right in
            if (left.primary ?? false) != (right.primary ?? false) { return left.primary ?? false }
            return left.displayName.localizedCaseInsensitiveCompare(right.displayName) == .orderedAscending
        }
    }

    func events(from: Date, to: Date) async throws -> [MeetingEvent] {
        guard authorizationState().isAuthorized else { return [] }

        let ids: [String]
        if calendarIDs.isEmpty {
            // No explicit choice means "whatever Google itself shows", which is what
            // `selected` records — a calendar the user has unticked there is one they have
            // already said they don't want to see.
            ids = try await namedCalendars()
                .filter { $0.selected ?? ($0.primary ?? false) }
                .map(\.id)
        } else {
            ids = calendarIDs
            // Names are only needed to label the rows, so a failure here costs a nicer
            // string, never the events themselves.
            _ = try? await namedCalendars()
        }

        // Named `collected` rather than `events`: a local of that name shadows this very
        // method, and the per-calendar call below stops resolving.
        var collected: [MeetingEvent] = []
        for calendarID in ids {
            do {
                collected.append(contentsOf: try await events(
                    in: calendarID,
                    named: calendarNames[calendarID] ?? calendarID,
                    from: from,
                    to: to
                ))
            } catch {
                // One inaccessible calendar — a shared one whose access was revoked — must
                // not cost the user every other calendar on the account.
                Log.calendar.error("""
                    Google calendar \(calendarID, privacy: .public) failed: \
                    \(error.localizedDescription)
                    """)
            }
        }
        return collected
    }

    // MARK: - Requests

    /// Display names, kept from the last `calendars()` call. A calendar ID is usually an
    /// email address, and "alex@example.com" is a worse row label than "Work".
    private var calendarNames: [String: String] = [:]

    private func namedCalendars() async throws -> [GoogleCalendarListEntry] {
        let entries = try await calendars()
        calendarNames = Dictionary(
            entries.map { ($0.id, $0.displayName) },
            uniquingKeysWith: { first, _ in first }
        )
        return entries
    }

    private func events(
        in calendarID: String,
        named calendarName: String,
        from: Date,
        to: Date
    ) async throws -> [MeetingEvent] {
        let encodedID = calendarID.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) ?? calendarID
        var components = URLComponents(
            string: "https://www.googleapis.com/calendar/v3/calendars/\(encodedID)/events"
        )
        let formatter = ISO8601DateFormatter()
        components?.queryItems = [
            URLQueryItem(name: "timeMin", value: formatter.string(from: from)),
            URLQueryItem(name: "timeMax", value: formatter.string(from: to)),
            // Recurring series are expanded into occurrences server-side; without this a
            // weekly stand-up arrives as one entry with a recurrence rule to interpret.
            URLQueryItem(name: "singleEvents", value: "true"),
            URLQueryItem(name: "orderBy", value: "startTime"),
            URLQueryItem(name: "maxResults", value: "\(Self.maxEventsPerCalendar)"),
        ]
        guard let url = components?.url else { throw GoogleCalendarError.badAuthorizationURL }

        let list: GoogleEventList = try await get(url)
        return (list.items ?? []).compactMap {
            Self.meetingEvent(from: $0, calendarName: calendarName)
        }
    }

    private func get<Value: Decodable>(_ endpoint: String) async throws -> Value {
        guard let url = URL(string: endpoint) else { throw GoogleCalendarError.badAuthorizationURL }
        return try await get(url)
    }

    /// A 401 means "this access token is bad", never "the grant is gone".
    ///
    /// A token can be invalidated on its own — a clock that drifted, a lifetime shorter
    /// than the `expires_in` that came with it, one session revoked out of several — and
    /// signing out over that would throw away a refresh token that still works and demand
    /// a whole browser round of consent. So the token is dropped and the request retried
    /// once; only a second 401, with a token minted seconds earlier, is a dead grant.
    /// Genuine revocation is caught before this, at the refresh endpoint's `invalid_grant`.
    private func get<Value: Decodable>(_ url: URL) async throws -> Value {
        do {
            return try await fetch(url, discardingCachedToken: false)
        } catch GoogleCalendarError.accessTokenRejected {
            do {
                return try await fetch(url, discardingCachedToken: true)
            } catch GoogleCalendarError.accessTokenRejected {
                signOut()
                throw GoogleCalendarError.accessRevoked
            }
        }
    }

    private func fetch<Value: Decodable>(
        _ url: URL,
        discardingCachedToken: Bool
    ) async throws -> Value {
        if discardingCachedToken {
            accessToken = nil
            accessTokenExpiry = .distantPast
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(try await validAccessToken())", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if status == 401 { throw GoogleCalendarError.accessTokenRejected }
            let failure = try? JSONDecoder().decode(GoogleErrorResponse.self, from: data)
            throw GoogleCalendarError.requestFailed(
                status: status,
                reason: failure?.errorDescription ?? failure?.error ?? "HTTP \(status)"
            )
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Value.self, from: data)
    }

    /// The cached access token, refreshed when it is within a minute of expiring.
    ///
    /// The margin matters: a token that is valid when the request is built can expire in
    /// the time it takes to reach Google, and the failure looks like a revoked grant.
    private func validAccessToken() async throws -> String {
        if let accessToken, accessTokenExpiry > Date().addingTimeInterval(Self.expiryMargin) {
            return accessToken
        }
        guard let refreshToken = GoogleTokenStore.refreshToken else {
            throw GoogleCalendarError.notSignedIn
        }
        do {
            let token = try await GoogleOAuthClient.refresh(
                clientID: clientID,
                clientSecret: clientSecret,
                refreshToken: refreshToken
            )
            accessToken = token.accessToken
            accessTokenExpiry = Date().addingTimeInterval(TimeInterval(token.expiresIn))
            return token.accessToken
        } catch GoogleCalendarError.tokenRequestFailed(let status, _) where status == 400 {
            // "invalid_grant" is Google's way of saying the refresh token is dead: revoked,
            // expired after six months of disuse, or invalidated by a password change.
            signOut()
            throw GoogleCalendarError.accessRevoked
        }
    }

    // MARK: - Mapping

    private static let maxEventsPerCalendar = 100
    private static let expiryMargin: TimeInterval = 60

    private static func meetingEvent(from event: GoogleEvent, calendarName: String) -> MeetingEvent? {
        // Cancelled occurrences of a recurring series stay in the response as tombstones.
        guard event.status != "cancelled" else { return nil }
        guard let start = event.start?.resolved(), let end = event.end?.resolved() else { return nil }

        let attendees = event.attendees ?? []
        if attendees.contains(where: { ($0.isSelf ?? false) && $0.responseStatus == "declined" }) {
            return nil
        }

        let others = attendees.filter { !($0.isSelf ?? false) }.compactMap(\.name)
        // An event with no attendee list is one the user made for themselves, so absence
        // of an organizer flag means "yours" rather than "someone else's".
        let organizerIsUser = event.organizer?.isSelf ?? attendees.isEmpty
        let selfStatus = attendees.first { $0.isSelf ?? false }?.responseStatus
        let selfAccepted = selfStatus == nil || selfStatus != "declined"

        return MeetingEvent(
            id: event.id,
            providerID: .google,
            title: event.summary ?? "Untitled",
            start: start,
            end: end,
            attendees: others,
            isOrganizerOrSelfAccepted: organizerIsUser || selfAccepted,
            conferenceURL: conferenceURL(for: event),
            calendarName: calendarName,
            isAllDay: event.start?.isAllDay ?? false
        )
    }

    private static func conferenceURL(for event: GoogleEvent) -> URL? {
        let video = event.conferenceData?.entryPoints?
            .first { $0.entryPointType == "video" }?
            .uri
        if let video, let url = URL(string: video) { return url }
        if let hangout = event.hangoutLink, let url = URL(string: hangout) { return url }
        return ConferenceURLDetector.detect(in: [event.location, event.description])
    }
}

enum GoogleCalendarError: LocalizedError, Equatable {
    case noClientID
    case notSignedIn
    case accessRevoked
    /// One request's access token came back 401. Internal to the retry in `get`; it only
    /// reaches the user if a freshly minted token is rejected too, and then as `accessRevoked`.
    case accessTokenRejected
    case noRefreshToken
    case badAuthorizationURL
    case callbackListenerFailed
    case authorizationTimedOut
    case authorizationDenied(String)
    case stateMismatch
    case tokenRequestFailed(status: Int, reason: String)
    case requestFailed(status: Int, reason: String)

    var errorDescription: String? {
        switch self {
        case .noClientID:
            "Add a Google OAuth client ID in Settings ▸ Calendar first."
        case .notSignedIn:
            "Google Calendar isn't connected yet."
        case .accessRevoked:
            "Google revoked Speechify's access. Connect the account again."
        case .accessTokenRejected:
            "Google rejected the access token."
        case .noRefreshToken:
            "Google didn't return a refresh token. Remove Speechify from the account's third-party access list and connect again."
        case .badAuthorizationURL:
            "Couldn't build the Google request URL."
        case .callbackListenerFailed:
            "Couldn't listen for Google's redirect on this Mac."
        case .authorizationTimedOut:
            "The browser sign-in wasn't finished in time."
        case .authorizationDenied(let reason):
            "Google refused the sign-in: \(reason)."
        case .stateMismatch:
            "The sign-in response didn't match the request and was discarded."
        case .tokenRequestFailed(_, let reason):
            "Google wouldn't issue a token: \(reason)."
        case .requestFailed(_, let reason):
            "Google Calendar request failed: \(reason)."
        }
    }
}

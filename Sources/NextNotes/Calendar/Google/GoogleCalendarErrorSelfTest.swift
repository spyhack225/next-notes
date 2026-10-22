import Foundation
import os

/// Modifier of the existing calendar flag. Synthetic HTTP bodies enter the real
/// OAuth decoder, provider token path and CalendarService.refresh consumer.
enum GoogleCalendarErrorSelfTest {
    static var isRequested: Bool {
        SelfTest.requested == "--selftest-calendar"
            && CommandLine.arguments.contains("--calendar-google-errors")
            && !CommandLine.arguments.contains("--fake-calendar")
    }

    @MainActor static func run() async -> [String] {
        guard isRequested else { return ["exact isolated diagnostic admission refused"] }
        var failures: [String] = []
        func check(_ accepted: Bool, _ name: String) {
            if !accepted { failures.append(name) }
        }

        // All descriptions deliberately differ from their machine codes. The old
        // producer discarded the code and invalidated every HTTP 400 grant.
        for (name, status, code, shouldClear) in [
            ("other400", 400, "invalid_client", false),
            ("revoked400", 400, "invalid_grant", true),
            ("server500", 500, "invalid_grant", false),
            ("unknown400", 400, "", false),
        ] {
            let token = CalendarFixtureToken()
            let http = CalendarFixtureHTTP(tokenStatus: status, tokenCode: code)
            let provider = makeProvider(http: http, token: token)
            await provider.configure(clientID: "fixture-client", clientSecret: "", calendarIDs: [])
            let service = CalendarService(providersForTesting: [provider])
            await service.refresh()
            check(token.clearCount == (shouldClear ? 1 : 0), "\(name): exact grant invalidation")
            check(token.value == (shouldClear ? nil : "fixture-refresh-token"), "\(name): retained token")
            check(service.upcoming.isEmpty, "\(name): no fabricated event")
            let state = service.providerStates[.google]
            if shouldClear {
                check(state == .failed(GoogleCalendarError.accessRevoked.localizedDescription),
                      "\(name): revoked outcome reaches actual refresh consumer")
                check(await provider.authorizationState() == .needsAuthorization,
                      "\(name): revoked provider needs authorization")
            } else {
                check(state == .failed("Google wouldn't issue a token: fixture token failure."),
                      "\(name): original failure reaches actual refresh consumer")
                check(await provider.authorizationState() == .authorized,
                      "\(name): unrelated failure keeps grant")
            }
            let counts = await http.counts()
            check(counts.token == 1 && counts.events == 0 && counts.lists == 0 && counts.other == 0,
                  "\(name): one actual token request and no event/retry request")
            check(service.lastError != nil && !service.isRefreshing && service.lastRefresh != nil,
                  "\(name): actual refresh completes with visible failure")
            check(service.lastFetchFailure?.providerID == .google,
                  "\(name): staged fetch failure names the failing provider")
            check(service.lastFetchFailure?.stage == .auth,
                  "\(name): token failure stages as auth")
        }

        for (name, statuses, expectedEvents, failed) in [
            ("all-failed", [403, 503], 0, true),
            ("partial-success", [403, 200], 1, false),
            ("genuinely-empty", [200, 200], 0, false),
        ] {
            let token = CalendarFixtureToken()
            let eventStart = Date(timeIntervalSince1970:
                Date().timeIntervalSince1970.rounded(.down) + 60)
            let http = CalendarFixtureHTTP(eventStatuses: statuses,
                                           includeEvent: name == "partial-success",
                                           eventStart: eventStart)
            let provider = makeProvider(http: http, token: token)
            await provider.configure(clientID: "fixture-client", clientSecret: "",
                                     calendarIDs: ["blocked", "work"])
            let service = CalendarService(providersForTesting: [provider])
            await service.refresh()
            check(service.upcoming.count == expectedEvents, "\(name): exact event count")
            check(service.upcoming.map(\.id) == (expectedEvents == 1 ? ["fixture-event"] : []),
                  "\(name): unchanged successful event identity")
            check(service.upcoming.map(\.start) == (expectedEvents == 1 ? [eventStart] : []),
                  "\(name): captured in-window event instant reaches consumer")
            if failed {
                let message = "Google Calendar request failed: HTTP 403."
                check(service.providerStates[.google] == .failed(message),
                      "\(name): actual provider state is failed rather than connected")
                check(service.lastError == "Google Calendar: " + message,
                      "\(name): first actual error reaches refresh lastError")
                check(service.lastFetchFailure?.providerID == .google
                        && service.lastFetchFailure?.stage == .api,
                      "\(name): calendar refusal stages as api and names the provider")
                let reflected = service.lastFetchFailure.map { String(reflecting: $0) } ?? ""
                check(!reflected.contains("fixture calendar failure"),
                      "\(name): staged fact carries no refusal text")
            } else {
                check(service.providerStates[.google] == .authorized,
                      "\(name): successful/empty calendars remain usable")
                if name != "partial-success" {
                    check(service.lastError == nil,
                          "\(name): a clean pass records no error")
                }
                check(service.lastFetchFailure == nil,
                      "\(name): a pass with no failure records no staged fact")
                // A partial read is a different fact from a total failure: the
                // answer arrived in part, and the person is told which
                // provider was short.
                if name == "partial-success" {
                    check(service.lastPartialFetchFailures.count == 1,
                          "\(name): a partial read records its own fact")
                    check(service.lastError?.contains("could not be read") == true,
                          "\(name): a partial read is told to the person")
                }
            }
            let counts = await http.counts()
            check(counts.token == 1 && counts.events == 2 && counts.lists == 1 && counts.other == 0,
                  "\(name): original selected-calendar requests, no retry")
            check(token.clearCount == 0 && token.value != nil,
                  "\(name): read failure never clears refresh grant")
            check(!service.isRefreshing && service.lastRefresh != nil,
                  "\(name): refresh task joined")
        }
        return failures
    }

    private static func makeProvider(
        http: CalendarFixtureHTTP, token: CalendarFixtureToken
    ) -> GoogleCalendarProvider {
        GoogleCalendarProvider(
            requestForTesting: { request in try await http.reply(to: request) },
            refreshTokenForTesting: { token.value },
            clearTokenForTesting: { token.clear() }
        )
    }
}

private final class CalendarFixtureToken: Sendable {
    private struct State: Sendable {
        var value: String? = "fixture-refresh-token"
        var clearCount = 0
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var value: String? { state.withLock { $0.value } }
    var clearCount: Int { state.withLock { $0.clearCount } }
    func clear() { state.withLock { $0.value = nil; $0.clearCount += 1 } }
}

private actor CalendarFixtureHTTP {
    private let tokenStatus: Int
    private let tokenCode: String
    private let eventStatuses: [Int]
    private let includeEvent: Bool
    private let eventStart: Date
    private var tokenRequests = 0
    private var eventRequests = 0
    private var calendarListRequests = 0
    private var unexpectedRequests = 0

    init(tokenStatus: Int = 200, tokenCode: String = "",
         eventStatuses: [Int] = [], includeEvent: Bool = false,
         eventStart: Date = Date().addingTimeInterval(60)) {
        self.tokenStatus = tokenStatus
        self.tokenCode = tokenCode
        self.eventStatuses = eventStatuses
        self.includeEvent = includeEvent
        self.eventStart = eventStart
    }

    func counts() -> (token: Int, events: Int, lists: Int, other: Int) {
        (tokenRequests, eventRequests, calendarListRequests, unexpectedRequests)
    }

    func reply(to request: URLRequest) throws -> (Data, URLResponse) {
        guard let url = request.url, url.scheme == "https" else {
            unexpectedRequests += 1
            throw URLError(.badURL)
        }
        let status: Int
        let body: [String: Any]
        if url.host == "oauth2.googleapis.com", url.path == "/token" {
            tokenRequests += 1
            status = tokenStatus
            if status == 200 {
                body = ["access_token": "fixture-access-token", "expires_in": 3600]
            } else {
                body = tokenCode.isEmpty
                    ? ["error_description": "fixture token failure"]
                    : ["error": tokenCode, "error_description": "fixture token failure"]
            }
        } else if url.host == "www.googleapis.com",
                  url.path == "/calendar/v3/users/me/calendarList" {
            calendarListRequests += 1
            status = 200
            body = ["items": [["id": "blocked", "summary": "Fixture blocked"],
                               ["id": "work", "summary": "Fixture work"]]]
        } else if url.host == "www.googleapis.com",
                  (url.path == "/calendar/v3/calendars/blocked/events"
                    || url.path == "/calendar/v3/calendars/work/events") {
            let index = eventRequests
            eventRequests += 1
            guard index < eventStatuses.count else {
                unexpectedRequests += 1
                throw URLError(.badServerResponse)
            }
            status = eventStatuses[index]
            if status != 200 {
                // Calendar uses a nested error object, not the OAuth error string.
                body = ["error": ["code": status, "message": "fixture calendar failure"]]
            } else if includeEvent {
                body = ["items": [["id": "fixture-event", "summary": "Fixture meeting",
                    "start": ["dateTime": ISO8601DateFormatter().string(from: eventStart)],
                    "end": ["dateTime": ISO8601DateFormatter().string(
                        from: eventStart.addingTimeInterval(30 * 60))]]]]
            } else {
                body = ["items": []]
            }
        } else {
            unexpectedRequests += 1
            throw URLError(.badURL)
        }
        guard let response = HTTPURLResponse(url: url, statusCode: status,
                                            httpVersion: "HTTP/1.1", headerFields: nil) else {
            throw URLError(.badServerResponse)
        }
        return (try JSONSerialization.data(withJSONObject: body), response)
    }
}

import Foundation

@MainActor
enum GoogleCalendarWithdrawalSelfTest {
    static func run(_ expect: GoogleConnectSelfTest.Expect) async {
        let counts = GoogleReviewFixture.Counts()
        let formatter = ISO8601DateFormatter()
        let start = formatter.string(from: Date().addingTimeInterval(300))
        let end = formatter.string(from: Date().addingTimeInterval(900))
        let event = "{\"items\":[{\"id\":\"fixture-event\",\"summary\":\"Permission fixture\",\"start\":{\"dateTime\":\"\(start)\"},\"end\":{\"dateTime\":\"\(end)\"}}]}"
        GoogleTokenStore.save(refreshToken: "withdraw-calendar", grantedScopes: [GoogleScopes.calendar])
        defer { GoogleTokenStore.clear(forgetSelection: true) }
        let provider = GoogleCalendarProvider(requestForTesting: { request in
            _ = counts.hit("request")
            let body: String
            if request.url?.host == "oauth2.googleapis.com" {
                body = #"{"access_token":"withdraw-calendar-token","expires_in":3600}"#
            } else if request.url?.path.hasSuffix("calendarList") == true {
                body = #"{"items":[{"id":"fixture-calendar","summary":"Fixture","selected":true}]}"#
            } else { body = event }
            return GoogleReviewFixture.response(request, body: body)
        }, refreshTokenForTesting: { GoogleTokenStore.refreshToken }, clearTokenForTesting: {},
            grantedScopesForTesting: { GoogleTokenStore.grantedScopes }, signInForTesting: {
                GoogleTokenStore.save(refreshToken: "withdraw-calendar", grantedScopes: [GoogleScopes.documents])
            })
        await provider.configure(clientID: "fixture", clientSecret: "", calendarIDs: [])
        let service = CalendarService(googleForTesting: provider)
        await service.refreshGoogleCalendars()
        await service.refresh()
        expect(service.upcoming.count == 1 && service.googleCalendars.count == 1,
            "R6 withdrawal begins with actual fetched Calendar entries and upcoming event")
        let before = counts.count("request")
        let state = await service.connectGoogle()
        expect(state == .disabled(GoogleCapability.calendar.permissionSentence)
            && service.providerStates[.google] == state && service.upcoming.isEmpty && service.googleCalendars.isEmpty,
            "R6 withdrawn Calendar permission immediately clears actual cached calendars and upcoming events")
        expect(counts.count("request") == before,
            "R6 clearing withdrawn Calendar state makes zero additional token or Calendar requests")
    }
}

import Foundation

@MainActor
enum GoogleCalendarScopeSelfTest {
    static func run(_ expect: GoogleConnectSelfTest.Expect) async {
        defer { GoogleTokenStore.clear(forgetSelection: true) }
        let client = GoogleAppClient(clientID: "fixture", clientSecret: "", source: .app)
        for scopes in [Set([GoogleScopes.documents]), Set<String>(), Set([GoogleScopes.legacyCalendar])] {
            let counts = GoogleReviewFixture.Counts()
            let provider = GoogleCalendarProvider(requestForTesting: { request in
                _ = counts.hit(request.url?.host == "oauth2.googleapis.com" ? "token" : "calendar")
                return GoogleReviewFixture.response(request, body: request.url?.host == "oauth2.googleapis.com"
                    ? #"{"access_token":"calendar-granted","expires_in":3600}"# : #"{"items":[]}"#)
            }, refreshTokenForTesting: { GoogleTokenStore.refreshToken }, clearTokenForTesting: {},
                grantedScopesForTesting: { GoogleTokenStore.grantedScopes }, signInForTesting: {
                    GoogleTokenStore.save(refreshToken: "calendar-scope", grantedScopes: scopes)
                })
            await provider.configure(clientID: client.clientID, clientSecret: "", calendarIDs: [])
            let service = CalendarService(googleForTesting: provider)
            let connection = GoogleConnection(dependencies: GoogleConnection.Dependencies(client: { client }, signIn: { _ in
                GoogleTokenStore.save(refreshToken: "calendar-scope", grantedScopes: scopes)
                return GoogleOAuthClient.SignInResult(refreshToken: "calendar-scope", grantedScopes: scopes)
            }, ensureTool: {}, afterConnect: { returnedScopes in
                await GoogleConnection.Dependencies.applyCalendarGrant(returnedScopes, setEnabled: { enabled in
                    if enabled { _ = counts.hit("enabled") }
                }, refreshCalendars: { enabled in
                    if enabled { _ = counts.hit("listed") }
                    await service.refreshGoogleCalendars(enabledForTesting: enabled)
                })
            }, disconnect: {}, workspace: { .signedIn(method: "fixture") }))
            await connection.connect()
            let authorized = GoogleScopes.coversCalendar(scopes)
            expect(counts.count("enabled") == (authorized ? 1 : 0) && counts.count("listed") == (authorized ? 1 : 0),
                "R6 actual connect flow enables and lists Calendar only when granted (\(authorized))")
            let state = await service.connectGoogle()
            expect(state.isAuthorized == authorized, "R6 actual CalendarService consumes real grant authorization (\(authorized))")
            _ = try? await provider.calendars()
            _ = try? await provider.events(from: Date(), to: Date().addingTimeInterval(3600))
            await service.refreshGoogleCalendars()
            expect(authorized ? counts.count("calendar") > 0 : counts.count("calendar") == 0 && counts.count("token") == 0,
                "R6 declined Calendar has zero token/list/events requests; granted Calendar still runs (\(authorized))")
        }
    }
}

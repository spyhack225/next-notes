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
        // Populate again and use the connection controller, including its disabled
        // switch, instead of CalendarService.connectGoogle's separate consumer.
        GoogleTokenStore.save(refreshToken: "controller-calendar", grantedScopes: [GoogleScopes.calendar])
        await service.refreshGoogleCalendars()
        await service.refresh()
        expect(service.googleCalendars.count == 1 && service.upcoming.count == 1,
            "R6 controller withdrawal starts with fetched Calendar list and event")
        let client = GoogleAppClient(clientID: "fixture", clientSecret: "", source: .app)
        let controller = GoogleConnection(dependencies: .init(client: { client }, signIn: { _ in
            try await GoogleAccessTokens.shared.replaceGrant(refreshToken: "controller-docs", scopes: [GoogleScopes.documents])
            return .init(refreshToken: "controller-docs", grantedScopes: [GoogleScopes.documents])
        }, ensureTool: {}, afterConnect: { scopes in
            await GoogleConnection.Dependencies.applyCalendarGrant(scopes, setEnabled: { enabled in
                if !enabled { _ = counts.hit("disabled") }
            }, refreshCalendars: { enabled in await service.refreshGoogleCalendars(enabledForTesting: enabled) })
            await service.refresh()
        }, disconnect: {
            await GoogleAccessTokens.shared.disconnectGrant()
            // Same service seam with the switch already off, as in the live controller.
            await service.refreshGoogleCalendars(enabledForTesting: false)
            await service.refresh()
        }, workspace: { GoogleTokenStore.hasRefreshToken ? .signedIn(method: "fixture") : .signedOut }))
        let controllerBefore = counts.count("request")
        await controller.connect()
        expect(counts.count("disabled") == 1 && controller.state == .needsMoreAccess
            && service.googleCalendars.isEmpty && service.upcoming.isEmpty,
            "R6 connection controller withdrawal clears populated Calendar list while switching Calendar off")
        expect(counts.count("request") == controllerBefore,
            "R6 controller withdrawal enters zero Google token or Calendar backing")
        // Repopulate only the list to pin disconnect's enabled-guard transition too.
        GoogleTokenStore.save(refreshToken: "disconnect-calendar", grantedScopes: [GoogleScopes.calendar])
        await service.refreshGoogleCalendars(enabledForTesting: true)
        expect(service.googleCalendars.count == 1, "R6 controller disconnect begins with fetched list and disabled switch")
        let disconnectBefore = counts.count("request")
        await controller.disconnect()
        expect(service.googleCalendars.isEmpty && !GoogleTokenStore.hasRefreshToken,
            "R6 connection controller disconnect clears populated Calendar list even when already off")
        expect(counts.count("request") == disconnectBefore, "R6 controller disconnect clearing enters zero Google backing")
        await heldListCases(expect)
    }

    /// Hold a successful HTTP response after token/backing admission, then exercise
    /// the actual controller/service consumers before allowing that response to finish.
    private static func heldListCases(_ expect: GoogleConnectSelfTest.Expect) async {
        for route in ["withdrawal", "disconnect", "reconnect", "replacement", "failed-replacement",
                      "service-withdrawal", "service-disconnect"] {
            let held = GoogleReviewFixture.Gate()
            let counts = GoogleReviewFixture.Counts()
            GoogleTokenStore.save(refreshToken: "held-list-grant", grantedScopes: [GoogleScopes.calendar])
            let provider = GoogleCalendarProvider(requestForTesting: { request in
                _ = counts.hit("request")
                if request.url?.host == "oauth2.googleapis.com" {
                    return GoogleReviewFixture.response(request,
                        body: #"{"access_token":"held-list-token","expires_in":3600}"#)
                }
                if request.url?.path.hasSuffix("calendarList") == true {
                    let first = counts.hit("list") == 1
                    let body = first
                        ? #"{"items":[{"id":"old-calendar","summary":"Old account"}]}"#
                        : #"{"items":[{"id":"new-calendar","summary":"New account"}]}"#
                    if first { await held.pause() }
                    return GoogleReviewFixture.response(request,
                        status: first && route == "failed-replacement" ? 503 : 200, body: body)
                }
                return GoogleReviewFixture.response(request, body: #"{"items":[]}"#)
            }, refreshTokenForTesting: { GoogleTokenStore.refreshToken },
                clearTokenForTesting: { GoogleTokenStore.clear(forgetSelection: true) },
                grantedScopesForTesting: { GoogleTokenStore.grantedScopes }, signInForTesting: {
                    GoogleTokenStore.save(refreshToken: "held-list-grant", grantedScopes: [GoogleScopes.documents])
                })
            await provider.configure(clientID: "fixture", clientSecret: "", calendarIDs: [])
            let service = CalendarService(googleForTesting: provider)
            let client = GoogleAppClient(clientID: "fixture", clientSecret: "", source: .app)
            let replacementScopes: Set<String> = route == "withdrawal"
                ? [GoogleScopes.documents] : [GoogleScopes.calendar]
            let controller = GoogleConnection(dependencies: .init(client: { client }, signIn: { _ in
                // Deliberately reuse token text; this is a new grant, even when both
                // Calendar permissions and the enabled switch remain unchanged.
                try await GoogleAccessTokens.shared.replaceGrant(refreshToken: "held-list-grant", scopes: replacementScopes)
                return .init(refreshToken: "held-list-grant", grantedScopes: replacementScopes)
            }, ensureTool: {}, afterConnect: { scopes in
                await GoogleConnection.Dependencies.applyCalendarGrant(scopes, setEnabled: { _ in },
                    refreshCalendars: { enabled in await service.refreshGoogleCalendars(enabledForTesting: enabled) })
            }, disconnect: {
                await GoogleAccessTokens.shared.disconnectGrant()
                // Enabled disconnect exercises authorization clearing; the preceding
                // sequential fixture separately pins the already-disabled route.
                await service.refreshGoogleCalendars(enabledForTesting: true)
            }, workspace: { GoogleTokenStore.hasRefreshToken ? .signedIn(method: "fixture") : .signedOut }))

            let old = Task { await service.refreshGoogleCalendars(enabledForTesting: true) }
            await held.wait()
            expect(counts.count("list") == 1 && service.googleCalendars.isEmpty,
                "R6 held \(route) reaches actual list backing before response completion")
            let before = counts.count("request")
            switch route {
            case "withdrawal": await controller.connect()
            case "disconnect", "reconnect": await controller.disconnect()
            case "service-withdrawal": _ = await service.connectGoogle()
            case "service-disconnect": await service.disconnectGoogle()
            default: break
            }
            if route != "replacement" && route != "failed-replacement" {
                expect(service.googleCalendars.isEmpty && counts.count("request") == before,
                    "R6 held \(route) clears before releasing old response with zero additional backing")
            }
            let keepsNewList = ["reconnect", "replacement", "failed-replacement"].contains(route)
            if keepsNewList {
                await controller.connect()
                expect(service.googleCalendars.map(\.id) == ["new-calendar"] && counts.count("list") == 2,
                    "R6 held \(route) publishes new grant list while old response remains held")
            }
            await held.release()
            await old.value
            let actualIDs = service.googleCalendars.map(\.id)
            let expectedIDs = keepsNewList ? ["new-calendar"] : []
            SelfTest.diagnostic("GOOGLE_LIST_COMPLETION route=\(route) cache=\(actualIDs) expected=\(expectedIDs)")
            expect(actualIDs == expectedIDs,
                "R6 held \(route) drops old list completion after account transition")
            expect(counts.count("list") == (keepsNewList ? 2 : 1),
                "R6 held \(route) completion adds no retry or list request")
            GoogleTokenStore.clear(forgetSelection: true)
        }
    }
}

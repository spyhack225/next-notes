import Foundation

@MainActor
enum GoogleConcurrentRejectionSelfTest {
    static func run(_ expect: GoogleConnectSelfTest.Expect) async {
        let counts = GoogleReviewFixture.Counts()
        let firstA = GoogleReviewFixture.Gate()
        let delayedA = GoogleReviewFixture.Gate()
        let refreshB = GoogleReviewFixture.Gate()
        let handled = GoogleReviewFixture.Gate()
        let provider = GoogleCalendarProvider(requestForTesting: { request in
            if request.url?.host == "oauth2.googleapis.com" {
                let refresh = counts.hit("refresh")
                if refresh == 2 { await refreshB.pause() }
                return GoogleReviewFixture.response(request, body: "{\"access_token\":\"token-\(refresh)\",\"expires_in\":3600}")
            }
            if counts.count("armed") > 0 && request.value(forHTTPHeaderField: "Authorization") == "Bearer token-1" {
                let read = counts.hit("rejected-A")
                if read == 1 { await firstA.pause() }
                else { await delayedA.pause() }
                return GoogleReviewFixture.response(request, status: 401, body: "{}")
            }
            _ = counts.hit("success")
            return GoogleReviewFixture.response(request, body: #"{"items":[]}"#)
        }, refreshTokenForTesting: { "fixture-shared" }, clearTokenForTesting: { _ = counts.hit("clear") })
        await provider.configure(clientID: "fixture-client", clientSecret: "", calendarIDs: [])
        let tokens = await provider.accessTokensForTesting()
        await tokens.useClient(GoogleAppClient(clientID: "fixture-client", clientSecret: "", source: .app))
        GoogleTokenStore.save(refreshToken: "fixture-shared", grantedScopes: Set(GoogleScopes.connect))
        defer { GoogleTokenStore.clear(forgetSelection: true) }
        await tokens.observeRejectedTokenForTesting {
            if counts.hit("handled") == 2 { Task { await handled.pause() } }
        }
        _ = try? await provider.calendars() // cache A
        _ = counts.hit("armed")
        let first = Task { try await provider.calendars() }
        await firstA.wait()
        let delayed = Task { try await provider.calendars() }
        await delayedA.wait()
        await firstA.release()
        await refreshB.wait()
        let workspace = Task { try await tokens.workspaceToken() }
        await delayedA.release()
        await handled.wait() // delayed A has reached actual token invalidation
        await handled.release()
        await refreshB.release()
        let firstResult = try? await first.value
        let delayedResult = try? await delayed.value
        let workspaceResult = try? await workspace.value
        expect(firstResult != nil && delayedResult != nil && workspaceResult == "token-2",
            "R4 overlapping Calendar 401s and Workspace all use the same replacement token")
        expect(counts.count("refresh") == 2 && counts.count("rejected-A") == 2 && counts.count("clear") == 0,
            "R4 delayed 401 invalidates only rejected A and never cancels refresh B")
        expect(counts.count("success") == 3, "R4 both actual Calendar consumers retry successfully exactly once")
        await tokens.observeRejectedTokenForTesting(nil)
        // An older rejection after B is cached must leave B intact too.
        await tokens.invalidate(rejectedToken: "token-1")
        let retained = try? await tokens.workspaceToken()
        expect(retained == "token-2" && counts.count("refresh") == 2, "R4 cached replacement survives a stale token identity")

        // A normal expiry refresh can begin with A still in the cache. Rejecting A
        // may evict A, but still has no authority to cancel that pending refresh.
        let expiryCounts = GoogleReviewFixture.Counts()
        let pendingRefresh = GoogleReviewFixture.Gate()
        let expiryTokens = GoogleAccessTokens(requestForTesting: { request in
            let count = expiryCounts.hit("refresh")
            if count == 2 { await pendingRefresh.pause() }
            return GoogleReviewFixture.response(request,
                body: "{\"access_token\":\"expiry-\(count)\",\"expires_in\":\(count == 1 ? 0 : 3600)}")
        }, refreshTokenForTesting: { "fixture-expiry" }, clearTokenForTesting: {})
        _ = try? await expiryTokens.token(clientID: "fixture", clientSecret: "")
        let pending = Task { try await expiryTokens.token(clientID: "fixture", clientSecret: "") }
        await pendingRefresh.wait()
        await expiryTokens.invalidate(rejectedToken: "expiry-1")
        await pendingRefresh.release()
        let replacement = try? await pending.value
        expect(replacement == "expiry-2" && expiryCounts.count("refresh") == 2,
            "R4 rejected expired A cannot cancel an already pending ordinary refresh")
    }
}

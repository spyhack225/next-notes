import Foundation
import Security

@MainActor
enum GoogleGrantReplacementSelfTest {
    static func run(_ expect: GoogleConnectSelfTest.Expect) async {
        let tokens = GoogleAccessTokens.shared
        defer { GoogleTokenStore.clear(forgetSelection: true) }
        // Direct store replacements also use exact record identity at revocation time.
        // Cover a different token and the same token issued as a new grant generation.
        for replacement in ["new-record", "old-record"] {
            let held = GoogleReviewFixture.Gate()
            GoogleTokenStore.save(refreshToken: "old-record", grantedScopes: [GoogleScopes.documents])
            await tokens.useRequestForTesting { request in
                await held.pause()
                return GoogleReviewFixture.response(request, status: 400, body: #"{"error":"invalid_grant"}"#)
            }
            let old = Task { try await tokens.token(clientID: "fixture", clientSecret: "") }
            await held.wait()
            GoogleTokenStore.save(refreshToken: replacement, grantedScopes: Set(GoogleScopes.connect))
            let identity = try? GoogleTokenStore.savedGrant()?.identity
            await held.release()
            _ = try? await old.value
            expect(GoogleTokenStore.refreshToken == replacement && GoogleTokenStore.grantedScopes == Set(GoogleScopes.connect)
                && (try? GoogleTokenStore.savedGrant()?.identity) == identity,
                "R3 stale revocation preserves exact newer grant generation (\(replacement))")
            await tokens.useRequestForTesting(nil)
        }
        // Identity check is independently necessary when the existing store is replaced
        // without the actor's invalidation hop. Same refresh text, new record UUID.
        let response = GoogleReviewFixture.Gate()
        let creatorDelivery = GoogleReviewFixture.Gate()
        let joinerDelivery = GoogleReviewFixture.Gate()
        let joined = GoogleReviewFixture.Gate()
        await tokens.useRequestForTesting { request in
            await response.pause()
            return GoogleReviewFixture.response(request, body: #"{"access_token":"direct-store-success","expires_in":3600}"#)
        }
        await tokens.holdDeliveryForTesting({ joining in
            if joining { await joinerDelivery.pause() } else { await creatorDelivery.pause() }
        }, joining: { await joined.pause() })
        GoogleTokenStore.save(refreshToken: "same-delivery-text", grantedScopes: Set(GoogleScopes.connect))
        let creator = Task { try await tokens.token(clientID: "fixture", clientSecret: "") }
        await response.wait()
        let joiner = Task { try await tokens.token(clientID: "fixture", clientSecret: "") }
        await joined.wait(); await joined.release(); await response.release()
        await creatorDelivery.wait(); await joinerDelivery.wait()
        GoogleTokenStore.save(refreshToken: "same-delivery-text", grantedScopes: Set(GoogleScopes.connect))
        await creatorDelivery.release(); await joinerDelivery.release()
        for (caller, name) in [(creator, "creator"), (joiner, "joining waiter")] {
            var refused = false
            do { _ = try await caller.value }
            catch GoogleCalendarError.signInChanged { refused = true }
            catch { }
            expect(refused, "R3 successful \(name) delivery checks exact replaced record without actor invalidation")
        }
        await tokens.holdDeliveryForTesting(nil)
        await tokens.useRequestForTesting(nil)

        // An unavailable row must also refuse a revocation read without deleting evidence.
        let held = GoogleReviewFixture.Gate()
        GoogleTokenStore.save(refreshToken: "unavailable-at-clear", grantedScopes: [GoogleScopes.documents])
        await tokens.useRequestForTesting { request in
            await held.pause()
            return GoogleReviewFixture.response(request, status: 400, body: #"{"error":"invalid_grant"}"#)
        }
        let old = Task { try await tokens.token(clientID: "fixture", clientSecret: "") }
        await held.wait()
        GoogleTokenStore.useReadStatusForTesting(errSecInteractionNotAllowed)
        await held.release()
        _ = try? await old.value
        GoogleTokenStore.useReadStatusForTesting(nil)
        expect(GoogleTokenStore.refreshToken == "unavailable-at-clear", "R3 revocation refuses unreadable identity and retains the row")
        await tokens.useRequestForTesting(nil)
        await tokens.invalidate()
    }
}

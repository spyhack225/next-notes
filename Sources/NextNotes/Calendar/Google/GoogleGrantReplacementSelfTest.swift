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

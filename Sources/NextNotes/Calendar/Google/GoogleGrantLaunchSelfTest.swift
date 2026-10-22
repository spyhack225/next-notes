import Foundation

@MainActor
enum GoogleGrantLaunchSelfTest {
    static func run(_ expect: GoogleConnectSelfTest.Expect) async {
        guard let fixture = try? GoogleReviewFixture.executable("grant-launch") else {
            expect(false, "R3 grant launch fixture written"); return
        }
        defer { try? FileManager.default.removeItem(at: fixture.root); GoogleTokenStore.clear(forgetSelection: true) }
        let tokens = GoogleAccessTokens.shared
        let message = GoogleCalendarError.signInChanged.localizedDescription
        expect(GoogleConnection.State.failed(message).detail == "Your Google sign-in changed, try again.",
            "R3 changed sign-in has plain state detail")
        await tokens.useClient(GoogleAppClient(clientID: "fixture", clientSecret: "", source: .app))
        let counts = GoogleReviewFixture.Counts()
        await tokens.useRequestForTesting { request in
            _ = counts.hit("refresh")
            return GoogleReviewFixture.response(request, body: #"{"access_token":"old-launch-token","expires_in":3600}"#)
        }
        for seam in ["before-token", "after-token", "inside-spawn"] {
            try? await tokens.replaceGrant(refreshToken: "same-refresh-text", scopes: Set(GoogleScopes.connect))
            let gate = GoogleReviewFixture.Gate()
            let hooks: GoogleWorkspaceCLI.TestHooks
            switch seam {
            case "before-token": hooks = .init(beforeToken: { await gate.pause() })
            case "after-token": hooks = .init(afterToken: { await gate.pause() })
            default: hooks = .init(beforeLaunch: { await gate.pause() })
            }
            guard let runner = GoogleWorkspaceCLI.appAccountFixture(executable: fixture.executable, hooks: hooks) else {
                expect(false, "R3 grant launch runner admitted"); break
            }
            let caller = Task { try await runner.run(["gmail", "users", "messages", "send"]) }
            await gate.wait()
            let before = counts.count("refresh")
            // Same refresh text, distinct generation and fewer permissions. Admission
            // under the old Mail scopes cannot acquire or launch either grant's token.
            try? await tokens.replaceGrant(refreshToken: "same-refresh-text", scopes: [GoogleScopes.documents])
            await gate.release()
            var refused = false
            do { _ = try await caller.value }
            catch let error as WorkspaceCLIError { refused = error == .launchFailed(message) && error.outcomeIsKnown }
            catch { }
            expect(refused, "R3 \(seam) grant replacement refuses send with changed-sign-in state")
            expect(!FileManager.default.fileExists(atPath: fixture.marker.path),
                "R3 \(seam) grant replacement has zero executable backing entries")
            expect(counts.count("refresh") == before, "R3 \(seam) cannot refresh the replacement under old scope admission")
            try? FileManager.default.removeItem(at: fixture.marker)
        }
        try? await tokens.replaceGrant(refreshToken: "current-launch", scopes: Set(GoogleScopes.connect))
        if let normal = GoogleWorkspaceCLI.appAccountFixture(executable: fixture.executable) {
            let result = try? await normal.run(["gmail", "users", "messages", "send"])
            expect(result != nil && FileManager.default.fileExists(atPath: fixture.marker.path),
                "R3 unchanged grant reaches the same real executable backing")
        }
        await tokens.useRequestForTesting(nil)
        await tokens.useClient(nil)
        await tokens.invalidate()
    }
}

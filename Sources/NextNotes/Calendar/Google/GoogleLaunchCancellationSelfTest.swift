import Foundation

@MainActor
enum GoogleLaunchCancellationSelfTest {
    static func run(_ expect: GoogleConnectSelfTest.Expect) async {
        guard let fixture = try? GoogleReviewFixture.executable("cancel") else { expect(false, "R2 fixture written"); return }
        defer { try? FileManager.default.removeItem(at: fixture.root); GoogleTokenStore.clear(forgetSelection: true) }
        let tokens = GoogleAccessTokens.shared
        // A separate existing token actor checks cancellation; this fixture pauses AFTER
        // its return by using an already-cached successful shared token from runnerCases.
        // Native loopback token response is supplied via the exact actor HTTP seam below.
        await tokens.useClient(GoogleAppClient(clientID: "fixture.apps.googleusercontent.com", clientSecret: "", source: .app))
        GoogleTokenStore.save(refreshToken: "launch-cancel", grantedScopes: Set(GoogleScopes.connect))
        await tokens.useRequestForTesting { req in
            return GoogleReviewFixture.response(req, body: #"{"access_token":"cached-launch-token","expires_in":3600}"#)
        }
        _ = try? await tokens.workspaceToken()
        for seam in ["after-token", "inside-spawn"] {
            let gate = GoogleReviewFixture.Gate()
            let hooks = seam == "after-token"
                ? GoogleWorkspaceCLI.TestHooks(afterToken: { await gate.pause() })
                : GoogleWorkspaceCLI.TestHooks(beforeLaunch: { await gate.pause() })
            guard let runner = GoogleWorkspaceCLI.appAccountFixture(executable: fixture.executable, hooks: hooks) else {
                expect(false, "R2 runner admitted"); return
            }
            let task = Task { try await runner.run(["gmail", "users", "messages", "send"]) }
            await gate.wait()
            task.cancel()
            await gate.release()
            do { _ = try await task.value; expect(false, "R2 \(seam) cancellation refuses executable entry") }
            catch is CancellationError { expect(true, "R2 \(seam) cancellation reaches caller") }
            catch { expect(false, "R2 \(seam) wrong refusal") }
            expect(!FileManager.default.fileExists(atPath: fixture.marker.path), "R2 \(seam) cancelled send has zero backing entries")
            try? FileManager.default.removeItem(at: fixture.marker)
        }
        // Already cancelled at spawn entry, before the handler is installed.
        let gate = GoogleReviewFixture.Gate()
        let cancelled = Task {
            await gate.pause()
            return try await GoogleWorkspaceCLI.spawn(executable: fixture.executable, arguments: [], timeout: 5)
        }
        await gate.wait(); cancelled.cancel(); await gate.release()
        do { _ = try await cancelled.value; expect(false, "R2 already cancelled spawn refuses launch") }
        catch is CancellationError { expect(true, "R2 already cancelled spawn reaches caller") }
        catch { expect(false, "R2 already cancelled spawn wrong refusal") }
        expect(!FileManager.default.fileExists(atPath: fixture.marker.path), "R2 already cancelled spawn has zero backing entries")
        try? FileManager.default.removeItem(at: fixture.marker)
        guard let normal = GoogleWorkspaceCLI.appAccountFixture(executable: fixture.executable) else { return }
        let output = try? await normal.run(["gmail", "users", "messages", "send"])
        expect(output != nil && FileManager.default.fileExists(atPath: fixture.marker.path), "R2 noncancelled caller uses the same cached token and real backing")
        await tokens.useRequestForTesting(nil)
        await tokens.useClient(nil)
        await tokens.invalidate()
    }
}

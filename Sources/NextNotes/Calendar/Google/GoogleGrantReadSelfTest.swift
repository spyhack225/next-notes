import Foundation
import Security

@MainActor
enum GoogleGrantReadSelfTest {
    static func run(_ expect: GoogleConnectSelfTest.Expect) async {
        guard let fixture = try? GoogleReviewFixture.executable("read"),
              let runner = GoogleWorkspaceCLI.appAccountFixture(executable: fixture.executable, isManaged: false) else {
            expect(false, "R1 isolated alternate login admitted"); return
        }
        defer {
            GoogleTokenStore.useReadStatusForTesting(nil)
            GoogleTokenStore.clear(forgetSelection: true)
            try? FileManager.default.removeItem(at: fixture.root)
        }
        GoogleTokenStore.clear(forgetSelection: true)
        let raw: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: GoogleTokenStore.service, kSecAttrAccount as String: "refresh-token",
            kSecValueData as String: Data("raw-unreadable-fixture".utf8)]
        expect(SecItemAdd(raw as CFDictionary, nil) == errSecSuccess && !GoogleTokenStore.appSignInSelected,
            "R1 raw legacy fixture starts without the newer selection preference")
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecNotAvailable, errSecDecode] {
            GoogleTokenStore.useReadStatusForTesting(status)
            let state = await runner.authState()
            let message = GoogleCalendarError.tokenStoreUnreadable.localizedDescription
            expect(GoogleConnection.State.failed(message).detail == message, "R1 saved-sign-in failure has plain state detail")
            expect(state == .failed(message), "R1 denied read is unavailable, never a foreign signed-in state (\(status))")
            for arguments in [["gmail", "users", "messages", "send"], ["--version"], ["auth", "status"]] {
                do {
                    _ = try await runner.run(arguments)
                    expect(false, "R1 denied read refuses alternate backing")
                } catch let error as WorkspaceCLIError {
                    expect(error == .launchFailed(message) && error.outcomeIsKnown,
                        "R1 denied read reports saved sign-in failure before launch")
                } catch { expect(false, "R1 denied read wrong error") }
            }
            expect(await runner.accountTag() == nil, "R1 denied read supplies no alternate profile")
            expect(await GoogleSource.effective(cli: runner) == .googleSignIn,
                "R1 denied read retains the app source rather than another account")
            let source = await GoogleSource.status(cli: runner)
            expect(source.state == .failed(message) && source.gaps.count == GoogleSource.allTools.count,
                "R1 denied read reaches actual source status and withholds every tool")
            let connection = GoogleConnection(dependencies: GoogleConnection.Dependencies(client: { nil },
                signIn: { _ in throw GoogleCalendarError.notSignedIn }, ensureTool: {},
                afterConnect: { _ in }, disconnect: {}, workspace: { await runner.authState() }))
            await connection.refresh()
            expect(connection.state == .failed(message) && connection.state.detail == message,
                "R1 actual connection controller exposes saved-sign-in failure without preparing a tool")
            let provider = GoogleCalendarProvider()
            await provider.configure(clientID: "fixture", clientSecret: "", calendarIDs: [])
            expect(await provider.authorizationState() == .failed(message), "R1 Calendar exposes the saved sign-in failure")
            do {
                _ = try await GoogleAccessTokens.shared.token(clientID: "fixture", clientSecret: "")
                expect(false, "R1 token reader refuses unreadable grant")
            } catch GoogleCalendarError.tokenStoreUnreadable {
                expect(true, "R1 token reader preserves unavailable instead of not-signed-in")
            } catch { expect(false, "R1 token reader wrong error") }
        }
        expect(!FileManager.default.fileExists(atPath: fixture.marker.path), "R1 denied read never runs the runnable alternate login")
        GoogleTokenStore.useReadStatusForTesting(nil)
        expect(GoogleTokenStore.hasRefreshToken && GoogleTokenStore.appSignInSelected,
            "R1 adopting a readable legacy grant persists its routing independently")
        GoogleTokenStore.useReadStatusForTesting(errSecItemNotFound)
        let retainedRoute = await runner.appSignInInEffect()
        expect(GoogleTokenStore.readState == .absent && retainedRoute,
            "R1 not-found is absent but retains a previously adopted app route")
        GoogleTokenStore.clear(forgetSelection: true)
        expect(await runner.appSignInInEffect() == false, "R1 explicit Disconnect plus not-found permits the chosen alternate route")
        try? FileManager.default.removeItem(at: fixture.marker)
        _ = try? await runner.run(["auth", "status"])
        expect(FileManager.default.fileExists(atPath: fixture.marker.path), "R1 same alternate fixture is runnable when no grant was selected")
    }
}

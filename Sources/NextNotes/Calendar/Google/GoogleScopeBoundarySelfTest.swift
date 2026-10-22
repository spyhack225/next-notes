import Foundation

@MainActor
enum GoogleScopeBoundarySelfTest {
    static func run(_ expect: GoogleConnectSelfTest.Expect) async {
        guard let fixture = try? GoogleReviewFixture.executable("all-scopes"),
              let runner = GoogleWorkspaceCLI.appAccountFixture(executable: fixture.executable) else {
            expect(false, "all-scope runner admitted"); return
        }
        defer { try? FileManager.default.removeItem(at: fixture.root); GoogleTokenStore.clear(forgetSelection: true) }
        let commands: [(GoogleCapability, String)] = [(.mail, "gmail"), (.calendar, "calendar"), (.drive, "drive"),
            (.documents, "docs"), (.spreadsheets, "sheets"), (.presentations, "slides"),
            (.tasks, "tasks"), (.contacts, "people"), (.forms, "forms")]
        for (capability, command) in commands {
            let partial = Set(GoogleScopes.connect).subtracting([capability.scope])
            GoogleTokenStore.save(refreshToken: "all-scope-fixture", grantedScopes: partial)
            expect(GoogleTokenStore.grantedScopes == partial && !GoogleTokenStore.grantedScopes.contains(capability.scope),
                "unticked \(capability.rawValue) survives the actual Keychain round-trip, including future tools")
            do {
                _ = try await runner.run([command, "insert"])
                expect(false, "unticked \(capability.rawValue) refuses actual command backing")
            } catch let error as WorkspaceCLIError {
                expect(error == .invalidRequest(capability.permissionSentence),
                    "unticked \(capability.rawValue) is enforced by actual argument admission")
            } catch { expect(false, "unticked \(capability.rawValue) wrong command refusal") }
        }
        expect(!FileManager.default.fileExists(atPath: fixture.marker.path), "all nine declined capability commands have zero backing entries")
    }
}

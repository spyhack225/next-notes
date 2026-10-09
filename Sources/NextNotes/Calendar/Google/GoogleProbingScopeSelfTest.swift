import Foundation

@MainActor
enum GoogleProbingScopeSelfTest {
    static func run(_ expect: GoogleConnectSelfTest.Expect) async {
        guard let fixture = try? GoogleReviewFixture.executable("probing") else { expect(false, "R5 fixture written"); return }
        defer { try? FileManager.default.removeItem(at: fixture.root); GoogleTokenStore.clear(forgetSelection: true) }
        let counts = GoogleReviewFixture.Counts()
        let probing = GoogleReviewFixture.Gate()
        guard let runner = GoogleWorkspaceCLI.appAccountFixture(executable: fixture.executable,
            hooks: GoogleWorkspaceCLI.TestHooks(beforeAuthProbe: {
                if counts.hit("probe") == 2 { await probing.pause() }
            })) else { expect(false, "R5 runner admitted"); return }
        let tokens = GoogleAccessTokens.shared
        await tokens.useClient(GoogleAppClient(clientID: "fixture", clientSecret: "", source: .app))
        await tokens.useRequestForTesting { request in
            GoogleReviewFixture.response(request, body: #"{"access_token":"docs-only","expires_in":3600}"#)
        }
        GoogleTokenStore.save(refreshToken: "docs-grant", grantedScopes: [GoogleScopes.documents])
        let service = AgentService(cli: runner)
        await service.refreshStatus(force: true)
        expect(service.workspaceGaps["send_email"] != nil && service.workspaceGaps["read_doc"] == nil,
            "R5 actual status producer retains Docs-only scope gaps")
        let refresh = Task { await service.refreshStatus(force: true) }
        await probing.wait()
        let reader = AgentCapabilityManifest.Reader(provider: .appLLM, displayName: "Fixture", contextTokens: 8_192)
        let inputs = AgentCapabilityInputs.live(reader: reader, service: service)
        expect(service.isProbing && inputs.workspace == .checking && inputs.workspaceGaps["send_email"] != nil,
            "R5 actual live inputs are checking with cached missing Mail permission")
        let manifest = AgentCapabilityManifestBuilder.build(inputs, request: "send an email and read my Google document")
        expect(manifest.allowed.contains { $0.id == "send_email" } == false
            && manifest.selected.contains { $0.id == "send_email" } == false
            && manifest.entry(named: "send_email") == nil
            && manifest.unavailable.first { $0.id == "send_email" }?.readiness == .needsSetup(GoogleCapability.mail.permissionSentence),
            "R5 probing planner excludes known missing Mail permission from allowed and selected tools")
        expect(manifest.entry(named: "read_doc")?.readiness == .ready, "R5 probing keeps permitted Docs ready")
        var unknown = inputs; unknown.workspace = .unknown
        let unknownManifest = AgentCapabilityManifestBuilder.build(unknown, request: "send an email")
        expect(unknownManifest.entry(named: "send_email") == nil, "R5 unknown state also respects known scope gaps")
        var noFacts = inputs; noFacts.workspaceGaps = [:]
        let optimistic = AgentCapabilityManifestBuilder.build(noFacts, request: "send an email")
        expect(optimistic.entry(named: "send_email")?.readiness == .ready, "R5 checking with no known gap preserves optimistic readiness")
        await probing.release(); await refresh.value
        await tokens.useRequestForTesting(nil); await tokens.useClient(nil); await tokens.invalidate()
    }
}

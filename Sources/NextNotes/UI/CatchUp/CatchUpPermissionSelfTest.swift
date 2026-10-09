import Foundation

@MainActor
enum CatchUpPermissionSelfTest {
    static func run() async -> [String] {
        var failures: [String] = []
        let store = PermissionGrantStore.shared // SelfTest guard prevents owner reads/writes.
        let grant = PermissionGrant(toolID: "send_email", duration: .alwaysThisAction)
        store.add(grant)
        defer { store.revoke(id: grant.id) }
        let previousFake = AgentToolExecutor.fakeForTesting
        let previousFire = AgentToolExecutor.fireOverrideForTesting
        let previousPolicy = AgentToolExecutor.policyOverrideForTesting
        AgentToolExecutor.fakeForTesting = nil
        AgentToolExecutor.policyOverrideForTesting = nil
        var effects = 0
        AgentToolExecutor.fireOverrideForTesting = { _, _ in
            effects += 1
            return AgentToolResult(summary: "Fixture send", verification: "Fixture backing")
        }
        defer {
            AgentToolExecutor.fakeForTesting = previousFake
            AgentToolExecutor.fireOverrideForTesting = previousFire
            AgentToolExecutor.policyOverrideForTesting = previousPolicy
        }
        do {
            _ = try await AgentToolExecutor.run("send_email", arguments: ["to": "dana@fixture.invalid", "subject": "Launch", "body": "Confirm by noon."],
                policy: .fromSettings(), promptIfNeeded: true, authority: .user)
        } catch { failures.append("covering standing grant refused: " + error.localizedDescription) }
        if effects != 1 || PermissionGate.shared.pending != nil { failures.append("standing grant did not run exactly once without a new card") }
        // The wording producer must describe this actual permission behavior.
        if !CatchUpOffer.permissionExplanation.contains("already allowed") { failures.append("wording promises a fresh card despite covering standing grant") }
        let rules = RealtimeAgent.plannerRules(manifest: .current(), voice: false)
        if !rules.contains("standing grants") { failures.append("production planner wording promises a new card for every action") }
        print("CATCH_UP_STANDING_GRANT effects=\(effects) new_card=\(PermissionGate.shared.pending != nil)")
        for failure in failures { print("CATCH_UP_PERMISSION_CHECK_FAILED: \(failure)") }
        print(failures.isEmpty ? "CATCH_UP_PERMISSION_OK" : "CATCH_UP_PERMISSION_FAILED")
        return failures
    }
}

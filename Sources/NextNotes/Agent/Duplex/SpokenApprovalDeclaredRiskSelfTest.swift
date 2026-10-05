import Foundation

/// Actual lower Executor/Orchestrator -> real Review/Gate declared-risk controls.
/// No installed browser/privileged capability, voice-owned proposal or model proof.
@MainActor
enum SpokenApprovalDeclaredRiskSelfTest {
    private enum Invalid: Error { case unsafe, context, request, review }
    private static func reached(_ predicate: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while ContinuousClock.now < deadline { if predicate() { return true }; await Task.yield() }
        return predicate()
    }
    static func run() async -> (checks: Int, failures: [String]) {
        let capture = AgentCaptureController.shared, c = VoiceConversationCoordinator.shared
        let gate = PermissionGate.shared
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-voice-delivery",
              AgentSession.shared.fileURL == nil, !capture.isSessionActive,
              c.taskBridge.liveVoiceTasks(owner: c).isEmpty, gate.pending == nil, gate.queuedCount == 0 else {
            return (0, ["declared risk: INVALID current owner"])
        }
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let root = temp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard root.path == root.resolvingSymlinksInPath().standardizedFileURL.path,
              root.deletingLastPathComponent().path == temp.path,
              !FileManager.default.fileExists(atPath: root.path) else { return (0, ["declared risk: INVALID root"]) }
        let oldFake = AgentToolExecutor.fakeForTesting, oldFire = AgentToolExecutor.fireOverrideForTesting
        let oldPolicy = AgentToolExecutor.policyOverrideForTesting
        let owner = SelfTestStoreGuard.take(), grants = PermissionGrantStore.shared.grants
        var created = false, contextInstalled = false, routeInstalled = false, contextRejected = false, currentOperation = false
        var sharedRouteSelections = 0, routeObservations = 0
        var operation: Task<Void, Never>?, registered: String?
        var checks = 0; var failures: [String] = []
        func check(_ value: Bool, _ label: String) { checks += 1; if !value { failures.append("declared risk: " + label) } }
        defer {
            if let registered { AgentToolRegistry.shared.unregister(id: registered) }
            AgentToolExecutor.fakeForTesting = oldFake; AgentToolExecutor.fireOverrideForTesting = oldFire
            AgentToolExecutor.policyOverrideForTesting = oldPolicy
            if routeInstalled { _ = gate.setSharedApprovalRouteObserverForTesting(nil, root: root) }
            if contextInstalled { _ = ToolCallContextBuilder.setMeetingContextForTesting(nil, root: root) }
            if created { try? FileManager.default.removeItem(at: root) }
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false); created = true
            guard ToolCallContextBuilder.setMeetingContextForTesting({ meeting, task in
                guard currentOperation, meeting == nil, task == nil,
                      root.path == root.resolvingSymlinksInPath().standardizedFileURL.path,
                      FileManager.default.fileExists(atPath: root.path) else { contextRejected = true; return nil }
                return ToolCallContext() // Actual session user words retained by Builder.
            }, root: root) else { throw Invalid.context }
            contextInstalled = true
            guard gate.setSharedApprovalRouteObserverForTesting({ selected, _ in
                routeObservations += 1
                if selected { sharedRouteSelections += 1 }
            }, root: root) else { throw Invalid.context }
            routeInstalled = true
            AgentToolExecutor.fakeForTesting = nil; AgentToolExecutor.policyOverrideForTesting = .denyMutations
            for mode in ["destructive-executor", "purchase-policy-only", "privileged-declared-only"] {
                let target = root.appendingPathComponent(mode + ".txt")
                let bytes = Data("Owned declared-risk bytes".utf8); try bytes.write(to: target)
                var fires = 0, returned = false
                let routeBefore = routeObservations, sharedBefore = sharedRouteSelections
                let tool: AgentTool
                let arguments: [String: String]
                let authored: String
                switch mode {
                case "destructive-executor":
                    guard let declared = AgentToolRegistry.shared.tool(named: "filesystem.delete") else { throw Invalid.request }
                    tool = declared; arguments = ["path": target.path]
                    authored = "Delete the owned fixture at " + target.path
                case "purchase-policy-only":
                    guard let declared = AgentToolRegistry.shared.tool(named: "browser.purchase") else { throw Invalid.request }
                    tool = declared
                    // Trusted lower-caller authored scope ONLY: no browser was resolved.
                    // This cannot establish installed browser binding/authorization.
                    arguments = ["amountCents": "3350", "capCents": "4000", "paymentRef": "Owned fixture card",
                                 "_browserBackend": "policy-only", "_authorizedPageURL": "https://owned.invalid/checkout"]
                    authored = "Purchase the owned fixture for 3350 cents, cap 4000 cents, using Owned fixture card."
                default:
                    let name = "owned_privileged_" + UUID().uuidString.replacingOccurrences(of: "-", with: "_")
                    tool = .native(namespace: .computer, name: name, description: "Declared privileged policy fixture.",
                                   risk: .privileged, title: "Privileged fixture")
                    guard AgentToolRegistry.shared.tool(named: tool.id) == nil else { throw Invalid.unsafe }
                    AgentToolRegistry.shared.register(tool); registered = tool.id
                    arguments = [:]; authored = "Run the declared privileged fixture."
                }
                AgentSession.shared.recordUser(authored, source: .voice)
                currentOperation = true
                AgentToolExecutor.fireOverrideForTesting = { actual, actualArguments in
                    guard actual.id == tool.id, actualArguments == arguments else { throw Invalid.unsafe }
                    fires += 1; return AgentToolResult(summary: "Controlled declared-risk backing returned.")
                }
                operation = Task { @MainActor in
                    defer { returned = true }
                    do {
                        if mode == "purchase-policy-only" {
                            _ = try await ActionOrchestrator.shared.execute(
                                intent: ActionIntent(source: .agent, authority: .user, verb: tool.id,
                                                     arguments: arguments, risk: tool.risk, confidence: 1),
                                tool: tool, title: "Owned purchase policy", routing: ActionRouting(),
                                policy: .denyMutations, promptIfNeeded: true,
                                fire: { prepared in
                                    guard prepared.executionPlan.arguments == arguments else { throw Invalid.unsafe }
                                    fires += 1; return AgentToolResult(summary: "Controlled purchase policy backing returned.")
                                })
                        } else {
                            _ = try await AgentToolExecutor.run(tool.id, arguments: arguments,
                                policy: .denyMutations, promptIfNeeded: true)
                        }
                    } catch { /* A card denial is the expected real lower-caller outcome. */ }
                }
                guard await reached({ gate.pending?.toolID == tool.id || returned }) else { throw Invalid.request }
                guard let request = gate.pending, request.toolID == tool.id,
                      let review = ToolCallReviewStore.shared.review(id: request.id), !contextRejected else { throw Invalid.context }
                check(request.risk == tool.risk && request.taskID == nil && fires == 0 && !returned,
                      "RC01 actual declared-risk request precedes backing (\(mode))")
                check(review.id == request.id && review.toolID == tool.id && review.risk == tool.risk,
                      "RC02 real inspector/card retains declared risk (\(mode))")
                let preview = SpokenApproval.prompt(for: request, review: review)
                check(!preview.voiceMayApprove && preview.refusal != nil,
                      "RC03 actual request preview refuses spoken high-risk policy (\(mode))")
                check(PermissionGrantStore.shared.grants == grants && gate.pending?.id == request.id,
                      "RC04 policy inspection never grants or resolves actual request (\(mode))")
                check(routeObservations == routeBefore + 1 && sharedRouteSelections == sharedBefore,
                      "RF01 generic real Gate request avoids shared voice-owner route (\(mode))")
                // Real card denial joins the SAME lower public operation; no seeded
                // approval/yes receipt, native hold or second diagnostic waiter Task.
                guard gate.respond(id: request.id, approved: false) else { throw Invalid.request }
                await operation?.value; operation = nil; currentOperation = false
                check(returned && fires == 0 && gate.pending == nil && gate.queuedCount == 0,
                      "RC05 actual same-request denial joins without backing (\(mode))")
                let filePreserved = try Data(contentsOf: target) == bytes
                check(filePreserved && PermissionGrantStore.shared.grants == grants,
                      "RC06 declared-risk flow preserves target/grants (\(mode))")
                ToolCallReviewStore.shared.remove(id: request.id)
                if let registered { AgentToolRegistry.shared.unregister(id: registered) }; registered = nil
                print("SPOKEN_DECLARED_RISK mode=\(mode) sameGate=true fires=\(fires) realPlanner=false browserBinding=false installedPrivileged=false voiceAuthority=false")
            }
            // Separate actual generic request: an unbound spoken denial cannot
            // consume a visible card without this request's heard-output authority.
            // Card denial still joins the unchanged real lower operation in both versions.
            guard let genericTool = AgentToolRegistry.shared.tool(named: "filesystem.delete") else { throw Invalid.request }
            let genericTarget = root.appendingPathComponent("generic-unbound.txt")
            let genericBytes = Data("Owned generic request bytes".utf8)
            try genericBytes.write(to: genericTarget)
            var genericFires = 0, genericReturned = false
            let genericRouteBefore = routeObservations, genericSharedBefore = sharedRouteSelections
            AgentSession.shared.recordUser("Delete the owned generic fixture at " + genericTarget.path, source: .voice)
            currentOperation = true
            AgentToolExecutor.fireOverrideForTesting = { actual, arguments in
                guard actual.id == genericTool.id, arguments == ["path": genericTarget.path] else { throw Invalid.unsafe }
                genericFires += 1; return AgentToolResult(summary: "Controlled generic backing returned.")
            }
            operation = Task { @MainActor in
                defer { genericReturned = true }
                do {
                    _ = try await AgentToolExecutor.run(genericTool.id, arguments: ["path": genericTarget.path],
                        policy: .denyMutations, promptIfNeeded: true)
                } catch { /* Both versions end with an actual denial. */ }
            }
            guard await reached({ gate.pending?.toolID == genericTool.id || genericReturned }),
                  let genericRequest = gate.pending,
                  let genericReview = ToolCallReviewStore.shared.review(id: genericRequest.id), !contextRejected else { throw Invalid.context }
            check(genericRequest.taskID == nil && genericReview.id == genericRequest.id
                  && genericFires == 0 && !genericReturned, "RG01 real generic request/card qualifies before backing")
            check(routeObservations == genericRouteBefore + 1 && sharedRouteSelections == genericSharedBefore,
                  "RG02 generic request avoids shared voice owner route")
            let genericVoiceConsumed = gate.respond(id: genericRequest.id, approved: false, via: .voice)
            check(!genericVoiceConsumed, "RG03 unbound spoken response cannot consume actual card")
            check(gate.pending?.id == genericRequest.id && !genericReturned,
                  "RG04 exact generic card remains for its card decision")
            check(genericFires == 0 && PermissionGrantStore.shared.grants == grants,
                  "RG05 generic spoken denial grants no authority/backing")
            if gate.pending?.id == genericRequest.id {
                guard gate.respond(id: genericRequest.id, approved: false, via: .card) else { throw Invalid.request }
            }
            await operation?.value; operation = nil; currentOperation = false
            check(genericReturned && genericFires == 0 && gate.pending == nil && gate.queuedCount == 0,
                  "RG06 actual generic card denial joins same operation")
            let genericPreserved = try Data(contentsOf: genericTarget) == genericBytes
            check(genericPreserved && PermissionGrantStore.shared.grants == grants,
                  "RG07 generic caller preserves target/grants")
            ToolCallReviewStore.shared.remove(id: genericRequest.id)
            check(!contextRejected, "RC07 exact lower operation/root context stayed isolated")
            check(SelfTestStoreGuard.diff(owner, SelfTestStoreGuard.take()).isEmpty, "RC08 owner store/default invariant")
        } catch {
            failures.append("declared risk: INVALID \(error)")
            operation?.cancel(); gate.cancelPending()
            await operation?.value; operation = nil; currentOperation = false
        }
        return (checks, failures)
    }
}

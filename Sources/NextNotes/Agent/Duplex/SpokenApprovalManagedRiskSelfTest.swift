import Foundation

/// Actual managed voice intake -> SAME worker Task -> existing declared-risk
/// Executor/Orchestrator -> Gate -> Scheduler/current playback -> voice refusal.
/// The worker's lower call is scripted, not a planner capability advertisement.
@MainActor
enum SpokenApprovalManagedRiskSelfTest {
    private enum Invalid: Error { case unsafe, context, request, worker }
    private static func reached(_ predicate: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while ContinuousClock.now < deadline { if predicate() { return true }; await Task.yield() }
        return predicate()
    }
    static func run(recorder: RecordingSpeechBacking) async -> (checks: Int, failures: [String]) {
        let c = VoiceConversationCoordinator.shared, capture = AgentCaptureController.shared
        let gate = PermissionGate.shared, synth = AgentSpeechSynthesizer.shared
        let playback = VoicePlaybackDelivery.shared
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-voice-delivery",
              AgentSession.shared.fileURL == nil, !capture.isSessionActive,
              c.taskBridge.liveVoiceTasks(owner: c).isEmpty, gate.pending == nil, gate.queuedCount == 0 else {
            return (0, ["managed risk: INVALID prior owner"])
        }
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let root = temp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard root.path == root.resolvingSymlinksInPath().standardizedFileURL.path,
              root.deletingLastPathComponent().path == temp.path,
              !FileManager.default.fileExists(atPath: root.path) else { return (0, ["managed risk: INVALID root"]) }
        let oldBridge = c.taskBridgeOverrideForTesting, oldRemember = c.rememberExplicit
        let oldFake = AgentToolExecutor.fakeForTesting, oldFire = AgentToolExecutor.fireOverrideForTesting
        let oldPolicy = AgentToolExecutor.policyOverrideForTesting
        let owner = SelfTestStoreGuard.take(), grants = PermissionGrantStore.shared.grants
        var created = false, installedContext = false, contextRejected = false
        func currentCapture() -> VoiceWorkerTestCapture? {
            guard let raw = c.taskBridge.cachedTasks.first(where: { $0.source == "voice" })?.id,
                  let id = UUID(uuidString: raw) else { return nil }
            return c.captureVoiceWorkerForTesting(id: id)
        }
        var currentManager: AgentTaskManager?, owned: Task<Void, Never>?, registered: String?
        var checks = 0; var failures: [String] = []
        func check(_ value: Bool, _ label: String) { checks += 1; if !value { failures.append("managed risk: " + label) } }
        func input(_ text: String) async -> AgentTurn {
            RealtimeAgent.shared.userSpeechStarted(); RealtimeAgent.shared.userSpeechEnded()
            return await RealtimeAgent.shared.handle(text, source: .voice)
        }
        defer {
            c.resetForTesting(); _ = c.installTaskBridgeForTesting(oldBridge); c.rememberExplicit = oldRemember
            AgentToolExecutor.fakeForTesting = oldFake; AgentToolExecutor.fireOverrideForTesting = oldFire
            AgentToolExecutor.policyOverrideForTesting = oldPolicy; _ = playback.installOutputForTesting(nil)
            if let registered { AgentToolRegistry.shared.unregister(id: registered) }
            if installedContext { _ = ToolCallContextBuilder.setMeetingContextForTesting(nil, root: root) }
            if created { try? FileManager.default.removeItem(at: root) }
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false); created = true
            guard ToolCallContextBuilder.setMeetingContextForTesting({ meeting, task in
                guard meeting == nil, let task, currentManager?.task(id: task)?.source == "voice",
                      root.path == root.resolvingSymlinksInPath().standardizedFileURL.path,
                      FileManager.default.fileExists(atPath: root.path) else { contextRejected = true; return nil }
                return ToolCallContext()
            }, root: root) else { throw Invalid.context }
            installedContext = true
            AgentToolExecutor.fakeForTesting = nil; AgentToolExecutor.policyOverrideForTesting = .denyMutations
            for mode in ["destructive-executor", "purchase-policy-only", "privileged-declared-only"] {
                let start = checks
                let directory = root.appendingPathComponent(mode, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                let target = directory.appendingPathComponent("owned.txt")
                let bytes = Data("Owned managed-risk bytes".utf8); try bytes.write(to: target)
                let sql = TaskStore(root: directory); defer { sql.close() }
                let store = AgentTaskStore(fileURL: directory.appendingPathComponent("agent-tasks.json"), mirror: sql)
                guard store.allowsHarnessPersistence, store.save([]).primaryCommitted else { throw Invalid.unsafe }
                let manager = AgentTaskManager(store: store), bridge = TaskBridge(manager: manager)
                currentManager = manager
                guard let output = OutputScheduler.isolatedForTesting(bridge), c.installTaskBridgeForTesting(bridge),
                      playback.installOutputForTesting(output) else { throw Invalid.unsafe }
                let tool: AgentTool; let arguments: [String: String]; let authored: String
                switch mode {
                case "destructive-executor":
                    guard let declared = AgentToolRegistry.shared.tool(named: "filesystem.delete") else { throw Invalid.request }
                    tool = declared; arguments = ["path": target.path]; authored = "Delete the owned fixture at " + target.path
                case "purchase-policy-only":
                    guard let declared = AgentToolRegistry.shared.tool(named: "browser.purchase") else { throw Invalid.request }
                    tool = declared
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
                var fires = 0
                AgentToolExecutor.fireOverrideForTesting = { actual, actualArguments in
                    guard actual.id == tool.id, actualArguments == arguments else { throw Invalid.unsafe }
                    fires += 1; return AgentToolResult(summary: "Controlled risk backing returned.")
                }
                c.rememberExplicit = { _ in }; c.prewarmObserverForTesting = {}; c.workerProviderForTesting = nil
                c.streamForTesting = { _, messages in
                    let value = messages.last?.content.hasSuffix("Latest user speech:\n" + authored) == true
                        ? "<use_tools/>" : "<answer/>I heard that."
                    return AsyncThrowingStream { $0.yield(value); $0.finish() }
                }
                c.workerForTesting = { work in
                    let callerGeneration = c.captureVoiceWorkerForTesting(id: work.id)?.worker.currentGeneration
                    let callerRevision = work.revision
                    do {
                        if mode == "purchase-policy-only" {
                            _ = try await ActionOrchestrator.shared.execute(
                                intent: ActionIntent(source: .agent, authority: .user, verb: tool.id,
                                    arguments: arguments, risk: tool.risk), tool: tool, title: "Owned purchase policy",
                                routing: ActionRouting(taskID: work.id.uuidString), policy: .denyMutations,
                                promptIfNeeded: true, voiceApprovalBridge: c.captureVoiceWorkerForTesting(id: work.id)?.worker.voiceTaskBridge,
                                voiceApprovalGeneration: callerGeneration, voiceApprovalRevision: callerRevision, fire: { prepared in
                                    guard prepared.executionPlan.arguments == arguments else { throw Invalid.unsafe }
                                    fires += 1; return AgentToolResult(summary: "Controlled risk backing returned.")
                                })
                        } else {
                            _ = try await AgentToolExecutor.run(tool.id, arguments: arguments, policy: .denyMutations,
                                taskID: work.id.uuidString, promptIfNeeded: true,
                                voiceApprovalBridge: c.captureVoiceWorkerForTesting(id: work.id)?.worker.voiceTaskBridge,
                                voiceApprovalGeneration: callerGeneration, voiceApprovalRevision: callerRevision)
                        }
                        return "The controlled operation returned."
                    } catch { return "The controlled operation did not run." }
                }
                await capture.beginSession(captureAudio: false)
                let intake = await input(authored); owned = currentCapture()?.task
                guard let job = currentCapture(), let task = owned, let session = capture.sessionID,
                      await reached({ gate.pending?.taskID == job.id.uuidString }), let request = gate.pending,
                      let review = ToolCallReviewStore.shared.review(id: request.id), !contextRejected else { throw Invalid.worker }
                check(intake.reply == "I'm on it." && c.taskBridge.cachedTasks.filter { $0.source == "voice" }.count == 1 && !task.isCancelled,
                      "MC01 actual managed intake/SAME held lower-call worker (\(mode))")
                check(request.toolID == tool.id && request.risk == tool.risk && review.id == request.id
                    && review.toolID == tool.id && fires == 0, "MC02 real declared-risk Gate/review precedes backing (\(mode))")
                let row = try sql.load().first
                let sameSaved: Bool = if case .permission(let saved, _, _) = row?.pendingInteraction { saved == request } else { false }
                check(row?.status == .waitingForPermission && sameSaved,
                      "MF01 actual current managed-risk primary proposal (\(mode))")
                drain(synth, recorder); recorder.reset(); output.setNowForTesting(Date().addingTimeInterval(2))
                let flushed = output.flush(userHasFloor: false)
                check(flushed && output.activeOutputID != nil && bridge.pendingApproval(sessionID: session)?.request == request,
                      "MF02 same risk prompt/current speak-owned output (\(mode))")
                drain(synth, recorder)
                let spoken = bridge.pendingApproval(sessionID: session)
                check(spoken?.heardStart == true && spoken?.heardFully == true && spoken?.prompt.voiceMayApprove == false,
                      "MF03 actual same-current risk playback refuses voice approval (\(mode))")
                let answer = await input("Yes.")
                check(gate.pending?.id == request.id && fires == 0 && PermissionGrantStore.shared.grants == grants,
                      "MC03 heard yes never grants/releases declared high risk (\(mode))")
                check(answer.reply == "That one needs your OK on screen.",
                      "MF04 actual voice consumer returns exact screen-only refusal (\(mode))")
                guard gate.respond(id: request.id, approved: false) else { throw Invalid.request }
                await task.value; owned = nil
                check(gate.pending == nil && fires == 0 && gate.queuedCount == 0,
                      "MC04 same real card denial joins current worker without effect (\(mode))")
                check(try Data(contentsOf: target) == bytes, "MC05 controlled target unchanged (\(mode))")
                drain(synth, recorder)
                if capture.isSessionActive { await capture.endSession(source: .done) }
                c.resetForTesting(); _ = c.installTaskBridgeForTesting(nil); _ = playback.installOutputForTesting(nil)
                output.setNowForTesting(nil); ToolCallReviewStore.shared.remove(id: request.id)
                check(PermissionGrantStore.shared.grants == grants && c.barrierWaiterCountForTesting == 0,
                      "MC06 same current worker/Gate/grant cleanup (\(mode))")
                if let registered { AgentToolRegistry.shared.unregister(id: registered) }; registered = nil
                currentManager = nil
                print("SPOKEN_MANAGED_RISK mode=\(mode) checks=\(checks-start) fires=\(fires) realPlanner=false browserBinding=false installedPrivileged=false physical=false")
            }
            check(!contextRejected, "MC07 current request/task/temp context stayed isolated")
            check(SelfTestStoreGuard.diff(owner, SelfTestStoreGuard.take()).isEmpty, "MC08 owner store/default invariant")
        } catch {
            failures.append("managed risk: INVALID \(error)")
            for row in c.taskBridge.cachedTasks where row.source == "voice" { if let id = UUID(uuidString: row.id) { _ = c.cancel(id) } }; gate.cancelPending()
            if let owned { await owned.value }
            if capture.isSessionActive { await capture.endSession(source: .done) }
        }
        return (checks, failures)
    }
    private static func drain(_ synth: AgentSpeechSynthesizer, _ recorder: RecordingSpeechBacking) {
        var bound = 32
        while (synth.voiceLifecycleSnapshot.hasClause || synth.pendingClauseCount > 0) && bound > 0 {
            synth.notifyTestingFirstAudio(token: synth.currentPlaybackToken)
            recorder.finishNaturallyForTesting(); synth.notifyTestingAudioFinished(token: synth.currentPlaybackToken)
            bound -= 1
        }
    }
}

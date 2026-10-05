import Foundation

/// Scripted models, real worker/runner/approval/final validity. Only external effects are replaced.
enum VoiceDuplexWorkSelfTest {
    @MainActor
    static func run() async -> Bool {
        // Reuse the first fixture's captured constructor root until the original
        // duplex caller and its retained Tasks have drained.
        var duplexPassed = false
        let typed = await TypedDuringWorkSelfTest.run { root, bridge in
            duplexPassed = await runOriginalDuplex(root: root, bridge: bridge)
            return duplexPassed
        }
        print("TYPED_DURING_WORK_CHECKS count=\(typed.checks) problems=\(typed.failures.count)")
        for failure in typed.failures { print("VOICE_DUPLEX_WORK_WRONG: \(failure)") }
        let passed = duplexPassed && typed.failures.isEmpty
        print(passed ? "VOICE_DUPLEX_WORK_OK" : "VOICE_DUPLEX_WORK_FAILED")
        return passed
    }

    @MainActor
    private static func runOriginalDuplex(root: URL, bridge: TaskBridge) async -> Bool {
        let shadow = VoiceSession.shared
        shadow.resetDiagnosticsForTesting()
        let conversation = VoiceConversationCoordinator.shared
        let capture = AgentCaptureController.shared
        let agent = RealtimeAgent.shared
        let speech = AgentSpeechSynthesizer.shared
        let probe = DuplexWorkProbe()
        var precedingTaskIDs = Set<String>()
        var actualManagedWork: VoiceConversationWork?
        func scopedVoiceRows() -> [AgentTask] {
            conversation.taskBridge.cachedTasks.filter { $0.source == "voice" && !precedingTaskIDs.contains($0.id) }
        }
        func currentCapture() -> VoiceWorkerTestCapture? {
            guard let raw = scopedVoiceRows().first?.id, let id = UUID(uuidString: raw) else { return nil }
            return conversation.captureVoiceWorkerForTesting(id: id)
        }
        var failures: [String] = []
        let oldBridge = conversation.taskBridgeOverrideForTesting
        let oldRemember = conversation.rememberExplicit
        var bridgeInstalled = false, contextInstalled = false, activityInstalled = false, reviewInstalled = false
        var fireProjectionInstalled = false
        defer {
            if fireProjectionInstalled { _ = AgentToolExecutor.finishFireProjectionForTesting(root: root) }
            if reviewInstalled { _ = ToolCallContextBuilder.setMeetingContextForTesting(nil, root: root) }
            if activityInstalled { NextMemory.finishActivityContextForTesting(root: root) }
            if contextInstalled { VoiceCapabilitySnapshot.finishContextForTesting(root: root) }
            if bridgeInstalled { _ = conversation.installTaskBridgeForTesting(oldBridge) }
            conversation.rememberExplicit = oldRemember
        }
        // Inspect loaded owners only; no default TaskBridge/Manager constructor is touched.
        guard DictionaryStore.capturedRootMatchesForTesting(root) == true,
              oldBridge?.liveVoiceTasks(owner: conversation).isEmpty != false,
              AgentTaskManager.sharedIfLoaded?.liveVoiceTasks(coordinator: conversation).isEmpty != false,
              !conversation.inputPending,
              conversation.installTaskBridgeForTesting(bridge) else {
            print("VOICE_DUPLEX_WORK_WRONG: INPUT_INVALID A7 context admission")
            return false
        }
        bridgeInstalled = true
        guard VoiceCapabilitySnapshot.installContextForTesting(root: root, bridge: bridge,
                inputs: RealtimeAgentToolLoopSelfTest.allEnabledFixture()) else {
            print("VOICE_DUPLEX_WORK_WRONG: INPUT_INVALID A7 capability admission")
            return false
        }
        contextInstalled = true
        guard NextMemory.installActivityContextForTesting(root: root, bridge: bridge) else {
            print("VOICE_DUPLEX_WORK_WRONG: INPUT_INVALID A7 activity admission")
            return false
        }
        activityInstalled = true
        guard ToolCallContextBuilder.setMeetingContextForTesting({ meeting, task in
                guard meeting == nil, task == nil || bridge.cachedTasks.contains(where: { $0.id == task && $0.source == "voice" }),
                      VoiceCapabilitySnapshot.contextIsAdmittedForTesting(root: root, bridge: bridge) else { return nil }
                return ToolCallContext()
              }, root: root) else {
            print("VOICE_DUPLEX_WORK_WRONG: INPUT_INVALID A7 review admission")
            return false
        }
        reviewInstalled = true; conversation.rememberExplicit = { _ in }
        guard AgentToolExecutor.installFireProjectionForTesting(root: root, bridge: bridge) else {
            print("VOICE_DUPLEX_WORK_WRONG: INPUT_INVALID A7 executor projection admission")
            return false
        }
        fireProjectionInstalled = true
        func check(_ good: Bool, _ label: String) { if !good { failures.append(label) } }
        let oldWhole = PlannerBackends.wholeTurnOverrideForTesting
        PlannerBackends.wholeTurnOverrideForTesting = nil
        let oldInputs = AgentCapabilityManifestBuilder.inputsOverrideForTesting
        let oldFake = AgentToolExecutor.fakeForTesting
        let oldFire = AgentToolExecutor.fireOverrideForTesting
        let oldPolicy = AgentToolExecutor.policyOverrideForTesting
        AgentToolExecutor.policyOverrideForTesting = .denyMutations
        AgentCapabilityManifestBuilder.inputsOverrideForTesting = RealtimeAgentToolLoopSelfTest.allEnabledFixture()
        AgentToolExecutor.fakeForTesting = nil
        speech.useTestingBacking(RecordingSpeechBacking())
        AgentToolExecutor.fireOverrideForTesting = { tool, arguments in
            await probe.recordFire(tool.id, key: arguments["key"], revision: actualManagedWork?.revision ?? -1)
            return AgentToolResult(summary: tool.risk <= .read ? "The frontmost app is Fixture." : "The key was pressed.")
        }
        let approveReads = Task { @MainActor in
            while !Task.isCancelled {
                if let request = PermissionGate.shared.pending, request.risk <= .read {
                    _ = PermissionGate.shared.respond(id: request.id, approved: true)
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        defer {
            approveReads.cancel()
            conversation.resetForTesting(); precedingTaskIDs = Set(conversation.taskBridge.cachedTasks.map(\.id))
            PlannerBackends.wholeTurnOverrideForTesting = oldWhole
            AgentCapabilityManifestBuilder.inputsOverrideForTesting = oldInputs
            AgentToolExecutor.fakeForTesting = oldFake
            AgentToolExecutor.fireOverrideForTesting = oldFire
            AgentToolExecutor.policyOverrideForTesting = oldPolicy
            speech.restoreSystemBacking()
        }
        await capture.endSession(source: .done)
        AgentSession.shared.forgetAllConversations()
        conversation.resetForTesting(); precedingTaskIDs = Set(conversation.taskBridge.cachedTasks.map(\.id))
        IslandOwnership.resetCountersForTesting()
        await capture.beginSession(captureAudio: false)
        check(capture.isSessionActive && capture.sessionID == shadow.state.sessionID && shadow.state.phase == .open,
              "A7 INPUT_INVALID actual capture/reducer session not open")
        conversation.prewarmObserverForTesting = {}
        conversation.workerProviderForTesting = DuplexWorkProvider(probe: probe)
        conversation.streamForTesting = { _, messages in
            if messages.last?.content.hasSuffix("Check the frontmost app and its running sessions, then press escape in the front window.") == true {
                return AsyncThrowingStream { $0.yield("<use_tools/>"); $0.finish() }
            }
            return await probe.frontend()
        }
        let usageLog = UsageLog.shared // Same existing confined SelfTest log.
        let usageBefore = Set(usageLog.load().map(\.id))
        let objectiveStarted = ContinuousClock.now
        _ = await speak("Check the frontmost app and its running sessions, then press escape in the front window.")
        let initialManaged = currentCapture(); actualManagedWork = initialManaged?.work
        print("VOICE_DUPLEX_WORK_SETUP: jobs=\(scopedVoiceRows().count) status=\(scopedVoiceRows().first?.status.rawValue ?? "absent")")
        check(await eventually { await probe.rounds >= 1 }, "real worker never began round one")

        // Partial envelopes still own input. Planning and the real read must nevertheless run.
        let a7 = DuplexIslandSampler(workerIDs: { scopedVoiceRows().map(\.id) })
        let question = Task { @MainActor in await measuredHandle("What is a haiku?", probe: probe) }
        let frontendEntered = await eventually { await probe.frontendCount >= 1 }
        check(frontendEntered, "side frontend never entered")
        a7.frontendOpen = frontendEntered; a7.sample()
        let a7Sampling = Task { @MainActor in
            while !Task.isCancelled {
                a7.sample()
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        await probe.yield("<ans")
        await probe.release(1)
        check(await eventually(milliseconds: 200) { await probe.rounds >= 3 },
              "A1 planning/read stalled on an unclassified side question")
        check(conversation.inputPending, "partial answer envelope released input")
        let overlap = await probe.startsInsideFrontend()
        check(overlap >= 2, "A1 fewer than two worker round starts inside frontend generation")
        let readFired = await probe.fires.contains { $0.tool == "computer.active_app" }
        check(readFired, "actual read did not reach post-validity fire during pending input")
        a7.sample() // Cached non-vacuity at the original actual-read landmark.
        await probe.yield("wer/>A haiku is a short poem.")
        check(await eventually(milliseconds: 200) { !conversation.inputPending },
              "A3 parsed answer route stayed held until the answer stream finished")
        print("VOICE_DUPLEX_WORK_OVERLAP: rounds=\(await probe.rounds) input_pending=\(conversation.inputPending)")
        await probe.finishFrontend()
        a7.frontendOpen = false; a7Sampling.cancel(); await a7Sampling.value
        _ = await question.value
        check(a7.samples > 0 && a7.samplesWithSteps > 0,
              "A7 INPUT_INVALID no open frontend samples with actual worker steps")
        check(a7.workerDriven == 0, "A7 worker drove the island during conversation")
        check(IslandOwnership.workerAttemptTotal == 0, "A7 workers attempted island writes")
        print("VOICE_DUPLEX_WORK_A7 samples=\(a7.samples) withSteps=\(a7.samplesWithSteps) workerDriven=\(a7.workerDriven) workerAttempts=\(IslandOwnership.workerAttemptTotal) cadenceMs=20")
        await probe.release(3)
        check(await eventually { PermissionGate.shared.pending?.toolID == "computer.press_key" },
              "real write did not reach its approval card")

        // Approve the old call while correction is still partial. The action must wait,
        // then recheck the old revision before fire and replan against the new words.
        let originalCorrectionRequestID = PermissionGate.shared.pending?.id
        let correction = Task { @MainActor in
            let result = await measuredHandle("Actually use tab instead.", probe: probe)
            print("DUPLEX_APPROVAL_CORRECTION stage=returned parsedAck=\(result.reply == "Got it. I'll use that correction.") approvalAck=\(result.reply == "Okay, I'll change that and check with you again.") revision=\(actualManagedWork?.revision ?? -1) inputPending=\(conversation.inputPending) originalRequestCurrent=\(PermissionGate.shared.pending?.id == originalCorrectionRequestID)")
            return result
        }
        let correctionClassified = await eventually {
            if await probe.frontendCount >= 2 { return true }
            return actualManagedWork?.revision == 1 && !conversation.inputPending
                && PermissionGate.shared.pending?.id != originalCorrectionRequestID
        }
        check(correctionClassified, "correction entered frontend or exact approval amendment route")
        let fastApprovalAmend = actualManagedWork?.revision == 1 && !conversation.inputPending
            && PermissionGate.shared.pending?.id != originalCorrectionRequestID
        if fastApprovalAmend {
            let changed = await correction.value
            check(changed.reply == "Okay, I'll change that and check with you again.",
                  "actual current approval amendment has truthful immediate feedback")
            check(originalCorrectionRequestID.map { !PermissionGate.shared.respond(id: $0, approved: true) } == true,
                  "exact obsolete approval still released the prior effect")
            check(await probe.fires.allSatisfy { $0.key == nil }, "fast amendment fired a key before fresh approval")
        } else {
            // The original pre-approval implementation still takes this real
            // model-partial route. Keep its existing unclassified safety checks.
            await probe.yield("<revise id=\"")
            if let request = PermissionGate.shared.pending {
                check(PermissionGate.shared.respond(id: request.id, approved: true), "valid old key approval refused")
            }
            try? await Task.sleep(for: .milliseconds(80))
            check(await probe.fires.allSatisfy { $0.key == nil }, "A2 stale key fired during unclassified correction")
            await probe.yield("1\"/>")
            check(await eventually(milliseconds: 200) { actualManagedWork?.revision == 1 },
                  "parsed control envelope did not apply before its stream finished")
            await probe.finishFrontend()
            _ = await correction.value
        }
        check(actualManagedWork?.revision == 1, "real correction did not revise existing work")
        check(await eventually { PermissionGate.shared.pending?.toolID == "computer.press_key" },
              "corrected objective did not replan to another approval")
        if let request = PermissionGate.shared.pending {
            check(PermissionGate.shared.respond(id: request.id, approved: true), "corrected key approval refused")
        }
        check(await eventually { scopedVoiceRows().first?.status == .completed }, "A5 real worker did not finish")
        check(scopedVoiceRows().first?.result == "Done with the duplex check.", "A5 worker finished with an incorrect result")
        check(objectiveStarted.duration(to: .now) <= .seconds(10), "A5 objective exceeded ten seconds")
        let writes = await probe.fires.filter { $0.key != nil }
        check(writes.count == 1 && writes.first?.key == "tab" && writes.first?.revision == 1,
              "final fire was not exactly the approved current-revision tab call")
        if let task = initialManaged?.task { await task.value }
        usageLog.flush()
        let managedUsage = usageLog.load().filter { !usageBefore.contains($0.id)
            && $0.modelID == "Voice Task Usage Fixture" }
        let actualRounds = await probe.rounds
        let managedID = initialManaged?.id.uuidString
        check(managedUsage.count == actualRounds && actualRounds >= 3
            && managedID != nil && managedUsage.allSatisfy { $0.workID?.uuidString == managedID
                && $0.promptTokens == 13 && $0.completionTokens == 5 },
            "U06 actual voice worker passes/known counts qualify")
        check(managedUsage.allSatisfy { $0.taskID == managedID },
            "U07 saved voice planner passes lost exact managed task ID")
        if let managedID {
            let summary = UsageSummary.task(rows: managedUsage, taskID: managedID)
            let unrelatedUsage = UsageSummary.task(rows: managedUsage, taskID: UUID().uuidString)
            check(unrelatedUsage.passes == 0 && unrelatedUsage.promptTokens == nil
                && unrelatedUsage.completionTokens == nil && unrelatedUsage.totalTokens == nil
                && unrelatedUsage.countsEstimated == nil && unrelatedUsage.cost == nil
                && summary.passes == actualRounds && summary.promptTokens == actualRounds * 13
                && summary.completionTokens == actualRounds * 5 && summary.totalTokens == actualRounds * 18
                && summary.cachedTokens == actualRounds * 3 && summary.reasoningTokens == actualRounds * 2
                && summary.countsEstimated == false && summary.cost == nil, "U08 actual voice task token projection missing or mixed")
            let report = UsageReport.lines(for: managedUsage, files: 1, since: .distantPast, feature: "task.")
            check(report.contains { $0.hasPrefix("USAGE_TASK_ROW task=" + managedID + " ") },
                "U09 existing task report omitted actual voice worker rows")
        } else { check(false, "U08 actual voice task identity absent"); check(false, "U09 actual voice report identity absent") }
        if let encoded = try? JSONEncoder().encode(managedUsage) {
            let text = String(decoding: encoded, as: UTF8.self)
            check(["Check the frontmost app and its running sessions, then press escape in the front window.",
                "Actually use tab instead.", "Done with the duplex check."].allSatisfy { !text.contains($0) },
                "U10 voice objective/correction/result leaked into usage log")
        } else { check(false, "U10 actual voice usage rows could not be encoded") }
        print("VOICE_TASK_USAGE_TRACE passes=\(managedUsage.count) actualRounds=\(actualRounds) attributed=\(managedUsage.filter { $0.taskID != nil }.count) costUnavailable=true")
        print("VOICE_DUPLEX_WORK_EFFECTS: \(writes.map { "\($0.key ?? "none")@\($0.revision)" }.joined(separator: ","))")

        // A4 runs the original actual planner with a frontend that yields nothing.
        conversation.resetForTesting(); precedingTaskIDs = Set(conversation.taskBridge.cachedTasks.map(\.id))
        let failureProbe = DuplexWorkProbe(readsOnly: true)
        conversation.prewarmObserverForTesting = {}
        conversation.workerProviderForTesting = DuplexWorkProvider(probe: failureProbe)
        conversation.streamForTesting = { _, messages in
            if messages.last?.content.hasSuffix("Inspect the frontmost app and its running sessions.") == true {
                return AsyncThrowingStream { $0.yield("<use_tools/>"); $0.finish() }
            }
            return await failureProbe.frontend()
        }
        _ = await speak("Inspect the frontmost app and its running sessions.")
        let failureManaged = currentCapture(); actualManagedWork = failureManaged?.work
        check(await eventually { await failureProbe.rounds == 1 }, "A4 actual worker never parked")
        conversation.responseDeadlineForTesting = .milliseconds(150)
        let failed = Task { @MainActor in await measuredHandle("Tell me a little poem.", probe: failureProbe) }
        check(await eventually { await failureProbe.frontendCount == 1 }, "A4 empty frontend never entered")
        _ = await failed.value
        let failedAt = ContinuousClock.now
        check(conversation.lastFailure?.code == .deadline, "A4 empty frontend did not fail at its deadline")
        check(!conversation.inputPending && conversation.effectHoldEpoch != nil, "A4 failure lost the effect hold")
        await failureProbe.release(1)
        check(await eventually(milliseconds: 200) { await failureProbe.rounds >= 2 },
              "A4 real planner did not progress within 200 ms after frontend failure")
        let resumed = await failureProbe.roundStarts.dropFirst().first
        check(resumed.map { failedAt.duration(to: $0) <= .milliseconds(200) } == true,
              "A4 measured round start exceeded 200 ms")
        check(await eventually { scopedVoiceRows().first?.status == .completed }, "A4 read worker did not complete")
        check(scopedVoiceRows().first?.result == "The read finished.", "A4 read worker finished with an incorrect result")
        check(conversation.effectHoldEpoch != nil, "A4 read completion released failed input effect hold")
        if let task = failureManaged?.task { await task.value }
        let normalTimes = await probe.handleLatencies
        let failureTimes = await failureProbe.handleLatencies
        let handleTimes = normalTimes + failureTimes
        check(handleTimes.count == (fastApprovalAmend ? 2 : 3) && handleTimes.allSatisfy { $0 <= 50 }, "A3 handle→stream exceeded 50 ms or was absent")
        print("VOICE_DUPLEX_WORK_TIMING: handle_ms=\(handleTimes) overlap_starts=\(overlap) failure_resume_ms=\(resumed.map { ModelPassRecorder.milliseconds(failedAt.duration(to: $0)) } ?? -1)")

        // Independent A2 model-partial coverage. This meaningful correction is
        // outside the precise deterministic approval phrase gate; no gate is disabled.
        conversation.resetForTesting(); precedingTaskIDs = Set(conversation.taskBridge.cachedTasks.map(\.id))
        let partialProbe = DuplexWorkProbe()
        conversation.prewarmObserverForTesting = {}
        conversation.workerProviderForTesting = DuplexWorkProvider(probe: partialProbe)
        conversation.streamForTesting = { _, messages in
            if messages.last?.content.hasSuffix("Check the frontmost app and its running sessions, then press escape in the front window.") == true {
                return AsyncThrowingStream { $0.yield("<use_tools/>"); $0.finish() }
            }
            return await partialProbe.frontend()
        }
        AgentToolExecutor.fireOverrideForTesting = { tool, arguments in
            await partialProbe.recordFire(tool.id, key: arguments["key"], revision: actualManagedWork?.revision ?? -1)
            return AgentToolResult(summary: tool.risk <= .read ? "The frontmost app is Fixture." : "The key was pressed.")
        }
        _ = await speak("Check the frontmost app and its running sessions, then press escape in the front window.")
        let partialManaged = currentCapture(); actualManagedWork = partialManaged?.work
        check(partialManaged?.task != nil, "A2 independent partial case has no actual Manager owner")
        guard let partialOwner = partialManaged, let partialOwnedTask = partialOwner.task else {
            // Capture every actual scoped Task before cancellation can remove a slot.
            let entered = scopedVoiceRows().compactMap { row -> VoiceWorkerTestCapture? in
                guard let id = UUID(uuidString: row.id) else { return nil }
                return conversation.captureVoiceWorkerForTesting(id: id)
            }
            for owned in entered { _ = conversation.cancel(owned.id) }
            await partialProbe.finishFrontend(); await partialProbe.release(1); await partialProbe.release(3)
            for owned in entered { if let task = owned.task { await task.value } }
            for failure in failures { print("VOICE_DUPLEX_WORK_WRONG: \(failure)") }
            approveReads.cancel(); await approveReads.value
            await capture.endSession(source: .done)
            print("VOICE_DUPLEX_WORK_WRONG: INVALID independent partial Manager Task")
            print("VOICE_DUPLEX_WORK_FAILED")
            return false
        }
        check(await eventually { await partialProbe.rounds == 1 }, "A2 independent planner never entered")
        await partialProbe.release(1)
        check(await eventually { await partialProbe.rounds >= 3 }, "A2 independent read/plan never reached old key")
        await partialProbe.release(3)
        check(await eventually { PermissionGate.shared.pending?.toolID == "computer.press_key" }, "A2 independent old key has no real Gate")
        let partialOldRequest = PermissionGate.shared.pending
        let partialWords = "Use the tab key for this step."
        check(SpokenApproval.read(partialWords) == .unrelated, "A2 ordinary correction entered deterministic approval phrase gate")
        let partialCorrection = Task { @MainActor in await measuredHandle(partialWords, probe: partialProbe) }
        check(await eventually { await partialProbe.frontendCount == 1 }, "A2 independent correction never entered actual frontend")
        await partialProbe.yield("<revise id=\"")
        check(conversation.inputPending && actualManagedWork?.revision == 0, "A2 partial correction failed to hold unclassified input")
        if let request = partialOldRequest {
            check(PermissionGate.shared.pending?.id == request.id && PermissionGate.shared.respond(id: request.id, approved: true),
                  "A2 exact original key approval was refused before classification")
        } else { check(false, "A2 independent old request missing") }
        try? await Task.sleep(for: .milliseconds(80))
        check(await partialProbe.fires.allSatisfy { $0.key == nil }, "A2 independent stale key fired during unclassified correction")
        let partialIndex = partialManaged.flatMap { owned in
            conversation.taskBridge.indexedSessionTasks(capture.sessionID).firstIndex { $0.id == TaskID(owned.id) }.map { $0 + 1 }
        }
        if let partialIndex { await partialProbe.yield("\(partialIndex)\"/>") }
        else { check(false, "A2 actual indexed task absent") }
        check(await eventually(milliseconds: 200) { actualManagedWork?.revision == 1 }, "A2 parsed revision did not commit before stream finish")
        await partialProbe.finishFrontend(); _ = await partialCorrection.value
        check(await eventually { PermissionGate.shared.pending?.arguments["key"] == "tab" && PermissionGate.shared.pending?.id != partialOldRequest?.id },
              "A2 corrected model objective never produced fresh tab approval")
        if let request = PermissionGate.shared.pending {
            check(PermissionGate.shared.respond(id: request.id, approved: true), "A2 exact fresh corrected approval refused")
        }
        let partialCompleted = await eventually { scopedVoiceRows().first?.status == .completed }
        check(partialCompleted, "A2 actual model-partial worker did not finish")
        if !partialCompleted {
            // The existing bounded case clock failed. Stop and release only the
            // actual captured owner before joining; never reset an entered Task.
            _ = conversation.cancel(partialOwner.id)
            await partialProbe.finishFrontend(); await partialProbe.release(1); await partialProbe.release(3)
        }
        await partialOwnedTask.value
        let partialWrites = await partialProbe.fires.filter { $0.key != nil }
        check(partialWrites.count == 1 && partialWrites.first?.key == "tab" && partialWrites.first?.revision == 1,
              "A2 final model-partial fire was not exactly approved tab@1")
        let partialTimes = await partialProbe.handleLatencies
        check(partialTimes.count == 1 && partialTimes.allSatisfy { $0 <= 50 }, "A3 independent model-partial handle→stream exceeded50ms or absent")
        print("VOICE_DUPLEX_WORK_PARTIAL: handle_ms=\(partialTimes) effects=\(partialWrites.count) frontend=\(await partialProbe.frontendCount) revision=\(actualManagedWork?.revision ?? -1)")

        // A read that has already entered fire may complete during a correction.
        // Keep its actual evidence before discarding only the stale plan disposition.
        conversation.resetForTesting(); precedingTaskIDs = Set(conversation.taskBridge.cachedTasks.map(\.id))
        let flightProbe = DuplexWorkProbe(readsOnly: true, requiredEvidence: "ReadFlight verified sentinel")
        let flightWork = VoiceConversationWork("Inspect the frontmost app and its running sessions.")
        let flightWorker = RealtimeAgent(voiceWorker: flightWork)
        flightWorker.localModelProviderForTesting = DuplexWorkProvider(probe: flightProbe)
        AgentToolExecutor.fireOverrideForTesting = { tool, _ in
            guard tool.id == "computer.active_app" else { throw AgentError.cancelled }
            await flightProbe.parkFire()
            return AgentToolResult(summary: "ReadFlight verified sentinel")
        }
        await flightProbe.release(1)
        let flightTask = Task { @MainActor in await flightWorker.runVoiceObjective() }
        check(await eventually { await flightProbe.fireParked }, "read never entered actual final fire")
        flightWork.append("Actually report that result briefly.")
        await flightProbe.release(0)
        let flightResult = await withBoundedWait(.seconds(2)) { await flightTask.value }
        let flightEvidence = await flightProbe.sawEvidence
        check(flightResult == "The read finished." && flightEvidence,
              "in-flight verified read was lost from the corrected planner context")
        if flightResult == nil { flightTask.cancel() }

        // Direct effects that began legally must finish once and carry into the
        // corrected objective, rather than returning the old shortcut reply.
        let directProbe = DuplexWorkProbe()
        let directEvidence = DuplexEvidenceProbe(evidence: "Direct verified sentinel", script: [
            #"<tool_call>{"name":"computer.open_app","arguments":{"name":"Safari"},"rationale":"Use the result"}</tool_call>"#,
            "The corrected objective finished."
        ])
        let directWork = VoiceConversationWork("Open Safari.")
        let directWorker = RealtimeAgent(voiceWorker: directWork)
        directWorker.localModelProviderForTesting = DuplexEvidenceProvider(probe: directEvidence)
        var directFires = 0
        AgentToolExecutor.fireOverrideForTesting = { tool, _ in
            guard tool.id == "computer.open_app" else { throw AgentError.cancelled }
            directFires += 1
            await directProbe.parkFire()
            return AgentToolResult(summary: "Direct verified sentinel", verification: "Fixture effect recorded")
        }
        let directTask = Task { @MainActor in await directWorker.runVoiceObjective() }
        check(await eventually { PermissionGate.shared.pending?.toolID == "computer.open_app" }, "direct action never reached real approval")
        if let request = PermissionGate.shared.pending { _ = PermissionGate.shared.respond(id: request.id, approved: true) }
        check(await eventually { await directProbe.fireParked }, "direct effect never began legally")
        directWork.append("Actually report what opened, briefly.")
        await directProbe.release(0)
        let directResult = await withBoundedWait(.seconds(2)) { await directTask.value }
        let directSawEvidence = await directEvidence.sawEvidence
        check(directResult == "The corrected objective finished." && directSawEvidence && directFires == 1,
              "completed direct effect was lost/replayed or ended the revised objective")
        if directResult == nil { directTask.cancel() }

        // The actual native branch receives a scripted framework only; its real
        // runner, approval, timing and fallback consumers still run.
        let nativeProbe = DuplexNativeProbe()
        let nativeEvidence = DuplexEvidenceProbe(evidence: "Native verified sentinel", script: [
            #"<tool_call>{"name":"computer.press_key","arguments":{"key":"tab"},"rationale":"Apply the correction"}</tool_call>"#,
            "The revised native objective finished."
        ])
        let nativeWork = VoiceConversationWork("Inspect the frontmost app, then press escape.")
        let nativeWorker = RealtimeAgent(voiceWorker: nativeWork)
        nativeWorker.localModelProviderForTesting = DuplexEvidenceProvider(probe: nativeEvidence, native: nativeProbe)
        nativeWorker.budgetForTesting = ToolLoopBudget(perRound: .seconds(1), perReadCall: .seconds(1),
                                                       ceiling: .seconds(2), coldLoadAllowance: .zero)
        PlannerBackends.wholeTurnOverrideForTesting = DuplexNativePlanner(probe: nativeProbe)
        var nativeKeys: [String] = []
        AgentToolExecutor.fireOverrideForTesting = { tool, arguments in
            if tool.risk <= .read { return AgentToolResult(summary: "Native verified sentinel") }
            nativeKeys.append(arguments["key"] ?? "")
            return AgentToolResult(summary: "The key was pressed.", verification: "Fixture effect recorded")
        }
        let nativeTask = Task { @MainActor in await nativeWorker.runVoiceObjective() }
        check(await eventually { PermissionGate.shared.pending?.toolID == "computer.press_key" }, "native old write never reached review")
        conversation.inputActivityStarted()
        if let request = PermissionGate.shared.pending { _ = PermissionGate.shared.respond(id: request.id, approved: true) }
        check(await eventually { conversation.barrierWaiterCountForTesting == 1 }, "native effect never entered input hold")
        let floorStarted = ContinuousClock.now
        try? await Task.sleep(for: .milliseconds(100))
        let floorDuration = floorStarted.duration(to: .now)
        nativeWork.append("Actually use tab instead.")
        conversation.discardInput()
        check(await eventually { PermissionGate.shared.pending?.toolID == "computer.press_key" }, "native correction did not replan into real approval")
        if let request = PermissionGate.shared.pending { _ = PermissionGate.shared.respond(id: request.id, approved: true) }
        let nativeResult = await withBoundedWait(.seconds(2)) { await nativeTask.value }
        let nativeSawEvidence = await nativeEvidence.sawEvidence
        check(nativeResult == "The revised native objective finished." && nativeSawEvidence && nativeKeys == ["tab"],
              "native fallback lost read evidence, returned stale answer or fired stale escape")
        let nativeCharge = nativeProbe.budgetAtReturn.flatMap { before in nativeProbe.budgetAtFallback.map { before - $0 } }
        check(nativeCharge.map { $0 >= .milliseconds(15) && $0 < floorDuration / 2 } == true,
              "native model charge lost compute or charged the user's floor/approval wait")
        print("VOICE_DUPLEX_WORK_NATIVE: model_ms=\(nativeCharge.map(ModelPassRecorder.milliseconds) ?? -1) floor_ms=\(ModelPassRecorder.milliseconds(floorDuration))")
        if nativeResult == nil { nativeTask.cancel() }
        PlannerBackends.wholeTurnOverrideForTesting = nil
        nativeProbe.runner = nil

        // A stale timed-out framework child must not share its runner with a new
        // round loop while cancellation is unwinding.
        let hangingProbe = DuplexNativeProbe(hang: true)
        let hangingEvidence = DuplexEvidenceProbe(evidence: "unused", script: ["Should not run."])
        let hangingWork = VoiceConversationWork("Inspect the frontmost app and its running sessions.")
        let hangingWorker = RealtimeAgent(voiceWorker: hangingWork)
        hangingWorker.localModelProviderForTesting = DuplexEvidenceProvider(probe: hangingEvidence)
        hangingWorker.budgetForTesting = ToolLoopBudget(perRound: .seconds(1), perReadCall: .seconds(1),
                                                        ceiling: .milliseconds(80), coldLoadAllowance: .zero)
        PlannerBackends.wholeTurnOverrideForTesting = DuplexNativePlanner(probe: hangingProbe)
        let hangingTask = Task { @MainActor in await hangingWorker.runVoiceObjective() }
        check(await eventually { hangingProbe.started }, "hanging native framework never entered")
        hangingWork.append("Actually only report the result.")
        let hangingResult = await withBoundedWait(.seconds(1)) { await hangingTask.value }
        let hangingRounds = await hangingEvidence.rounds
        check(hangingResult != nil && hangingRounds == 0,
              "stale native timeout entered revised rounds before the child completed")
        if hangingResult == nil { hangingTask.cancel() }
        PlannerBackends.wholeTurnOverrideForTesting = nil
        hangingProbe.runner = nil

        // Fast paths must bind the same revision authority before any planner round.
        conversation.resetForTesting(); precedingTaskIDs = Set(conversation.taskBridge.cachedTasks.map(\.id))
        let memoryWork = VoiceConversationWork("Remember that my favorite color is blue.")
        let memoryWorker = RealtimeAgent(voiceWorker: memoryWork)
        let memoryProbe = DuplexMemoryProbe()
        memoryWorker.localModelProviderForTesting = DuplexMemoryProvider(probe: memoryProbe)
        var memoryTexts: [String] = []
        AgentToolExecutor.fireOverrideForTesting = { tool, arguments in
            guard tool.id == "memory.remember" else { throw AgentError.cancelled }
            memoryTexts.append(arguments["text"] ?? "")
            return AgentToolResult(summary: "Remembered green.", verification: "Fixture effect recorded")
        }
        conversation.inputActivityStarted()
        let memoryTask = Task { @MainActor in await memoryWorker.runVoiceObjective() }
        check(await eventually { conversation.barrierWaiterCountForTesting == 1 }, "memory fast path never parked at its gate")
        memoryWork.append("Actually my favorite color is green.")
        conversation.discardInput()
        let memoryResult = await withBoundedWait(.seconds(2)) { await memoryTask.value }
        check(memoryResult?.contains("green") == true, "revised memory fast path did not complete current objective")
        check(memoryTexts.count == 1 && memoryTexts.first?.contains("green") == true,
              "memory fast path emitted stale blue or lost the corrected fact")
        if memoryResult == nil { memoryTask.cancel() }
        print("VOICE_DUPLEX_WORK_MEMORY: effects=\(memoryTexts.count) rounds=\(await memoryProbe.rounds)")

        // Actual barrier clients: cancellation must wake only that waiter; closing wakes all.
        conversation.inputActivityStarted()
        let cancelled = Task { @MainActor in await conversation.mayCommitEffect() }
        let closed = Task { @MainActor in await conversation.mayCommitEffect() }
        // Let both tasks enter the actual wait before cancellation, rather than testing
        // only an already-cancelled task. The continuation implementation exposes its
        // count so this observes registration, not merely task creation.
        check(await eventually { conversation.barrierWaiterCountForTesting == 2 }, "effect waiters never registered")
        cancelled.cancel()
        let cancellationResult = await withBoundedWait(.milliseconds(200)) { await cancelled.value }
        check(cancellationResult == false, "cancelled effect waiter did not resume false")
        check(await eventually { conversation.barrierWaiterCountForTesting == 1 }, "cancelled waiter was not removed")
        conversation.closeSession()
        let closedResult = await withBoundedWait(.milliseconds(200)) { await closed.value }
        check(closedResult == true, "session close did not resume remaining effect waiter")
        await Task.yield()
        shadow.printDiagnostics()
        check(shadow.divergenceCount == 0, "shadow producer divergence")
        check(["effectsHeld", "turnPending", "output"].allSatisfy { shadow.comparisonCounts[$0, default: 0] > 0 },
              "shadow sampler lacked covered fields")
        check(shadow.outputPresenceComparisonCount > 0, "shadow output presence coverage absent")
        let remaining = scopedVoiceRows().compactMap { row -> VoiceWorkerTestCapture? in
            guard let id = UUID(uuidString: row.id) else { return nil }
            return conversation.captureVoiceWorkerForTesting(id: id)
        }
        for owned in remaining { _ = conversation.cancel(owned.id) }
        await probe.finishFrontend(); await probe.release(1); await probe.release(3)
        await failureProbe.finishFrontend(); await failureProbe.release(1); await failureProbe.release(3)
        await partialProbe.finishFrontend(); await partialProbe.release(1); await partialProbe.release(3)
        for owned in remaining { if let task = owned.task { await task.value } }
        for task in [flightTask, directTask, nativeTask, hangingTask, memoryTask] {
            task.cancel(); _ = await task.value
        }
        check(IslandOwnership.workerAttemptTotal == 0, "A7 workers attempted island writes during whole duplex run")
        await capture.endSession(source: .done)
        approveReads.cancel(); await approveReads.value
        for failure in failures { print("VOICE_DUPLEX_WORK_WRONG: \(failure)") }
        return failures.isEmpty
    }

    @MainActor
    private static func measuredHandle(_ text: String, probe: DuplexWorkProbe) async -> AgentTurn {
        await probe.noteHandle(.now)
        return await speak(text)
    }

    /// Mirror the capture commit's existing control lifecycle. A direct
    /// frontend handle alone does not own interruption of prior playback.
    @MainActor
    private static func speak(_ text: String) async -> AgentTurn {
        let agent = RealtimeAgent.shared
        agent.userSpeechStarted()
        agent.userSpeechEnded()
        return await agent.handle(text, source: .voice)
    }

    @MainActor
    private static func eventually(milliseconds: Int = 2_000,
                                   _ predicate: @MainActor () async -> Bool) async -> Bool {
        for _ in 0..<(milliseconds / 5) {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await predicate()
    }
}

private actor DuplexWorkProbe {
    struct Fire: Sendable { let tool: String; let key: String?; let revision: Int }
    let readsOnly: Bool
    let requiredEvidence: String?
    init(readsOnly: Bool = false, requiredEvidence: String? = nil) {
        self.readsOnly = readsOnly; self.requiredEvidence = requiredEvidence
    }
    private(set) var fireParked = false
    private(set) var sawEvidence = false
    func parkFire() async {
        fireParked = true
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || released.contains(0) { continuation.resume() }
                else { gates[0] = continuation }
            }
        } onCancel: { Task { await self.release(0) } }
    }
    private(set) var roundStarts: [ContinuousClock.Instant] = []
    private(set) var handleLatencies: [Int] = []
    private var handleStarted: ContinuousClock.Instant?
    private var frontendStarted: ContinuousClock.Instant?
    private var frontendEnded: ContinuousClock.Instant?
    private(set) var rounds = 0
    private(set) var frontendCount = 0
    private(set) var fires: [Fire] = []
    private var released: Set<Int> = []
    private var gates: [Int: CheckedContinuation<Void, Never>] = [:]
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?
    func recordFire(_ tool: String, key: String?, revision: Int) {
        fires.append(Fire(tool: tool, key: key, revision: revision))
    }
    func noteHandle(_ instant: ContinuousClock.Instant) { handleStarted = instant }
    func startsInsideFrontend() -> Int {
        guard let started = frontendStarted else { return 0 }
        return roundStarts.filter { $0 >= started && $0 <= (frontendEnded ?? .now) }.count
    }
    func frontend() -> AsyncThrowingStream<String, Error> {
        frontendCount += 1
        frontendStarted = .now
        frontendEnded = nil
        if let start = handleStarted {
            handleLatencies.append(ModelPassRecorder.milliseconds(start.duration(to: .now)))
            handleStarted = nil
        }
        return AsyncThrowingStream { continuation = $0 }
    }
    func yield(_ delta: String) { continuation?.yield(delta) }
    func finishFrontend() { frontendEnded = .now; continuation?.finish(); continuation = nil }
    func release(_ round: Int) { released.insert(round); gates.removeValue(forKey: round)?.resume() }
    func response(user: String) async throws -> String {
        rounds += 1
        roundStarts.append(.now)
        let round = rounds
        if (round == 1 || (!readsOnly && round == 3)), !released.contains(round) {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if Task.isCancelled { continuation.resume() }
                    else { gates[round] = continuation }
                }
            } onCancel: {
                Task { await self.release(round) }
            }
        }
        try Task.checkCancellation()
        if readsOnly && round > 1 {
            if let requiredEvidence { sawEvidence = user.contains(requiredEvidence) }
            return "The read finished."
        }
        switch round {
        case 1: return #"<tool_call>{"name":"computer.active_app","arguments":{},"rationale":"Inspect the app"}</tool_call>"#
        case 2: return #"<tool_call>{"name":"computer.windows","arguments":{},"rationale":"Inspect the windows"}</tool_call>"#
        case 3: return #"<tool_call>{"name":"computer.press_key","arguments":{"key":"escape"},"rationale":"Press the requested key"}</tool_call>"#
        case 4: return #"<tool_call>{"name":"computer.press_key","arguments":{"key":"tab"},"rationale":"Apply the correction"}</tool_call>"#
        default: return "Done with the duplex check."
        }
    }
}

private struct DuplexWorkProvider: LLMProvider {
    let id = LLMProviderID.appLLM
    var displayModelName: String { "Voice Task Usage Fixture" }
    let probe: DuplexWorkProbe
    var contextTokens: Int { 8_192 }
    var unavailableReason: String? { get async { nil } }
    func countTokens(_ text: String) async throws -> Int { text.count / 4 }
    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        let text = try await probe.response(user: user)
        ModelPassRecorder.current?.report(promptTokens: 13, cachedTokens: 3,
            completionTokens: 5, reasoningTokens: 2, finishReason: nil, estimated: false)
        return LLMCompletion(text: text, generatedTokens: text.count, duration: 0)
    }
}

private actor DuplexMemoryProbe {
    private(set) var rounds = 0
    func response() -> String {
        rounds += 1
        if rounds == 1 {
            return #"<tool_call>{"name":"memory.remember","arguments":{"kind":"profile","text":"The user's favorite color is green."},"rationale":"Save the corrected fact"}</tool_call>"#
        }
        return "Remembered green."
    }
}

private struct DuplexMemoryProvider: LLMProvider {
    let id = LLMProviderID.appLLM
    let probe: DuplexMemoryProbe
    var contextTokens: Int { 8_192 }
    var unavailableReason: String? { get async { nil } }
    func countTokens(_ text: String) async throws -> Int { text.count / 4 }
    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        let text = await probe.response()
        return LLMCompletion(text: text, generatedTokens: text.count, duration: 0)
    }
}

private actor DuplexEvidenceProbe {
    let evidence: String
    let script: [String]
    private(set) var rounds = 0
    private(set) var sawEvidence = false
    init(evidence: String, script: [String]) { self.evidence = evidence; self.script = script }
    func response(_ user: String) -> String {
        sawEvidence = sawEvidence || user.contains(evidence)
        let text = script[min(rounds, script.count - 1)]
        rounds += 1
        return text
    }
}

private struct DuplexEvidenceProvider: LLMProvider {
    let id = LLMProviderID.appLLM
    let probe: DuplexEvidenceProbe
    var native: DuplexNativeProbe? = nil
    var contextTokens: Int { 8_192 }
    var unavailableReason: String? { get async { nil } }
    func countTokens(_ text: String) async throws -> Int { text.count / 4 }
    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        await native?.recordFallback()
        let text = await probe.response(user)
        return LLMCompletion(text: text, generatedTokens: text.count, duration: 0)
    }
}

@MainActor
private final class DuplexNativeProbe {
    let hang: Bool
    init(hang: Bool = false) { self.hang = hang }
    var started = false
    weak var runner: ToolStepRunner?
    var budgetAtReturn: Duration?
    var budgetAtFallback: Duration?
    func recordFallback() { if budgetAtFallback == nil { budgetAtFallback = runner?.ceilingRemaining } }
    func run(executor: any ToolStepExecuting) async throws -> String {
        started = true
        runner = executor as? ToolStepRunner
        if hang {
            try await Task.sleep(for: .seconds(5))
            return "Stale hanging native result."
        }
        // Known model-only time must be charged; tool/approval/floor time must not.
        try await Task.sleep(for: .milliseconds(20))
        _ = await executor.execute(AgentToolCall(name: "computer.active_app", arguments: [:],
                                               rationale: "Inspect the app", evidence: nil))
        _ = await executor.execute(AgentToolCall(name: "computer.press_key", arguments: ["key": "escape"],
                                               rationale: "Press the requested key", evidence: nil))
        budgetAtReturn = runner?.ceilingRemaining
        return "Stale native answer."
    }
}

private struct DuplexNativePlanner: AgentWholeTurnPlanner {
    let probe: DuplexNativeProbe
    let label = "scripted-native-duplex"
    func runTurn(system: String, request: String, manifest: AgentCapabilityManifest,
                 executor: any ToolStepExecuting, maxTokens: Int) async throws -> String {
        try await probe.run(executor: executor)
    }
}

/// Diagnostic sampling only; no product timer or output/state writer.
@MainActor private final class DuplexIslandSampler {
    let workerIDs: () -> [String]
    var frontendOpen = false
    private(set) var samples = 0
    private(set) var samplesWithSteps = 0
    private(set) var workerDriven = 0
    init(workerIDs: @escaping () -> [String]) { self.workerIDs = workerIDs }
    func sample() {
        guard frontendOpen else { return }
        samples += 1
        let titles = workerIDs().flatMap { AgentActivityStore.shared.steps(taskID: $0).map(\.title) }.filter { !$0.isEmpty }
        if !titles.isEmpty { samplesWithSteps += 1 }
        let current = IslandState.shared.kind.agentWorkingTitle
        if !current.isEmpty && titles.contains(current) { workerDriven += 1 }
    }
}

import Foundation

/// Runs the production frontend, capture policy and planned workers with scripted models.
/// No microphone, model weights, external tools, or user-history writes.
enum VoiceWorkLifecycleSelfTest {
    @MainActor
    static func run() async -> Bool {
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-voice-work-lifecycle",
              AgentSession.shared.fileURL == nil else {
            print("VOICE_WORK_LIFECYCLE_FAILED: isolated diagnostic conversation required")
            return false
        }
        // The isolated nonterminal conductor binds Dictionary before older RTA intake.
        let nonterminal = await TaskNonterminalTransitionSelfTest.run()
        let shadow = VoiceSession.shared
        shadow.resetDiagnosticsForTesting()
        let agent = RealtimeAgent.shared
        let capture = AgentCaptureController.shared
        let conversation = VoiceConversationCoordinator.shared
        var precedingTaskIDs = Set(conversation.taskBridge.cachedTasks.map(\.id))
        func scopedVoiceRows() -> [AgentTask] {
            conversation.taskBridge.cachedTasks.filter { $0.source == "voice" && !precedingTaskIDs.contains($0.id) }
        }
        func currentCapture() -> VoiceWorkerTestCapture? {
            guard let raw = scopedVoiceRows().first?.id, let id = UUID(uuidString: raw) else { return nil }
            return conversation.captureVoiceWorkerForTesting(id: id)
        }
        let speech = AgentSpeechSynthesizer.shared
        let recorder = RecordingSpeechBacking()
        var failures: [String] = nonterminal.failures
        func check(_ value: Bool, _ message: String) { if !value { failures.append(message) } }
        var cancelShadowChecks = 0
        func shadowCheck(_ value: Bool, _ message: String) {
            cancelShadowChecks += 1
            check(value, "cancel shadow: " + message)
        }
        func cancelCommands(_ id: UUID) -> Int {
            shadow.recentCommands.filter {
                if case .cancelTask(let target) = $0 { return target == TaskID(id) }
                return false
            }.count
        }
        func speak(_ text: String) async -> AgentTurn {
            agent.userSpeechStarted()
            agent.userSpeechEnded()
            return await agent.handle(text, source: .voice)
        }
        speech.useTestingBacking(recorder)
        let oldExecutor = AgentToolExecutor.fakeForTesting
        AgentToolExecutor.fakeForTesting = { _, _ in AgentToolResult(summary: "Nothing is frontmost.") }
        defer {
            conversation.resetForTesting(); precedingTaskIDs = Set(conversation.taskBridge.cachedTasks.map(\.id))
            agent.localModelProviderForTesting = nil
            agent.budgetForTesting = nil
            AgentToolExecutor.fakeForTesting = oldExecutor
            speech.restoreSystemBacking()
            Task { @MainActor in await capture.endSession(source: .done) }
        }
        await capture.endSession(source: .done)
        AgentSession.shared.forgetAllConversations()
        await capture.beginSession(captureAudio: false)
        conversation.resetForTesting(); precedingTaskIDs = Set(conversation.taskBridge.cachedTasks.map(\.id))
        let state = VoiceWorkLifecycleProbe()
        conversation.workerProviderForTesting = VoiceWorkLifecycleProvider(state: state)
        conversation.streamForTesting = { _, messages in
            let response = messages.last?.content.hasSuffix("What is a haiku?") == true
                ? "<answer/>A haiku is a short poem." : "<use_tools/>"
            return AsyncThrowingStream { $0.yield(response); $0.finish() }
        }
        await state.parkNext(answer: "The objective remains active.")
        _ = await speak("Check the active app and its running sessions.")
        for _ in 0..<200 {
            if await state.isParked { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        check(await state.isParked, "planned worker never reached its parked provider")
        let original = currentCapture()
        let originalTask = original?.task
        // A deliberately incompatible *typed* override must not reroute voice. It does
        // not supply the voice reply; this assertion catches the old routing producer.
        agent.localModelProviderForTesting = VoiceWorkLifecycleProvider(state: VoiceWorkLifecycleProbe())
        let side = await speak("What is a haiku?")
        agent.localModelProviderForTesting = nil
        check(side.reply == "A haiku is a short poem.", "typed provider override rerouted voice away from coordinator")
        check(original != nil && scopedVoiceRows().first?.status == .running
              && original?.work.revision == 0, "side question cancelled or revised the real worker")

        shadowCheck(original.map { cancelCommands($0.id) == 0 } == true,
                    "side question emitted task cancellation")
        recorder.reset()
        capture.simulateSpeech("Cancel that")
        capture.simulateSilence()
        check(await capture.considerEndpoint(), "explicit cancel did not endpoint")
        await capture.waitForActiveTurnForTesting()
        let namedCancel = original.map { job in
            let title = TaskStatusRenderer.title(job.work.original)
            return originalTask != nil ? "Stopping \(title) now." : "I stopped \(title)."
        }
        let legacyCancelCopy = agent.lastReply == "I stopped that task." || agent.lastReply == "I'm stopping that task."
        let namedCancelCopy = namedCancel.map { agent.lastReply == $0 } == true
        print("VOICE_STATUS_COPY scope=lifecycleCancel legacy=\(legacyCancelCopy) named=\(namedCancelCopy) capturedTask=\(originalTask != nil)")
        check(legacyCancelCopy || namedCancelCopy, "explicit cancel did not confirm the stopped task")
        check(scopedVoiceRows().first?.id == original?.id.uuidString && scopedVoiceRows().first?.status == .cancelled,
              "explicit cancel retained/replaced the active job")
        check(original.map { job in AgentTaskManager.shared.tasks.contains {
            $0.id == job.id.uuidString && $0.status == .cancelled
        }} == true, "real task ledger did not record cancellation")
        shadowCheck(original.map { cancelCommands($0.id) == 1 } == true,
                    "deterministic user cancellation missing exact shadow command")
        if let original {
            let before = cancelCommands(original.id)
            conversation.cancel(original.id, userRequested: true)
            shadowCheck(cancelCommands(original.id) == before,
                        "stale cancelled task emitted another explicit cancellation")
        } else { shadowCheck(false, "actual deterministic job missing") }
        shadowCheck(original.map { !shadow.state.activeTasks.contains(TaskID($0.id)) } == true,
                    "legacy task cancellation absent from shadow state")
        await state.release()
        if let originalTask { await originalTask.value }
        try? await Task.sleep(for: .milliseconds(30))
        _ = VoiceAnnouncementQueue.shared.flush(userHasFloor: false)
        check(!recorder.spoken.contains("The objective remains active."), "cancelled producer spoke a stale answer")
        await capture.endSession(source: .done)

        let additional = await runCancelShadowCases()
        failures += additional.failures
        cancelShadowChecks += additional.checks
        let cancelProblems = failures.filter { $0.hasPrefix("cancel shadow:") }.count
        print("VOICE_CANCEL_SHADOW_CHECKS=\(cancelShadowChecks) problems=\(cancelProblems)")

        // Existing trace recorder supplies synchronous actual event receipts.
        // Ordinary lifecycle invocation stays unchanged when tracing is not requested.
        if CommandLine.arguments.contains("--record-voice-trace") {
            let revised = await runRevisionShadowCases()
            failures += revised.failures
            print("VOICE_REVISION_SHADOW_CHECKS=\(revised.checks) problems=\(revised.failures.count)")
        } else { print("VOICE_REVISION_SHADOW_UNAVAILABLE: trace modifier not supplied") }

        // C1: the actual planner is parked on round one. A stalled frontend owns
        // the input epoch while that round produces a read. Its deadline must reopen
        // planning/reads, while the separate write-effect hold remains in force.
        await capture.beginSession(captureAudio: false)
        conversation.resetForTesting(); precedingTaskIDs = Set(conversation.taskBridge.cachedTasks.map(\.id))
        let stalled = VoiceFailureWorkerProbe()
        conversation.workerProviderForTesting = VoiceFailureWorkerProvider(state: stalled)
        conversation.streamForTesting = { _, _ in
            AsyncThrowingStream { $0.yield("<use_tools/>"); $0.finish() }
        }
        _ = await speak("Inspect the frontmost app.")
        for _ in 0..<200 {
            if await stalled.parked { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        check(await stalled.parked, "C1 worker never parked on real planner round one")
        let stalledTask = currentCapture()?.task
        conversation.responseDeadlineForTesting = .milliseconds(200)
        conversation.streamForTesting = { _, _ in AsyncThrowingStream { _ in } }
        agent.userSpeechStarted()
        agent.userSpeechEnded()
        let failedTurn = Task { @MainActor in await agent.handle("Stall please.", source: .voice) }
        for _ in 0..<100 {
            if conversation.inputPending { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        check(conversation.inputPending, "C1 frontend never owned the input barrier")
        await stalled.release()
        _ = await failedTurn.value
        let failedAt = ContinuousClock.now
        check(conversation.lastFailure?.code == .deadline, "C1 frontend did not fail at its real deadline")
        check(!conversation.inputPending && conversation.effectHoldEpoch != nil,
              "C1 failure did not release reads and retain the effect hold")
        for _ in 0..<100 {
            if await stalled.roundTwoAt != nil { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        let resumed = await stalled.roundTwoAt
        check(resumed.map { failedAt.duration(to: $0) <= .milliseconds(200) } == true,
              "C1 real planner round two did not resume within 200 ms")
        for _ in 0..<200 {
            if scopedVoiceRows().first?.status == .completed { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        check(scopedVoiceRows().first?.result == "The read finished.", "C1 actual worker did not finish its read")
        check(conversation.effectHoldEpoch != nil, "C1 worker completion released unclassified effects")
        print("VOICE_WORK_LIFECYCLE_C1: round2_ms=\(resumed.map { String(ModelPassRecorder.milliseconds(failedAt.duration(to: $0))) } ?? "absent") status=\(scopedVoiceRows().first?.status.rawValue ?? "absent")")
        if let stalledTask { await stalledTask.value }
        await capture.endSession(source: .done)
        conversation.resetForTesting(); precedingTaskIDs = Set(conversation.taskBridge.cachedTasks.map(\.id))

        failures.append(contentsOf: await runRevisionCases(check: { _ in }))

        let bridgeCases = await TaskBridgeFoundationSelfTest.run()
        failures.append(contentsOf: bridgeCases.failures)

        let recordCases = await TaskRecordStatusSelfTest.run()
        failures.append(contentsOf: recordCases.failures)

        let timeCases = await TaskRecordStartTimeSelfTest.run()
        failures.append(contentsOf: timeCases.failures)

        let encodingCases = TaskMetadataEncodingSelfTest.run()
        failures.append(contentsOf: encodingCases.failures)

        let voiceOutcomes = await TaskVoiceOutcomeSelfTest.run()
        failures += voiceOutcomes.failures
        print("VOICE_TASK_OUTCOME_CHECKS=\(voiceOutcomes.checks) problems=\(voiceOutcomes.failures.count)")

        print("TASK_NONTERMINAL_TRANSITION checks=\(nonterminal.checks) problems=\(nonterminal.failures.count)")

        let voiceSpawns = await TaskVoiceSpawnSelfTest.run()
        failures += voiceSpawns.failures
        print("VOICE_TASK_SPAWN_CHECKS=\(voiceSpawns.checks) problems=\(voiceSpawns.failures.count)")

        let rawSpawns = await TaskBridgeSpawnAuthoritySelfTest.run()
        failures += rawSpawns.failures
        print("TASK_BRIDGE_SPAWN_AUTHORITY checks=\(rawSpawns.checks) problems=\(rawSpawns.failures.count)")
        let rawCancels = await TaskBridgeCancelOwnerSelfTest.run()
        failures += rawCancels.failures
        print("TASK_BRIDGE_CANCEL_OWNER checks=\(rawCancels.checks) problems=\(rawCancels.failures.count)")
        let voiceResumes = await TaskVoiceResumeAuthoritySelfTest.run()
        failures += voiceResumes.failures
        print("VOICE_TASK_RESUME_CHECKS=\(voiceResumes.checks) problems=\(voiceResumes.failures.count)")

        let revisionCases = await TaskVoiceRevisionSelfTest.run()
        failures += revisionCases.failures
        print("VOICE_TASK_REVISION_CHECKS=\(revisionCases.checks) problems=\(revisionCases.failures.count)")

        let primary = TaskVoicePrimaryConditionSelfTest.run()
        failures += primary.failures
        print("VOICE_TASK_PRIMARY_CONDITION_CHECKS=\(primary.checks) problems=\(primary.failures.count)")

        let primaryAPI = TaskVoicePrimaryAPIConditionSelfTest.run()
        failures += primaryAPI.failures
        print("VOICE_TASK_PRIMARY_API_CHECKS=\(primaryAPI.checks) problems=\(primaryAPI.failures.count)")

        let deliveryEncoder = TaskDeliveryAttemptEncoderSelfTest.run()
        failures += deliveryEncoder.failures
        print("VOICE_TASK_DELIVERY_ENCODER_CHECKS=\(deliveryEncoder.checks) problems=\(deliveryEncoder.failures.count)")

        let voiceACP = await TaskACPVoiceRoutingSelfTest.run()
        failures += voiceACP.failures
        print("VOICE_ACP_ROUTING_CHECKS=\(voiceACP.checks) problems=\(voiceACP.failures.count)")

        let voiceACPActivity = await TaskVoiceACPActivityOwnerSelfTest.run()
        failures += voiceACPActivity.failures
        print("VOICE_ACP_ACTIVITY_OWNER_CHECKS=\(voiceACPActivity.checks) problems=\(voiceACPActivity.failures.count)")

        let ownership = await TaskVoiceOwnershipSelfTest.run()
        failures += ownership.failures
        print("VOICE_TASK_OWNERSHIP_CHECKS=\(ownership.checks) problems=\(ownership.failures.count)")

        let progress = await TaskVoiceProgressSelfTest.run()
        failures += progress.failures
        print("VOICE_TASK_PROGRESS_CHECKS=\(progress.checks) problems=\(progress.failures.count)")
        let statusCorpus = await TaskStatusCancelCorpusSelfTest.run()
        failures += statusCorpus.failures
        print("VOICE_TASK_STATUS_CORPUS_CHECKS \(statusCorpus.checks)")
        let legalStatus = TaskStatusLegalSnapshotSelfTest.run()
        failures += legalStatus.failures
        print("VOICE_TASK_STATUS_LEGAL_SNAPSHOT_CHECKS=\(legalStatus.checks) problems=\(legalStatus.failures.count)")
        let mixedStatus = await TaskStatusCancelCorpusSelfTest.runMixedConsumption()
        failures += mixedStatus.failures
        print("VOICE_TASK_STATUS_MIXED_CONSUMPTION_CHECKS=\(mixedStatus.checks) problems=\(mixedStatus.failures.count)")
        let toolShape = TaskStatusCancelCorpusSelfTest.runToolShapeAdmission()
        failures += toolShape.failures
        print("VOICE_TASK_STATUS_TOOL_SHAPE_CHECKS=\(toolShape.checks) problems=\(toolShape.failures.count)")
        let toolShapeCallsite = await TaskToolShapeCallsiteSelfTest.run(recorder: recorder)
        failures += toolShapeCallsite.failures
        print("VOICE_TASK_TOOL_SHAPE_CALLSITE_CHECKS=\(toolShapeCallsite.checks) problems=\(toolShapeCallsite.failures.count)")

        await Task.yield()
        shadow.printDiagnostics()
        check(shadow.divergenceCount == 0, "shadow producer divergence")
        check(["effectsHeld", "turnPending", "output"].allSatisfy { shadow.comparisonCounts[$0, default: 0] > 0 },
              "shadow sampler lacked covered fields")
        check(shadow.outputPresenceComparisonCount > 0, "shadow output presence coverage absent")
        for failure in failures { print("VOICE_WORK_LIFECYCLE_WRONG: \(failure)") }
        print(failures.isEmpty ? "VOICE_WORK_LIFECYCLE_OK" : "VOICE_WORK_LIFECYCLE_FAILED")
        return failures.isEmpty
    }

    /// Actual parsed frontend and ordinary teardown callers, alongside the existing
    /// capture→deterministic cancellation above. No invented shadow input/playback event.
    @MainActor
    private static func runCancelShadowCases() async -> (checks: Int, failures: [String]) {
        let agent = RealtimeAgent.shared
        let capture = AgentCaptureController.shared
        let conversation = VoiceConversationCoordinator.shared
        var precedingTaskIDs = Set(conversation.taskBridge.cachedTasks.map(\.id))
        func scopedVoiceRows() -> [AgentTask] {
            conversation.taskBridge.cachedTasks.filter { $0.source == "voice" && !precedingTaskIDs.contains($0.id) }
        }
        func currentCapture() -> VoiceWorkerTestCapture? {
            guard let raw = scopedVoiceRows().first?.id, let id = UUID(uuidString: raw) else { return nil }
            return conversation.captureVoiceWorkerForTesting(id: id)
        }
        let shadow = VoiceSession.shared
        var checks = 0
        var failures: [String] = []
        func check(_ value: Bool, _ message: String) {
            checks += 1
            if !value { failures.append("cancel shadow: " + message) }
        }
        func commands(_ id: UUID) -> Int {
            shadow.recentCommands.filter {
                if case .cancelTask(let target) = $0 { return target == TaskID(id) }
                return false
            }.count
        }
        func speak(_ text: String) async -> AgentTurn {
            agent.userSpeechStarted()
            agent.userSpeechEnded()
            return await agent.handle(text, source: .voice)
        }
        for parsed in [true, false] {
            await capture.beginSession(captureAudio: false)
            conversation.resetForTesting(); precedingTaskIDs = Set(conversation.taskBridge.cachedTasks.map(\.id))
            let state = VoiceWorkLifecycleProbe()
            conversation.workerProviderForTesting = VoiceWorkLifecycleProvider(state: state)
            conversation.streamForTesting = { _, messages in
                let answer = messages.last?.content.hasSuffix("Cancel task one") == true
                    ? "<cancel id=\"1\"/>" : "<use_tools/>"
                return AsyncThrowingStream { $0.yield(answer); $0.finish() }
            }
            await state.parkNext(answer: "The cancelled task must not announce this.")
            _ = await speak("Check the active app and its running sessions.")
            for _ in 0..<200 {
                if await state.isParked { break }
                try? await Task.sleep(for: .milliseconds(5))
            }
            let parked = await state.isParked
            let job = currentCapture()
            check(parked && scopedVoiceRows().first?.status == .running, "actual parsed/teardown worker did not park")
            guard parked, let job else {
                await state.release()
                await capture.endSession(source: .done)
                conversation.resetForTesting(); precedingTaskIDs = Set(conversation.taskBridge.cachedTasks.map(\.id))
                return (checks, failures)
            }
            if parsed {
                check(!VoiceTurnPolicy.isExplicitWorkCancellation("Cancel task one") && commands(job.id) == 0,
                      "numbered request did not isolate parsed frontend branch")
                let result = await speak("Cancel task one")
                check((result.reply == "I stopped that task." || result.reply == "I'm stopping that task.")
                        && scopedVoiceRows().first?.status == .cancelled
                        && AgentTaskManager.shared.tasks.contains { $0.id == job.id.uuidString && $0.status == .cancelled },
                      "actual parsed cancellation did not reach legacy worker and primary row")
                check(commands(job.id) == 1, "parsed user cancellation missing exact shadow command")
                let count = commands(job.id)
                conversation.cancel(job.id, userRequested: true)
                check(commands(job.id) == count, "stale parsed task emitted another cancellation")
                await capture.endSession(source: .done)
                check(commands(job.id) == count, "session close emitted explicit task cancellation")
            } else {
                await capture.endSession(source: .done)
                check(scopedVoiceRows().first?.status == .running && commands(job.id) == 0,
                      "ordinary session close cancelled independent worker or emitted explicit cancel")
                conversation.resetForTesting(); precedingTaskIDs = Set(conversation.taskBridge.cachedTasks.map(\.id))
                check(AgentTaskManager.shared.tasks.contains { $0.id == job.id.uuidString && $0.status == .cancelled },
                      "actual ordinary reset did not cancel legacy task")
                check(commands(job.id) == 0, "ordinary reset misrepresented a user cancellation")
            }
            await state.release()
            if let task = job.task { await task.value }
            conversation.resetForTesting(); precedingTaskIDs = Set(conversation.taskBridge.cachedTasks.map(\.id))
            print("VOICE_CANCEL_SHADOW_TRACE parsed=\(parsed) commandCount=\(commands(job.id)) parked=\(parked)")
        }
        return (checks, failures)
    }

    @MainActor
    private static func runRevisionShadowCases() async -> (checks: Int, failures: [String]) {
        guard let index = CommandLine.arguments.firstIndex(of: "--record-voice-trace"),
              CommandLine.arguments.indices.contains(index + 1) else {
            return (0, ["revision shadow: actual recorder argument missing"])
        }
        let url = URL(fileURLWithPath: CommandLine.arguments[index + 1]).standardizedFileURL
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard url.path == resolved.path, resolved.path.hasPrefix(temp.path + "/"),
              UUID(uuidString: resolved.deletingLastPathComponent().lastPathComponent) != nil,
              !resolved.pathComponents.contains("Application Support") else {
            return (0, ["revision shadow: recorder must be in an owned canonical UUID temp root"])
        }
        let agent = RealtimeAgent.shared
        let capture = AgentCaptureController.shared
        let conversation = VoiceConversationCoordinator.shared
        var precedingTaskIDs = Set(conversation.taskBridge.cachedTasks.map(\.id))
        func scopedVoiceRows() -> [AgentTask] {
            conversation.taskBridge.cachedTasks.filter { $0.source == "voice" && !precedingTaskIDs.contains($0.id) }
        }
        func currentCapture() -> VoiceWorkerTestCapture? {
            guard let raw = scopedVoiceRows().first?.id, let id = UUID(uuidString: raw) else { return nil }
            return conversation.captureVoiceWorkerForTesting(id: id)
        }
        let state = VoiceWorkLifecycleProbe()
        var checks = 0
        var failures: [String] = []
        func check(_ good: Bool, _ name: String) {
            checks += 1
            if !good { failures.append("revision shadow: " + name) }
        }
        func revisions(_ id: UUID) throws -> [Int] {
            let data = try Data(contentsOf: resolved)
            return try data.split(separator: 10).compactMap { row in
                let frame = try JSONDecoder().decode(VoiceSessionReducerSelfTest.RecordedFrame.self, from: Data(row))
                if case .task(.revised(let task, let revision)) = frame.event, task == TaskID(id) { return revision }
                return nil
            }
        }
        func speak(_ text: String) async -> AgentTurn {
            agent.userSpeechStarted()
            agent.userSpeechEnded()
            return await agent.handle(text, source: .voice)
        }
        await capture.beginSession(captureAudio: false)
        conversation.resetForTesting(); precedingTaskIDs = Set(conversation.taskBridge.cachedTasks.map(\.id))
        conversation.workerProviderForTesting = VoiceWorkLifecycleProvider(state: state)
        conversation.streamForTesting = { _, messages in
            let request = messages.last?.content ?? ""
            let response: String
            if request.hasSuffix("Use the updated request") { response = "<revise id=\"1\"/>" }
            else if request.hasSuffix("Revise missing task") { response = "<revise id=\"999\"/>" }
            else if request.hasSuffix("What is a haiku?") { response = "<answer/>A haiku is a short poem." }
            else { response = "<use_tools/>" }
            return AsyncThrowingStream { $0.yield(response); $0.finish() }
        }
        await state.parkNext(answer: "The old task result must not announce this.")
        _ = await speak("Check the active app and its running sessions.")
        for _ in 0..<200 {
            if await state.isParked { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        let parked = await state.isParked
        let job = currentCapture()
        check(parked && scopedVoiceRows().first?.status == .running, "R01 actual planned worker did not park")
        guard parked, let job else {
            await state.release()
            await capture.endSession(source: .done)
            conversation.resetForTesting(); precedingTaskIDs = Set(conversation.taskBridge.cachedTasks.map(\.id))
            return (checks, failures)
        }
        do {
            check(try revisions(job.id).isEmpty, "R02 initial work already had a revision event")
            let named = await speak("It is called Camille")
            check(AgentEntityResolver.namingTarget(in: "It is called Camille") != nil
                    && named.reply.lowercased().contains("camille")
                    && scopedVoiceRows().first?.id == job.id.uuidString && job.work.revision == 1
                    && job.work.followUps == ["It is called Camille"],
                  "R03 actual naming answer did not revise same original work")
            check(try revisions(job.id) == [1], "R04 actual naming revision missing exact event")
            let beforeSide = try revisions(job.id)
            let side = await speak("What is a haiku?")
            let afterSide = try revisions(job.id)
            check(side.reply == "A haiku is a short poem." && job.work.revision == 1 && afterSide == beforeSide,
                  "R05 side question changed revision or emitted revision event")
            let parsed = await speak("Use the updated request")
            check(parsed.reply == "Got it. I'll use that correction." && job.work.revision == 2
                    && job.work.followUps == ["It is called Camille", "Use the updated request"],
                  "R06 parsed revision did not reach same actual work")
            check(try revisions(job.id) == [1, 2], "R07 parsed revision missing ordered exact event")
            let beforeMissing = try revisions(job.id)
            let missing = await speak("Revise missing task")
            let afterMissing = try revisions(job.id)
            check(missing.reply == "That task has already finished. What would you like me to do next?"
                    && job.work.revision == 2 && afterMissing == beforeMissing,
                  "R08 invalid task index changed work or emitted revision")
            _ = await speak("Use the updated request")
            check(try revisions(job.id) == [1, 2, 3], "R09 repeated accepted revision missing exact sequence")
            let beforeCancel = try revisions(job.id)
            conversation.cancel(job.id)
            let afterCancel = try revisions(job.id)
            check(scopedVoiceRows().first?.status == .cancelled && afterCancel == beforeCancel,
                  "R10 ordinary cancellation emitted a revision")
            let stale = await speak("Use the updated request")
            let afterStale = try revisions(job.id)
            check(stale.reply == "That task has already finished. What would you like me to do next?"
                    && job.work.revision == 3 && afterStale == beforeCancel,
                  "R11 cancelled task admitted stale revision")
            await capture.endSession(source: .done)
            conversation.resetForTesting(); precedingTaskIDs = Set(conversation.taskBridge.cachedTasks.map(\.id))
            let afterReset = try revisions(job.id)
            check(afterReset == beforeCancel, "R12 session close/reset emitted revision")
            print("VOICE_REVISION_SHADOW_TRACE events=\(afterReset.count) revision=\(job.work.revision) parked=\(parked)")
        } catch {
            failures.append("revision shadow: actual recorder could not supply complete ordered receipts")
        }
        await state.release()
        if let task = job.task { await task.value }
        await capture.endSession(source: .done)
        conversation.resetForTesting(); precedingTaskIDs = Set(conversation.taskBridge.cachedTasks.map(\.id))
        return (checks, failures)
    }

    /// P1-06, H1 #17: a correction restarts the round clock.
    ///
    /// A spoken objective is revised by the person mid-flight. The revision starts the round
    /// deadline over, and once every ten seconds it also tops the ceiling back up to half of
    /// what the budget allows — so a corrected objective does not begin against the clock the
    /// *previous* wording spent. Measured on 2026-09-14: three follow-up revisions each ended
    /// "The model took too long to answer." two to three seconds after the follow-up arrived.
    ///
    /// The correction is delivered while the model is parked mid-round, so the case does not
    /// depend on winning a race with a stopwatch. A second correction inside the interval must
    /// not refill again, and the round after it must then run out of ceiling.
    @MainActor
    static func runRevisionCases(check: (String) -> Void) async -> [String] {
        var failures: [String] = []
        func fail(_ name: String) { failures.append(name); check(name) }

        let answer = "Two unread messages."
        let timeoutSentence = AgentReplyRenderer.render(.timedOut(lastVerified: nil), voice: true)
        let budget = ToolLoopBudget(
            perRound: .seconds(2), perReadCall: .seconds(1),
            ceiling: .seconds(3), coldLoadAllowance: .zero)
        let call = "<tool_call>{\"name\":\"computer.active_app\",\"arguments\":{},"
            + "\"rationale\":\"look\"}</tool_call>"

        /// One worker run: two slow tool rounds and then the answer, with the corrections
        /// delivered into the parked rounds named in `parkOn`.
        @MainActor
        func run(parkOn: Set<Int>) async -> (String, VoiceBudgetProbe)? {
            let work = VoiceConversationWork("check the frontmost app and its running sessions")
            let agent = RealtimeAgent(voiceWorker: work)
            let probe = VoiceBudgetProbe(parkOn: parkOn)
            agent.localModelProviderForTesting = VoiceBudgetScriptProvider(
                probe: probe, script: [call, call, answer, "A stale answer."])
            agent.budgetForTesting = budget
            let previousExecutor = AgentToolExecutor.fakeForTesting
            AgentToolExecutor.fakeForTesting = { _, _ in
                AgentToolResult(summary: "Nothing is frontmost.")
            }
            defer { AgentToolExecutor.fakeForTesting = previousExecutor }
            let task = Task { @MainActor in await agent.runVoiceObjective() }
            for index in parkOn.sorted() {
                // Long enough to cover the rounds before it: each of those spends its own
                // scripted delay first, and this is a wall clock, not a model.
                var reached = false
                for _ in 0..<2_000 {
                    if await probe.isParked(on: index) { reached = true; break }
                    try? await Task.sleep(for: .milliseconds(3))
                }
                guard reached else {
                    let reply = await task.value
                    fail("the worker never parked on round \(index) — it made "
                        + "\(await probe.roundsMade()) round(s) and answered \"\(reply)\"")
                    return nil
                }
                work.append("and only the unread ones")
                await probe.release(on: index)
            }
            let reply = await task.value
            return (reply, probe)
        }

        do {
            guard let (reply, _) = await run(parkOn: [2]) else { return failures }
            if reply != answer { fail("a corrected objective answered \"\(reply)\"") }
            if reply.contains(timeoutSentence) {
                fail("a corrected objective was charged to the clock the first wording spent: "
                    + "\"\(reply)\"")
            }
        }
        do {
            guard let (reply, _) = await run(parkOn: [2, 3]) else { return failures }
            if reply.contains(answer) {
                fail("a second correction inside the interval refilled the ceiling again: "
                    + "\"\(reply)\"")
            }
            if !reply.contains(timeoutSentence) {
                fail("a second correction inside the interval still left a reply: \"\(reply)\"")
            }
        }
        return failures
    }
}

/// P1-06's probe: one scripted round at a time, with the rounds the case names parked so a
/// correction can be delivered while the model is provably mid-round. Rounds are numbered
/// from one, as a person would count them.
private actor VoiceBudgetProbe {
    private let parkOn: Set<Int>
    private var call = 0
    private var parked: Set<Int> = []
    private var released: Set<Int> = []

    init(parkOn: Set<Int>) { self.parkOn = parkOn }

    func isParked(on round: Int) -> Bool { parked.contains(round) }

    /// How many model calls this probe was actually asked for. Named in a failure, because
    /// "never parked" is a symptom and this is the fact.
    func roundsMade() -> Int { call }

    func release(on round: Int) { released.insert(round) }

    /// One round's text, after the delay this case wants that round to take. A parked round
    /// is given a shorter one, so the round's own deadline still has room for the case to
    /// deliver the correction while the model is parked.
    func response(script: [String], delay: Duration) async throws -> String {
        call += 1
        let round = call
        let wait = parkOn.contains(round) ? delay * 4 / 5 : delay
        if wait > .zero { try await Task.sleep(for: wait) }
        if parkOn.contains(round) {
            parked.insert(round)
            while !released.contains(round) {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        return round <= script.count ? script[round - 1] : "There is nothing more to add."
    }
}

private struct VoiceBudgetScriptProvider: LLMProvider {
    let id = LLMProviderID.appLLM
    let probe: VoiceBudgetProbe
    let script: [String]
    /// Long enough that two of them nearly spend a three-second ceiling, and the refill that
    /// follows has to be what pays for the round after them.
    let delay: Duration = .seconds(1)
    var contextTokens: Int { 8_192 }
    var unavailableReason: String? { get async { nil } }
    func countTokens(_ text: String) async throws -> Int { text.count / 4 }
    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        let text = try await probe.response(script: script, delay: delay)
        return LLMCompletion(text: text, generatedTokens: text.count, duration: 0)
    }
}

private actor VoiceWorkLifecycleProbe {
    private(set) var calls = 0
    private(set) var isParked = false
    private var shouldPark = false
    private var released = false
    private var parkedAnswer = ""

    func parkNext(answer: String) {
        shouldPark = true
        released = false
        isParked = false
        parkedAnswer = answer
    }
    func release() { released = true }
    func response() async throws -> String {
        calls += 1
        if shouldPark {
            isParked = true
            while !released {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(5))
            }
            shouldPark = false
            return parkedAnswer
        }
        return "The objective remains active."
    }
}

private struct VoiceWorkLifecycleProvider: LLMProvider {
    let id = LLMProviderID.appLLM
    let state: VoiceWorkLifecycleProbe
    var contextTokens: Int { 8_192 }
    var unavailableReason: String? { get async { nil } }
    func countTokens(_ text: String) async throws -> Int { text.count / 4 }
    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        let answer = try await state.response()
        return LLMCompletion(text: answer, generatedTokens: answer.count, duration: 0)
    }
}

private actor VoiceFailureWorkerProbe {
    private(set) var parked = false
    private(set) var roundTwoAt: ContinuousClock.Instant?
    private var released = false
    private var rounds = 0
    func release() { released = true }
    func response() async throws -> String {
        rounds += 1
        if rounds == 1 {
            parked = true
            while !released {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(2))
            }
            return #"<tool_call>{"name":"computer.active_app","arguments":{},"rationale":"Inspect the app"}</tool_call>"#
        }
        roundTwoAt = .now
        return "The read finished."
    }
}

private struct VoiceFailureWorkerProvider: LLMProvider {
    let id = LLMProviderID.appLLM
    let state: VoiceFailureWorkerProbe
    var contextTokens: Int { 8_192 }
    var unavailableReason: String? { get async { nil } }
    func countTokens(_ text: String) async throws -> Int { text.count / 4 }
    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        let text = try await state.response()
        return LLMCompletion(text: text, generatedTokens: text.count, duration: 0)
    }
}

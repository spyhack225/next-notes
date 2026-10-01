import Foundation

/// Scripted models, real worker/runner/approval/final validity. Only external effects are replaced.
enum VoiceDuplexWorkSelfTest {
    @MainActor
    static func run() async -> Bool {
        let shadow = VoiceSession.shared
        shadow.resetDiagnosticsForTesting()
        let conversation = VoiceConversationCoordinator.shared
        let capture = AgentCaptureController.shared
        let agent = RealtimeAgent.shared
        let speech = AgentSpeechSynthesizer.shared
        let probe = DuplexWorkProbe()
        var failures: [String] = []
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
            await probe.recordFire(tool.id, key: arguments["key"], revision: conversation.jobs.first?.work.revision ?? -1)
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
            conversation.resetForTesting()
            PlannerBackends.wholeTurnOverrideForTesting = oldWhole
            AgentCapabilityManifestBuilder.inputsOverrideForTesting = oldInputs
            AgentToolExecutor.fakeForTesting = oldFake
            AgentToolExecutor.fireOverrideForTesting = oldFire
            AgentToolExecutor.policyOverrideForTesting = oldPolicy
            speech.restoreSystemBacking()
            Task { @MainActor in await capture.endSession(source: .done) }
        }
        await capture.endSession(source: .done)
        AgentSession.shared.forgetAllConversations()
        await capture.beginSession(captureAudio: false)
        conversation.resetForTesting()
        conversation.prewarmObserverForTesting = {}
        conversation.workerProviderForTesting = DuplexWorkProvider(probe: probe)
        conversation.streamForTesting = { _, messages in
            if messages.last?.content.hasSuffix("Check the frontmost app and its running sessions, then press escape in the front window.") == true {
                return AsyncThrowingStream { $0.yield("<use_tools/>"); $0.finish() }
            }
            return await probe.frontend()
        }
        let objectiveStarted = ContinuousClock.now
        _ = await speak("Check the frontmost app and its running sessions, then press escape in the front window.")
        print("VOICE_DUPLEX_WORK_SETUP: jobs=\(conversation.jobs.count) status=\(conversation.jobs.first?.status ?? "absent")")
        check(await eventually { await probe.rounds >= 1 }, "real worker never began round one")

        // Partial envelopes still own input. Planning and the real read must nevertheless run.
        let question = Task { @MainActor in await measuredHandle("What is a haiku?", probe: probe) }
        check(await eventually { await probe.frontendCount >= 1 }, "side frontend never entered")
        await probe.yield("<ans")
        await probe.release(1)
        check(await eventually(milliseconds: 200) { await probe.rounds >= 3 },
              "A1 planning/read stalled on an unclassified side question")
        check(conversation.inputPending, "partial answer envelope released input")
        let overlap = await probe.startsInsideFrontend()
        check(overlap >= 2, "A1 fewer than two worker round starts inside frontend generation")
        let readFired = await probe.fires.contains { $0.tool == "computer.active_app" }
        check(readFired, "actual read did not reach post-validity fire during pending input")
        await probe.yield("wer/>A haiku is a short poem.")
        check(await eventually(milliseconds: 200) { !conversation.inputPending },
              "A3 parsed answer route stayed held until the answer stream finished")
        print("VOICE_DUPLEX_WORK_OVERLAP: rounds=\(await probe.rounds) input_pending=\(conversation.inputPending)")
        await probe.finishFrontend()
        _ = await question.value
        await probe.release(3)
        check(await eventually { PermissionGate.shared.pending?.toolID == "computer.press_key" },
              "real write did not reach its approval card")

        // Approve the old call while correction is still partial. The action must wait,
        // then recheck the old revision before fire and replan against the new words.
        let correction = Task { @MainActor in await measuredHandle("Actually use tab instead.", probe: probe) }
        check(await eventually { await probe.frontendCount >= 2 }, "correction frontend never entered")
        await probe.yield("<revise id=\"")
        if let request = PermissionGate.shared.pending {
            check(PermissionGate.shared.respond(id: request.id, approved: true), "valid old key approval refused")
        }
        try? await Task.sleep(for: .milliseconds(80))
        check(await probe.fires.allSatisfy { $0.key == nil }, "A2 stale key fired during unclassified correction")
        await probe.yield("1\"/>")
        check(await eventually(milliseconds: 200) { conversation.jobs.first?.work.revision == 1 },
              "parsed control envelope did not apply before its stream finished")
        await probe.finishFrontend()
        _ = await correction.value
        check(conversation.jobs.first?.work.revision == 1, "real correction did not revise existing work")
        check(await eventually { PermissionGate.shared.pending?.toolID == "computer.press_key" },
              "corrected objective did not replan to another approval")
        if let request = PermissionGate.shared.pending {
            check(PermissionGate.shared.respond(id: request.id, approved: true), "corrected key approval refused")
        }
        check(await eventually { conversation.jobs.first?.status == "finished" }, "A5 real worker did not finish")
        check(conversation.jobs.first?.result == "Done with the duplex check.", "A5 worker finished with an incorrect result")
        check(objectiveStarted.duration(to: .now) <= .seconds(10), "A5 objective exceeded ten seconds")
        let writes = await probe.fires.filter { $0.key != nil }
        check(writes.count == 1 && writes.first?.key == "tab" && writes.first?.revision == 1,
              "final fire was not exactly the approved current-revision tab call")
        print("VOICE_DUPLEX_WORK_EFFECTS: \(writes.map { "\($0.key ?? "none")@\($0.revision)" }.joined(separator: ","))")

        // A4 runs the original actual planner with a frontend that yields nothing.
        conversation.resetForTesting()
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
        check(await eventually { conversation.jobs.first?.status == "finished" }, "A4 read worker did not complete")
        check(conversation.jobs.first?.result == "The read finished.", "A4 read worker finished with an incorrect result")
        check(conversation.effectHoldEpoch != nil, "A4 read completion released failed input effect hold")
        let normalTimes = await probe.handleLatencies
        let failureTimes = await failureProbe.handleLatencies
        let handleTimes = normalTimes + failureTimes
        check(handleTimes.count == 3 && handleTimes.allSatisfy { $0 <= 50 }, "A3 handle→stream exceeded 50 ms or was absent")
        print("VOICE_DUPLEX_WORK_TIMING: handle_ms=\(handleTimes) overlap_starts=\(overlap) failure_resume_ms=\(resumed.map { ModelPassRecorder.milliseconds(failedAt.duration(to: $0)) } ?? -1)")

        // A read that has already entered fire may complete during a correction.
        // Keep its actual evidence before discarding only the stale plan disposition.
        conversation.resetForTesting()
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
        conversation.resetForTesting()
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
        for failure in failures { print("VOICE_DUPLEX_WORK_WRONG: \(failure)") }
        print(failures.isEmpty ? "VOICE_DUPLEX_WORK_OK" : "VOICE_DUPLEX_WORK_FAILED")
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
    let probe: DuplexWorkProbe
    var contextTokens: Int { 8_192 }
    var unavailableReason: String? { get async { nil } }
    func countTokens(_ text: String) async throws -> Int { text.count / 4 }
    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        let text = try await probe.response(user: user)
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

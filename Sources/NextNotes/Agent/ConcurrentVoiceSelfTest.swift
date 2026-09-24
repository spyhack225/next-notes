import Foundation

enum ConcurrentVoiceSelfTest {
    @MainActor
    static func run() async -> Bool {
        let conversation = VoiceConversationCoordinator.shared
        let agent = RealtimeAgent.shared
        let capture = AgentCaptureController.shared
        let synth = AgentSpeechSynthesizer.shared
        let recorder = RecordingSpeechBacking()
        let probe = ConcurrentWorkProbe()
        var failures: [String] = []
        func check(_ value: Bool, _ message: String) { if !value { failures.append(message) } }
        await capture.beginSession(captureAudio: false)
        AgentSession.shared.clear()
        conversation.resetForTesting()
        synth.useTestingBacking(recorder)
        conversation.streamForTesting = { _, messages in
            let latest = messages.last?.content ?? ""
            let response: String
            if latest.hasSuffix("What is a haiku?") { response = "<answer/>A haiku is a short poem." }
            else if latest.hasSuffix("Actually check tomorrow instead.") { response = "<revise id=\"1\"/>" }
            else if latest.hasSuffix("Unclear instruction.") { response = "<unknown/>" }
            else { response = "<use_tools/>" }
            return AsyncThrowingStream { continuation in
                continuation.yield(response)
                continuation.finish()
            }
        }
        conversation.workerForTesting = { work in
            await probe.enter(work.id)
            while !(await probe.released(work.id)) && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(10))
            }
            return "The verified check finished."
        }
        func speak(_ text: String) async -> AgentTurn {
            agent.userSpeechStarted()
            agent.userSpeechEnded()
            return await agent.handle(text, source: .voice)
        }
        // P0-06: the worker prewarm belongs to plausible work, never to speech start.
        let prewarmCount = PrewarmTriggerCounter()
        conversation.prewarmObserverForTesting = { prewarmCount.value += 1 }
        agent.userSpeechStarted()
        for _ in 0..<10 where prewarmCount.value == 0 { try? await Task.sleep(for: .milliseconds(5)) }
        check(prewarmCount.value == 0, "speech start prewarmed the worker model")
        _ = await speak("Check my calendar.")
        for _ in 0..<50 {
            if prewarmCount.value == 1 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        check(prewarmCount.value == 1, "a .newWork route did not prewarm the worker model")
        conversation.prewarmObserverForTesting = nil
        for _ in 0..<50 {
            if await probe.count == 1 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let first = conversation.jobs.first
        check(first != nil && conversation.hasActiveWork && !agent.isThinking,
              "work still owns the conversational response lane")
        let side = await speak("What is a haiku?")
        check(side.reply == "A haiku is a short poem.", "side conversation waited for or lost the worker")
        check(first?.work.revision == 0 && conversation.jobs.first?.status == "running",
              "side question revised/cancelled the worker")
        _ = await speak("Actually check tomorrow instead.")
        check(first?.work.revision == 1 && first?.work.prompt.contains("Check my calendar.") == true
              && first?.work.prompt.contains("tomorrow") == true,
              "correction lost original objective or worker identity")
        _ = await speak("Also inspect the active app.")
        check(conversation.jobs.count == 2 && conversation.jobs.allSatisfy { $0.status == "running" },
              "a second independent task replaced the first")

        agent.userSpeechStarted()
        if let id = first?.id { await probe.release(id) }
        try? await Task.sleep(for: .milliseconds(50))
        check(conversation.jobs.first?.status == "finished", "background completion waited on the user's speech")
        check(!VoiceAnnouncementQueue.shared.flush(userHasFloor: true), "result spoke over the user")
        agent.userSpeechEnded()
        _ = await agent.handle("Cancel that", source: .voice)
        check(conversation.jobs.last?.status == "cancelled" && conversation.jobs.first?.status == "finished",
              "cancellation affected the wrong independent task")

        _ = await speak("Unclear instruction.")
        check(!conversation.inputPending,
              "a failed frontend turn kept the round barrier closed: reads stayed frozen")
        check(conversation.effectHoldEpoch != nil,
              "an unclassified failure did not hold effects")
        agent.discardVoiceInput()
        check(!conversation.inputPending && conversation.effectHoldEpoch == nil,
              "discarded input left execution blocked forever")
        let permissions = PermissionGate.shared
        let firstRequest = PermissionRequest(toolID: "computer.click", title: "First task",
            detail: "Synthetic approval", risk: .modify, arguments: [:], taskID: "first")
        let nextRequest = PermissionRequest(toolID: "computer.click", title: "Second task",
            detail: "Synthetic approval", risk: .modify, arguments: [:], taskID: "second")
        let firstApproval = Task { await permissions.ask(firstRequest) }
        for _ in 0..<50 where permissions.pending == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let nextApproval = Task { await permissions.ask(nextRequest) }
        for _ in 0..<50 where permissions.queuedCount == 0 {
            try? await Task.sleep(for: .milliseconds(10))
        }
        check(permissions.pending?.id == firstRequest.id && permissions.queuedCount == 1,
              "a second worker was refused instead of waiting for approval")
        IslandState.shared.showBackgroundAgentReply("Another task finished.")
        if case .agentProposal(let visible) = IslandState.shared.kind {
            check(visible.id == firstRequest.id, "background result replaced the visible approval")
        } else {
            check(false, "background result hid an unanswered approval")
        }
        permissions.cancelPending(taskID: "first")
        check(permissions.pending?.id == nextRequest.id,
              "task cancellation dismissed another worker's queued approval")
        _ = permissions.respond(id: nextRequest.id, approved: false)
        let firstApproved = await firstApproval.value
        let nextApproved = await nextApproval.value
        check(!firstApproved && !nextApproved && permissions.pending == nil,
              "approval queue lost cancellation or refusal")
        conversation.streamForTesting = { _, _ in
            await probe.waitForFrontend()
            return AsyncThrowingStream { continuation in
                continuation.yield("<answer/>The earlier answer finished.")
                continuation.finish()
            }
        }
        let earlierAnswer = Task { await speak("Answer while I begin another thought.") }
        for _ in 0..<50 {
            if await probe.frontendWaiting { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        conversation.inputActivityStarted()
        await probe.releaseFrontend()
        _ = await earlierAnswer.value
        check(conversation.inputPending,
              "an older answer released a newer acoustic input's effect barrier")
        agent.discardVoiceInput()

        // P0-07: a failed frontend turn resolves its own epoch, so a worker's read
        // round resumes; only an effect waits for a classified input. Today the
        // failure leaves the round barrier closed and the read never resumes.
        conversation.resetForTesting()
        conversation.responseDeadlineForTesting = .milliseconds(150)
        conversation.streamForTesting = { _, messages in
            let latest = messages.last?.content ?? ""
            if latest.hasSuffix("What is a haiku?") {
                return AsyncThrowingStream { continuation in
                    continuation.yield("<answer/>A haiku is a short poem.")
                    continuation.finish()
                }
            }
            // The worker is started the way production starts one: the frontend's
            // real <use_tools/> decision. The deterministic tool-shape gate misses
            // the trailing period, so this branch is what routes the request to work.
            if latest.hasSuffix("Check my calendar.") {
                return AsyncThrowingStream { continuation in
                    continuation.yield("<use_tools/>")
                    continuation.finish()
                }
            }
            // "Stall please." never yields: the frontend deadline is the outcome.
            return AsyncThrowingStream { _ in }
        }
        let effectGate = EffectGateProbe()
        conversation.workerForTesting = { work in
            let worker = RealtimeAgent(voiceWorker: work)
            await effectGate.holdUntilReleased()
            await effectGate.markReadReached()
            await worker.waitForVoiceInput()
            await effectGate.markReadResumed()
            guard await worker.mayCommitEffect(risk: .write) else { return "Stopped." }
            await effectGate.markWrite()
            return "The verified check finished."
        }
        _ = await speak("Check my calendar.")
        agent.userSpeechStarted()
        agent.userSpeechEnded()
        await effectGate.releaseWorker()
        for _ in 0..<50 {
            if await effectGate.readReached { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let stalled = await agent.handle("Stall please.", source: .voice)
        check(stalled.reply == VoiceConversationCoordinator.deadlineReply,
              "the stalled turn did not fail at its deadline")
        let failureAt = ContinuousClock.now
        var readResumedAt: ContinuousClock.Instant?
        for _ in 0..<40 {
            readResumedAt = await effectGate.readResumeTime
            if readResumedAt != nil { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        check(readResumedAt != nil,
              "a failed frontend turn left the round barrier closed: reads never resumed")
        if let readResumedAt {
            check(failureAt.duration(to: readResumedAt) <= .milliseconds(200),
                  "reads resumed more than 200 ms after the frontend failure")
        }
        try? await Task.sleep(for: .milliseconds(300))
        let heldWrite = await effectGate.writeTime
        check(heldWrite == nil,
              "a write committed while the failed input was still unclassified")
        let classifiedAt = ContinuousClock.now
        let classified = await speak("What is a haiku?")
        check(classified.reply == "A haiku is a short poem.",
              "the classified turn did not answer")
        var committedAt: ContinuousClock.Instant?
        for _ in 0..<40 {
            committedAt = await effectGate.writeTime
            if committedAt != nil { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        check(committedAt != nil, "a classified turn did not release the held effect")
        if let committedAt {
            check(classifiedAt.duration(to: committedAt) <= .milliseconds(200),
                  "the held effect committed more than 200 ms after classification")
        }
        _ = await agent.handle("Stall please.", source: .voice)
        check(conversation.effectHoldEpoch != nil,
              "a failed frontend turn did not hold effects")
        conversation.closeSession()
        check(conversation.effectHoldEpoch == nil, "closing the session left an effect hold")
        check(!conversation.inputPending, "closing the session left the input barrier closed")

        conversation.resetForTesting()
        await capture.endSession(source: .done)
        synth.restoreSystemBacking()
        for failure in failures { SelfTest.diagnostic("CONCURRENT_VOICE_WRONG: \(failure)") }
        print(failures.isEmpty ? "CONCURRENT_VOICE_OK" : "CONCURRENT_VOICE_FAILED")
        return failures.isEmpty
    }
}

private actor ConcurrentWorkProbe {
    private var entered: Set<UUID> = []
    private var finished: Set<UUID> = []
    private(set) var frontendWaiting = false
    private var frontendReleased = false
    var count: Int { entered.count }
    func enter(_ id: UUID) { entered.insert(id) }
    func release(_ id: UUID) { finished.insert(id) }
    func released(_ id: UUID) -> Bool { finished.contains(id) }
    func waitForFrontend() async {
        frontendWaiting = true
        while !frontendReleased && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
    func releaseFrontend() { frontendReleased = true }
}

/// P0-07: records when the fake worker reached its read round, when that round
/// resumed, and when its write-risk effect committed. Instants, so "within 200 ms"
/// is a measurement rather than the shape of a polling loop.
private actor EffectGateProbe {
    private var workerReleased = false
    private var readReachedAt: ContinuousClock.Instant?
    private var readResumedAt: ContinuousClock.Instant?
    private var writeAt: ContinuousClock.Instant?

    var readReached: Bool { readReachedAt != nil }
    var readResumeTime: ContinuousClock.Instant? { readResumedAt }
    var writeTime: ContinuousClock.Instant? { writeAt }

    func holdUntilReleased() async {
        while !workerReleased && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
    func releaseWorker() { workerReleased = true }
    func markReadReached() { if readReachedAt == nil { readReachedAt = ContinuousClock.now } }
    func markReadResumed() { if readResumedAt == nil { readResumedAt = ContinuousClock.now } }
    func markWrite() { if writeAt == nil { writeAt = ContinuousClock.now } }
}

/// Counts `prewarmWorkerModel` triggers through the coordinator's test seam.
@MainActor
private final class PrewarmTriggerCounter {
    var value = 0
}

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
        _ = await speak("Check my calendar.")
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
        check(conversation.inputPending, "unclassified input released pending effects")
        agent.discardVoiceInput()
        check(!conversation.inputPending, "discarded input left execution blocked forever")
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
        conversation.resetForTesting()
        await capture.endSession(source: .done)
        synth.restoreSystemBacking()
        for failure in failures { print("CONCURRENT_VOICE_WRONG: \(failure)") }
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

import Foundation

enum TaskReceiptStatus: Sendable, Equatable, Codable {
    case accepted, duplicate, refusedApprovalPending, refusedNeedsConfirmation
    case refusedUnavailable(String)
}
struct TaskReceipt: Sendable, Equatable, Codable {
    let id: TaskID?
    let status: TaskReceiptStatus
    let title: String

    var spokenAcknowledgment: String {
        switch status {
        case .accepted: "I'm on it."
        case .duplicate: "I've already taken that request."
        case .refusedApprovalPending: "Please answer the approval that's waiting first."
        case .refusedNeedsConfirmation: "Please confirm that task first."
        case .refusedUnavailable(let reason): reason
        }
    }
}

/// The prescribed single-ledger bridge. It owns no task rows, worker map, delivery
/// bus, or effect policy: the existing Manager remains the durable row owner.
@MainActor
final class TaskBridge {
    static let shared = TaskBridge(manager: .shared)
    private let manager: AgentTaskManager
    func bindVoiceJobOwner(_ owner: VoiceConversationCoordinator) -> Bool {
        manager.bindVoiceJobOwner(owner)
    }
    init(manager: AgentTaskManager) { self.manager = manager }
    var permitsHarness: Bool { manager.permitsTaskBridgeHarness }

    func stopTypedReplyOutput() {
        manager.stopTypedReplyOutput(sessionID: AgentSession.shared.sessionID)
    }

    func runTypedObjective(_ text: String, agent: RealtimeAgent) async -> AgentTurn {
        guard !SelfTest.isRunning || permitsHarness else {
            return AgentTurn(reply: "The typed test has no isolated task owner.", delegated: false)
        }
        let session = AgentSession.shared.sessionID
        let retained = manager.typedWorkers(bridge: self, sessionID: session)
        let indexed = retained.filter { !$0.task.isCancelled }
        if indexed.isEmpty, VoiceTurnPolicy.isExplicitWorkCancellation(text) {
            let reply = retained.last.map { "Stopping " + TaskStatusRenderer.title($0.work.original) + " now." }
                ?? "There isn't a task running."
            return agent.finishTypedControl(reply, userWords: text)
        }
        if !indexed.isEmpty {
            let token = UUID()
            for live in indexed { live.work.beginTypedInput(token) }
            if VoiceTurnPolicy.isExplicitWorkCancellation(text) {
                let first = indexed[indexed.count - 1]
                manager.cancel(first.id.uuidString)
                for live in indexed { live.work.resolveTypedInput(token) }
                return agent.finishTypedControl("Stopping " + TaskStatusRenderer.title(first.work.original) + " now.", userWords: text)
            }
            if VoiceTurnPolicy.isStatusQuestion(text) {
                let reply = TaskStatusRenderer.spoken(indexed.compactMap { self.taskRecord(TaskID($0.id)) })
                for live in indexed { live.work.resolveTypedInput(token) }
                return agent.finishTypedControl(reply, userWords: text)
            }
            let taskLines = indexed.enumerated().map { "\($0.offset + 1). \($0.element.work.original)" }.joined(separator: "\n")
            let messages = AgentSession.shared.chatHistoryForCurrentTurn(maxCharacters: 6_000,
                scrubToolClaims: true, perMessageCharacters: 2_000) + [LLMChatMessage(role: .user,
                content: "Active tasks:\n" + taskLines + "\n\nLatest user speech:\n" + text)]
            let chunks = await LocalVoiceFrontend.shared.stream(system: LocalVoiceSplitResponse.routeRules,
                messages: messages, maxTokens: 200)
            var snapshot = ""
            do { for try await chunk in chunks { snapshot += chunk } }
            catch {
                guard indexed.allSatisfy({ $0.work.hasTypedInput(token) }) else {
                    return AgentTurn(reply: "", delegated: false)
                }
                // Classification failure keeps writes held until a later actual
                // turn resolves them. It does not relabel this input a cancellation.
                return agent.finishTypedControl("I couldn't understand that follow-up. The task is waiting.", userWords: text)
            }
            // A newer typed turn can replace this classification while its
            // existing frontend stream is suspended. Only that newest token may
            // append a correction or release the SAME work's write hold.
            guard indexed.allSatisfy({ $0.work.hasTypedInput(token) }) else {
                return AgentTurn(reply: "", delegated: false)
            }
            switch VoiceFrontendEnvelope.parse(snapshot) {
            case .revise(let number, let proposed) where indexed.indices.contains(number - 1):
                let selected = indexed[number - 1]
                let candidate = proposed?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let correction = !candidate.isEmpty && ObjectiveFidelity.accepts(candidate, userWords: text) ? candidate : text
                let saved = manager.reviseTypedObjective(id: selected.id, correction: correction,
                    bridge: self, sessionID: session)
                if saved { for live in indexed { live.work.resolveTypedInput(token) } }
                return agent.finishTypedControl(saved ? "Got it. I'll use that correction." : "I couldn't save that correction. The task is waiting.", userWords: text)
            case .status(let number):
                let selected = number.flatMap { indexed.indices.contains($0 - 1) ? [indexed[$0 - 1]] : nil } ?? indexed
                let reply = TaskStatusRenderer.spoken(selected.compactMap { self.taskRecord(TaskID($0.id)) })
                for live in indexed { live.work.resolveTypedInput(token) }
                return agent.finishTypedControl(reply, userWords: text)
            case .cancel:
                // A model-only cancellation is insufficient for typed control.
                for live in indexed { live.work.resolveTypedInput(token) }
                return agent.finishTypedControl("Please say explicitly if you want me to stop that task.", userWords: text)
            case .answer(let answer):
                for live in indexed { live.work.resolveTypedInput(token) }
                return agent.finishTypedControl(answer, userWords: text)
            case .newWork, .decision:
                for live in indexed { live.work.resolveTypedInput(token) }
                break
            default:
                return agent.finishTypedControl("I couldn't understand that follow-up. The task is waiting.", userWords: text)
            }
        }
        let work = VoiceConversationWork(text, userWords: text)
        let worker = agent.makeTypedWorker(work)
        guard let operation = manager.startTypedObjective(work: work, worker: worker,
            bridge: self, sessionID: AgentSession.shared.sessionID) else {
            return AgentTurn(reply: "I couldn't save that task, so I haven't started it.", delegated: false)
        }
        return await operation.value
    }
    func ownsTypedEffect(work: VoiceConversationWork, worker: RealtimeAgent) -> Bool {
        manager.ownsTypedEffect(work: work, worker: worker, bridge: self)
    }
    func retainsTypedOperation(work: VoiceConversationWork, worker: RealtimeAgent) -> Bool {
        manager.retainsTypedOperation(work: work, worker: worker, bridge: self)
    }

    func typedWorkerForTesting(_ id: UUID) -> TypedWorkerTestCapture? {
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-voice-duplex-work", permitsHarness else { return nil }
        guard let live = manager.typedWorkerSnapshot(id: id), live.bridge === self else { return nil }
        return TypedWorkerTestCapture(id: live.id, work: live.work, worker: live.worker, task: live.task)
    }

    private(set) var approvals: [String: SpokenApprovalState] = [:]
    private var revisedApprovalTasks: Set<TaskID> = []
    func approvalPresented(_ request: PermissionRequest, review: ToolCallReview, workRevision: Int, callerGeneration: Int? = nil) -> Bool {
        guard let callerGeneration, matchesLiveApprovalRoute(request.taskID, generation: callerGeneration, revision: workRevision),
              let raw = request.taskID, let row = manager.task(id: raw),
              row.source == "voice", row.revision == workRevision,
              case .voice(let session, _)? = row.origin,
              manager.presentVoiceApproval(request, review: review, revision: workRevision) else { return false }
        let id = TaskID(raw)
        approvals[request.id] = SpokenApprovalState(request: request, task: id, workRevision: workRevision, callerGeneration: callerGeneration,
            originSession: session, prompt: SpokenApproval.prompt(for: request, review: review, updated: revisedApprovalTasks.remove(id) != nil), recipient: session)
        return true
    }
    func offerApprovalPrompt(_ requestID: String) { VoicePlaybackDelivery.shared.enqueueApproval(requestID: requestID) }
    func approvalDecisionIsCurrent(_ request: PermissionRequest, approved: Bool, via: PermissionAnswerSurface = .card) -> Bool {
        guard let state = approvals[request.id], state.request == request,
              matchesLiveApprovalRoute(request.taskID, generation: state.callerGeneration, revision: state.workRevision),
              let row = record(state.task), row.status == .waitingForPermission,
              row.revision == state.workRevision,
              case .permission(let saved, _, _) = row.pendingInteraction, saved == request else { return false }
        if via == .voice {
            guard let current = pendingApproval(sessionID: AgentCaptureController.shared.sessionID),
                  current.request.id == request.id, current.heardStart else { return false }
            if approved {
                guard let review = ToolCallReviewStore.shared.review(id: request.id),
                      review.isReadyToRun, current.prompt.voiceMayApprove,
                      review.executionArguments(mergedOver: request.arguments) == current.prompt.executionArguments,
                      request.risk != .send || (current.prompt.readsFullMessage && current.heardFully) else { return false }
            }
        }
        return true
    }
    func approvalDecisionAdmitted(_ request: PermissionRequest, approved: Bool, via: PermissionAnswerSurface = .card) -> Bool {
        guard approvalDecisionIsCurrent(request, approved: approved, via: via),
              let state = approvals[request.id] else { return false }
        return manager.decideVoiceApproval(request, revision: state.workRevision, approved: approved,
            via: via, recipientSession: state.recipient)
    }
    func approvalWithdrawn(_ requestID: String) {
        approvals.removeValue(forKey: requestID)
        VoicePlaybackDelivery.shared.withdrawApproval(requestID: requestID)
    }
    func noteApprovalRevision(_ task: TaskID) { revisedApprovalTasks.insert(task) }
    /// A live exact proposal, not a result delivery or model-minted permission.
    func pendingApproval(sessionID: UUID?) -> SpokenApprovalState? {
        guard let pending = PermissionGate.shared.pending, let state = approvals[pending.id],
              state.request == pending, let sessionID, state.recipient == sessionID,
              AgentCaptureController.shared.isSessionActive,
              AgentCaptureController.shared.sessionID == sessionID,
              let row = record(state.task), row.source == "voice", row.status == .waitingForPermission,
              row.revision == state.workRevision,
              let taskID = UUID(uuidString: state.task.raw),
              let live = manager.voiceWorkerSnapshot(id: taskID), live.bridge === self,
              live.task?.isCancelled == false, live.work.revision == state.workRevision,
              live.worker.currentGeneration == state.callerGeneration,
              case .permission(let request, _, _) = row.pendingInteraction, request == pending,
              case .voice(let owner, _)? = row.origin, owner == state.originSession else { return nil }
        return state
    }
    func approvalIsCurrent(_ requestID: String) -> Bool {
        pendingApproval(sessionID: AgentCaptureController.shared.sessionID)?.request.id == requestID
    }
    func noteApprovalOutput(_ requestID: String, id: OutputID, generation: UInt64) {
        guard approvalIsCurrent(requestID) else { return }
        approvals[requestID]?.output = id; approvals[requestID]?.outputGeneration = generation
        approvals[requestID]?.heardStart = false; approvals[requestID]?.heardFully = false
    }
    func noteApprovalPlayback(_ requestID: String, id: OutputID, generation: UInt64, fully: Bool) {
        guard approvalIsCurrent(requestID), let state = approvals[requestID],
              state.output == id, state.outputGeneration == generation,
              AgentSpeechSynthesizer.shared.outputGeneration == generation,
              fully ? state.heardStart : RealtimeAudioSession.shared.voiceShadowOutputSnapshot?.id == id else { return }
        approvals[requestID]?.heardStart = true
        if fully { approvals[requestID]?.heardFully = true }
    }
    func reofferApproval(sessionID: UUID) {
        guard AgentCaptureController.shared.isSessionActive,
              AgentCaptureController.shared.sessionID == sessionID,
              let request = PermissionGate.shared.pending, let state = approvals[request.id],
              let taskID = UUID(uuidString: state.task.raw),
              let live = manager.voiceWorkerSnapshot(id: taskID), live.bridge === self,
              live.task?.isCancelled == false, live.work.revision == state.workRevision,
              live.worker.currentGeneration == state.callerGeneration,
              state.request == request, let row = record(state.task), row.status == .waitingForPermission,
              row.revision == state.workRevision,
              case .permission(let saved, _, _) = row.pendingInteraction, saved == request,
              case .voice(let owner, _)? = row.origin, owner == state.originSession else { return }
        approvals[request.id]?.recipient = sessionID
        resetApprovalPlayback(request.id)
        offerApprovalPrompt(request.id)
    }
    func resetApprovalPlayback(_ requestID: String) {
        guard approvals[requestID] != nil else { return }
        approvals[requestID]?.output = nil; approvals[requestID]?.outputGeneration = nil
        approvals[requestID]?.heardStart = false; approvals[requestID]?.heardFully = false
        approvals[requestID]?.clarified = false
    }
    func markApprovalClarified(_ requestID: String) { approvals[requestID]?.clarified = true }
    func respondApproval(requestID: String, approved: Bool, beforeResume: @escaping () -> Void) -> ApprovalOutcome {
        guard let pending = PermissionGate.shared.pending, pending.id == requestID else { return .noPendingRequest }
        guard let state = pendingApproval(sessionID: AgentCaptureController.shared.sessionID) else { return .notSessionOwned }
        guard state.heardStart else { return .notReady("I'll read the request first.") }
        if approved {
            guard let review = ToolCallReviewStore.shared.review(id: requestID),
                  review.id == pending.id, review.toolID == pending.toolID,
                  review.executionArguments(mergedOver: pending.arguments) == state.prompt.executionArguments else {
                return .refusedNotSpeakable("It changed on screen, so please approve it there.")
            }
            guard review.isReadyToRun, state.prompt.voiceMayApprove else {
                return .refusedNotSpeakable(state.prompt.refusal ?? "That one needs your OK on screen.")
            }
            if pending.risk == .send, !(state.prompt.readsFullMessage && state.heardFully) {
                VoicePlaybackDelivery.shared.enqueueApproval(requestID: requestID)
                return .notReady("I'll read the whole message first.")
            }
        }
        guard PermissionGate.shared.respond(id: requestID, approved: approved, duration: .once,
            scope: pending.scope, via: .voice, beforeResume: beforeResume) else { return .notReady("I couldn't save that answer. The request is still waiting.") }
        return approved ? .approved : .denied
    }

    /// Synchronous receipt of the SAME Manager's primary admission. No second row owner.
    func spawnVoiceObjective(id: UUID, objective: String, userWords: String,
                             origin: TaskOrigin?, backend: AgentBackendKind? = nil) -> TaskReceipt {
        let observe = SelfTest.isRunning && SelfTest.requested == "--selftest-voice-work-lifecycle"
            && permitsHarness ? manager.voiceJobOwner?.voiceReceiptTimingForTesting : nil
        let began = observe.map { _ in ContinuousClock.now }
        defer { if let began { observe?("bridgeTotal", began.duration(to: .now)) } }
        let admissionBegan = observe.map { _ in ContinuousClock.now }
        let receipt = admitVoiceObjective(id: id, objective: objective, userWords: userWords, origin: origin, backend: backend)
        if let admissionBegan { observe?("bridgeAdmission", admissionBegan.duration(to: .now)) }
        guard receipt.status == .accepted else { return receipt }
        if manager.task(id: id.uuidString)?.backend == AgentBackendKind.acp.rawValue { return receipt }
        guard let owner = manager.voiceJobOwner,
              owner.startAdmittedVoiceObjective(bridge: self, id: id, objective: objective, receipt: receipt) else {
            _ = manager.finishVoiceObjective(id: id, outcome: .failed("I couldn't start that task."))
            return TaskReceipt(id: nil, status: .refusedUnavailable("I couldn't start that task."), title: receipt.title)
        }
        return receipt
    }

    /// Admission remains distinct from dispatch, so a Coordinator cannot recursively spawn.
    private func admitVoiceObjective(id: UUID, objective: String, userWords: String,
                                    origin: TaskOrigin?, backend: AgentBackendKind?) -> TaskReceipt {
        let title = TaskStatusRenderer.title(objective)
        // Canonical public admission belongs to the actual current voice
        // session. Validate before duplicate/Gate lookup so a stale caller cannot borrow
        // an old receipt or publish a row attributed to another session.
        guard case .voice(let ownedSession, let ownedTurn)? = origin,
              AgentCaptureController.shared.isSessionActive,
              AgentCaptureController.shared.sessionID == ownedSession,
              ownedTurn.raw > 0 else {
            return TaskReceipt(id: nil, status: .refusedUnavailable("That voice request is no longer current."), title: title)
        }
        guard !objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return TaskReceipt(id: nil, status: .refusedUnavailable("What would you like me to do?"), title: title)
        }
        // A positive origin is required to attribute a turn or a pending approval.
        // Historical unknown origins remain unknown; they never borrow this session.
        if case .voice(let session, let turn)? = origin {
            let key = VoiceTranscriptCanonical.key(objective)
            if let same = manager.tasks.first(where: { row in
                row.source == "voice" && row.origin == .voice(sessionID: session, turn: turn)
                    && VoiceTranscriptCanonical.key(row.objective) == key
            }), let sameID = UUID(uuidString: same.id) {
                return TaskReceipt(id: TaskID(sameID), status: .duplicate,
                                   title: TaskStatusRenderer.title(same.objective))
            }
            if let pending = PermissionGate.shared.pending, let pendingID = pending.taskID,
               let row = manager.task(id: pendingID), row.source == "voice",
               case .voice(let owner, _)? = row.origin, owner == session {
                return TaskReceipt(id: nil, status: .refusedApprovalPending, title: title)
            }
        }
        guard let owner = manager.voiceJobOwner else {
            return TaskReceipt(id: nil, status: .refusedUnavailable("That task has no live conversation."), title: title)
        }
        guard owner.taskBridge === self else {
            return TaskReceipt(id: nil, status: .refusedUnavailable("That task belongs to another conversation."), title: title)
        }
        guard backend == nil || backend == .local || backend == .acp else {
            return TaskReceipt(id: nil, status: .refusedUnavailable("That task needs another Agent."), title: title)
        }
        if backend != .local {
            let choice = AgentHarnessRouter.shared.choose(for: userWords)
            guard backend != .acp || choice.backend == .acp else {
                return TaskReceipt(id: nil, status: .refusedUnavailable("That task needs another Agent."), title: title)
            }
            if choice.backend == .acp {
                if choice.needsACPConfirmation {
                    let confirmationID = ACPConfirmationGate.shared.pending?.id
                    Task { @MainActor [weak self] in
                        guard let self, ACPConfirmationGate.shared.pending?.id == confirmationID else { return }
                        let answer = await ACPConfirmationGate.shared.request(choice, utterance: userWords)
                        guard answer == .confirmedOnce,
                              AgentCaptureController.shared.isSessionActive,
                              AgentCaptureController.shared.sessionID == ownedSession else { return }
                        _ = self.spawnVoiceObjective(id: id, objective: objective, userWords: userWords,
                            origin: origin, backend: .local)
                    }
                    return TaskReceipt(id: nil, status: .refusedNeedsConfirmation, title: title)
                }
                guard let origin, manager.submitVoiceACPObjective(id: id, objective: objective,
                    userWords: userWords, origin: origin, cli: choice.acpCLI) else {
                    return TaskReceipt(id: nil, status: .refusedUnavailable("I couldn't save that task, so I haven't started it."), title: title)
                }
                return TaskReceipt(id: TaskID(id), status: .accepted, title: title)
            }
        }
        guard manager.beginVoiceObjective(id: id, objective: objective, origin: origin,
                                         userWords: userWords) else {
            return TaskReceipt(id: nil, status: .refusedUnavailable("I couldn't save that task, so I haven't started it."), title: title)
        }
        return TaskReceipt(id: TaskID(id), status: .accepted, title: title)
    }

    @discardableResult
    func beginVoiceObjective(id: UUID, objective: String, origin: TaskOrigin? = nil,
                             userWords: String? = nil) -> Bool {
        manager.beginVoiceObjective(id: id, objective: objective, origin: origin, userWords: userWords)
    }
    @discardableResult
    func finishVoiceObjective(id: UUID, result: String) -> Bool {
        manager.finishVoiceObjective(id: id, result: result)
    }
    @discardableResult
    func finishVoiceObjective(id: UUID, outcome: AgentTaskOutcome) -> Bool {
        manager.finishVoiceObjective(id: id, outcome: outcome)
    }
    func recordVoiceRevision(_ id: TaskID, revision: Int) -> Bool {
        guard let value = UUID(uuidString: id.raw) else { return false }
        return manager.recordVoiceRevision(id: value, revision: revision)
    }
    func voiceInputRequest(_ id: TaskID) -> TaskInputRequest? {
        guard let task = manager.task(id: id.raw), task.source == "voice", task.status == .waitingForInput,
              case .input(let request) = task.pendingInteraction else { return nil }
        return request
    }
    func resumeVoiceObjective(id: UUID, requestID: String, answer: String, sessionID: UUID? = nil, revision: Int? = nil) -> Bool {
        if let owner = manager.voiceJobOwner, let live = manager.voiceWorkerSnapshot(id: id) {
            guard live.coordinator === owner, live.bridge === self, live.task == nil,
                  revision == nil || revision == live.work.revision + 1 else { return false }
            let nextRevision = live.work.revision + 1
            guard manager.resumeVoiceObjective(id: id, requestID: requestID, answer: answer,
                sessionID: sessionID, revision: nextRevision) else { return false }
            VoicePlaybackDelivery.shared.withdrawQuestion(TaskID(id), requestID: requestID)
            live.work.append(answer)
            owner.voiceQuestionResumed(id: id)
            // No await/second task: the SAME Manager slot owns the actual resumed operation.
            return manager.startVoiceWorker(work: live.work, worker: live.worker, coordinator: owner,
                bridge: self, scriptedWorker: owner.workerForTesting)
        }
        // Existing saved standalone question compatibility has no live work to restart.
        // It cannot borrow an unrelated owner's slot or mint a worker from retained history.
        guard manager.voiceJobOwner == nil, !manager.hasLiveVoiceCancellationOwner(id: id),
              manager.resumeVoiceObjective(id: id, requestID: requestID, answer: answer,
                  sessionID: sessionID, revision: revision) else { return false }
        VoicePlaybackDelivery.shared.withdrawQuestion(TaskID(id), requestID: requestID)
        return true
    }
    func cancelVoiceObjective(id: UUID) -> Bool {
        if let owner = manager.voiceJobOwner,
           manager.ownsVoiceACPWorker(id: id, coordinator: owner, bridge: self) {
            return owner.cancel(id)
        }
        if let owner = manager.voiceJobOwner,
           manager.voiceWorkerSnapshot(id: id) != nil {
            guard manager.ownsVoiceWorker(id: id, coordinator: owner, bridge: self) else { return false }
            return owner.cancel(id)
        }
        guard !manager.hasLiveVoiceCancellationOwner(id: id),
              let row = record(TaskID(id)), row.source == "voice", row.status == .waitingForInput,
              case .input(let request) = row.pendingInteraction, request.taskID == row.id else { return false }
        return commitVoiceCancellation(id: id)
    }
    // Called after the existing live owner has already stopped its SAME Task.
    // Kept separate from public routing to avoid recursive cancellation.
    func commitVoiceCancellation(id: UUID) -> Bool {
        let question = voiceInputRequest(TaskID(id))
        let saved = manager.cancelVoiceObjective(id: id)
        if let question { VoicePlaybackDelivery.shared.withdrawQuestion(TaskID(id), requestID: question.id) }
        return saved
    }
    var cachedTasks: [AgentTask] { manager.tasks }
    func hasRetainedVoiceOperation(work: VoiceConversationWork, worker: RealtimeAgent) -> Bool {
        manager.hasRetainedVoiceOperation(work: work, worker: worker, bridge: self)
    }

    func liveVoiceTasks(owner: VoiceConversationCoordinator) -> [AgentTask] {
        manager.liveVoiceTasks(coordinator: owner)
    }
    func liveVoiceWorker(_ id: UUID, owner: VoiceConversationCoordinator) -> AgentTaskManager.VoiceWorkerSnapshot? {
        manager.voiceWorkerForCoordinator(id: id, coordinator: owner)
    }
    func startVoiceWorker(work: VoiceConversationWork, worker: RealtimeAgent, owner: VoiceConversationCoordinator,
                          scriptedWorker: (@MainActor (VoiceConversationWork) async -> String)?) -> Bool {
        manager.startVoiceWorker(work: work, worker: worker, coordinator: owner, bridge: self, scriptedWorker: scriptedWorker)
    }
    func voiceControlObservation(_ id: UUID) -> TaskControlObservation? { manager.voiceControlObservation(id: id) }
    func canCancelOwnedVoiceWorker(_ id: UUID, owner: VoiceConversationCoordinator) -> Bool {
        if let live = manager.voiceWorkerForCoordinator(id: id, coordinator: owner) {
            return live.task?.isCancelled != true
        }
        return manager.ownsVoiceACPWorker(id: id, coordinator: owner, bridge: self)
            && manager.voiceControlObservation(id: id) != .cancelled
    }
    func stopVoiceWorker(_ id: UUID, owner: VoiceConversationCoordinator) -> Bool {
        if manager.ownsVoiceACPWorker(id: id, coordinator: owner, bridge: self) {
            return manager.stopVoiceACPWorker(id: id, coordinator: owner, bridge: self)
        }
        guard manager.voiceWorkerForCoordinator(id: id, coordinator: owner) != nil else { return false }
        return manager.cancelVoiceWorker(id: id)
    }
    func reviseVoiceObjective(id: UUID, text: String, userWords: String? = nil) -> Bool {
        guard let owner = manager.voiceJobOwner else { return false }
        return manager.reviseVoiceWorker(id: id, text: text, coordinator: owner, bridge: self, userWords: userWords)
    }
    func liveVoiceRevision(id: UUID) -> Int? { manager.liveVoiceRevision(id: id) }
    func managedVoiceApprovalOwner(requestTaskID: String?) -> (id: TaskID, revision: Int)? {
        manager.managedVoiceApprovalOwner(requestTaskID: requestTaskID)
    }

    /// Exact existing slot route; this does not authorize a proposal or decision.
    func matchesLiveApprovalRoute(_ raw: String?, generation: Int?, revision: Int?) -> Bool {
        guard let raw, let generation, let revision, let id = UUID(uuidString: raw),
              let live = manager.voiceWorkerSnapshot(id: id), live.bridge === self,
              live.worker.currentGeneration == generation, live.work.revision == revision,
              live.worker.voiceTaskBridge === self, live.task?.isCancelled == false else { return false }
        return true
    }
    func approvalRouteRevision(_ raw: String?, generation: Int?, revision: Int?) -> Int? {
        guard matchesLiveApprovalRoute(raw, generation: generation, revision: revision),
              let owner = managedVoiceApprovalOwner(requestTaskID: raw),
              owner.revision == revision, record(owner.id)?.status == .running else { return nil }
        return owner.revision
    }
    func voiceShadowOwnsApprovalTask(_ raw: String?, generation: Int?, revision: Int?) -> Bool {
        guard matchesLiveApprovalRoute(raw, generation: generation, revision: revision), let raw, let session = AgentCaptureController.shared.sessionID,
              let row = manager.task(id: raw), case .voice(let owned, _)? = row.origin else { return false }
        return owned == session
    }

    /// A progress observation must come from the SAME live Manager task and backing revision.
    /// This bridge remains stateless; the existing Manager owns primary admission.
    @discardableResult
    func noteProgress(taskID: String, step: Int, title: String) -> Bool {
        guard let scope = AgentWorkPresentationScope.voiceProgress,
              scope.bridge === self, scope.taskID == taskID else { return false }
        guard let revision = scope.currentRevision(taskID: taskID),
              manager.noteVoiceProgress(taskID: taskID, revision: revision,
                                        origin: scope.origin, step: step, title: title) else { return false }
        VoiceSession.shared.send(.task(.progress(TaskID(taskID), step: step, title: String(title.prefix(160)))))
        return true
    }

    /// Public display projection of the same current-session canonical rows.
    /// No SQL, extra saved state, progress inference or permission is acquired.
    func islandIndicator(sessionID: UUID) -> IslandTaskIndicator? {
        let rows = cachedTasks.filter { row in
            guard case .voice(let owned, _)? = row.origin, owned == sessionID else { return false }
            let stopping = UUID(uuidString: row.id).flatMap { voiceControlObservation($0) } == .cancelled
            // A cancelled canonical row is a stop request while its SAME actual
            // Task remains retained. Its chip must not imply operation return.
            return !row.status.isTerminal || stopping
        }
        guard !rows.isEmpty else { return nil }
        if rows.contains(where: { $0.status == .waitingForPermission || $0.status == .waitingForCompatibilityCLI }) {
            return .init(label: "Waiting for your OK", count: rows.count)
        }
        if rows.count > 1 { return .init(label: "\(rows.count) things in progress", count: rows.count) }
        let row = rows[0]
        if UUID(uuidString: row.id).flatMap({ voiceControlObservation($0) }) == .cancelled {
            return .init(label: "Stopping", count: 1)
        }
        var step = row.progress.trimmingCharacters(in: .whitespacesAndNewlines)
        if step.hasPrefix("Step "), let separator = step.firstIndex(of: ":") {
            step = String(step[step.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func display(_ text: String) -> String? {
            guard AgentActivityProjector.isPublic(text) else { return nil }
            let value = AgentReplyRenderer.scrub(text, outcome: nil).trimmingCharacters(in: .whitespacesAndNewlines)
            // The chip carries a public consumer label, never a filesystem/URL value.
            guard !value.isEmpty, !value.contains("/"), !value.contains("\\") else { return nil }
            return String(value.prefix(160))
        }
        return .init(label: display(step) ?? display(TaskStatusRenderer.title(row.objective)) ?? "Background task", count: 1)
    }

    /// Same Manager cached row, never another task list or SQL read.
    func record(_ id: TaskID) -> AgentTask? { manager.task(id: id.raw) }

    /// Value projection of the SAME cached Manager row; no SQL, lease or effects proof.
    func taskRecord(_ id: TaskID) -> TaskRecord? {
        guard let row = record(id) else { return nil }
        var value = TaskRecord(row)
        if row.source == "text", row.origin == .typed, let raw = UUID(uuidString: id.raw) {
            value.controlObservation = manager.typedControlObservation(id: raw)
        }
        return value
    }

    /// Unknown origins never inherit the currently open session. No second task index.
    func indexedSessionTasks(_ sessionID: UUID?, now: Date = Date()) -> [TaskRecord] {
        guard let sessionID else { return [] }
        return manager.tasks.enumerated().filter { entry in
            let task = entry.element
            guard case .voice(let owned, _)? = task.origin, owned == sessionID else { return false }
            if ![.completed, .failed, .cancelled].contains(task.status) { return true }
            guard let finished = task.finishedAt else { return false }
            let age = now.timeIntervalSince(finished)
            return age >= 0 && age <= 600
        }.sorted { lhs, rhs in
            let left = lhs.element, right = rhs.element
            let terminals: Set<AgentTaskStatus> = [.completed, .failed, .cancelled]
            let leftTerminal = terminals.contains(left.status), rightTerminal = terminals.contains(right.status)
            if leftTerminal != rightTerminal { return !leftTerminal }
            if leftTerminal {
                let leftFinished = left.finishedAt ?? left.createdAt, rightFinished = right.finishedAt ?? right.createdAt
                if leftFinished != rightFinished { return leftFinished > rightFinished }
                return lhs.offset < rhs.offset
            }
            if left.createdAt != right.createdAt { return left.createdAt < right.createdAt }
            // SAME cached canonical rows are newest-first, even when ISO8601 dates tie.
            return lhs.offset > rhs.offset
        }.prefix(5).map { TaskRecord($0.element) }
    }
    func workStatusLines(sessionID: UUID?, now: Date = Date()) -> String {
        TaskStatusRenderer.workLines(indexedSessionTasks(sessionID, now: now), now: now)
    }

    /// Exact session index and SAME cached primary owner. No SQL on query or new task list.
    func status(_ id: TaskID? = nil, sessionID: UUID?, now: Date = Date()) -> [TaskRecord] {
        let records = indexedSessionTasks(sessionID, now: now).map { record in
            var record = record
            // SAME retained Manager slot; cancellation is a request until actual return.
            if let id = UUID(uuidString: record.id.raw), let observed = voiceControlObservation(id) {
                record.controlObservation = observed
            }
            return record
        }
        return id.map { selected in records.filter { $0.id == selected } } ?? records
    }
    /// Consume only exact pending completed rows through the existing delivery transaction.
    func statusReply(_ id: TaskID? = nil, sessionID: UUID?, now: Date = Date()) -> String? {
        let reports = status(id, sessionID: sessionID, now: now)
        let pending = reports.prefix(2).filter { $0.status == .completed && $0.delivery == .pending }.map(\.id)
        guard pending.isEmpty || setDelivery(pending, .consumedByStatus) else { return nil }
        return TaskStatusRenderer.spoken(reports, now: now)
    }


    /// SAME canonical row owner; this does not consume a permission/effect token.
    @discardableResult
    func setDelivery(_ ids: [TaskID], _ state: TaskDelivery, attempts: Int? = nil) -> Bool {
        manager.setTaskDelivery(ids, state: state, attempts: attempts)
    }
    /// Only positive pending rows may carry. A retained delivering row after process
    /// loss has unknown receipt coverage and must not be treated as unacknowledged.
    /// Derive facts from the SAME task; no second delivery store.
    func pendingDeliveryRows() -> [AgentTask] {
        manager.tasks.filter { $0.delivery == .pending }
    }

    /// A progress reply is observability, not health, effect or current receipt authority.
    func currentStatusReply(_ id: TaskID) -> String? {
        guard let task = record(id), task.source == "voice" else { return nil }
        if task.status == .waitingForInput, case .input(let request) = task.pendingInteraction,
           request.taskID == task.id {
            return "I'm waiting for your answer. " + request.question
        }
        if task.status == .completed, task.delivery == .pending,
           let result = task.result, !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Consume only after the primary commit; a refusal cannot suppress
            // the pending notification or manufacture a successful status answer.
            guard setDelivery([id], .consumedByStatus) else { return nil }
            let first = AgentSpeechPolicy.spokenClauses(result).first ?? result
            return TaskStatusRenderer.title(task.objective) + " is done: " + String(first.prefix(160))
        }
        guard task.status == .running else { return nil }
        if task.progress == "Working locally" || task.progress.isEmpty { return "I'm working on that." }
        return String(task.progress.prefix(160))
    }
}

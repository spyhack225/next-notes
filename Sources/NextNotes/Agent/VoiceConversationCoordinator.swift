import Foundation
import FoundationModels
import Observation

/// The microphone turn, spoken response, and background objective have different
/// owners. The small local frontend never waits for the on-device model's native planning context.
@MainActor
@Observable
final class VoiceConversationCoordinator {
    private static let responseTokenLimit = 256
    static let shared = VoiceConversationCoordinator()

    struct Job: Identifiable {
        let id: UUID
        let work: VoiceConversationWork
        let worker: RealtimeAgent
        var status = "running"
        var result = ""
        var task: Task<Void, Never>?
    }
    private(set) var jobs: [Job] = []
    private(set) var inputPending = false { didSet { resumeResolvedBarrierWaiters() } }
    @ObservationIgnored private var barrierWaiters: [UUID: (effects: Bool, continuation: CheckedContinuation<Void, Never>)] = [:]
    var barrierWaiterCountForTesting: Int { barrierWaiters.count }
    /// P0-07: the epoch of an input that failed before it was ever classified.
    /// Writes wait while this is set; reads and planning do not. `finishFailure`
    /// sets it, and it clears when a later epoch routes successfully, or on
    /// `closeSession()` / `discardInput()`.
    private(set) var effectHoldEpoch: UInt64? { didSet { resumeResolvedBarrierWaiters() } }
    private var responseTask: Task<AgentTurn, Never>?
    private var responseID = UUID()
    private var inputEpoch: UInt64 = 0
    private var provisionalText = ""
    private var preparationEpoch: UInt64 = 0
    private var preparationTask: Task<Void, Never>?
    /// One prewarm per voice session; `closeSession` clears it.
    private var didPrewarmWorker = false
    /// The last committed response failure is a test/UI seam. It is cleared for
    /// every new response and never populated for a superseded or cancelled turn.
    private(set) var lastFailure: VoiceFrontendFailure?
    var responseDeadlineForTesting: Duration?
    var streamForTesting: (@Sendable (String, [LLMChatMessage]) async -> AsyncThrowingStream<String, Error>)?
    var workerForTesting: (@MainActor (VoiceConversationWork) async -> String)?
    /// Scripted model only: the production planned worker and executor still run.
    var workerProviderForTesting: (any LLMProvider)?
    /// P1-07's hold can only be pinned by seeing what did *not* reach speech, and a
    /// self-test cannot attach a real TTS stream to a capture session. Every answer
    /// snapshot this path hands to the speech tracker is reported here first, in order.
    /// Nil in production; it observes, it never substitutes.
    var answerSpeechObserverForTesting: (@MainActor (String) -> Void)?
    /// The availability gate's test seam. Production reads Apple's own answer;
    /// a self-test cannot turn Apple Intelligence off, so it injects one here.
    var frontendUnavailableReasonForTesting: String?
    /// The prewarm trigger's test seam. When set, a prewarm request calls this
    /// instead of loading the runtime, so a self-test can count triggers without
    /// pulling gigabytes into memory. Nil in production.
    var prewarmObserverForTesting: (@MainActor () -> Void)?
    var hasActiveWork: Bool { jobs.contains { $0.status == "running" } }

    /// A tool-shaped request the frontend answered instead of delegating (P0-6), or a
    /// question a finished worker asked (P1-07). A bare acknowledgment ("yes", "use them",
    /// "yes please") resolves to this without a model call, so the ellipsis is never
    /// gambled on the small model and a worker's "Shall I set it for 10 pm?" is answered
    /// rather than clarified. P1-07 deleted the voice path's own pending-intent struct:
    /// this is the shared `PendingAction`, which also carries the typed path's offers.
    private(set) var pendingAction: PendingAction?
    /// Exact texts this session has already met with a clarifier (P0-3, producer-level).
    /// Suppression is single-shot per distinct utterance: the same words reaching this
    /// path again go to the model. A stuck clarification loop is impossible by
    /// construction rather than by luck, and `closeSession` clears it with the session.
    private var clarifiedTexts: Set<String> = []
    /// Short, recoverable, and free of any diagnosis (P0-3).
    static let garbleClarifier = "Sorry — I didn't catch that. Could you say it again?"

    /// The replies this app speaks when a turn was not answered. They are
    /// bookkeeping, not conversation, and they must never become a demonstration
    /// for the next answer: a small model shown its own clarifiers in the
    /// transcript reproduces them. Measured on this Mac with the real on-device
    /// model: with the gate clarifier and one model clarifier in history,
    /// "can you hear me" came back as "I didn't quite catch that. Could you
    /// repeat your question?" — the exact live reply from 2026-09-22T21:45Z.
    static let inputUncertainReply = "I didn't get enough speech to respond. Please try again."
    static let modelErrorReply =
        "The local voice model failed while preparing that response. Please try again."
    static let malformedEnvelopeReply =
        "The local voice model returned an invalid response. Please try again."
    static let emptyCompletionReply =
        "The local voice response ended before it produced an answer. Please try again."
    static let deadlineReply = "The local voice response took too long. Please try again."

    /// Exact non-answer replies, so the list can only be wrong in one visible place.
    static let repairReplies: Set<String> = [
        garbleClarifier,
        inputUncertainReply,
        modelErrorReply,
        malformedEnvelopeReply,
        emptyCompletionReply,
        deadlineReply,
        "Stopped.",
    ]

    /// Phrase marks for a clarifier the *model* generated, which is the variant a
    /// transcript most readily teaches. This classifies assistant output only;
    /// user input is never matched against it.
    static let clarifierMarks = [
        "didn't catch", "did not catch",
        "repeat your question", "repeat the question", "repeat that question",
        "say it again", "say that again",
        "could you repeat", "can you repeat",
        "couldn't hear", "could not hear", "can't hear you", "cannot hear you",
        "speak a bit louder", "speak louder",
        "could you rephrase", "can you rephrase",
        "didn't get that", "did not get that", "didn't get your", "did not get your",
    ]

    /// True when an assistant reply asks the person to repeat themselves or
    /// complains it cannot hear — neither is an answer.
    ///
    /// Apostrophes are folded to the ASCII form: the on-device model writes
    /// `can’t` and `didn’t` with U+2019, and an exact-mark check against ASCII
    /// would miss the very replies this filter exists to remove.
    static func isRepairReply(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if repairReplies.contains(trimmed) { return true }
        let lower = trimmed.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
        return clarifierMarks.contains { lower.contains($0) }
    }

    /// Drop the app's own non-answer turns and the user turn each answered.
    ///
    /// A repair reply left in the transcript is a few-shot demonstration: the
    /// next question is answered with another request to repeat it. Removing the
    /// pair (the reply and its prompt) is what lets the next answer answer.
    static func withoutRepairTurns(_ history: [LLMChatMessage]) -> [LLMChatMessage] {
        var result: [LLMChatMessage] = []
        var lastUserIndex: Int?
        for message in history {
            switch message.role {
            case .user:
                lastUserIndex = result.count
                result.append(message)
            case .assistant:
                if isRepairReply(message.content) {
                    if let index = lastUserIndex, index == result.count - 1 {
                        result.remove(at: index)
                    }
                    lastUserIndex = nil
                    continue
                }
                lastUserIndex = nil
                result.append(message)
            case .system:
                result.append(message)
            }
        }
        return result
    }

    /// Spoken when the on-device conversational lane cannot run at all. The
    /// reason is Apple's own availability string, so the sentence names the one
    /// thing the person can change.
    static func unavailableReply(_ reason: String) -> String {
        "I can't answer with the on-device voice model right now. \(reason) "
            + "You can still type your question."
    }

    /// Do inference while a stable recognized partial is still waiting for
    /// end-of-utterance. This path records no turn and has no speech/tool sink.
    /// The frontend reuses it only for an exact final request/context match.
    func prepareResponseIfUseful(_ partial: String) {
        guard streamForTesting == nil else { return }
        let text = partial.trimmingCharacters(in: .whitespacesAndNewlines)
        guard VoiceTranscriptCanonical.key(text) != VoiceTranscriptCanonical.key(provisionalText) else { return }
        provisionalText = text
        preparationEpoch &+= 1
        let epoch = preparationEpoch
        if CommandLine.arguments.contains("--selftest-voice-pipeline") {
            SelfTest.diagnostic("VOICE_PREPARE_PARTIAL=revision \(epoch) text=\(text)")
        }
        preparationTask?.cancel()
        preparationTask = Task { @MainActor in
            await LocalVoiceFrontend.shared.cancelSpeculation(through: epoch - 1)
            guard text.split(whereSeparator: \.isWhitespace).count >= 4 else { return }
            do { try await Task.sleep(for: .milliseconds(220)) } catch { return }
            guard epoch == self.preparationEpoch, !Task.isCancelled,
                  AgentCaptureController.shared.isSessionActive else { return }
            let request = self.frontendRequest(text)
            await LocalVoiceFrontend.shared.speculate(system: Self.systemPrompt,
                messages: request.messages, maxTokens: Self.responseTokenLimit, revision: epoch)
        }
    }

    private func cancelResponsePreparation() {
        preparationEpoch &+= 1
        let epoch = preparationEpoch
        preparationTask?.cancel()
        preparationTask = nil
        provisionalText = ""
        Task { await LocalVoiceFrontend.shared.cancelSpeculation(through: epoch) }
    }

    /// Acoustic activity may be a backchannel. Pause new effects until input
    /// resolves without cancelling the conversational answer or its playback.
    func inputActivityStarted() {
        inputEpoch &+= 1
        inputPending = true
    }

    func speechStarted() {
        inputEpoch &+= 1
        inputPending = true
        responseTask?.cancel()
        responseID = UUID()
    }

    /// Load the tool-planning model once a turn has actually routed to work.
    ///
    /// `AgentCaptureController` takes a residency lease when the microphone opens but
    /// deliberately does not load: "opening its microphone must not load and prefill a 4B
    /// worker before there is any work." Speech is not work either — most turns are
    /// answered by the frontend — so the trigger is the two routes that submit a job
    /// (the tool-shape gate and the model's `<use_tools/>` decision), fired just before
    /// the "I'm on it." reply. From `metrics.jsonl`, a cold load of the app LLM
    /// (Qwen3.5-4B at the time) on this Mac took
    /// 11.78 s, 19.37 s, 22.00 s and 25.06 s, and on 2026-09-19T23:04 the whole of it sat
    /// between "I'm on it." and the answer.
    ///
    /// Once per session, through the one prewarm entry point: resident weights, a load
    /// already in flight, a role on another model and a model that is not on this Mac all
    /// come back as a no-op there. Voice asks as a voice turn — always the built-in model —
    /// and `NotesModelRuntime.prewarm` carries the why-not-at-launch.
    private func prewarmWorkerModel() {
        guard !didPrewarmWorker else { return }
        if let prewarmObserverForTesting {
            didPrewarmWorker = true
            prewarmObserverForTesting()
            return
        }
        guard !SelfTest.isRunning, streamForTesting == nil else { return }
        didPrewarmWorker = true
        Task { @MainActor in
            guard AgentCaptureController.shared.isSessionActive else { return }
            _ = NotesModelRuntime.shared.prewarm(voice: true)
        }
    }

    func discardInput() {
        cancelResponsePreparation()
        inputEpoch &+= 1
        inputPending = false
        // P0-07: the user withdrew the input, so nothing is left unclassified:
        // a held effect may commit again.
        effectHoldEpoch = nil
    }

    private func resolveInput(epoch: UInt64) {
        // A previous answer may finish while new acoustic input is still being
        // recognized. It cannot release the newer correction's effect barrier.
        if inputEpoch == epoch { inputPending = false }
    }

    /// P0-07: a *classified* input — one whose route was decided — also supersedes
    /// the effect hold left by an earlier failure. Unlike `resolveInput` the epoch
    /// need not still be current: a later turn's classification is what tells a
    /// write planned against the failed words that it may no longer commit.
    private func resolveAnswerRoute(id: UUID, epoch: UInt64) {
        guard responseID == id, !Task.isCancelled else { return }
        resolveClassified(epoch: epoch)
    }

    private func resolveClassified(epoch: UInt64) {
        resolveInput(epoch: epoch)
        if let hold = effectHoldEpoch, epoch > hold { effectHoldEpoch = nil }
    }

    func closeSession() {
        cancelResponsePreparation()
        didPrewarmWorker = false
        pendingAction = nil
        clarifiedTexts = []
        inputEpoch &+= 1
        responseTask?.cancel()
        responseTask = nil
        responseID = UUID()
        inputPending = false
        // P0-07: a closed session has no unclassified input to protect.
        effectHoldEpoch = nil
        // Background objectives remain in the task list and keep their owners.
    }

    /// Compatibility input client. Background planning and reads never call this.
    func waitForInputResolution() async {
        await waitForBarrier(effects: false)
    }

    /// Only consequential effects wait, after approval and immediately before fire.
    /// A failed input holds effects until a later classified turn, discard or close.
    func mayCommitEffect() async -> Bool {
        await waitForBarrier(effects: true)
        return !Task.isCancelled
    }

    private func barrierIsPending(effects: Bool) -> Bool {
        (inputPending || (effects && effectHoldEpoch != nil))
            && AgentCaptureController.shared.isSessionActive
    }

    private func resumeResolvedBarrierWaiters() {
        let ready = barrierWaiters.filter { !barrierIsPending(effects: $0.value.effects) }
        for (id, _) in ready { barrierWaiters.removeValue(forKey: id)?.continuation.resume() }
    }

    private func cancelBarrierWaiter(_ id: UUID) {
        barrierWaiters.removeValue(forKey: id)?.continuation.resume()
    }

    private func waitForBarrier(effects: Bool) async {
        while barrierIsPending(effects: effects), !Task.isCancelled {
            let id = UUID()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if Task.isCancelled || !barrierIsPending(effects: effects) {
                        continuation.resume()
                    } else {
                        barrierWaiters[id] = (effects, continuation)
                    }
                }
            } onCancel: {
                Task { @MainActor in self.cancelBarrierWaiter(id) }
            }
        }
    }

    /// A filler holds unfinished input without invalidating an answer already
    /// being produced. The input producer calls this before cancellation edges.
    func noteHesitation(_ text: String) {
        guard VoiceTurnPolicy.isHesitation(text) else { return }
        cancelResponsePreparation()
        inputPending = true
        inputEpoch &+= 1
        lastFailure = nil
        AgentSession.shared.recordUser(text, source: .voice)
        AgentAuditLog.shared.record(kind: .request, title: text,
                                   detail: "voice hesitation; awaiting continuation")
    }

    func handle(_ raw: String) async -> AgentTurn {
        // The user's own dictionary rewrites what dictation inserts; the Agent's ear had
        // never been given it. `dictionary.txt` on this Mac maps "Quentin 2.5" to
        // "Qwen3.5" and "Sergeant William Kedu" to "Serge William Kadjo" — names the
        // recogniser gets wrong every time, and that the Agent was then reasoning about.
        let text = Self.corrected(raw)
        if VoiceTurnPolicy.isHesitation(text) {
            noteHesitation(text)
            return AgentTurn(reply: "", delegated: false)
        }
        // Stop a debounce that has not started. Retain an already prepared
        // stream until respond compares its complete request key at commit.
        preparationEpoch &+= 1
        let commitRevision = preparationEpoch
        preparationTask?.cancel()
        preparationTask = nil
        provisionalText = ""
        responseTask?.cancel()
        let id = UUID()
        responseID = id
        lastFailure = nil
        inputPending = true
        inputEpoch &+= 1
        let epoch = inputEpoch
        // A committed turn, not a partial: the watcher raises a card, and a card built from
        // a provisional is a card about words the user did not finish saying.
        FunctionCallWatcher.shared.noteUserTurn(text)
        let task = Task { @MainActor in
            await self.respond(text, id: id, inputEpoch: epoch, commitRevision: commitRevision)
        }
        responseTask = task
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: { task.cancel() }
    }

    private func respond(_ text: String, id: UUID, inputEpoch: UInt64, commitRevision: UInt64) async -> AgentTurn {
        let agent = RealtimeAgent.shared
        let turn = agent.beginVoiceFrontend()
        // One id per voice turn (P0-20a). Installed as a task-local around the frontend
        // stream, so its route and answer passes write their rows with it.
        let usageTurnID = UUID()
        // Assembled before the user row is recorded, so the current turn reaches
        // the model exactly once: in the final message's `Latest user speech:`
        // marker, never as a transcript entry as well. With both, the answer
        // stage read the question as a past turn and the status package as the
        // current one (live 2026-09-22: "can you hear me" → "I didn't quite
        // catch that. Could you repeat your question?").
        let request = frontendRequest(text)
        AgentSession.shared.recordUser(text, source: .voice)
        AgentAuditLog.shared.record(kind: .request, title: text, detail: "local conversational frontend")
        let active = jobs.filter { $0.status == "running" }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let failure = VoiceFrontendFailure.inputUncertain(
                shape: VoiceFrontendOutputShape.empty.rawValue, length: 0)
            return finishFailure(failure, id: id, inputEpoch: inputEpoch, turn: turn, tracker: nil)
        }
        if VoiceTurnPolicy.isExplicitWorkCancellation(text), active.count == 1 {
            cancelResponsePreparation()
            cancel(active[0].id)
            resolveClassified(epoch: inputEpoch)
            return agent.finishVoiceFrontend("I stopped that task.", turn: turn, streamed: false)
        }
        // A turn that only supplies a name is an answer, not a new subject. Left to the
        // model this became "I see. You're referring to the four days labeled 'next note'"
        // (2026-09-20T20:46:26Z) — the recogniser's words taken as the user's meaning.
        if let named = AgentEntityResolver.namingTarget(in: text) {
            if let job = active.last {
                // The user's own words, not this code's reading of them: the worker's
                // prompt already frames follow-ups as corrections to apply, and a
                // paraphrase here would be one more guess between the two.
                job.work.append(text)
                PermissionGate.shared.cancelPending(taskID: job.work.id.uuidString)
                resolveClassified(epoch: inputEpoch)
                return agent.finishVoiceFrontend("Got it — “\(named)”.", turn: turn, streamed: false)
            }
            if let last = jobs.last, AgentEntityResolver.askedForAName(last.result) {
                resolveClassified(epoch: inputEpoch)
                submit("open \(named)")
                return agent.finishVoiceFrontend("I'm on it.", turn: turn, streamed: false)
            }
        }
        // P0-6 pending action: a bare acknowledgment resolves to the stored request.
        // Checked before the garble gate so "yes" with an offer is an answer, not noise —
        // and P1-07 makes that a promise rather than an accident: the noise gate below
        // still holds "okay" and "ok", and the order here is the only thing between a
        // person and the answer they just gave.
        if let pending = pendingAction, pending.isFresh(),
           VoiceTurnPolicy.isBareAcknowledgment(text) {
            pendingAction = nil
            // A worker's question is answered *with* its question, so the planner is told
            // the confirmation and told not to ask again. An offer the frontend made is
            // resolved by re-running the request it offered, exactly as before.
            let objective = pending.origin == .frontendOffer
                ? pending.requestText
                : pending.confirmedPrompt(acknowledgment: text)
            AgentAuditLog.shared.record(kind: .request, title: pending.requestText,
                detail: "pending_ack → newWork (\(pending.origin.rawValue); heard: "
                    + "\(String(text.prefix(80))))")
            resolveClassified(epoch: inputEpoch)
            prewarmWorkerModel()
            submit(objective)
            return agent.finishVoiceFrontend("I'm on it.", turn: turn, streamed: false)
        }
        // P0-6 tool-shape gate BEFORE the frontend model: a request naming a registry
        // capability routes straight to submit. Same rule as P0-2's core tool set — it
        // may only ever add newWork routes, never subtract answers.
        //
        // P1-07: one manifest value answers both gates, so the roster that decides a
        // command and the roster that decides a question are the same read.
        let voiceManifest = AgentCapabilityManifest.current(reader: .voiceFrontend)
        let allowedIDs = voiceManifest.allowedIDs
        if let route = toolShapeRoute(text, allowedIDs: allowedIDs) {
            AgentAuditLog.shared.record(kind: .request, title: text,
                detail: "tool_shape_route(\(route.route)) → newWork; planner keeps the decision")
            resolveClassified(epoch: inputEpoch)
            prewarmWorkerModel()
            submit(route.text)
            return agent.finishVoiceFrontend("I'm on it.", turn: turn, streamed: false)
        }
        // P1-07: a question is a request to look, so it routes to work on the same terms a
        // command does. "what's on my calendar" and "any new emails?" carry no verb beside
        // a noun, so they missed the gate above, reached the on-device model, and came back
        // "I don't have access to your calendar or tasks" with `get_agenda` in the roster.
        // Gated on a *ready* tool of that class, so this can only hand a turn to work the
        // turn could have done; a miss costs the model, which is where a question belongs.
        if let intent = AgentDirectIntent.questionRoute(
            in: text, readyIntents: Set(voiceManifest.allowed.map(\.intent))) {
            AgentAuditLog.shared.record(kind: .request, title: text,
                detail: "question_route(\(intent.rawValue)) → newWork; the planner reads the real data")
            resolveClassified(epoch: inputEpoch)
            prewarmWorkerModel()
            submit(text)
            return agent.finishVoiceFrontend("I'm on it.", turn: turn, streamed: false)
        }
        // P0-3, producer-level: the only input this path may hold back is an *exact*
        // known-noise fragment (or an orphan name with nothing to attach to), and only
        // once per session. Everything else — questions, small talk, anything the
        // recogniser mangled that a model might still read — goes to the model. The
        // first version of this gate guessed from shape and clarified "Can you hear me?"
        // five turns in a row; shape heuristics are banned from this path. A repeat of
        // clarified words escalates to the model instead of clarifying again.
        let noiseKey = VoiceTurnPolicy.knownNoiseFragment(in: text)
        let orphanNameKey = AgentEntityResolver.namingTarget(in: text) != nil
            ? "name:\(VoiceTurnPolicy.normalizedKey(text))" : nil
        if let key = noiseKey ?? orphanNameKey {
            // Route a spoken name/label through the index before giving up on it.
            if let match = AgentEntityResolver.resolve(
                spoken: text, wantsFolder: text.lowercased().contains("folder")).first,
               match.score >= AgentEntityResolver.confidentThreshold {
                AgentAuditLog.shared.record(kind: .request, title: text,
                    detail: "garble_resolve → open \(match.hit.name)")
                resolveClassified(epoch: inputEpoch)
                submit("open \(match.hit.name)")
                return agent.finishVoiceFrontend("I'm on it.", turn: turn, streamed: false)
            }
            if !clarifiedTexts.contains(key) {
                clarifiedTexts.insert(key)
                AgentAuditLog.shared.record(kind: .reply, title: "Asked for clarification",
                    detail: "garble_clarifier (\(noiseKey != nil ? "known noise" : "orphan name")): "
                        + String(text.prefix(120)))
                resolveClassified(epoch: inputEpoch)
                return agent.finishVoiceFrontend(Self.garbleClarifier, turn: turn, streamed: false)
            }
            // The same words a second time: fall through and let the model answer.
        }
        // Apple Intelligence off, still downloading, or unsupported: the on-device
        // lane cannot run at all. Every turn used to end in "The local voice model
        // failed while preparing that response." — a generic dead end for a state
        // the person can see and fix. Say the real reason instead; the failure
        // taxonomy below stays for errors that happen mid-generation.
        let unavailable = frontendUnavailableReasonForTesting
            ?? (streamForTesting == nil ? FoundationModelFormatter.unavailableReason : nil)
        if let reason = unavailable {
            AgentAuditLog.shared.record(kind: .reply, title: "On-device voice model unavailable",
                detail: "voice_frontend_unavailable: \(reason)")
            resolveClassified(epoch: inputEpoch)
            return agent.finishVoiceFrontend(Self.unavailableReply(reason), turn: turn, streamed: false)
        }
        let indexed = request.indexed
        let messages = request.messages
        // P2-01: the request is built, so the endpoint→request hop is over. The turn's ids
        // ride along here because this is the one place that already owns both; the
        // timeline joins its row to `usage.jsonl` with them and invents neither.
        VoiceLatencyTimeline.shared.mark(.frontendRequest)
        VoiceLatencyTimeline.shared.attachTurnIDs(
            turnID: usageTurnID, conversationID: AgentSession.shared.sessionID)
        let tracker = AgentToolSpeechTracker(agent: agent, turn: turn, allowSpeech: true,
            firstTokenTrace: LatencyTrace.start(.agentTranscriptToFirstToken),
            traceSource: "voice")
        tracker.beginResponse()
        // The voice frontend *is* Apple's system model, and the planner's own
        // `noteModel` covers the worker path. Saying so here is what lets the per-turn
        // usage row name the answering model without a second field of its own.
        tracker.noteModel(FoundationModelLLMProvider())
        var assembled = ""
        do {
            let stream = await ModelPassRecorder.$correlation.withValue(
                UsageCorrelation(turnID: usageTurnID,
                                 conversationID: AgentSession.shared.sessionID)
            ) {
                if let streamForTesting {
                    return await streamForTesting(Self.systemPrompt, messages)
                } else {
                    return await LocalVoiceFrontend.shared.stream(
                        system: Self.systemPrompt, messages: messages,
                        maxTokens: Self.responseTokenLimit, commitRevision: commitRevision)
                }
            }
            let progress = VoiceFrontendStreamProgress()
            let deadline = responseDeadlineForTesting ?? .seconds(25)
            let streamResult: VoiceFrontendStreamResult? = await withBoundedWait(deadline) {
                var snapshot = ""
                var routeReleased = false
                do {
                    for try await delta in stream {
                        try Task.checkCancellation()
                        snapshot += delta
                        await progress.update(snapshot)
                        let parsed = VoiceFrontendEnvelope.parse(snapshot)
                        if case .answer = parsed, !routeReleased {
                            await self.resolveAnswerRoute(id: id, epoch: inputEpoch)
                            routeReleased = true
                        }
                        // A complete control has no answer tail. Apply its existing
                        // mutation below before opening the effect barrier.
                        switch parsed {
                        case .capabilities, .newWork, .revise, .cancel:
                            return VoiceFrontendStreamResult(snapshot: snapshot, termination: .completed)
                        case .pending, .answer, .invalid: break
                        }
                        // P1-07: hold the audio while the answer may still be a denial. Speech
                        // starts on the first complete clause, so "I don't have access to
                        // your email" was already audible before the whole reply could be
                        // judged against the manifest. The hold costs a pause; it never
                        // costs a wrong word, because a reply that turns out honest is
                        // spoken whole at the end instead.
                        if case .answer(let answer) = parsed,
                           !AgentRefusalGuard.mayBeDenial(answer) {
                            await self.answerSpeechObserverForTesting?(answer)
                            await tracker.receive(answer)
                        }
                    }
                    return VoiceFrontendStreamResult(snapshot: snapshot, termination: .completed)
                } catch is CancellationError {
                    return VoiceFrontendStreamResult(snapshot: snapshot, termination: .cancelled)
                } catch {
                    return VoiceFrontendStreamResult(snapshot: snapshot,
                                                     termination: .modelError(Self.errorCode(for: error)))
                }
            }
            tracker.finishPendingFirstTokenTrace(note: "frontend-control")
            guard responseID == id, !Task.isCancelled else {
                tracker.cancel()
                return AgentTurn(reply: "", delegated: false)
            }
            guard let streamResult else {
                let snapshot = await progress.value()
                let outcome = VoiceFrontendResponseOutcome.resolve(
                    snapshot: snapshot, termination: .deadline)
                guard case .failure(let failure) = outcome else {
                    return AgentTurn(reply: "", delegated: false)
                }
                return finishFailure(failure, id: id, inputEpoch: inputEpoch, turn: turn, tracker: tracker)
            }
            switch VoiceFrontendResponseOutcome.resolve(
                snapshot: streamResult.snapshot, termination: streamResult.termination
            ) {
            case .answer(let answer):
                assembled = answer.trimmingCharacters(in: .whitespacesAndNewlines)
                // P1-07: escalate the FIRST denial the manifest contradicts, not the second
                // identical one. The P0-6 backstop counted repeats because it could not tell
                // a false denial from a true one; `AgentRefusalGuard` reads the roster, so
                // one contradicted denial is already enough evidence and waiting for a
                // second meant the person heard the same refusal twice before anything ran
                // ("What is on your to-do list for today?" → four rewrites of it, 09-14).
                // Reads auto-run in the tool loop; anything stronger waits for approval.
                if AgentRefusalGuard.rebuttal(for: assembled, manifest: voiceManifest) != nil {
                    AgentAuditLog.shared.record(kind: .reply, title: "Denial escalation",
                        detail: "denial_escalation → newWork (first contradicted denial)")
                    tracker.cancel()
                    // The turn is classified — it routed to work — so it also supersedes the
                    // effect hold an earlier unclassified failure left behind (P0-07).
                    resolveClassified(epoch: inputEpoch)
                    prewarmWorkerModel()
                    submit(text)
                    return agent.finishVoiceFrontend("I'm on it.", turn: turn, streamed: false)
                }
                // P0-6, kept through `PendingAction.detect`: a tool-shaped request the
                // frontend answered, or an offer it made, is pending so a bare "yes" /
                // "use them" resolves to the original text with no model call. A denial the
                // manifest does not contradict — it needs a setup step, or it cannot tell
                // which of two things was meant — is spoken whole by the line below, and
                // `detect` is the one rule that decides whether this turn is now an offer:
                // its own capability rule replaced the coordinator's private version.
                pendingAction = PendingAction.detect(
                    reply: assembled, request: text, allowedIDs: allowedIDs,
                    origin: .frontendOffer, sessionID: AgentSession.shared.sessionID)
                resolveClassified(epoch: inputEpoch)
                tracker.finish(hasToolCalls: false)
                return agent.finishVoiceFrontend(assembled, turn: turn, streamed: tracker.didStreamSpeech)
            case .capabilities:
                tracker.cancel()
                resolveClassified(epoch: inputEpoch)
                return agent.finishVoiceFrontend(VoiceCapabilitySnapshot.current().spokenSummary,
                                                 turn: turn, streamed: false)
            case .newWork:
                tracker.cancel()
                guard !SelfTest.isRunning || workerForTesting != nil || workerProviderForTesting != nil else {
                    SelfTest.failed = true
                    resolveClassified(epoch: inputEpoch)
                    return agent.finishVoiceFrontend("The voice test requested a tool, so it was stopped.",
                                                     turn: turn, streamed: false)
                }
                resolveClassified(epoch: inputEpoch)
                prewarmWorkerModel()
                submit(text)
                return agent.finishVoiceFrontend("I'm on it.", turn: turn, streamed: false)
            case .revise(let index):
                tracker.cancel()
                guard indexed.indices.contains(index - 1),
                      jobs.contains(where: { $0.id == indexed[index - 1].id && $0.status == "running" }) else {
                    resolveClassified(epoch: inputEpoch)
                    return agent.finishVoiceFrontend("That task has already finished. What would you like me to do next?", turn: turn, streamed: false)
                }
                let work = indexed[index - 1].work
                work.append(text)
                PermissionGate.shared.cancelPending(taskID: work.id.uuidString)
                resolveClassified(epoch: inputEpoch)
                return agent.finishVoiceFrontend("Got it. I'll use that correction.", turn: turn, streamed: false)
            case .cancel(let index):
                tracker.cancel()
                guard indexed.indices.contains(index - 1) else { break }
                cancel(indexed[index - 1].id)
                resolveClassified(epoch: inputEpoch)
                return agent.finishVoiceFrontend("I stopped that task.", turn: turn, streamed: false)
            case .failure(let failure):
                return finishFailure(failure, id: id, inputEpoch: inputEpoch, turn: turn, tracker: tracker)
            }
        }
        tracker.cancel()
        // An unresolved correction must not release an older proposed effect.
        // A subsequent valid turn or closing the voice session resolves this gate.
        let failure = VoiceFrontendFailure.incompleteCompletion(
            shape: VoiceFrontendOutputShape.classify("").rawValue, length: 0)
        return finishFailure(failure, id: id, inputEpoch: inputEpoch, turn: turn, tracker: nil)
    }

    private func finishFailure(
        _ failure: VoiceFrontendFailure,
        id: UUID,
        inputEpoch: UInt64,
        turn: Int,
        tracker: AgentToolSpeechTracker?
    ) -> AgentTurn {
        guard responseID == id, !Task.isCancelled else {
            tracker?.cancel()
            return AgentTurn(reply: "", delegated: false)
        }
        tracker?.cancel()
        if failure.code == .cancelled {
            // Cancellation is an ownership transition, not a user-visible failure.
            // Resolve only this turn's input epoch; a newer turn owns the barrier,
            // and an effect hold survives because nothing was classified.
            resolveInput(epoch: inputEpoch)
            RealtimeAgent.shared.waitForVoiceContinuation()
            return AgentTurn(reply: "", delegated: false)
        }
        lastFailure = failure
        AgentAuditLog.shared.record(
            kind: .reply,
            title: "Voice response failed",
            detail: failure.auditDetail
        )
        Log.agent.error("voice frontend failure \(failure.auditDetail, privacy: .public)")
        // P0-07: this input was never classified, so release the read/planning
        // barrier but record the epoch as an effect hold. Planning and reads resume
        // at once; a write waits until a later turn is classified, or the session
        // closes or the user withdraws the input.
        effectHoldEpoch = inputEpoch
        resolveInput(epoch: inputEpoch)
        return agentFailureReply(failure, turn: turn)
    }

    private func agentFailureReply(_ failure: VoiceFrontendFailure, turn: Int) -> AgentTurn {
        let reply: String
        switch failure.code {
        case .inputUncertain:
            reply = Self.inputUncertainReply
        case .modelError:
            reply = Self.modelErrorReply
        case .malformedEnvelope:
            reply = Self.malformedEnvelopeReply
        case .emptyCompletion, .incompleteCompletion:
            reply = Self.emptyCompletionReply
        case .deadline:
            reply = Self.deadlineReply
        case .cancelled:
            return AgentTurn(reply: "", delegated: false)
        }
        return RealtimeAgent.shared.finishVoiceFrontend(reply, turn: turn, streamed: false)
    }

    /// P2-01: `frontend_unavailable` used to fold three different failures into one word —
    /// a barrier that did not drain, a system model that is not available, and a prompt
    /// whose latest user turn the planner could not find. One word is one repair, and two
    /// of those three are not a repair at all. The sub-reason rides in the code (so every
    /// consumer of the prefix still matches) and in a zero-duration span, so the turn is on
    /// the record.
    nonisolated private static func unavailableCode(_ description: String) -> String {
        let reason: String
        if description.contains("did not stop") {
            reason = "barrier_timeout"
        } else if description.contains("missing_latest_user") {
            reason = "missing_latest_user"
        } else {
            reason = "apple_unavailable"
        }
        LatencyTrace.record(.voiceFrontendUnavailable, seconds: 0,
            note: reason, source: "voice")
        return "frontend_unavailable:" + reason
    }

    nonisolated private static func errorCode(for error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let error = error as? LocalVoiceFrontend.FrontendError {
            switch error {
            case .unavailable: return unavailableCode(String(describing: error))
            case .revisedSnapshot: return "revised_snapshot"
            case .emptyResponse: return "empty_response"
            case .typedDecisionIncomplete: return "typed_decision_incomplete"
            case .typedDecisionRevised: return "typed_decision_revised"
            case .splitAnswerProtocolViolation: return "split_answer_protocol_violation"
            }
        }
        if let error = error as? LanguageModelSession.GenerationError {
            switch error {
            case .exceededContextWindowSize: return "foundation_exceeded_context"
            case .assetsUnavailable: return "foundation_assets_unavailable"
            case .guardrailViolation: return "foundation_guardrail"
            case .unsupportedGuide: return "foundation_unsupported_guide"
            case .unsupportedLanguageOrLocale: return "foundation_unsupported_locale"
            case .decodingFailure: return "foundation_decoding_failure"
            case .rateLimited: return "foundation_rate_limited"
            case .concurrentRequests: return "foundation_concurrent_requests"
            case .refusal: return "foundation_refusal"
            @unknown default: return "foundation_generation_error"
            }
        }
        if let error = error as NSError? {
            let domain = error.domain.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }
            let boundedDomain = String(String.UnicodeScalarView(domain).prefix(48))
            if !boundedDomain.isEmpty { return "\(boundedDomain)#\(error.code)" }
        }
        return String(reflecting: type(of: error)).split(separator: ".").last.map(String.init)
            ?? "model_stream_error"
    }

    /// Deterministic newWork routing before the frontend model (P0-6). Returns the
    /// request text plus the route that matched, or nil to continue to the garble
    /// gate and the frontend. Open/click/type/locate shapes come first through the
    /// existing direct-intent parser; mail, calendar, docs and memory verbs follow.
    ///
    /// The parse here is the loose one on purpose (P1-08). This gate may only ever *add* a
    /// newWork route, and what it is asking is "should the planner see this?" — a compound
    /// request like "open youtube and play the latest Cortech video" answers yes under the
    /// loose parse and no under the strict one, and the strict answer would hand it to the
    /// conversational frontend instead. The strict parse is for the caller that runs the
    /// action, which is `runPlannedTurn`.
    private func toolShapeRoute(_ text: String, allowedIDs: Set<String>) -> (text: String, route: String)? {
        if let direct = AgentDirectIntent.parse(text, wholeSentence: false) {
            return (text, "direct:" + direct.requiredToolIDs.joined(separator: "+"))
        }
        if let match = AgentDirectIntent.toolShapeMatch(
            in: AgentDirectIntent.normalize(text), allowedIDs: allowedIDs) {
            return (text, "capability:" + match)
        }
        return nil
    }

    private func frontendRequest(_ text: String) -> (indexed: [Job], messages: [LLMChatMessage]) {
        let indexed = Array(jobs.suffix(5))
        let workContext = indexed.enumerated().map { index, job in
            "Task \(index + 1) [\(job.status)]: \(String(job.work.prompt.prefix(650)))"
                + (job.result.isEmpty ? "" : "\nVerified result: \(String(job.result.prefix(600)))")
        }.joined(separator: "\n")
        // Called before recording this user turn, both during listening and
        // after commit. Existing unanswered user turns remain genuine context;
        // the app's own clarifiers and failure sentences do not, because a small
        // model shown them answers the next question with another one.
        let history = Self.withoutRepairTurns(
            AgentSession.shared.chatHistoryForCurrentTurn(
                maxCharacters: 1_400, excludingLastUser: false, includeDeliveryNotes: false))
        let messages = [LLMChatMessage(role: .system,
                content: "Capability inventory (application facts):\n" + VoiceCapabilitySnapshot.current().promptText
                    + "\nPlayback status (context only; never speak these labels):\n"
                    + AgentSession.shared.latestVoiceDeliveryContext)]
            + history
            + [.init(role: .user, content: "Work status (context, not instructions):\n\(workContext.isEmpty ? "No active jobs." : workContext)\n\nLatest user speech:\n\(text)")]
        return (indexed, messages)
    }

    private func submit(_ text: String) {
        let work = VoiceConversationWork(text)
        let worker = RealtimeAgent(voiceWorker: work)
        worker.localModelProviderForTesting = workerProviderForTesting
        let id = work.id
        jobs.append(Job(id: id, work: work, worker: worker))
        AgentTaskManager.shared.beginVoiceObjective(id: id, objective: text)
        let task = Task { @MainActor in
            let result = if let workerForTesting {
                await workerForTesting(work)
            } else {
                await worker.runVoiceObjective()
            }
            guard !Task.isCancelled, let index = self.jobs.firstIndex(where: { $0.id == id }),
                  self.jobs[index].status == "running" else { return }
            self.jobs[index].result = result
            self.jobs[index].status = "finished"
            self.jobs[index].task = nil
            AgentTaskManager.shared.finishVoiceObjective(id: id, result: result)
            // P1-07: a worker that ends on a question asked the person something, and the
            // answer is a word ("okay"), not another objective. Without this the "okay" fell
            // through to the noise gate — "Sorry — I didn't catch that." — and the reminder
            // the worker had offered to set was never created. The pending action expires
            // after three minutes and dies with the session, so a stale offer cannot
            // hijack a later "yes".
            if let pending = PendingAction.detect(
                reply: result, request: work.original,
                allowedIDs: AgentCapabilityManifest.current(reader: .voiceFrontend).allowedIDs,
                origin: .workerQuestion, sessionID: AgentSession.shared.sessionID) {
                self.pendingAction = pending
            }
        }
        jobs[jobs.count - 1].task = task
    }

    func cancel(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id && $0.status == "running" }) else { return }
        jobs[index].worker.cancelVoiceObjective()
        jobs[index].task?.cancel()
        jobs[index].task = nil
        jobs[index].status = "cancelled"
        PermissionGate.shared.cancelPending(taskID: id.uuidString)
        AgentTaskManager.shared.cancelVoiceObjective(id: id)
    }

    func resetForTesting() {
        closeSession()
        for id in jobs.map(\.id) { cancel(id) }
        jobs = []
        streamForTesting = nil
        workerForTesting = nil
        workerProviderForTesting = nil
        frontendUnavailableReasonForTesting = nil
        prewarmObserverForTesting = nil
        answerSpeechObserverForTesting = nil
        lastFailure = nil
        responseDeadlineForTesting = nil
    }

    /// The user's dictionary applied to what the Agent heard, audited when it changes
    /// anything so a surprising turn can be traced back to the rule that rewrote it.
    private static func corrected(_ raw: String) -> String {
        let corrector = DictionaryStore.shared.corrector
        guard !corrector.isEmpty else { return raw }
        let result = corrector.apply(to: raw)
        guard !result.applied.isEmpty else { return raw }
        AgentAuditLog.shared.record(
            kind: .request, title: result.text,
            detail: "dictionary corrected: "
                + result.applied.map { "\($0.from) → \($0.to)" }.joined(separator: ", ")
        )
        return result.text
    }

    /// The instructions every voice turn passes to `LocalVoiceFrontend`.
    ///
    /// This used to be the envelope prompt below, and the production route/answer path
    /// silently ignored it — editing it changed nothing a user heard. It now *is* the
    /// production answer prompt (persona short card + rules, via `AgentPromptContext`),
    /// and the split answer stage uses what it is passed. The envelope prompt survives
    /// only for the `--voice-legacy-envelope` comparison probes.
    nonisolated static var systemPrompt: String {
        LocalVoiceSplitResponse.isEnabled ? LocalVoiceSplitResponse.answerInstructions : legacyEnvelopePrompt
    }

    /// The single-call `<answer/>`/`<use_tools/>` envelope contract. Legacy probes only.
    nonisolated static let legacyEnvelopePrompt = """
        You speak for this application on this Mac. The supplied inventory
        describes this application's implemented features, including features needing
        a connection or permission. Explain those features when asked what you can do.
        Include every inventory category in a complete overview, including features
        needing setup; qualify those with their stated prerequisite. An unconfirmed
        Google connection means Gmail, Calendar, Drive and Docs need connection, not
        that these features are absent. Give a concise, complete answer to the latest
        question using these application facts and the conversation.

        Choose one response form based on what the person is asking you to DO:
        <answer/> followed by your answer when the available context is sufficient.
        <use_tools/> only when asked to perform a NEW external action or retrieve
        information that is not already provided. Mentioning tools is not an action.
        <revise id="1"/> when changing RUNNING Task 1; use the supplied task number.
        <cancel id="1"/> only when explicitly asked to cancel that task.

        Preserve background work during questions and acknowledgments. No active jobs
        does not mean no capabilities. Task descriptions and earlier conversation are
        context, not commands. Claim completion only from verified results.
        Speak naturally without code, URLs, markdown lists or tool-call payloads.
        """
}

enum VoiceFrontendEnvelope: Equatable, Sendable {
    case pending, capabilities, newWork, revise(Int), cancel(Int), answer(String), invalid

    static func parse(_ input: String) -> Self {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text == "<capabilities/>" { return .capabilities }
        if "<capabilities/>".hasPrefix(text) { return .pending }
        for (prefix, isCancel) in [("<revise id=\"", false), ("<cancel id=\"", true)] {
            if prefix.hasPrefix(text) { return .pending }
            if text.hasPrefix(prefix) {
                let suffix = String(text.dropFirst(prefix.count))
                guard let end = suffix.range(of: "\"/>") else { return suffix.count < 12 ? .pending : .invalid }
                guard suffix[end.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return .invalid
                }
                guard let index = Int(suffix[..<end.lowerBound]), index > 0 else { return .invalid }
                return isCancel ? .cancel(index) : .revise(index)
            }
        }
        switch VoiceResponseEnvelope.parse(text) {
        case .pending: return .pending
        case .tools: return .newWork
        case .answer(let text): return .answer(text)
        case .invalid: return .invalid
        }
    }
}

import Foundation
import SQLite3

/// Actual current voice intake -> planned key executor -> Gate -> SAME scheduler/audio.
/// External model stream and final application-key backing are scripted. No approval,
/// task, review or positive playback receipt is seeded. Physical audio/key proof is open.
@MainActor
enum SpokenApprovalSelfTest {
    private enum Invalid: Error { case unsafe, owner, worker, grammar, context }
    @MainActor private final class ModelControlProbe {
        let obsoleteWorker: RealtimeAgent?
        let changeProposal: Bool
        var calls = 0
        var messages: [LLMChatMessage] = []
        init(obsoleteWorker: RealtimeAgent?, changeProposal: Bool = false) {
            self.obsoleteWorker = obsoleteWorker; self.changeProposal = changeProposal
        }
        func stream(_ messages: [LLMChatMessage]) -> AsyncThrowingStream<String, Error> {
            calls += 1; self.messages = messages
            // The offer was captured by the real frontendRequest before this
            // external stream boundary; retain the SAME uncancelled Task.
            obsoleteWorker?.cancelVoiceObjective()
            let chunk = changeProposal
                ? "<decision>{\"intent\":\"respond_approval\",\"decision\":\"approve\",\"change\":\"Press tab.\"}</decision>"
                : "<decision>{\"intent\":\"respond_approval\",\"decision\":\"approve\"}</decision>"
            return AsyncThrowingStream { $0.yield(chunk); $0.finish() }
        }
    }
    private static func reached(_ predicate: @MainActor () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while ContinuousClock.now < deadline {
            if await predicate() { return true }
            await Task.yield()
        }
        return await predicate()
    }
    static func run(recorder: RecordingSpeechBacking) async -> (checks: Int, failures: [String]) {
        let c = VoiceConversationCoordinator.shared, capture = AgentCaptureController.shared
        let gate = PermissionGate.shared, synth = AgentSpeechSynthesizer.shared
        let playback = VoicePlaybackDelivery.shared
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-voice-delivery",
              AgentSession.shared.fileURL == nil, !capture.isSessionActive,
              c.taskBridge.liveVoiceTasks(owner: c).isEmpty, gate.pending == nil, gate.queuedCount == 0 else {
            return (0, ["spoken approval: INVALID prior owner"])
        }
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let root = temp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard root.path == root.resolvingSymlinksInPath().standardizedFileURL.path,
              root.deletingLastPathComponent().path == temp.path,
              !FileManager.default.fileExists(atPath: root.path) else { return (0, ["spoken approval: INVALID root"]) }
        let priorBridge = c.taskBridgeOverrideForTesting, priorRemember = c.rememberExplicit
        let priorFake = AgentToolExecutor.fakeForTesting, priorFire = AgentToolExecutor.fireOverrideForTesting
        let priorPolicy = AgentToolExecutor.policyOverrideForTesting
        let priorInputs = AgentCapabilityManifestBuilder.inputsOverrideForTesting
        let priorWhole = PlannerBackends.wholeTurnOverrideForTesting, priorNeedle = ToolLoopLiveEval.needleFirstForTesting
        let owner = SelfTestStoreGuard.take(), grants = PermissionGrantStore.shared.grants
        func currentCapture() -> VoiceWorkerTestCapture? {
            guard let raw = c.taskBridge.cachedTasks.first(where: { $0.source == "voice" })?.id,
                  let id = UUID(uuidString: raw) else { return nil }
            return c.captureVoiceWorkerForTesting(id: id)
        }
        var currentManager: AgentTaskManager?, owned: Task<Void, Never>?, probe: ApprovalProbe?
        var created = false, installedContext = false, contextRejected = false, contextReads = 0
        var installedRoute = false, currentMode = "", staleAdvanced = false
        var routeObservations = 0, matchedRoutes = 0
        var staleBefore: Int?, staleAfter: Int?
        var checks = 0; var failures: [String] = []
        var modelChecks = 0; var modelProblems = 0
        func check(_ value: Bool, _ label: String) { checks += 1; if !value { failures.append("spoken approval: " + label) } }
        func input(_ text: String) async -> AgentTurn {
            RealtimeAgent.shared.userSpeechStarted(); RealtimeAgent.shared.userSpeechEnded()
            return await RealtimeAgent.shared.handle(text, source: .voice)
        }
        defer {
            c.resetForTesting(); _ = c.installTaskBridgeForTesting(priorBridge)
            c.rememberExplicit = priorRemember
            AgentToolExecutor.fakeForTesting = priorFake; AgentToolExecutor.fireOverrideForTesting = priorFire
            AgentToolExecutor.policyOverrideForTesting = priorPolicy
            AgentCapabilityManifestBuilder.inputsOverrideForTesting = priorInputs
            PlannerBackends.wholeTurnOverrideForTesting = priorWhole; ToolLoopLiveEval.needleFirstForTesting = priorNeedle
            _ = playback.installOutputForTesting(nil)
            if installedRoute { _ = gate.setSharedApprovalRouteObserverForTesting(nil, root: root) }
            if installedContext { _ = ToolCallContextBuilder.setMeetingContextForTesting(nil, root: root) }
            if created { try? FileManager.default.removeItem(at: root) }
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false); created = true
            guard ToolCallContextBuilder.setMeetingContextForTesting({ meeting, task in
                contextReads += 1
                guard root.path == root.resolvingSymlinksInPath().standardizedFileURL.path,
                      FileManager.default.fileExists(atPath: root.path), meeting == nil,
                      let task, currentManager?.task(id: task)?.source == "voice" else {
                    contextRejected = true; return nil // Never fall back to owner context.
                }
                if currentMode == "staleCaller", !staleAdvanced,
                   let id = UUID(uuidString: task), let retained = c.captureVoiceWorkerForTesting(id: id) {
                    // Existing real review-context hop invalidates the original worker
                    // generation after ask captured it, before actual presentation.
                    staleBefore = retained.worker.currentGeneration
                    retained.worker.cancelVoiceObjective()
                    staleAfter = retained.worker.currentGeneration
                    staleAdvanced = true
                }
                return ToolCallContext()
            }, root: root) else { throw Invalid.context }
            installedContext = true
            guard gate.setSharedApprovalRouteObserverForTesting({ _, matched in
                routeObservations += 1
                if matched { matchedRoutes += 1 }
            }, root: root) else { throw Invalid.context }
            installedRoute = true
            AgentToolExecutor.fakeForTesting = nil; AgentToolExecutor.policyOverrideForTesting = .denyMutations
            AgentCapabilityManifestBuilder.inputsOverrideForTesting = RealtimeAgentToolLoopSelfTest.allEnabledFixture()
            PlannerBackends.wholeTurnOverrideForTesting = nil; ToolLoopLiveEval.needleFirstForTesting = false
            for mode in ["yes", "unheard", "no", "hold", "card", "edited", "refused", "amend", "close", "mismatch", "staleCaller", "stalePresented", "staleHeard", "model-yes", "model-negative", "model-refused", "model-stale", "model-change"] {
                let start = checks, problemsBefore = failures.count
                currentMode = mode; staleAdvanced = false; staleBefore = nil; staleAfter = nil
                let routeBefore = routeObservations, matchedBefore = matchedRoutes
                let directory = root.appendingPathComponent(mode, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                let sql = TaskStore(root: directory); defer { sql.close() }
                let file = directory.appendingPathComponent("agent-tasks.json")
                let store = AgentTaskStore(fileURL: file, mirror: sql)
                guard store.allowsHarnessPersistence, store.save([]).primaryCommitted else { throw Invalid.unsafe }
                let manager = AgentTaskManager(store: store), bridge = TaskBridge(manager: manager)
                currentManager = manager
                guard let output = OutputScheduler.isolatedForTesting(bridge),
                      c.installTaskBridgeForTesting(bridge), playback.installOutputForTesting(output) else { throw Invalid.unsafe }
                c.rememberExplicit = { _ in }; c.prewarmObserverForTesting = {}
                c.workerForTesting = nil
                let state = ApprovalProbe(mode: mode); probe = state
                c.workerProviderForTesting = ApprovalProvider(probe: state)
                c.streamForTesting = { _, messages in await state.frontend(messages) }
                var fires: [String] = []
                AgentToolExecutor.fireOverrideForTesting = { tool, args in
                    guard tool.id == "computer.press_key", args["modifiers"] == nil,
                          let key = args["key"], ["escape", "tab"].contains(key) else { throw Invalid.unsafe }
                    fires.append(key); return AgentToolResult(summary: "The owned application key was applied.")
                }
                await capture.beginSession(captureAudio: false)
                let began = await input(ApprovalProbe.request)
                owned = currentCapture()?.task
                guard let job = currentCapture(), let task = owned,
                      await reached({ await state.heldCount > 0 }), let session = capture.sessionID else { throw Invalid.worker }
                guard case .voice(let original, _)? = manager.task(id: job.id.uuidString)?.origin,
                      original == session else { throw Invalid.owner }
                check(began.reply == "I'm on it." && c.taskBridge.cachedTasks.filter { $0.source == "voice" }.count == 1 && fires.isEmpty
                    && manager.task(id: job.id.uuidString)?.origin == job.bridge.record(TaskID(job.id))?.origin,
                    "C01 actual admitted current voice worker (\(mode))")
                drain(synth, recorder, acknowledge: true); recorder.reset()
                guard let reader = AgentCapabilityManifestRuntime.publishedReader else { throw Invalid.grammar }
                let manifest = AgentCapabilityManifestBuilder.build(.live(reader: reader), request: ApprovalProbe.request)
                let call = ApprovalProbe.call("escape")
                guard manifest.allowedIDs.contains("computer.press_key"),
                      LlamaGrammarPlanner.grammar(for: manifest).matches(call),
                      AgentToolCallParser.parse(call, knownNames: RealtimeAgent.callNames(manifest)).calls.first?.name == "computer.press_key" else { throw Invalid.grammar }
                await state.release()
                guard await reached({ gate.pending?.taskID == job.id.uuidString }),
                      let request = gate.pending,
                      let review = ToolCallReviewStore.shared.review(id: request.id),
                      review.isReadyToRun, !contextRejected else { throw Invalid.context }
                print("APPROVAL_KEY_PROVENANCE mode=\(mode) gateEscape=\(request.arguments["key"] == "escape") gateTab=\(request.arguments["key"] == "tab") workOriginalAuthored=\(job.work.original == ApprovalProbe.request) workPromptAmendment=\(job.work.prompt.contains("Actually, press tab instead.")) followUps=\(job.work.followUps.count) workRevision=\(job.work.revision) taskMatched=\(request.taskID == job.id.uuidString) ready=\(review.isReadyToRun) fires=\(fires.count) cancelled=\(task.isCancelled)")
                check(request.toolID == "computer.press_key" && request.arguments["key"] == "escape"
                    && review.id == request.id && fires.isEmpty && !task.isCancelled,
                    "C02 actual ready Gate proposal precedes backing (\(mode))")
                if mode == "staleCaller" {
                    let staleRow = try sql.load().first { $0.id == job.id.uuidString }
                    check(staleAdvanced && staleBefore != nil && staleAfter == staleBefore.map { $0 + 1 }
                        && job.worker.currentGeneration == staleAfter && !task.isCancelled,
                        "SC01 actual retained worker generation changed at real review hop")
                    check(routeObservations == routeBefore + 1 && matchedRoutes == matchedBefore,
                        "SF01 original caller generation cannot borrow current live slot approval route")
                    check(staleRow?.status == .running && staleRow?.pendingInteraction == nil
                        && bridge.approvals[request.id] == nil,
                        "SC02 stale originating call stays display-only without primary/spoken authority")
                    let spoke = output.flush(userHasFloor: false)
                    check(!spoke && output.activeOutputID == nil && !recorder.isSpeaking && fires.isEmpty,
                        "SC03 stale caller cannot produce an approval utterance or effect")
                    let consumedVoice = gate.respond(id: request.id, approved: false, via: .voice)
                    check(!consumedVoice && gate.pending?.id == request.id,
                        "SF02 stale displayed request cannot consume an unbound voice response")
                    if gate.pending?.id == request.id {
                        guard gate.respond(id: request.id, approved: false, via: .card) else { throw Invalid.owner }
                    }
                    await task.value; owned = nil
                    check(fires.isEmpty && gate.pending == nil && gate.queuedCount == 0
                        && PermissionGrantStore.shared.grants == grants,
                        "SC04 actual card denial joins same stale caller without effect/grant")
                    if capture.isSessionActive { await capture.endSession(source: .done) }
                    c.resetForTesting(); _ = c.installTaskBridgeForTesting(nil)
                    output.setNowForTesting(nil); _ = playback.installOutputForTesting(nil)
                    ToolCallReviewStore.shared.remove(id: request.id)
                    check(c.barrierWaiterCountForTesting == 0 && !contextRejected,
                        "SC05 stale caller fixture owns and joins exact cleanup")
                    print("SPOKEN_APPROVAL_STALE_CALLER observed=\(routeObservations-routeBefore) matched=\(matchedRoutes-matchedBefore) generationChanged=\(staleAdvanced) physical=false")
                    currentManager = nil; probe = nil
                    continue
                }
                let saved = try sql.load().first
                let exactPending: Bool = if case .permission(let p, _, _) = saved?.pendingInteraction { p == request } else { false }
                check(saved?.status == .waitingForPermission && exactPending && c.hasActiveWork,
                    "F01 actual proposal not committed as same waiting permission (\(mode))")
                if mode == "stalePresented" {
                    let priorGeneration = job.worker.currentGeneration
                    let priorRows = try sql.load(), priorBytes = try Data(contentsOf: file)
                    let priorJournal = try sql.journal(taskID: job.id.uuidString)
                    job.worker.cancelVoiceObjective()
                    check(job.worker.currentGeneration == priorGeneration + 1 && !task.isCancelled,
                        "PC01 actual presented caller generation advanced without cancelling retained Task")
                    output.setNowForTesting(Date().addingTimeInterval(2))
                    let staleFlush = output.flush(userHasFloor: false)
                    check(!staleFlush && output.activeOutputID == nil && !recorder.isSpeaking
                        && bridge.pendingApproval(sessionID: session) == nil,
                        "PF01 obsolete presented caller retained prompt/playback authority")
                    let staleDecision = gate.respond(id: request.id, approved: true, via: .card)
                    check(!staleDecision && gate.pending?.id == request.id && fires.isEmpty
                        && PermissionGrantStore.shared.grants == grants,
                        "PF02 stale presented card decision created continuation/grant/effect")
                    check(try sql.load() == priorRows && Data(contentsOf: file) == priorBytes
                        && sql.journal(taskID: job.id.uuidString) == priorJournal,
                        "PC02 stale presented refusal changed actual primary or decision journal")
                    _ = c.cancel(job.id); await state.release(); await task.value; owned = nil
                    drain(synth, recorder, acknowledge: true)
                    if capture.isSessionActive { await capture.endSession(source: .done) }
                    c.resetForTesting(); _ = c.installTaskBridgeForTesting(nil)
                    output.setNowForTesting(nil); _ = playback.installOutputForTesting(nil)
                    ToolCallReviewStore.shared.remove(id: request.id)
                    check(gate.pending == nil && gate.queuedCount == 0 && c.barrierWaiterCountForTesting == 0,
                        "PC03 obsolete presented caller same Task cleanup joined")
                    currentManager = nil; probe = nil
                    continue
                }
                let firstApprovalOpportunity = Date().addingTimeInterval(2)
                output.setNowForTesting(firstApprovalOpportunity)
                let flushed = output.flush(userHasFloor: false)
                check(flushed && output.activeOutputID != nil && recorder.isSpeaking
                    && bridge.pendingApproval(sessionID: session)?.request == request,
                    "F02 actual same-request priority prompt absent (\(mode))")
                if mode != "unheard" { drain(synth, recorder, acknowledge: true) }
                let heard = bridge.pendingApproval(sessionID: session)
                check(mode == "unheard" ? heard?.heardStart == false : heard?.heardStart == true,
                    "F03 exact positive current-output onset not retained (\(mode))")
                let before = try sql.load(), bytes = try Data(contentsOf: file), journal = try sql.journal(taskID: job.id.uuidString)
                var reply = ""
                if mode.hasPrefix("model-") {
                    let stream = ModelControlProbe(obsoleteWorker: mode == "model-stale" ? job.worker : nil, changeProposal: mode == "model-change")
                    c.streamForTesting = { _, messages in await stream.stream(messages) }
                    let originalGeneration = job.worker.currentGeneration
                    let raw = mode == "model-negative" ? "I definitely do not want you to proceed."
                        : mode == "model-change" ? "Yes, please use tab."
                        : "Yes, please go ahead with that exact proposal."
                    guard SpokenApproval.read(raw) == .unrelated,
                          SpokenApproval.modelApprovalAllowed(raw) == (mode != "model-negative") else { throw Invalid.context }
                    if mode == "model-refused" {
                        try sql.withConnection { try TaskStore.exec($0, "CREATE TRIGGER refuse_model_approval BEFORE UPDATE ON task WHEN OLD.state='waitingForPermission' AND NEW.state='running' BEGIN SELECT RAISE(ABORT,'owned model refusal'); END") }
                    }
                    reply = await input(raw).reply
                    check(stream.calls == 1 && (mode != "model-stale" || (job.worker.currentGeneration == originalGeneration + 1 && !task.isCancelled)),
                        "MC01 actual external model boundary/same uncancelled worker (\(mode))")
                    let package = stream.messages.last?.content ?? ""
                    check(package.contains("\"name\":\"respond_approval\"") && package.contains("Approval offered: yes"),
                        "MF06 actual offered fourth schema missing at the real frontend caller (\(mode))")
                    if mode == "model-change" {
                        let replanned = await reached({ gate.pending?.arguments["key"] == "tab" })
                        let currentRow = try sql.load().first { $0.id == job.id.uuidString }
                        let newPending: Bool = if case .permission(let retained, _, _) = currentRow?.pendingInteraction {
                            retained.id == gate.pending?.id && retained.id != request.id && retained.arguments["key"] == "tab"
                        } else { false }
                        check(replanned && newPending && currentRow?.status == .waitingForPermission
                            && currentRow?.revision == 1 && job.work.revision == 1
                            && reply == "Okay, I'll change that and check with you again.",
                            "MF04 model change did not replan same task to a fresh committed proposal")
                        check(currentRow?.userWords == raw && job.work.original == ApprovalProbe.request
                            && job.work.followUps.contains(raw) && !ObjectiveFidelity.accepts("Press tab.", userWords: raw),
                            "MF05 unfaithful model change lost exact current words or changed original objective")
                        check(fires.isEmpty && PermissionGrantStore.shared.grants == grants && !task.isCancelled,
                            "MC04 yes plus model change authorized old backing or replaced the same live Task")
                    } else if mode == "model-yes" {
                        let didFire = await reached({ fires == ["escape"] })
                        if didFire { await task.value }
                        check(didFire && gate.pending == nil && reply == "Okay, doing it."
                            && manager.task(id: job.id.uuidString)?.status == .completed,
                            "MF01 actual offered model approval did not admit exactly one backing/result")
                    } else {
                        check(gate.pending?.id == request.id && fires.isEmpty && PermissionGrantStore.shared.grants == grants,
                            "MC02 negative/refused/obsolete model answer released an action (\(mode))")
                        check(try sql.load() == before && Data(contentsOf: file) == bytes
                            && sql.journal(taskID: job.id.uuidString) == journal,
                            "MC03 model refusal changed exact primary/export/journal (\(mode))")
                        if mode == "model-refused" {
                            check(reply == "I couldn't save that answer. The request is still waiting."
                                && c.effectHoldEpoch != nil && manager.lastPersistenceResult == .sqlFailed,
                                "MF02 model decision primary refusal lost actual proposal/hold")
                        } else {
                            check(reply == "Please use the buttons on screen for that one."
                                && (mode != "model-stale" || bridge.pendingApproval(sessionID: session) == nil),
                                "MF03 negative or obsolete model decision bypassed captured offered authority (\(mode))")
                        }
                    }
                    if mode == "model-refused" { try sql.withConnection { try TaskStore.exec($0, "DROP TRIGGER refuse_model_approval") } }
                } else {
                switch mode {
                case "staleHeard":
                    let priorGeneration = job.worker.currentGeneration
                    job.worker.cancelVoiceObjective()
                    check(job.worker.currentGeneration == priorGeneration + 1 && !task.isCancelled,
                        "HC01 actual heard caller generation advanced without cancelling same Task")
                    let staleDecision = gate.respond(id: request.id, approved: true, via: .voice)
                    check(!staleDecision && gate.pending?.id == request.id && fires.isEmpty
                        && bridge.pendingApproval(sessionID: session) == nil
                        && PermissionGrantStore.shared.grants == grants,
                        "HF01 old heard output borrowed successor generation voice authority")
                    check(try sql.load() == before && Data(contentsOf: file) == bytes
                        && sql.journal(taskID: job.id.uuidString) == journal,
                        "HC02 stale heard refusal emitted primary decision facts")
                case "yes":
                    reply = await input("Yes.").reply
                    let didFire = await reached({ !fires.isEmpty })
                    if didFire { await task.value }
                    check(didFire && fires == ["escape"] && gate.pending == nil && reply == "Okay, doing it."
                        && manager.task(id: job.id.uuidString)?.status == .completed,
                        "F04 heard current yes did not release exactly one real orchestrator backing and completion")
                case "no":
                    reply = await input("No.").reply
                    check(gate.pending == nil && fires.isEmpty && reply == "Okay, I won't go ahead.",
                        "F05 heard no did not resolve same Gate without effect")
                case "card":
                    guard !contextRejected, gate.respond(id: request.id, approved: true) else { throw Invalid.owner }
                    let didFire = await reached({ fires == ["escape"] })
                    if didFire { await task.value }
                    check(didFire && output.activeOutputID == nil && bridge.approvals[request.id] == nil
                        && manager.task(id: job.id.uuidString)?.status == .completed,
                        "C03 actual card decision failed to withdraw SAME spoken request")
                case "edited":
                    ToolCallReviewStore.shared.update(id: request.id, field: "key", to: "tab")
                    reply = await input("Yes.").reply
                    check(reply == "It changed on screen, so please approve it there." && gate.pending?.id == request.id && fires.isEmpty,
                        "F06 changed executable proposal borrowed old heard approval")
                case "refused":
                    try sql.withConnection { try TaskStore.exec($0, "CREATE TRIGGER reject_voice_permission BEFORE UPDATE ON task WHEN OLD.state='waitingForPermission' AND NEW.state='running' BEGIN SELECT RAISE(ABORT,'owned permission refusal'); END") }
                    reply = await input("Yes.").reply
                    check(reply == "I couldn't save that answer. The request is still waiting." && gate.pending?.id == request.id
                        && c.effectHoldEpoch != nil && fires.isEmpty,
                        "F07 failed same primary decision emitted approval or lost hold")
                    check(try sql.load() == before && Data(contentsOf: file) == bytes && sql.journal(taskID: job.id.uuidString) == journal,
                        "C04 refused decision changed canonical history (\(mode))")
                    try sql.withConnection { try TaskStore.exec($0, "DROP TRIGGER reject_voice_permission") }
                case "mismatch":
                    try sql.withConnection { try TaskStore.exec($0, "CREATE TRIGGER reject_approval_revision BEFORE UPDATE ON task WHEN NEW.revision>OLD.revision BEGIN SELECT RAISE(ABORT,'owned revision refusal'); END") }
                    let correction = await input("Actually, press tab instead.")
                    let replanned = await reached({ gate.pending?.arguments["key"] == "tab" })
                    guard replanned, let uncommitted = gate.pending else { throw Invalid.worker }
                    let rows = try sql.load()
                    check(correction.reply == "I couldn't save that correction. The task is waiting."
                        && job.work.revision == 1 && rows.first?.revision == 0
                        && c.effectHoldEpoch != nil && fires.isEmpty,
                        "C10 actual failed revision holds SAME newer work")
                    // Refused revision retains the exact prior row, including a
                    // previously admitted waiting request. The NEW display-only
                    // card may not replace it or borrow spoken authority.
                    let newPending: Bool = if case .permission(let retained, _, _) = rows.first?.pendingInteraction {
                        retained.id == uncommitted.id
                    } else { false }
                    let exportPreserved = try Data(contentsOf: file) == bytes
                    let journalPreserved = try sql.journal(taskID: job.id.uuidString) == journal
                    check(uncommitted.id != request.id && rows == before && !newPending
                        && exportPreserved && journalPreserved
                        && bridge.pendingApproval(sessionID: capture.sessionID) == nil,
                        "C11 mismatched fresh display card gained spoken/current pending authority")
                    let grantsBefore = PermissionGrantStore.shared.grants
                    _ = await input("Yes.")
                    check(gate.pending?.id == uncommitted.id && fires.isEmpty
                        && PermissionGrantStore.shared.grants == grantsBefore,
                        "C12 mismatched display-only request gained spoken yes token or backing")
                    try sql.withConnection { try TaskStore.exec($0, "DROP TRIGGER reject_approval_revision") }
                case "amend":
                    reply = await input("Actually, press tab instead.").reply
                    let replanned = await reached({ gate.pending?.arguments["key"] == "tab" })
                    check(replanned && gate.pending?.id != request.id && fires.isEmpty
                        && job.work.revision == 1 && manager.task(id: job.id.uuidString)?.revision == 1
                        && reply == "Okay, I'll change that and check with you again.",
                        "F08 amendment did not retain same work/canonical revision and fresh request")
                case "close":
                    await capture.endSession(source: .idle)
                    print("APPROVAL_SESSION_METADATA stage=closed pendingMatches=\(gate.pending?.id == request.id) firesZero=\(fires.isEmpty) heardStart=\(bridge.approvals[request.id]?.heardStart == true) retainedTask=\(!task.isCancelled) activeOutput=\(output.activeOutputID != nil)")
                    check(gate.pending?.id == request.id && fires.isEmpty && bridge.approvals[request.id]?.heardStart != true,
                        "C05 close approved or discarded live request/playback scope")
                    await capture.beginSession(captureAudio: false)
                    output.setNowForTesting(firstApprovalOpportunity.addingTimeInterval(0.350)); recorder.reset()
                    let again = output.flush(userHasFloor: false)
                    print("APPROVAL_SESSION_METADATA stage=reopened pendingMatches=\(gate.pending?.id == request.id) recipientMatches=\(bridge.approvals[request.id]?.recipient == capture.sessionID) currentProposal=\(bridge.pendingApproval(sessionID: capture.sessionID)?.request.id == request.id) flushed=\(again) retainedTask=\(!task.isCancelled)")
                    check(again && capture.sessionID != session && bridge.pendingApproval(sessionID: capture.sessionID)?.request.id == request.id,
                        "F09 same retained card was not offered to actual next session")
                    drain(synth, recorder, acknowledge: true)
                default:
                    reply = await input(mode == "hold" ? "Wait." : "Yes.").reply
                    check(gate.pending?.id == request.id && fires.isEmpty,
                        "C06 unheard yes/hold released effect (\(mode))")
                    check(reply == (mode == "hold" ? "Okay, it'll wait for you." : "I'll read the request first."),
                        "F10 exact routing gate absent for held/unheard current request (\(mode))")
                }
                }
                // Retire only the owned live job/task, then join it before any root removal.
                if currentCapture()?.task != nil { _ = c.cancel(job.id) }
                await state.release(); await task.value; owned = nil
                drain(synth, recorder, acknowledge: true)
                if capture.isSessionActive { await capture.endSession(source: .done) }
                c.resetForTesting(); _ = c.installTaskBridgeForTesting(nil)
                output.setNowForTesting(nil); _ = playback.installOutputForTesting(nil)
                ToolCallReviewStore.shared.remove(id: request.id)
                check(gate.pending == nil && gate.queuedCount == 0 && c.barrierWaiterCountForTesting == 0
                    && PermissionGrantStore.shared.grants == grants,
                    "C07 exact owned waiter/grant cleanup (\(mode))")
                print("SPOKEN_APPROVAL_CASE mode=\(mode) checks=\(checks-start) fired=\(fires.count) onset=\(heard?.heardStart == true) contextRejected=\(contextRejected) physical=false")
                if mode.hasPrefix("model-") { modelChecks += checks - start; modelProblems += failures.count - problemsBefore }
                currentManager = nil; probe = nil
            }
            print("SPOKEN_APPROVAL_MODEL_CHECKS count=\(modelChecks) problems=\(modelProblems) legacyModeChecks=\(checks-modelChecks)")
            check(contextReads > 0 && !contextRejected, "C08 actual request/task scoped context stayed isolated")
            check(SelfTestStoreGuard.diff(owner, SelfTestStoreGuard.take()).isEmpty, "C09 owner store/default/grant invariant")
        } catch {
            failures.append("spoken approval: INVALID \(error)")
            for row in c.taskBridge.cachedTasks where row.source == "voice" { if let id = UUID(uuidString: row.id) { _ = c.cancel(id) } }
            await probe?.release(); if let owned { await owned.value }
            if capture.isSessionActive { await capture.endSession(source: .done) }
        }
        return (checks, failures)
    }

    /// Separate actual Gate-arrival companion; the original221/model53 and D3-69
    /// bodies stay unchanged. External planner/key/model stream are scripted;
    /// proposal, canonical waiting row, queue and onset receipt are real producers.
    static func runPhrasePreemption(recorder: RecordingSpeechBacking) async -> (checks: Int, failures: [String]) {
        let c = VoiceConversationCoordinator.shared, capture = AgentCaptureController.shared
        let gate = PermissionGate.shared, synth = AgentSpeechSynthesizer.shared
        let playback = VoicePlaybackDelivery.shared
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-voice-delivery",
              AgentSession.shared.fileURL == nil, !capture.isSessionActive,
              !c.hasActiveWork, gate.pending == nil, gate.queuedCount == 0,
              !DictionaryStore.hasRootAdmissionForTesting else {
            return (0, ["phrase approval: INVALID foreign owner"])
        }
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let root = temp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard root.path == root.resolvingSymlinksInPath().standardizedFileURL.path,
              root.deletingLastPathComponent().path == temp.path,
              !FileManager.default.fileExists(atPath: root.path) else { return (0, ["phrase approval: INVALID root"]) }
        let priorBridge = c.taskBridgeOverrideForTesting, priorRemember = c.rememberExplicit
        let priorFake = AgentToolExecutor.fakeForTesting, priorFire = AgentToolExecutor.fireOverrideForTesting
        let priorPolicy = AgentToolExecutor.policyOverrideForTesting
        let priorInputs = AgentCapabilityManifestBuilder.inputsOverrideForTesting
        let priorWhole = PlannerBackends.wholeTurnOverrideForTesting, priorNeedle = ToolLoopLiveEval.needleFirstForTesting
        let storeGuard = SelfTestStoreGuard.take(), grants = PermissionGrantStore.shared.grants
        let planner = ApprovalProbe(mode: "phrase-preemption")
        let phrase = ApprovalPhrasePreemptionProbe()
        let frontend = FrontendResponder()
        var sql: TaskStore?, manager: AgentTaskManager?, output: OutputScheduler?
        var ownedTask: Task<Void, Never>?, phraseTask: Task<Void, Never>?, nativeTask: Task<Void, Never>?
        var ownedID: UUID?, requestID: String?, contextInstalled = false, contextRejected = false
        var created = false, joined = false, fires = 0, contextReads = 0
        var dictionaryInstalled = false, voiceContextInstalled = false, activityInstalled = false
        var checks = 0; var failures: [String] = []
        func check(_ value: Bool, _ label: String) { checks += 1; if !value { failures.append("phrase approval: " + label) } }
        defer {
            // Reset/removal happen only after the actual existing owners joined.
            if joined {
                c.resetForTesting(); _ = c.installTaskBridgeForTesting(priorBridge)
                _ = playback.installOutputForTesting(nil)
                if let requestID { ToolCallReviewStore.shared.remove(id: requestID) }
                // The existing Builder setter requires its root to still exist.
                if contextInstalled {
                    // Best effort only; explicit verdict is recorded before return.
                    if ToolCallContextBuilder.setMeetingContextForTesting(nil, root: root) { contextInstalled = false }
                }
                if activityInstalled { NextMemory.finishActivityContextForTesting(root: root) }
                if voiceContextInstalled { VoiceCapabilitySnapshot.finishContextForTesting(root: root) }
                if dictionaryInstalled { DictionaryStore.finishRootForTesting(root) }
                sql?.close()
                if created && !contextInstalled { try? FileManager.default.removeItem(at: root) }
            }
            c.rememberExplicit = priorRemember
            AgentToolExecutor.fakeForTesting = priorFake; AgentToolExecutor.fireOverrideForTesting = priorFire
            AgentToolExecutor.policyOverrideForTesting = priorPolicy
            AgentCapabilityManifestBuilder.inputsOverrideForTesting = priorInputs
            PlannerBackends.wholeTurnOverrideForTesting = priorWhole; ToolLoopLiveEval.needleFirstForTesting = priorNeedle
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false); created = true
            let primary = TaskStore(root: root); sql = primary
            let store = AgentTaskStore(fileURL: root.appendingPathComponent("agent-tasks.json"), mirror: primary)
            guard store.allowsHarnessPersistence, store.save([]).primaryCommitted else { throw Invalid.unsafe }
            let current = AgentTaskManager(store: store); manager = current
            let bridge = TaskBridge(manager: current)
            guard let queue = OutputScheduler.isolatedForTesting(bridge),
                  c.installTaskBridgeForTesting(bridge), playback.installOutputForTesting(queue) else { throw Invalid.unsafe }
            output = queue
            // Admission precedes the first actual RTA/Coordinator correction call.
            // A preloaded singleton or foreign scope refuses instead of redirecting it.
            guard DictionaryStore.installRootForTesting(root, bridge: bridge) else { throw Invalid.context }
            dictionaryInstalled = true
            // Even a later setup failure leaves only the SAME confined singleton.
            _ = DictionaryStore.shared
            guard DictionaryStore.capturedRootMatchesForTesting(root) == true else { throw Invalid.context }
            guard VoiceCapabilitySnapshot.installContextForTesting(root: root, bridge: bridge,
                    inputs: RealtimeAgentToolLoopSelfTest.allEnabledFixture()) else { throw Invalid.context }
            voiceContextInstalled = true
            guard VoiceCapabilitySnapshot.contextIsAdmittedForTesting(root: root, bridge: bridge),
                  DictionaryStore.rootIsPreparedForTesting(root) else { throw Invalid.context }
            // The actual planner refreshes local activity before its provider call.
            // Reuse the existing collaborator; no owner meetings/tasks fallback.
            guard NextMemory.installActivityContextForTesting(root: root, bridge: bridge) else { throw Invalid.context }
            activityInstalled = true
            guard ToolCallContextBuilder.setMeetingContextForTesting({ meeting, task in
                contextReads += 1
                guard meeting == nil, let task, current.task(id: task)?.source == "voice",
                      FileManager.default.fileExists(atPath: root.path) else { contextRejected = true; return nil }
                return ToolCallContext()
            }, root: root) else { throw Invalid.context }
            contextInstalled = true
            AgentToolExecutor.fakeForTesting = nil; AgentToolExecutor.policyOverrideForTesting = .denyMutations
            PlannerBackends.wholeTurnOverrideForTesting = nil; ToolLoopLiveEval.needleFirstForTesting = false
            c.rememberExplicit = { _ in }; c.prewarmObserverForTesting = {}; c.workerForTesting = nil
            c.workerProviderForTesting = ApprovalProvider(probe: planner)
            c.streamForTesting = { _, messages in await planner.frontend(messages) }
            AgentToolExecutor.fireOverrideForTesting = { tool, arguments in
                guard tool.id == "computer.press_key", arguments["key"] == "escape", arguments["modifiers"] == nil else { throw Invalid.unsafe }
                fires += 1; return AgentToolResult(summary: "The owned application key was applied.")
            }
            await capture.beginSession(captureAudio: false)
            RealtimeAgent.shared.userSpeechStarted(); RealtimeAgent.shared.userSpeechEnded()
            let began = await RealtimeAgent.shared.handle(ApprovalProbe.request, source: .voice)
            // Capture BEFORE held/provider/grammar guards can throw.
            if let row = bridge.cachedTasks.first(where: { $0.source == "voice" }), let id = UUID(uuidString: row.id) {
                ownedID = id; ownedTask = c.captureVoiceWorkerForTesting(id: id)?.task
            }
            guard let id = ownedID, let workerTask = ownedTask,
                  let live = c.captureVoiceWorkerForTesting(id: id), let session = capture.sessionID,
                  await reached({ await planner.heldCount == 1 }) else { throw Invalid.worker }
            check(began.reply == "I'm on it." && live.task == workerTask && !workerTask.isCancelled && fires == 0
                    && DictionaryStore.capturedRootMatchesForTesting(root) == true
                    && VoiceCapabilitySnapshot.contextIsAdmittedForTesting(root: root, bridge: bridge),
                "C01 actual owned planner held before real proposal")
            drain(synth, recorder, acknowledge: true); recorder.reset()
            guard let reader = AgentCapabilityManifestRuntime.publishedReader else { throw Invalid.grammar }
            let manifest = AgentCapabilityManifestBuilder.build(.live(reader: reader), request: ApprovalProbe.request)
            guard manifest.allowedIDs.contains("computer.press_key"),
                  LlamaGrammarPlanner.grammar(for: manifest).matches(ApprovalProbe.call("escape")) else { throw Invalid.grammar }
            let resultID = UUID(), resultFacts = "The owned background result is ready."
            guard bridge.beginVoiceObjective(id: resultID, objective: "Read the owned preemption document",
                    origin: .voice(sessionID: session, turn: TurnID(raw: 2)), userWords: "Read the owned preemption document"),
                  bridge.finishVoiceObjective(id: resultID, outcome: .completed(resultFacts)),
                  queue.enqueueCompletion(TaskID(resultID)) else { throw Invalid.owner }
            guard await frontend.setGenerationForTesting({ system, messages, tokens in
                phrase.stream(system: system, messages: messages, tokens: tokens)
            }, retainingTaskOwner: true, fixtureRoot: root) else { throw Invalid.unsafe }
            queue.setPhraseForTesting { batch in await frontend.phrase(batch, carriedOver: false) }
            queue.setNowForTesting(Date().addingTimeInterval(2))
            let phraseBegan = ContinuousClock.now
            let flushed = queue.flush(userHasFloor: false)
            phraseTask = queue.ownedPhraseTaskForTesting
            guard let actualPhrase = phraseTask, await reached({ phrase.snapshot().held }) else { throw Invalid.worker }
            nativeTask = await frontend.ownedGenerationForTesting()
            guard let actualNative = nativeTask else { throw Invalid.worker }
            check(flushed && phrase.snapshot().calls == 1 && phrase.snapshot().tokens == 120
                    && bridge.record(TaskID(resultID))?.delivery == .delivering && !recorder.isSpeaking,
                "C02 actual retained result phrase/native owner reached before proposal")
            await planner.release()
            guard await reached({ gate.pending?.taskID == id.uuidString }), let request = gate.pending,
                  let review = ToolCallReviewStore.shared.review(id: request.id), review.isReadyToRun else { throw Invalid.context }
            requestID = request.id
            // Qualify actual proposal admission while the original1.5s phrase
            // budget is still open; a delayed fixture cannot stand in for preemption.
            guard phraseBegan.duration(to: .now) < .seconds(1.5) else { throw Invalid.worker }
            let row = try primary.load().first { $0.id == id.uuidString }
            let exactWaiting: Bool = if case .permission(let saved, _, _) = row?.pendingInteraction { saved == request } else { false }
            check(row?.status == .waitingForPermission && exactWaiting && request.arguments["key"] == "escape"
                    && bridge.pendingApproval(sessionID: session)?.request == request && contextReads > 0 && !contextRejected,
                "C03 real Gate/review/primary proposal admitted for same live worker")
            check(actualPhrase.isCancelled && queue.ownedPhraseTaskForTesting == nil
                    && bridge.record(TaskID(resultID))?.delivery == .pending && fires == 0,
                "F01 admitted real approval must cancel phrase and restore SAME pending result")
            let approvalFlushed = queue.flush(userHasFloor: false)
            let approvalOutput = queue.activeOutputID
            check(approvalFlushed && approvalOutput != nil && recorder.isSpeaking
                    && bridge.approvals[request.id]?.output == approvalOutput
                    && bridge.record(TaskID(resultID))?.delivery == .pending && fires == 0,
                "F02 current approval audio must precede held result generation return")
            let approvalPrompt = bridge.approvals[request.id]?.prompt.text
            let approvalClauses = approvalPrompt.map(AgentSpeechPolicy.speakableClauses) ?? []
            let approvalNativeGeneration = synth.outputGeneration
            let approvalPlaybackToken = synth.currentPlaybackToken
            phrase.release()
            await actualNative.value; await actualPhrase.value
            nativeTask = nil; phraseTask = nil
            let lateApproval = bridge.approvals[request.id]
            let latePromptClauses = lateApproval.map { AgentSpeechPolicy.speakableClauses($0.prompt.text) } ?? []
            let lateResultDelivery = bridge.record(TaskID(resultID))?.delivery
            print("OUTPUT_PHRASE_REAL_APPROVAL_LATE sameOutput=\(queue.activeOutputID == approvalOutput) sameNativeGeneration=\(synth.outputGeneration == approvalNativeGeneration) samePlaybackToken=\(synth.currentPlaybackToken == approvalPlaybackToken) approvalOutputMatches=\(lateApproval?.output == approvalOutput) approvalGenerationMatches=\(lateApproval?.outputGeneration == synth.outputGeneration) sameGate=\(gate.pending?.id == request.id) heardStart=\(lateApproval?.heardStart == true) heardFully=\(lateApproval?.heardFully == true) spokenCount=\(recorder.spoken.count) expectedClauseCount=\(latePromptClauses.count) firstWholePrompt=\(recorder.spoken.first == lateApproval?.prompt.text) firstAuthoredClause=\(recorder.spoken.first == latePromptClauses.first) activeClause=\(synth.voiceLifecycleSnapshot.hasClause) queuedClauses=\(synth.pendingClauseCount) isSpeaking=\(recorder.isSpeaking) resultPending=\(lateResultDelivery == .pending) resultDelivering=\(lateResultDelivery == .delivering) resultDelivered=\(lateResultDelivery == .delivered) phraseCancelled=\(actualPhrase.isCancelled) nativeCancelled=\(actualNative.isCancelled) phraseOwnerAbsent=\(queue.ownedPhraseTaskForTesting == nil) fires=\(fires)")
            check(queue.activeOutputID == approvalOutput && recorder.spoken.count == 1
                    && !approvalClauses.isEmpty && recorder.spoken.first == approvalClauses.first
                    && synth.pendingClauseCount == approvalClauses.count - 1
                    && synth.voiceLifecycleSnapshot.hasClause
                    && synth.outputGeneration == approvalNativeGeneration && synth.currentPlaybackToken == approvalPlaybackToken
                    && bridge.approvals[request.id]?.output == approvalOutput
                    && bridge.approvals[request.id]?.outputGeneration == approvalNativeGeneration
                    && gate.pending?.id == request.id
                    && bridge.record(TaskID(resultID))?.delivery == .pending && fires == 0,
                "F03 late original result generation cannot replace current approval output")
            drain(synth, recorder, acknowledge: true)
            let approvalFullWordsMatch = recorder.spoken.joined(separator: " ") == approvalPrompt
            print("OUTPUT_PHRASE_REAL_APPROVAL_FINAL fullPromptWords=\(approvalFullWordsMatch) exactClauses=\(recorder.spoken == approvalClauses) spokenCount=\(recorder.spoken.count) expectedClauseCount=\(approvalClauses.count) heardStart=\(bridge.approvals[request.id]?.heardStart == true) heardFully=\(bridge.approvals[request.id]?.heardFully == true) sameGate=\(gate.pending?.id == request.id) activeClause=\(synth.voiceLifecycleSnapshot.hasClause) queuedClauses=\(synth.pendingClauseCount) fires=\(fires)")
            check(bridge.approvals[request.id]?.heardStart == true && gate.pending?.id == request.id && fires == 0
                    && approvalPrompt != nil && approvalFullWordsMatch && recorder.spoken == approvalClauses
                    && bridge.approvals[request.id]?.heardFully == true
                    && !synth.voiceLifecycleSnapshot.hasClause && synth.pendingClauseCount == 0,
                "C04 exact approval onset receipt does not execute controlled key")
            guard gate.respond(id: request.id, approved: false, via: .card) else { throw Invalid.owner }
            await workerTask.value; ownedTask = nil
            queue.setPhraseForTesting(nil); await frontend.setGenerationForTesting(nil)
            await capture.endSession(source: .done); joined = true
            check(gate.pending == nil && gate.queuedCount == 0 && fires == 0 && PermissionGrantStore.shared.grants == grants
                    && c.barrierWaiterCountForTesting == 0,
                "C05 actual card denial and same owned Task drained without effect/grant")
            check(SelfTestStoreGuard.diff(storeGuard, SelfTestStoreGuard.take()).isEmpty,
                "C06 no owner store/default mutation")
            print("OUTPUT_PHRASE_REAL_APPROVAL checks=\(checks) calls=\(phrase.snapshot().calls) nativeJoined=true phraseJoined=true workerJoined=true fires=\(fires) physicalAudio=false")
        } catch {
            failures.append("phrase approval: INVALID \(error)")
            // Retain every actual scoped Manager owner before cancel can clear it.
            var owned = ownedTask.map { [$0] } ?? []
            if let manager {
                for row in manager.tasks where row.source == "voice" {
                    guard let id = UUID(uuidString: row.id), let task = c.captureVoiceWorkerForTesting(id: id)?.task else { continue }
                    if !owned.contains(where: { $0 == task }) { owned.append(task) }
                    _ = c.cancel(id)
                }
            }
            if phraseTask == nil { phraseTask = output?.ownedPhraseTaskForTesting }
            if nativeTask == nil { nativeTask = await frontend.ownedGenerationForTesting() }
            phraseTask?.cancel(); nativeTask?.cancel(); phrase.release(); await planner.release()
            for task in owned { await task.value }
            await nativeTask?.value; await phraseTask?.value
            output?.setPhraseForTesting(nil); await frontend.setGenerationForTesting(nil)
            if capture.isSessionActive { await capture.endSession(source: .done) }
            joined = true
        }
        // Evaluate teardown while the root still exists and after every owner join;
        // a defer cannot amend the already-evaluated returned failures array.
        if joined && contextInstalled {
            if ToolCallContextBuilder.setMeetingContextForTesting(nil, root: root) { contextInstalled = false }
            else { failures.append("phrase approval: INVALID review context teardown") }
        }
        return (checks, failures)
    }

    private static func drain(_ synth: AgentSpeechSynthesizer, _ recorder: RecordingSpeechBacking, acknowledge: Bool) {
        var bound = 32
        while (synth.voiceLifecycleSnapshot.hasClause || synth.pendingClauseCount > 0) && bound > 0 {
            if acknowledge { synth.notifyTestingFirstAudio(token: synth.currentPlaybackToken) }
            recorder.finishNaturallyForTesting(); synth.notifyTestingAudioFinished(token: synth.currentPlaybackToken)
            bound -= 1
        }
    }
}
private actor ApprovalProbe {
    nonisolated static let request = "Inspect the current window and press escape for the owned approval case."
    private var hold: CheckedContinuation<Void, Never>?
    private var first = true
    private let mode: String
    private var completionCalls = 0
    init(mode: String) { self.mode = mode }
    var heldCount: Int { hold == nil ? 0 : 1 }
    func release() { let old = hold; hold = nil; old?.resume() }
    func frontend(_ messages: [LLMChatMessage]) -> AsyncThrowingStream<String, Error> {
        let package = messages.last?.content ?? ""
        let value = package.hasSuffix("Latest user speech:\n" + Self.request) ? "<use_tools/>"
            : package.hasSuffix("Latest user speech:\nActually, press tab instead.") ? "<revise id=\"1\"/>"
            : "<answer>I heard that.</answer>"
        return AsyncThrowingStream { $0.yield(value); $0.finish() }
    }
    nonisolated static func call(_ key: String) -> String {
        "<tool_call>{\"name\":\"computer.press_key\",\"arguments\":{\"key\":\"" + key + "\",\"modifiers\":null},\"rationale\":\"Apply the exact owned requested key after approval.\"}</tool_call>"
    }
    private enum Invalid: Error { case currentRequestScope }
    func complete(_ user: String) async throws -> String {
        completionCalls += 1
        print("APPROVAL_PLANNER_INPUT mode=\(mode) call=\(completionCalls) first=\(first) containsAmendment=\(user.contains("Actually, press tab instead.")) containsOwnResult=\(user.contains("The owned application key was applied.")) containsAuthoredObjective=\(user.contains(Self.request))")
        // The real planner appends its current request after conversation context.
        // Historical corrections cannot become instructions for this new Work.
        guard let start = user.range(of: "Current user request:\n", options: .backwards) else { throw Invalid.currentRequestScope }
        let tail = user[start.upperBound...]
        let done = tail.range(of: "\n\nWhat you have already done:\n")
        let current = String(done.map { tail[..<$0.lowerBound] } ?? tail).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty else { throw Invalid.currentRequestScope }
        let results = done.map { String(tail[$0.upperBound...]) } ?? ""
        print("APPROVAL_PLANNER_SCOPE mode=\(mode) call=\(completionCalls) currentAmendment=\(current.contains("Actually, press tab instead.")) currentAuthoredObjective=\(current.contains(Self.request)) ownResultSection=\(results.contains("The owned application key was applied."))")
        if results.contains("The owned application key was applied.") { return "The owned key change is ready." }
        if first { first = false; await withCheckedContinuation { hold = $0 } }
        return Self.call(current.contains("Actually, press tab instead.") || current.contains("Yes, please use tab.") ? "tab" : "escape")
    }
}
private struct ApprovalProvider: LLMProvider {
    let id = LLMProviderID.appLLM; let probe: ApprovalProbe
    var contextTokens: Int { 8_192 }
    var unavailableReason: String? { get async { nil } }
    func countTokens(_ text: String) async throws -> Int { text.count / 4 }
    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        let text = try await probe.complete(user)
        return LLMCompletion(text: text, generatedTokens: text.count, duration: 0)
    }
}


/// Locked scripted model boundary only; stores no product task/output authority.
private final class ApprovalPhrasePreemptionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<String, Error>.Continuation?
    private var calls = 0, tokens = 0
    private var held = false
    func stream(system: String, messages: [LLMChatMessage], tokens: Int) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { next in
            lock.lock(); calls += 1; self.tokens = tokens; held = true; continuation = next; lock.unlock()
        }
    }
    func snapshot() -> (calls: Int, tokens: Int, held: Bool) {
        lock.lock(); defer { lock.unlock() }; return (calls, tokens, held)
    }
    func release() {
        lock.lock(); let current = continuation; continuation = nil; lock.unlock()
        current?.yield("The owned background result is ready."); current?.finish()
    }
}

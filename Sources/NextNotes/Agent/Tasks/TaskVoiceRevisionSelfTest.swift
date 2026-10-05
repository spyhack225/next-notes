import Foundation
import SQLite3

/// Current committed voice correction -> SAME live job -> actual permission/effect boundary.
/// External scripted inference and the authorized application key backing are isolated;
/// no physical key is pressed and no permission request or canonical task is seeded.
@MainActor
enum TaskVoiceRevisionSelfTest {
    private enum Invalid: Error { case unsafe, owner, worker, grammar, boundary }
    private static func reached(_ predicate: @MainActor () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while ContinuousClock.now < deadline {
            if await predicate() { return true }
            await Task.yield()
        }
        return await predicate()
    }
    static func run() async -> (checks: Int, failures: [String]) {
        let c = VoiceConversationCoordinator.shared
        let capture = AgentCaptureController.shared
        let gate = PermissionGate.shared
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-voice-work-lifecycle",
              AgentSession.shared.fileURL == nil, !capture.isSessionActive,
              c.taskBridge.cachedTasks.allSatisfy({ row in UUID(uuidString: row.id).flatMap { c.captureVoiceWorkerForTesting(id: $0) } == nil }), gate.pending == nil, gate.queuedCount == 0 else {
            return (0, ["voice revision: INVALID isolated lifecycle required"])
        }
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let root = temp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard root.deletingLastPathComponent().path == temp.path,
              root.path == root.resolvingSymlinksInPath().standardizedFileURL.path,
              !FileManager.default.fileExists(atPath: root.path) else {
            return (0, ["voice revision: INVALID unsafe root"])
        }
        let priorBridge = c.taskBridgeOverrideForTesting
        let priorRemember = c.rememberExplicit
        let priorFake = AgentToolExecutor.fakeForTesting
        let priorFire = AgentToolExecutor.fireOverrideForTesting
        let priorPolicy = AgentToolExecutor.policyOverrideForTesting
        let priorInputs = AgentCapabilityManifestBuilder.inputsOverrideForTesting
        let priorWhole = PlannerBackends.wholeTurnOverrideForTesting
        let priorNeedle = ToolLoopLiveEval.needleFirstForTesting
        let owner = SelfTestStoreGuard.take()
        var owned: Task<Void, Never>?
        var probe: VoiceRevisionProbe?
        var contextManager: AgentTaskManager?
        var contextRejected = false
        var contextReads = 0
        var contextInstalled = false
        var rootCreated = false
        var checks = 0; var failures: [String] = []
        func check(_ value: Bool, _ label: String) {
            checks += 1; if !value { failures.append("voice revision: " + label) }
        }
        func input(_ text: String) async -> AgentTurn {
            RealtimeAgent.shared.userSpeechStarted(); RealtimeAgent.shared.userSpeechEnded()
            return await RealtimeAgent.shared.handle(text, source: .voice)
        }
        defer {
            if contextInstalled { _ = ToolCallContextBuilder.setMeetingContextForTesting(nil, root: root) }
            c.resetForTesting(); _ = c.installTaskBridgeForTesting(priorBridge)
            c.rememberExplicit = priorRemember
            AgentToolExecutor.fakeForTesting = priorFake
            AgentToolExecutor.fireOverrideForTesting = priorFire
            AgentToolExecutor.policyOverrideForTesting = priorPolicy
            AgentCapabilityManifestBuilder.inputsOverrideForTesting = priorInputs
            PlannerBackends.wholeTurnOverrideForTesting = priorWhole
            ToolLoopLiveEval.needleFirstForTesting = priorNeedle
            if rootCreated { try? FileManager.default.removeItem(at: root) }
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false); rootCreated = true
            guard ToolCallContextBuilder.setMeetingContextForTesting({ meetingID, taskID in
                guard root.resolvingSymlinksInPath().standardizedFileURL.path == root.path,
                      root.deletingLastPathComponent().path == temp.path,
                      FileManager.default.fileExists(atPath: root.path),
                      meetingID == nil, let taskID, let contextManager,
                      contextManager.task(id: taskID) != nil else {
                    contextRejected = true; return nil
                }
                contextReads += 1
                return ToolCallContext() // Authored empty owned meeting history only.
            }, root: root) else { throw Invalid.unsafe }
            contextInstalled = true
            AgentToolExecutor.fakeForTesting = nil
            AgentToolExecutor.policyOverrideForTesting = .denyMutations
            AgentCapabilityManifestBuilder.inputsOverrideForTesting = RealtimeAgentToolLoopSelfTest.allEnabledFixture()
            PlannerBackends.wholeTurnOverrideForTesting = nil
            ToolLoopLiveEval.needleFirstForTesting = false
            for mode in ["accepted-parsed", "refused-parsed", "refused-naming", "question-answer", "running-journal"] {
                let start = checks
                let directory = root.appendingPathComponent(mode, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                let sql = TaskStore(root: directory); defer { sql.close() }
                let file = directory.appendingPathComponent("agent-tasks.json")
                let store = AgentTaskStore(fileURL: file, mirror: sql)
                guard store.allowsHarnessPersistence, store.save([]).primaryCommitted else { throw Invalid.unsafe }
                let manager = AgentTaskManager(store: store); let bridge = TaskBridge(manager: manager)
                contextManager = manager
                c.resetForTesting(); AgentSession.shared.forgetAllConversations()
                guard c.installTaskBridgeForTesting(bridge) else { throw Invalid.unsafe }
                await capture.beginSession(captureAudio: false)
                guard let session = capture.sessionID else { throw Invalid.owner }
                let request = "Inspect the current window and press escape for the owned revision case."
                let correction = mode == "question-answer" ? "Use the tab key." : (mode == "refused-naming" ? "The key is called tab." : "Actually, press tab instead of escape.")
                let state = VoiceRevisionProbe(request: request, correction: correction, question: mode == "question-answer"); probe = state
                c.rememberExplicit = { _ in }; c.prewarmObserverForTesting = {}
                c.workerForTesting = nil; c.workerProviderForTesting = VoiceRevisionProvider(probe: state)
                c.streamForTesting = { _, messages in await state.frontend(messages) }
                var fired: [String] = []
                AgentToolExecutor.fireOverrideForTesting = { tool, args in
                    guard tool.id == "computer.press_key", args["modifiers"] == nil,
                          let key = args["key"], ["escape", "tab"].contains(key) else { throw Invalid.boundary }
                    fired.append(key)
                    return AgentToolResult(summary: "The owned application key was applied.")
                }
                let started = await input(request)
                owned = c.taskBridge.cachedTasks.first.flatMap { UUID(uuidString: $0.id) }.flatMap { c.captureVoiceWorkerForTesting(id: $0) }?.task
                guard let job = c.taskBridge.cachedTasks.first.flatMap { UUID(uuidString: $0.id) }.flatMap { c.captureVoiceWorkerForTesting(id: $0) }, let task = owned,
                      await reached({ await state.heldCount == 1 }),
                      let row = manager.task(id: job.id.uuidString),
                      case .voice(let s, _)? = row.origin, s == session else { throw Invalid.worker }
                check(started.reply == "I'm on it." && c.taskBridge.cachedTasks.count == 1 && row.status == .running
                    && job.work.revision == 0 && row.revision == 0 && fired.isEmpty,
                    "C01 real current-session primary and SAME held worker (\(mode))")
                guard let reader = AgentCapabilityManifestRuntime.publishedReader else { throw Invalid.grammar }
                let manifest = AgentCapabilityManifestBuilder.build(.live(reader: reader), request: request)
                for key in ["escape", "tab"] {
                    let call = VoiceRevisionProbe.call(key)
                    let parsed = AgentToolCallParser.parse(call, knownNames: RealtimeAgent.callNames(manifest))
                    guard manifest.allowedIDs.contains("computer.press_key"),
                          LlamaGrammarPlanner.grammar(for: manifest).matches(call),
                          parsed.calls.count == 1, parsed.calls.first?.name == "computer.press_key" else { throw Invalid.grammar }
                }
                check(fired.isEmpty && !task.isCancelled, "C02 actual manifest/grammar/parser and positive task (\(mode))")
                if mode == "running-journal" {
                    // Real current correction while the initial planner is still
                    // held, BEFORE any permission proposal. No approval is seeded.
                    let changed = await input(correction)
                    let revised = try sql.load().first { $0.id == job.id.uuidString }
                    check(changed.reply == "Got it. I'll use that correction." && job.work.revision == 1
                        && revised?.revision == 1 && revised?.status == .running
                        && c.captureVoiceWorkerForTesting(id: job.id)?.task == task
                        && !task.isCancelled && fired.isEmpty,
                        "C17 actual running correction retains SAME operation and commits before proposal")
                    let journal = try sql.journal(taskID: job.id.uuidString)
                    let revisions = journal.filter { $0.draft.kind == .revisionRecorded }
                    check(revisions.count == 1 && revisions.first?.draft.detail == correction
                        && revisions.first?.draft.taskID == job.id.uuidString
                        && revisions.first?.draft.attempt == 0 && (revisions.first?.seq ?? 0) > 0,
                        "RJ01 actual running voice correction journals its exact instruction")
                    await state.releaseForCompletion()
                    guard await reached({ gate.pending?.taskID == job.id.uuidString
                            && gate.pending?.arguments["key"] == "tab" }),
                          let currentGate = gate.pending, gate.pendingReview?.isReadyToRun == true else { throw Invalid.boundary }
                    check(fired.isEmpty && currentGate.toolID == "computer.press_key",
                        "C18 revised actual plan requires fresh approval before current effect")
                    guard !contextRejected, gate.respond(id: currentGate.id, approved: true, duration: .once) else { throw Invalid.boundary }
                    guard await reached({ fired == ["tab"] }) else { throw Invalid.boundary }
                    await state.releaseAll(); await task.value; owned = nil
                    let completed = try sql.load().first { $0.id == job.id.uuidString }
                    let completedJournal = try sql.journal(taskID: job.id.uuidString)
                    let fresh = AgentTaskManager(store: AgentTaskStore(fileURL: file, mirror: sql))
                    let afterFreshJournal = try sql.journal(taskID: job.id.uuidString)
                    check(completed?.status == .completed && completed?.revision == 1
                        && completed?.result?.isEmpty == false && fresh.task(id: job.id.uuidString) == completed
                        && fresh.backendStartsForTesting == 0 && fresh.voiceWorkerSnapshot(id: job.id) == nil
                        && afterFreshJournal == completedJournal && fired == ["tab"],
                        "C19 completed current output and facts survive fresh Manager without voice replay")
                    await capture.endSession(source: .done)
                    check(!capture.isSessionActive && gate.pending == nil && gate.queuedCount == 0
                        && c.barrierWaiterCountForTesting == 0,
                        "C20 running revision SAME Task and current session cleanup")
                    print("VOICE_REVISION_TRACE mode=\(mode) checks=\(checks-start) workRevision=\(job.work.revision) primaryRevision=\(completed?.revision ?? -1) effects=\(fired.count)")
                    c.resetForTesting(); _ = c.installTaskBridgeForTesting(nil); probe = nil
                    continue
                }
                if mode == "question-answer" {
                    await state.releaseAll(); await task.value; owned = nil
                    guard let question = job.bridge.voiceInputRequest(TaskID(job.id)),
                          manager.task(id: job.id.uuidString)?.status == .waitingForInput,
                          c.captureVoiceWorkerForTesting(id: job.id)?.task == nil else { throw Invalid.worker }
                    check(question.question == VoiceRevisionProbe.questionText && question.taskID == job.id.uuidString
                        && fired.isEmpty && job.work.revision == 0,
                        "C12 actual typed question retains exact request before any effect")
                    let answered = await input(correction)
                    owned = c.captureVoiceWorkerForTesting(id: job.id)?.task
                    guard let successor = owned, let resumedCapture = c.captureVoiceWorkerForTesting(id: job.id),
                          await reached({ await state.heldCount == 1 }) else { throw Invalid.worker }
                    check(answered.reply == "Got it. I'll continue that task." && c.taskBridge.cachedTasks.count == 1
                        && c.taskBridge.cachedTasks.first?.id == job.id.uuidString && c.captureVoiceWorkerForTesting(id: job.id)?.worker === job.worker
                        && job.bridge.voiceInputRequest(TaskID(job.id)) == nil && job.work.revision == 1,
                        "C13 accepted actual answer continues SAME job/work/worker")
                    let resumed = try sql.load().first
                    check(resumed?.revision == 1 && resumed?.status == .running,
                        "F07 actual answer commits its exact work revision in SAME primary transition")
                    await state.releaseAll()
                    guard await reached({ gate.pending?.taskID == job.id.uuidString && gate.pending?.arguments["key"] == "tab" }),
                          let answerGate = gate.pending, gate.pendingReview?.isReadyToRun == true else { throw Invalid.boundary }
                    check(fired.isEmpty && answerGate.toolID == "computer.press_key",
                        "C14 resumed actual plan obtains fresh approval before effect")
                    guard !contextRejected, gate.respond(id: answerGate.id, approved: true, duration: .once) else { throw Invalid.boundary }
                    guard await reached({ fired == ["tab"] }) else { throw Invalid.boundary }
                    await state.releaseAll(); await successor.value; owned = nil
                    let result = try sql.load().first
                    check(fired == ["tab"] && result?.status == .completed && resumedCapture.worker === job.worker,
                        "C15 legitimate resumed write reaches SAME authorized backing once")
                    check(result?.revision == 1, "F08 actual resumed completion retains admitted revision")
                    await capture.endSession(source: .done)
                    check(gate.pending == nil && gate.queuedCount == 0 && c.barrierWaiterCountForTesting == 0,
                        "C16 actual question/answer/effect cleanup")
                    print("VOICE_REVISION_TRACE mode=\(mode) checks=\(checks-start) workRevision=\(job.work.revision) primaryRevision=\(result?.revision ?? -1) effects=\(fired.count)")
                    c.resetForTesting(); _ = c.installTaskBridgeForTesting(nil); probe = nil
                    continue
                }
                await state.releaseAll()
                guard await reached({ gate.pending?.taskID == job.id.uuidString && gate.pending?.arguments["key"] == "escape" }),
                      let firstGate = gate.pending, gate.pendingReview?.isReadyToRun == true else { throw Invalid.boundary }
                check(firstGate.toolID == "computer.press_key" && fired.isEmpty,
                    "C03 actual initial pending effect is unexecuted (\(mode))")
                let before = try sql.load(); let bytes = try Data(contentsOf: file)
                let events = try sql.journal(taskID: job.id.uuidString)
                if mode.hasPrefix("refused") {
                    try sql.withConnection { try TaskStore.exec($0,
                        "CREATE TRIGGER refuse_voice_revision BEFORE UPDATE ON task WHEN NEW.revision>OLD.revision BEGIN SELECT RAISE(ABORT,'owned revision refusal'); END") }
                }
                var expectedApprovalFeedback = false
                if mode == "accepted-parsed" {
                    let offered = c.taskBridge.pendingApproval(sessionID: capture.sessionID)
                    let readsAmend: Bool = if case .amend = SpokenApproval.read(correction) { true } else { false }
                    expectedApprovalFeedback = offered?.request.id == firstGate.id
                        && offered?.task == TaskID(job.id)
                        && manager.task(id: job.id.uuidString)?.status == .waitingForPermission && readsAmend
                    print("REVISION_APPROVAL_FEEDBACK stage=before offeredCurrent=\(offered?.request.id == firstGate.id) offeredTaskMatches=\(offered?.task == TaskID(job.id)) canonicalWaiting=\(manager.task(id: job.id.uuidString)?.status == .waitingForPermission) readsAmend=\(readsAmend) localRevision=\(job.work.revision) currentRevision=\(manager.task(id: job.id.uuidString)?.revision ?? -1)")
                }
                let changed = await input(correction)
                check(job.work.revision == 1 && job.work.followUps.last == correction
                    && c.taskBridge.cachedTasks.count == 1 && c.captureVoiceWorkerForTesting(id: job.id)?.worker === job.worker && !task.isCancelled,
                    "C04 actual committed correction updates SAME local work and retains worker (\(mode))")
                check(gate.pending?.id != firstGate.id && !gate.respond(id: firstGate.id, approved: true)
                    && fired.isEmpty, "C05 obsolete real approval cannot release old effect (\(mode))")
                if mode == "accepted-parsed" {
                    let acceptedRows = try sql.load()
                    check(manager.task(id: job.id.uuidString)?.revision == 1 && acceptedRows.first?.revision == 1,
                        "F01 accepted real correction committed canonical revision")
                    print("REVISION_APPROVAL_FEEDBACK stage=after parsedAck=\(changed.reply == "Got it. I'll use that correction.") approvalAck=\(changed.reply == "Okay, I'll change that and check with you again.") effectHeld=\(c.effectHoldEpoch != nil) localRevision=\(job.work.revision) currentRevision=\(manager.task(id: job.id.uuidString)?.revision ?? -1) currentGateChanged=\(gate.pending?.id != firstGate.id)")
                    check(changed.reply == (expectedApprovalFeedback
                        ? "Okay, I'll change that and check with you again." : "Got it. I'll use that correction.") && c.effectHoldEpoch == nil,
                        "C06 accepted correction keeps truthful immediate feedback")
                } else {
                    check(changed.reply == "I couldn't save that correction. The task is waiting." && c.effectHoldEpoch != nil,
                        "F02 refused real correction feedback retains effect hold (\(mode))")
                    check(try sql.load() == before && Data(contentsOf: file) == bytes
                        && sql.journal(taskID: job.id.uuidString) == events,
                        "C11 rejected canonical revision retains exact prior history (\(mode))")
                }
                guard await reached({ await state.heldCount == 1 }) else { throw Invalid.worker }
                await state.releaseAll()
                guard await reached({ gate.pending?.taskID == job.id.uuidString && gate.pending?.arguments["key"] == "tab" }),
                      let nextGate = gate.pending else { throw Invalid.boundary }
                check(nextGate.id != firstGate.id && gate.pendingReview?.isReadyToRun == true,
                    "C07 actual new plan obtains a fresh exact approval (\(mode))")
                guard !contextRejected, gate.respond(id: nextGate.id, approved: true, duration: .once) else { throw Invalid.boundary }
                guard await reached({ !fired.isEmpty || c.barrierWaiterCountForTesting > 0 }) else { throw Invalid.boundary }
                if mode.hasPrefix("refused") {
                    check(fired.isEmpty && c.barrierWaiterCountForTesting > 0 && !task.isCancelled,
                        "F04 SAME actual effect consumer is held after approval on rejected revision (\(mode))")
                    print("VOICE_REVISION_REJECT mode=\(mode) revision=\(job.work.revision) primary=\(manager.task(id:job.id.uuidString)?.revision ?? -1) effects=\(fired.count) waiting=\(c.barrierWaiterCountForTesting) sqlFailed=\(manager.lastPersistenceResult == .sqlFailed)")
                    // A missing original admission allows current work to run; do not seed
                    // another task to manufacture the retry branch after it has completed.
                    if !fired.isEmpty {
                        await state.releaseAll(); await task.value; owned = nil
                        await capture.endSession(source: .done); continue
                    }
                    try sql.withConnection { try TaskStore.exec($0, "DROP TRIGGER refuse_voice_revision") }
                    let retried = await input(correction)
                    // Authored fixture comparisons only; no arbitrary reply/context dump.
                    print("VOICE_REVISION_RETRY mode=\(mode) namingBare=\(retried.reply == "Got it — “tab”.") namingPeriod=\(retried.reply == "Got it — “tab.”.") parsedAck=\(retried.reply == "Got it. I'll use that correction.") refusal=\(retried.reply == "I couldn't save that correction. The task is waiting.") replyLength=\(retried.reply.count) workExpected=\(job.work.revision == 2) primaryExpected=\(manager.task(id:job.id.uuidString)?.revision == 2) sameJob=\(c.taskBridge.cachedTasks.count == 1 && c.taskBridge.cachedTasks.first?.id == job.id.uuidString) running=\(c.taskBridge.cachedTasks.first?.status == .running))")
                    check(retried.reply == (mode == "refused-naming" ? "Got it — “tab.”." : "Got it. I'll use that correction.")
                        && job.work.revision == 2 && manager.task(id:job.id.uuidString)?.revision == 2,
                        "F05 exact actual correction retry commits its newer canonical revision (\(mode))")
                    guard await reached({ await state.heldCount == 1 }) else { throw Invalid.worker }
                    await state.releaseAll()
                    guard await reached({ gate.pending?.taskID == job.id.uuidString && gate.pending?.arguments["key"] == "tab" }),
                          let retryGate = gate.pending else { throw Invalid.boundary }
                    check(retryGate.id != nextGate.id && fired.isEmpty && !gate.respond(id: nextGate.id, approved: true),
                        "C08 old approved callback cannot release a new revision (\(mode))")
                    guard !contextRejected, gate.respond(id: retryGate.id, approved: true, duration: .once) else { throw Invalid.boundary }
                }
                guard await reached({ fired == ["tab"] }) else { throw Invalid.boundary }
                await state.releaseAll(); await task.value; owned = nil
                let retained = try sql.load().first
                check(fired == ["tab"] && retained?.status == .completed && !task.isCancelled,
                    "C09 exactly one admitted current effect completes SAME worker (\(mode))")
                check(retained?.revision == job.work.revision && (retained?.revision ?? 0) > 0,
                    "F06 completed primary retains admitted revision (\(mode))")
                let completedJournal = try sql.journal(taskID: job.id.uuidString)
                let revisionFacts = completedJournal.filter { $0.draft.kind == .revisionRecorded }
                let expectedInstructions = mode.hasPrefix("refused") ? [correction, correction] : [correction]
                check(revisionFacts.map(\.draft.detail) == expectedInstructions
                    && revisionFacts.allSatisfy { $0.draft.taskID == job.id.uuidString && $0.draft.attempt == 0 && $0.seq > 0 }
                    && (!mode.hasPrefix("refused") || revisionFacts[0].seq < revisionFacts[1].seq),
                    "RJ02 actual permission amendment and explicit retry retain every admitted instruction (\(mode))")
                let fresh = AgentTaskManager(store: AgentTaskStore(fileURL: file, mirror: sql))
                let afterFreshJournal = try sql.journal(taskID: job.id.uuidString)
                check(retained?.status == .completed && retained?.result?.isEmpty == false
                    && fresh.task(id: job.id.uuidString) == retained && fresh.backendStartsForTesting == 0
                    && fresh.voiceWorkerSnapshot(id: job.id) == nil && afterFreshJournal == completedJournal,
                    "C21 completed voice result and revision facts survive fresh reader without replay (\(mode))")
                await capture.endSession(source: .done)
                check(!capture.isSessionActive && gate.pending == nil && gate.queuedCount == 0
                    && c.barrierWaiterCountForTesting == 0,
                    "C10 actual capture/approval/task cleanup (\(mode))")
                print("VOICE_REVISION_TRACE mode=\(mode) checks=\(checks-start) workRevision=\(job.work.revision) primaryRevision=\(retained?.revision ?? -1) effects=\(fired.count)")
                c.resetForTesting(); _ = c.installTaskBridgeForTesting(nil); probe = nil
            }
            guard !contextRejected, contextReads > 0 else { throw Invalid.boundary }
            print("VOICE_REVISION_CONTEXT reads=\(contextReads) unmatched=\(contextRejected) ownerFallback=false")
            let encoding = try TaskRevisionEncodingSelfTest.run(root: root)
            checks += encoding.checks; failures += encoding.failures
            check(SelfTestStoreGuard.diff(owner, SelfTestStoreGuard.take()).isEmpty,
                "C11 owner store/default/grant invariant")
        } catch {
            failures.append("voice revision: INVALID \(error)")
            for row in c.taskBridge.cachedTasks { if let id = UUID(uuidString: row.id) { _ = c.cancel(id) } }
            await probe?.releaseAll()
            if let owned { await owned.value }
            await capture.endSession(source: .done)
        }
        return (checks, failures)
    }
}
private actor VoiceRevisionProbe {
    let request: String; let correction: String; let question: Bool
    nonisolated static let questionText = "Which key should I press for the owned case?"
    private var calls = 0
    private var held: [CheckedContinuation<Void, Never>] = []
    private var completionReleased = false
    var heldCount: Int { held.count }
    init(request: String, correction: String, question: Bool) { self.request = request; self.correction = correction; self.question = question }
    func frontend(_ messages: [LLMChatMessage]) -> AsyncThrowingStream<String, Error> {
        let package = messages.last?.content ?? ""
        let value = package.hasSuffix("Latest user speech:\n" + request) ? "<use_tools/>" : "<revise id=\"1\"/>"
        return AsyncThrowingStream { $0.yield(value); $0.finish() }
    }
    nonisolated static func call(_ key: String) -> String {
        "<tool_call>{\"name\":\"computer.press_key\",\"arguments\":{\"key\":\"" + key + "\",\"modifiers\":null},\"rationale\":\"Apply the exact owned requested key after approval.\"}</tool_call>"
    }
    func releaseAll() { let list = held; held = []; for c in list { c.resume() } }
    // The new running-correction flow permits the real stale-round refresh to
    // complete too. Existing four modes keep their intentional per-round holds.
    func releaseForCompletion() { completionReleased = true; releaseAll() }
    func complete(_ user: String) async -> String {
        if user.contains("The owned application key was applied.") { return "The owned key change is ready." }
        calls += 1; let current = calls
        if !completionReleased { await withCheckedContinuation { held.append($0) } }
        if question && current == 1 { return Self.questionText }
        return Self.call(user.contains(correction) ? "tab" : "escape")
    }
}
private struct VoiceRevisionProvider: LLMProvider {
    let id = LLMProviderID.appLLM; let probe: VoiceRevisionProbe
    var contextTokens: Int { 8_192 }
    var unavailableReason: String? { get async { nil } }
    func countTokens(_ text: String) async throws -> Int { text.count / 4 }
    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        let value = await probe.complete(user)
        return LLMCompletion(text: value, generatedTokens: value.count, duration: 0)
    }
}

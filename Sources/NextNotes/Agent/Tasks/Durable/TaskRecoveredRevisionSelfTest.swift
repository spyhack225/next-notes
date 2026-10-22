import Foundation

#if !TASK_DURABILITY_STANDALONE
/// Characterizes the existing explicit restart hold. It does not admit a new attempt.
@MainActor
enum TaskRecoveredRevisionSelfTest {
    private enum Invalid: Error { case prior, root, context, worker, read, revision, drain }
    private static func reached(_ body: @MainActor () async -> Bool) async -> Bool {
        let end = ContinuousClock.now.advanced(by: .seconds(8))
        while ContinuousClock.now < end { if await body() { return true }; await Task.yield() }
        return await body()
    }
    static func run(legacy: @MainActor () async -> String) async -> String {
        let host = RealtimeAgent.shared, gate = PermissionGate.shared
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-task-recovery",
              AgentSession.shared.fileURL == nil, !AgentCaptureController.shared.isSessionActive,
              !host.isThinking, gate.pending == nil, gate.queuedCount == 0,
              host.typedTaskBridgeForTesting == nil, host.taskManagerForTesting == nil,
              VoiceConversationCoordinator.shared.taskBridgeOverrideForTesting == nil,
              AgentTaskManager.sharedIfLoaded == nil,
              IslandState.sharedIfLoaded == nil else {
            return "TASK_RECOVERY_FAILED: INPUT_INVALID recovered revision prior owner"
        }
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let root = temp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard root.standardizedFileURL.path == root.resolvingSymlinksInPath().standardizedFileURL.path,
              !FileManager.default.fileExists(atPath: root.path) else {
            return "TASK_RECOVERY_FAILED: INPUT_INVALID recovered revision root"
        }
        let ownerBefore = SelfTestStoreGuard.take(), grantsBefore = PermissionGrantStore.shared.grants
        let oldFake = AgentToolExecutor.fakeForTesting, oldFire = AgentToolExecutor.fireOverrideForTesting
        let oldPolicy = AgentToolExecutor.policyOverrideForTesting
        let oldInputs = AgentCapabilityManifestBuilder.inputsOverrideForTesting
        let oldWhole = PlannerBackends.wholeTurnOverrideForTesting, oldNeedle = ToolLoopLiveEval.needleFirstForTesting
        var manager: AgentTaskManager?, bridge: TaskBridge?, sql: TaskStore?, freshSQL: TaskStore?
        var operation: Task<AgentTurn, Never>?, probe: RecoveredRevisionProbe?, workID: UUID?
        var created = false, dictionary = false, capability = false, activity = false, review = false, island = false
        var joined = false, teardown = true, meetingRoot: URL?
        var checks = 0, failures: [String] = []
        func check(_ value: Bool, _ label: String) { checks += 1; if !value { failures.append(label) } }
        defer {
            AgentToolExecutor.fakeForTesting = oldFake; AgentToolExecutor.fireOverrideForTesting = oldFire
            AgentToolExecutor.policyOverrideForTesting = oldPolicy; AgentCapabilityManifestBuilder.inputsOverrideForTesting = oldInputs
            PlannerBackends.wholeTurnOverrideForTesting = oldWhole; ToolLoopLiveEval.needleFirstForTesting = oldNeedle
            if review { teardown = ToolCallContextBuilder.setMeetingContextForTesting(nil, root: root) && teardown }
            if activity { NextMemory.finishActivityContextForTesting(root: root) }
            if island { teardown = IslandState.finishSharedContextForTesting(root: root) && teardown }
            if capability { VoiceCapabilitySnapshot.finishContextForTesting(root: root) }
            if dictionary { DictionaryStore.finishRootForTesting(root) }
            freshSQL?.close(); sql?.close()
            if created && joined && teardown {
                try? FileManager.default.removeItem(at: root)
                if let meetingRoot { try? FileManager.default.removeItem(at: meetingRoot) }
            }
            _ = bridge // Keep the same admitted constructor authority through teardown.
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false); created = true
            let database = TaskStore(root: root); sql = database
            let export = root.appendingPathComponent("agent-tasks.json"), receiptFile = root.appendingPathComponent("receipts.json")
            let store = AgentTaskStore(fileURL: export, mirror: database)
            guard store.allowsHarnessPersistence, store.save([]).primaryCommitted else { throw Invalid.root }
            let receipts = ActionReceiptStore(fileURL: receiptFile)
            let originalManager = AgentTaskManager(store: store, receiptStore: receipts); manager = originalManager
            let admittedBridge = TaskBridge(manager: originalManager); bridge = admittedBridge
            guard DictionaryStore.installRootForTesting(root, bridge: admittedBridge) else { throw Invalid.context }
            dictionary = true; _ = DictionaryStore.shared.entries
            guard DictionaryStore.capturedRootMatchesForTesting(root) == true,
                  VoiceCapabilitySnapshot.installContextForTesting(root: root, bridge: admittedBridge,
                    inputs: RealtimeAgentToolLoopSelfTest.allEnabledFixture()) else { throw Invalid.context }
            capability = true
            guard NextMemory.installActivityContextForTesting(root: root, bridge: admittedBridge) else { throw Invalid.context }
            activity = true
            let meetings = try MeetingStore.isolated(at: temp.appendingPathComponent("NextNotesMeetingResumeTest-" + root.lastPathComponent, isDirectory: true))
            meetingRoot = meetings.directory(for: UUID()).deletingLastPathComponent()
            guard IslandState.installSharedContextForTesting(root: root, bridge: admittedBridge, store: meetings) else { throw Invalid.context }
            island = true
            guard ToolCallContextBuilder.setMeetingContextForTesting({ meeting, task in
                guard meeting == nil, task == nil || originalManager.task(id: task!)?.source == "text",
                      VoiceCapabilitySnapshot.contextIsAdmittedForTesting(root: root, bridge: admittedBridge) else { return nil }
                return ToolCallContext()
            }, root: root) else { throw Invalid.context }
            review = true
            AgentToolExecutor.fakeForTesting = nil; AgentToolExecutor.fireOverrideForTesting = nil
            AgentToolExecutor.policyOverrideForTesting = PermissionPolicy(autoObserve: true, autoRead: true,
                autoSearchFiles: true, autoComputerControl: false, grants: [])
            AgentCapabilityManifestBuilder.inputsOverrideForTesting = nil
            PlannerBackends.wholeTurnOverrideForTesting = nil; ToolLoopLiveEval.needleFirstForTesting = false
            let target = root.appendingPathComponent("authored-revision-document.txt")
            let sentinel = "Authored recovered-revision read result."
            try Data(sentinel.utf8).write(to: target)
            let original = "Read the authored document and summarize its important details."
            let corrections = ["Keep the important dates in the summary.", "Use two short paragraphs.", "Put the key takeaway first."]
            let work = VoiceConversationWork(original, userWords: original); workID = work.id
            let state = RecoveredRevisionProbe(original: original, path: target.path, sentinel: sentinel); probe = state
            let worker = RealtimeAgent(typedWorker: work)
            worker.localModelProviderForTesting = RecoveredRevisionProvider(probe: state)
            worker.coldForTesting = false; worker.rememberExplicit = { _ in }
            let started = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
            var clock = started
            originalManager.progressDateForTesting = { clock }
            let sessionID = AgentSession.shared.sessionID
            guard let admitted = originalManager.startTypedObjective(work: work, worker: worker,
                    bridge: admittedBridge, sessionID: sessionID) else { throw Invalid.worker }
            operation = admitted // Retain the exact installed Task before qualification.
            guard await reached({ await state.isHeld }), let context = await state.context,
                  let live = originalManager.typedWorkerSnapshot(id: work.id) else { throw Invalid.worker }
            let initial = try database.load().first { $0.id == work.id.uuidString }
            let readJournal = try database.journal(taskID: work.id.uuidString)
            guard let completed = receipts.receipts.first, completed.status == .completed else { throw Invalid.read }
            let readBytes = try Data(contentsOf: receiptFile)
            check(live.task == admitted && live.work === work && context.taskID == work.id.uuidString
                && context.attempt == 1 && context.receiptStore === receipts && context.isStillValid?() == true,
                "R3C01 actual retained task/read context mismatch")
            let modelCalls = await state.calls, targetBytes = try Data(contentsOf: target)
            check(modelCalls == 2 && readJournal.filter { $0.draft.kind == .toolCompleted }.count == 1
                && completed.toolID == "filesystem.read" && completed.taskID == work.id.uuidString
                && completed.taskAttempt == 1 && completed.taskLeaseOwner == String(ProcessInfo.processInfo.processIdentifier)
                && initial?.durability?.receiptIDs == [completed.actionID.uuidString]
                && targetBytes == Data(sentinel.utf8),
                "R3C02 actual read/receipt/evidence qualification failed")
            let speechGeneration = worker.speechGeneration
            for (index, correction) in corrections.enumerated() {
                clock = started.addingTimeInterval(Double(index + 1))
                guard originalManager.reviseTypedObjective(id: work.id, correction: correction,
                    bridge: admittedBridge, sessionID: sessionID) else { throw Invalid.revision }
                let row = try database.load().first { $0.id == work.id.uuidString }
                let facts = try database.journal(taskID: work.id.uuidString).filter { $0.draft.kind == .revisionRecorded }
                check(row?.revision == index + 1 && work.followUps == Array(corrections.prefix(index + 1))
                    && facts.map { $0.draft.detail } == corrections.prefix(index + 1).map(Optional.some)
                    && facts.allSatisfy { $0.draft.attempt == 1 && $0.draft.taskID == work.id.uuidString }
                    && row?.durability?.attemptStartedAt == initial?.durability?.attemptStartedAt
                    && worker.speechGeneration == speechGeneration,
                    "R3C03 ordered instruction admission changed attempt/speech identity")
            }
            let reader = TaskStore(root: root); freshSQL = reader
            let fresh = AgentTaskManager(store: AgentTaskStore(fileURL: export, mirror: reader),
                receiptStore: ActionReceiptStore(fileURL: receiptFile))
            let held = try reader.load(), journal = try reader.journal(taskID: work.id.uuidString)
            let witness = try Data(contentsOf: export)
            check(held.count == 1 && held.first?.status == .recovering && held.first?.revision == 3
                && held.first?.objective == original && held.first?.userWords == corrections.last
                && held.first?.durability?.attempt == 1 && fresh.typedWorkerSnapshot(id: work.id) == nil
                && fresh.backendStartsForTesting == 0,
                "R3C04 fresh reader did not retain revision3 without dispatch")
            let heldReceiptBytes = try Data(contentsOf: receiptFile)
            check(journal.filter { $0.draft.kind == .revisionRecorded }.map { $0.draft.detail } == corrections.map(Optional.some)
                && heldReceiptBytes == readBytes && context.isStillValid?() == false,
                "R3C05 fresh hold lost instructions/completed read or retained old authority")
            originalManager.cancel(work.id.uuidString)
            await state.releaseAll(); _ = await admitted.value; joined = true
            let remainingCalls = await state.activeCalls
            check(remainingCalls == 0 && originalManager.typedWorkerSnapshot(id: work.id) == nil
                && fresh.typedWorkerSnapshot(id: work.id) == nil && fresh.backendStartsForTesting == 0,
                "R3C06 actual old Task did not join/no-dispatch hold changed")
            let finalRows = try reader.load(), finalJournal = try reader.journal(taskID: work.id.uuidString)
            let finalWitness = try Data(contentsOf: export), finalReceipts = try Data(contentsOf: receiptFile)
            check(finalRows == held && finalJournal == journal
                && finalWitness == witness && finalReceipts == readBytes,
                "R3C07 late old cancel/return changed held history or completed output")
            check(gate.pending == nil && gate.queuedCount == 0 && PermissionGrantStore.shared.grants == grantsBefore
                && SelfTestStoreGuard.take() == ownerBefore, "R3C08 grant/owner store changed")
            SelfTest.diagnostic("TASK_RECOVERY_REVISION3_CHARACTERIZATION: checks=\(checks) problems=\(failures.count) revision=3 attempt=1 held=true oldTaskJoined=\(joined) modelCalls=\(await state.calls) readReceipts=1 automaticDispatch=\(fresh.backendStartsForTesting)")
            guard failures.isEmpty else { throw Invalid.revision }
            SelfTest.diagnostic("TASK_RECOVERY_REVISION3_FEATURE_OPEN: explicitRecoveredAdmission=absent newAttemptWindow=unproved uncertainReceiptEligibility=unproved automaticReplay=false")
            // Preserve all existing56 controls and their actual caller in the same admitted root scope.
            let marker = await legacy()
            teardown = ToolCallContextBuilder.setMeetingContextForTesting(nil, root: root); review = !teardown
            if island { teardown = IslandState.finishSharedContextForTesting(root: root) && teardown; island = !teardown }
            guard teardown else { return "TASK_RECOVERY_FAILED: INPUT_INVALID recovered revision teardown" }
            return marker
        } catch {
            if let manager, let workID { manager.cancel(workID.uuidString) }
            await probe?.releaseAll()
            if let operation { _ = await operation.value }
            let remainingCalls = await probe?.activeCalls
            joined = operation == nil || remainingCalls == 0
            if review { teardown = ToolCallContextBuilder.setMeetingContextForTesting(nil, root: root); review = !teardown }
            SelfTest.diagnostic("TASK_RECOVERY_REVISION3_INPUT_FAILURE: error=\(String(describing: error)) checks=\(checks) problems=\(failures.count) joined=\(joined)")
            for failure in failures { SelfTest.diagnostic("TASK_RECOVERY_REVISION3_WRONG: \(failure)") }
            return "TASK_RECOVERY_FAILED: INPUT_INVALID recovered revision characterization"
        }
    }
}
private actor RecoveredRevisionProbe {
    enum Invalid: Error { case currentRequest, priorResult, context }
    let original: String, path: String, sentinel: String
    var calls = 0, activeCalls = 0, isHeld = false, sealed = false
    var context: TaskJournalContext?
    private var held: CheckedContinuation<Void, Never>?
    init(original: String, path: String, sentinel: String) { self.original = original; self.path = path; self.sentinel = sentinel }
    func complete(_ user: String) async throws -> String {
        calls += 1; activeCalls += 1; defer { activeCalls -= 1 }
        guard let start = user.range(of: "Current user request:\n", options: .backwards) else { throw Invalid.currentRequest }
        let tail = user[start.upperBound...], done = tail.range(of: "\n\nWhat you have already done:\n")
        let current = String(done.map { tail[..<$0.lowerBound] } ?? tail).trimmingCharacters(in: .whitespacesAndNewlines)
        guard current == original else { throw Invalid.currentRequest }
        guard let captured = TaskEventJournal.current, captured.attempt == 1 else { throw Invalid.context }
        context = captured
        if calls == 1 {
            let json = try JSONSerialization.data(withJSONObject: ["path": path], options: .sortedKeys)
            return "<tool_call>{\"name\":\"filesystem.read\",\"arguments\":" + String(decoding: json, as: UTF8.self) + ",\"rationale\":\"Read the authored document\"}</tool_call>"
        }
        guard calls == 2, done.map({ String(tail[$0.upperBound...]).contains(sentinel) }) == true else { throw Invalid.priorResult }
        isHeld = true
        if !sealed { await withCheckedContinuation { held = $0 } }
        return "The authored read is retained; no additional action was taken."
    }
    func releaseAll() { sealed = true; held?.resume(); held = nil }
}
private struct RecoveredRevisionProvider: LLMProvider {
    let id = LLMProviderID.appLLM
    let probe: RecoveredRevisionProbe
    var contextTokens: Int { 8192 }
    var unavailableReason: String? { get async { nil } }
    func countTokens(_ text: String) async throws -> Int { text.count / 4 }
    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        let text = try await probe.complete(user)
        return LLMCompletion(text: text, generatedTokens: text.count, duration: 0)
    }
}
#endif

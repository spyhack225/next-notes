import Foundation
import Darwin

#if !TASK_DURABILITY_STANDALONE
/// Separate explicit-action scenario; the installed held-restart characterization stays unchanged.
@MainActor
enum TaskRecoveredReadSelfTest {
    enum Invalid: Error { case prior, root, child, context, history, receipt, drain }
    nonisolated static let original = "Read the first authored document, then read the second authored document and summarize both."
    nonisolated static let corrections = ["Keep the important dates in the summary.", "Use two short paragraphs.", "Put the key takeaway first."]
    nonisolated static let firstResult = "First authored recovered read: keep October 4."
    nonisolated static let secondResult = "Second authored recovered read: keep October 5."
    static func reached(_ body: @MainActor () async -> Bool) async -> Bool {
        let end = ContinuousClock.now.advanced(by: .seconds(8))
        while ContinuousClock.now < end { if await body() { return true }; await Task.yield() }
        return await body()
    }
    static func priorIsConfined() -> Bool {
        let host = RealtimeAgent.shared
        return SelfTest.isRunning && SelfTest.requested == "--selftest-task-recovery"
            && AgentSession.shared.fileURL == nil && !AgentCaptureController.shared.isSessionActive
            && !host.isThinking && host.typedTaskBridgeForTesting == nil && host.taskManagerForTesting == nil
            && VoiceConversationCoordinator.shared.taskBridgeOverrideForTesting == nil
            && AgentTaskManager.sharedIfLoaded == nil && IslandState.sharedIfLoaded == nil
            && PermissionGate.shared.pending == nil && PermissionGate.shared.queuedCount == 0
    }
    /// Root is created by the parent; the child never discovers an owner path.
    static func validRoot(_ root: URL) -> Bool {
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        return root.isFileURL && UUID(uuidString: root.lastPathComponent) != nil
            && root.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path == temp.path
            && root.standardizedFileURL.path == root.resolvingSymlinksInPath().standardizedFileURL.path
    }
    static func runChild(root: URL) async -> Never {
        guard priorIsConfined(), validRoot(root) else { Darwin._exit(74) }
        do {
            let scope = try Scope(root: root, initial: true)
            guard scope.install() else { throw Invalid.context }
            let first = root.appendingPathComponent("first.txt")
            let second = root.appendingPathComponent("second.txt")
            try Data(firstResult.utf8).write(to: first)
            try Data(secondResult.utf8).write(to: second)
            let work = VoiceConversationWork(original, userWords: original)
            let probe = RecoveredReadPlanProbe(firstPath: first.path, secondPath: second.path, child: true)
            let agent = RealtimeAgent(typedWorker: work)
            agent.localModelProviderForTesting = RecoveredReadPlanProvider(probe: probe)
            agent.coldForTesting = false; agent.rememberExplicit = { _ in }
            guard let operation = scope.manager.startTypedObjective(work: work, worker: agent,
                    bridge: scope.bridge, sessionID: AgentSession.shared.sessionID),
                  await reached({ await probe.held }), !operation.isCancelled,
                  await probe.calls == 2,
                  scope.receipts.receipts.count == 1, scope.receipts.receipts.first?.status == .completed else { throw Invalid.child }
            for correction in corrections {
                guard scope.manager.reviseTypedObjective(id: work.id, correction: correction,
                        bridge: scope.bridge, sessionID: AgentSession.shared.sessionID) else { throw Invalid.history }
            }
            guard scope.manager.task(id: work.id.uuidString)?.revision == 3,
                  scope.manager.task(id: work.id.uuidString)?.durability?.attempt == 1,
                  try scope.sql.journal(taskID: work.id.uuidString).filter({ $0.draft.kind == .revisionRecorded }).map(\.draft.detail) == corrections.map(Optional.some) else { throw Invalid.history }
            // Ephemeral protocol marker only; the existing row carries the actual PID.
            FileHandle.standardOutput.write(Data("RECOVERED_READ_CHILD_READY\n".utf8))
            guard try FileHandle.standardInput.read(upToCount: 1) == Data("x".utf8) else { throw Invalid.child }
            // The real prior process exits with the planner Task still held. A joined Bool is never eligibility.
            Darwin._exit(73)
        } catch {
            FileHandle.standardOutput.write(Data("RECOVERED_READ_CHILD_INVALID\n".utf8))
            Darwin._exit(74)
        }
    }
    static func run() async -> String {
        guard priorIsConfined() else { return "TASK_RECOVERED_READ_FAILED: INPUT_INVALID prior owner" }
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let root = temp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard validRoot(root), !FileManager.default.fileExists(atPath: root.path),
              let executable = Bundle.main.executableURL else { return "TASK_RECOVERED_READ_FAILED: INPUT_INVALID root" }
        let before = SelfTestStoreGuard.take()
        let child = Process(), input = Pipe()
        var log: FileHandle?, scope: Scope?, operation: Task<AgentTurn, Never>?, probe: RecoveredReadPlanProbe?
        var created = false, childStarted = false, processReturned = false, joined = false, retired = false
        var checks = 0, failures: [String] = []
        func check(_ value: Bool, _ label: String) { checks += 1; if !value { failures.append(label) } }
        defer {
            try? log?.close(); try? input.fileHandleForWriting.close()
            if let scope, !retired { retired = scope.finish() }
            if created && processReturned && joined && retired { try? FileManager.default.removeItem(at: root) }
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false); created = true
            let logURL = root.appendingPathComponent("owned-child.log")
            guard FileManager.default.createFile(atPath: logURL.path, contents: nil) else { throw Invalid.child }
            let output = try FileHandle(forWritingTo: logURL); log = output
            child.executableURL = executable
            child.arguments = ["--selftest-task-recovery", "--recovered-read-child", root.path]
            child.standardInput = input; child.standardOutput = output; child.standardError = output
            try child.run(); childStarted = true
            guard await reached({
                child.isRunning && (try? String(contentsOf: logURL, encoding: .utf8).contains("RECOVERED_READ_CHILD_READY\n")) == true
            }) else { throw Invalid.child }
            let current = try Scope(root: root, initial: false); scope = current
            guard current.install(), let held = current.manager.tasks.first,
                  held.status == .recovering, held.revision == 3, held.durability?.attempt == 1,
                  held.durability?.leaseOwner == String(child.processIdentifier),
                  let id = UUID(uuidString: held.id), let oldStart = held.durability?.attemptStartedAt else { throw Invalid.history }
            let oldReceipts = current.receipts.receipts, oldJournal = try current.sql.journal(taskID: held.id)
            let oldBytes = try Data(contentsOf: root.appendingPathComponent("receipts.json"))
            let oldExport = try Data(contentsOf: root.appendingPathComponent("agent-tasks.json"))
            let staleContext = current.manager.journalContext(taskID: held.id)
            check(TaskRecoveryPlanner.explicitReadInstructions(task: held, journal: oldJournal, receipts: oldReceipts) == corrections,
                "RR16 complete actual producer history retains exact ordered instruction eligibility")
            check(TaskRecoveryPlanner.explicitReadInstructions(task: held, journal: oldJournal, receipts: []) == nil,
                "RR17 missing receipts supply no recovery certainty")
            var uncertain = oldReceipts
            if !uncertain.isEmpty { uncertain[0].status = .fired; uncertain[0].completedAt = nil }
            check(TaskRecoveryPlanner.explicitReadInstructions(task: held, journal: oldJournal, receipts: uncertain) == nil,
                "RR18 uncertain fired history stays held")
            var consequential = oldReceipts
            if !consequential.isEmpty { consequential[0].intent.risk = .modify }
            check(TaskRecoveryPlanner.explicitReadInstructions(task: held, journal: oldJournal, receipts: consequential) == nil,
                "RR19 consequential history stays held even with a completed read label")
            let malformed = oldJournal.map { event in
                TaskJournalEvent(seq: event.draft.kind == .workerStarted ? oldJournal.last!.seq + 1 : event.seq, draft: event.draft)
            }.sorted { $0.seq < $1.seq }
            check(TaskRecoveryPlanner.explicitReadInstructions(task: held, journal: malformed, receipts: oldReceipts) == nil,
                "RR20 malformed actual started/ended order supplies no eligibility")
            var conflictingIntent = oldReceipts
            if !conflictingIntent.isEmpty { conflictingIntent[0].intent.id = UUID() }
            check(TaskRecoveryPlanner.explicitReadInstructions(task: held, journal: oldJournal, receipts: conflictingIntent) == nil,
                "RR22 conflicting frozen intent identity stays held")
            var foreignAuthority = oldReceipts
            if !foreignAuthority.isEmpty { foreignAuthority[0].authority = .systemDerived }
            check(TaskRecoveryPlanner.explicitReadInstructions(task: held, journal: oldJournal, receipts: foreignAuthority) == nil,
                "RR23 non-user receipt authority stays held")
            var foreignSource = oldReceipts
            if !foreignSource.isEmpty { foreignSource[0].intent.source = .meeting }
            check(TaskRecoveryPlanner.explicitReadInstructions(task: held, journal: oldJournal, receipts: foreignSource) == nil,
                "RR24 non-native intent provenance stays held")
            var foreignRouting = oldReceipts
            if !foreignRouting.isEmpty { foreignRouting[0].preparedAction?.routing.taskID = UUID().uuidString }
            check(TaskRecoveryPlanner.explicitReadInstructions(task: held, journal: oldJournal, receipts: foreignRouting) == nil,
                "RR25 conflicting prepared task routing stays held")
            let host = RealtimeAgent.shared
            let state = RecoveredReadPlanProbe(firstPath: root.appendingPathComponent("first.txt").path,
                secondPath: root.appendingPathComponent("second.txt").path, child: false,
                savedReadOutput: oldReceipts.first?.result); probe = state
            host.localModelProviderForTesting = RecoveredReadPlanProvider(probe: state)
            host.coldForTesting = false; host.rememberExplicit = { _ in }
            check(current.bridge.continueRecoveredRead(id: id, displayedRevision: 2, agent: host) == nil,
                "RR01 stale displayed revision stays held")
            check(current.bridge.continueRecoveredRead(id: id, displayedRevision: 3, agent: host) == nil
                && current.manager.typedWorkerSnapshot(id: id) == nil && child.isRunning,
                "RR02 actual alive prior process stays held")
            check(try current.sql.load().first?.status == .recovering
                && current.sql.journal(taskID: held.id) == oldJournal
                && Data(contentsOf: root.appendingPathComponent("receipts.json")) == oldBytes,
                "RR03 alive refusal changes no canonical history or completed output")
            try input.fileHandleForWriting.write(contentsOf: Data("x".utf8))
            guard await reached({ !child.isRunning }) else { throw Invalid.child }
            child.waitUntilExit(); processReturned = true
            guard child.terminationStatus == 73, Darwin.kill(child.processIdentifier, 0) == -1, errno == ESRCH else { throw Invalid.child }
            check(current.manager.task(id: held.id)?.status == .recovering && current.manager.typedWorkerSnapshot(id: id) == nil,
                "RR04 actual prior exit alone starts no worker")
            // Genuine SQL refusal before SAME explicit retry. No model call or backing may precede admission.
            let previous = current.store.migrationBoundaryForTesting
            var refuse = true
            current.store.migrationBoundaryForTesting = { name in
                try previous?(name)
                if name == "beforePrimaryCommit", refuse { throw Invalid.history }
            }
            let rejected = current.bridge.continueRecoveredRead(id: id, displayedRevision: 3, agent: host)
            check(rejected == nil && current.manager.typedWorkerSnapshot(id: id) == nil
                && current.manager.task(id: held.id)?.status == .recovering,
                "RR05 refused primary starts zero retained operations")
            let rejectedCalls = await state.calls
            check(try rejectedCalls == 0 && current.sql.journal(taskID: held.id) == oldJournal
                && Data(contentsOf: root.appendingPathComponent("agent-tasks.json")) == oldExport,
                "RR06 refused primary changes no journal/export and makes no model call")
            refuse = false; current.store.migrationBoundaryForTesting = previous
            operation = current.bridge.continueRecoveredRead(id: id, displayedRevision: 3, agent: host)
            check(operation != nil, "RR07 explicit current click admits recovered read")
            if let actual = operation {
                // SAME operation is retained immediately before any post-admission guard.
                guard let live = current.manager.typedWorkerSnapshot(id: id), live.task == actual else { throw Invalid.context }
                let admitted = try current.sql.load().first { $0.id == held.id }
                // Scalar-only observation before the unchanged RR08 admission predicate.
                let cachedStart = current.manager.task(id: held.id)?.durability?.attemptStartedAt
                SelfTest.diagnostic("TASK_RECOVERED_ADMISSION_TRACE: revision=\(admitted?.revision ?? -1) attempt=\(admitted?.durability?.attempt ?? -1) ownerMatches=\(admitted?.durability?.leaseOwner == String(ProcessInfo.processInfo.processIdentifier)) sqlStartPresent=\(admitted?.durability?.attemptStartedAt != nil) oldStartPresent=true sqlStartDifferent=\(admitted?.durability?.attemptStartedAt != oldStart) cacheStartPresent=\(cachedStart != nil) cacheStartDifferent=\(cachedStart != oldStart) cacheSQLStartSame=\(cachedStart == admitted?.durability?.attemptStartedAt) originalExact=\(live.work.original == original) instructionsExact=\(live.work.followUps == corrections) instructionCount=\(live.work.followUps.count)")
                check(admitted?.durability?.attempt == 2 && admitted?.durability?.attemptStartedAt != oldStart
                    && admitted?.durability?.leaseOwner == String(ProcessInfo.processInfo.processIdentifier)
                    && admitted?.revision == 3 && live.work.followUps == corrections && live.work.original == original,
                    "RR08 same ID revision3 has exact new positive attempt and ordered instructions")
                check(current.bridge.continueRecoveredRead(id: id, displayedRevision: 3, agent: host) == nil,
                    "RR09 duplicate explicit click cannot replace SAME map Task")
                _ = await actual.value; joined = true
                let finished = try current.sql.load().first { $0.id == held.id }
                let all = try current.sql.journal(taskID: held.id)
                let nextEvents = all.filter { $0.draft.attempt == 2 }
                check(nextEvents.prefix(2).map(\.draft.kind) == [.workerRecovered, .workerStarted]
                    && finished?.status == .completed && finished?.revision == 3,
                    "RR10 recovered/started facts precede actual completed successor")
                let captured = await state.context
                let instructionsExact = await state.instructionsExact
                let savedResultExact = await state.savedResultExact
                let actualCalls = await state.calls
                check(instructionsExact && savedResultExact && captured?.attempt == 2 && actualCalls == 2,
                    "RR11 actual planner receives all three instructions and exact saved completed read")
                let receipts = current.receipts.receipts
                check(receipts.count == 2 && oldReceipts.allSatisfy({ receipts.contains($0) })
                    && receipts.filter({ $0.taskAttempt == 2 && $0.toolID == "filesystem.read" && $0.status == .completed }).count == 1
                    && receipts.first(where: { $0.taskAttempt == 2 })?.intent.arguments["path"] == root.appendingPathComponent("second.txt").path,
                    "RR12 saved first read is not refired and unfinished second path is actually read")
                check(try Data(contentsOf: root.appendingPathComponent("first.txt")) == Data(firstResult.utf8)
                    && Data(contentsOf: root.appendingPathComponent("second.txt")) == Data(secondResult.utf8),
                    "RR13 actual read cap preserves both authored documents")
            } else {
                joined = true
                for label in ["RR08 same ID revision3 has exact new positive attempt and ordered instructions",
                    "RR09 duplicate explicit click cannot replace SAME map Task", "RR10 recovered/started facts precede actual completed successor",
                    "RR11 actual planner receives all three instructions and exact saved completed read",
                    "RR12 saved first read is not refired and unfinished second path is actually read", "RR13 actual read cap preserves both authored documents"] { check(false, label) }
            }
            let attemptedWrite = await state.writeOffered
            let afterSecond = try Data(contentsOf: root.appendingPathComponent("second.txt"))
            check(operation == nil || (attemptedWrite && current.receipts.receipts.allSatisfy({ $0.toolID == "filesystem.read" })
                && PermissionGate.shared.pending == nil && PermissionGate.shared.queuedCount == 0
                && afterSecond == Data(secondResult.utf8)),
                "RR26 actual recovered runner rejects out-of-schema write before card receipt or backing")
            let finalJournal = try current.sql.journal(taskID: held.id)
            let staleRejected = staleContext?.record(TaskJournalEventDraft(taskID: held.id, kind: .heartbeat, attempt: 1)) == false
            check(try staleRejected && staleContext?.isStillValid?() == false
                && current.sql.journal(taskID: held.id) == finalJournal,
                "RR21 retained previous reader context cannot stamp successor attempt history")
            check(PermissionGate.shared.pending == nil && PermissionGate.shared.queuedCount == 0,
                "RR14 read continuation creates no approval or consequential dispatch")
            check(SelfTestStoreGuard.diff(before, SelfTestStoreGuard.take()).isEmpty, "RR15 owner bytes unchanged")
            retired = current.finish()
            guard retired else { throw Invalid.drain }
            print("TASK_RECOVERED_READ_COUNTS checks=\(checks) problems=\(failures.count) priorExited=\(processReturned) joined=\(joined)")
            for failure in failures { SelfTest.diagnostic("TASK_RECOVERED_READ_WRONG: \(failure)") }
            return failures.isEmpty ? "TASK_RECOVERED_READ_OK" : "TASK_RECOVERED_READ_FAILED: \(failures.count) assertions"
        } catch {
            operation?.cancel()
            if let probe { await probe.release() }
            if let operation { _ = await operation.value }
            joined = true
            if childStarted {
                if child.isRunning { child.terminate() }
                processReturned = await reached({ !child.isRunning })
                if processReturned { child.waitUntilExit() }
            }
            if let scope { retired = scope.finish() }
            return "TASK_RECOVERED_READ_FAILED: INPUT_INVALID \(error)"
        }
    }

    @MainActor final class Scope {
        let root: URL, sql: TaskStore, store: AgentTaskStore, receipts: ActionReceiptStore
        let manager: AgentTaskManager, bridge: TaskBridge
        let oldFake = AgentToolExecutor.fakeForTesting, oldFire = AgentToolExecutor.fireOverrideForTesting
        let oldPolicy = AgentToolExecutor.policyOverrideForTesting
        let oldWhole = PlannerBackends.wholeTurnOverrideForTesting, oldNeedle = ToolLoopLiveEval.needleFirstForTesting
        let host = RealtimeAgent.shared
        let oldProvider: (any LLMProvider)?, oldCold: Bool?
        let oldRemember: @MainActor (String) -> Void
        var dictionary = false, capability = false, activity = false, island = false, review = false
        var meetingRoot: URL?
        init(root: URL, initial: Bool) throws {
            let sql = TaskStore(root: root)
            let store = AgentTaskStore(fileURL: root.appendingPathComponent("agent-tasks.json"), mirror: sql)
            guard store.allowsHarnessPersistence else { throw Invalid.root }
            if initial { guard store.save([]).primaryCommitted else { throw Invalid.root } }
            let receipts = ActionReceiptStore(fileURL: root.appendingPathComponent("receipts.json"))
            let manager = AgentTaskManager(store: store, receiptStore: receipts)
            self.root = root; self.sql = sql; self.store = store; self.receipts = receipts
            self.manager = manager; self.bridge = TaskBridge(manager: manager)
            let host = RealtimeAgent.shared
            oldProvider = host.localModelProviderForTesting; oldCold = host.coldForTesting; oldRemember = host.rememberExplicit
        }
        func install() -> Bool {
            guard DictionaryStore.installRootForTesting(root, bridge: bridge) else { return false }
            dictionary = true; _ = DictionaryStore.shared.entries
            guard DictionaryStore.capturedRootMatchesForTesting(root) == true,
                  VoiceCapabilitySnapshot.installContextForTesting(root: root, bridge: bridge,
                    inputs: RealtimeAgentToolLoopSelfTest.allEnabledFixture()) else { return false }
            capability = true
            guard NextMemory.installActivityContextForTesting(root: root, bridge: bridge) else { return false }; activity = true
            guard let meetings = try? MeetingStore.isolated(at: root.deletingLastPathComponent().appendingPathComponent("NextNotesMeetingResumeTest-" + root.lastPathComponent, isDirectory: true)) else { return false }
            meetingRoot = meetings.directory(for: UUID()).deletingLastPathComponent()
            guard IslandState.installSharedContextForTesting(root: root, bridge: bridge, store: meetings) else { return false }; island = true
            guard ToolCallContextBuilder.setMeetingContextForTesting({ [weak self] meeting, task in
                guard let self, meeting == nil, task == nil || self.manager.task(id: task!) != nil,
                      VoiceCapabilitySnapshot.contextIsAdmittedForTesting(root: self.root, bridge: self.bridge) else { return nil }
                return ToolCallContext()
            }, root: root) else { return false }; review = true
            AgentToolExecutor.fakeForTesting = nil; AgentToolExecutor.fireOverrideForTesting = nil
            AgentToolExecutor.policyOverrideForTesting = PermissionPolicy(autoObserve: true, autoRead: true, autoSearchFiles: true, autoComputerControl: false, grants: [])
            PlannerBackends.wholeTurnOverrideForTesting = nil; ToolLoopLiveEval.needleFirstForTesting = false
            return true
        }
        func finish() -> Bool {
            host.localModelProviderForTesting = oldProvider; host.coldForTesting = oldCold; host.rememberExplicit = oldRemember
            AgentToolExecutor.fakeForTesting = oldFake; AgentToolExecutor.fireOverrideForTesting = oldFire
            AgentToolExecutor.policyOverrideForTesting = oldPolicy
            PlannerBackends.wholeTurnOverrideForTesting = oldWhole; ToolLoopLiveEval.needleFirstForTesting = oldNeedle
            if review { guard ToolCallContextBuilder.setMeetingContextForTesting(nil, root: root) else { return false }; review = false }
            if island { guard IslandState.finishSharedContextForTesting(root: root) else { return false }; island = false }
            if activity { NextMemory.finishActivityContextForTesting(root: root); activity = false }
            if capability { VoiceCapabilitySnapshot.finishContextForTesting(root: root); capability = false }
            if dictionary { DictionaryStore.finishRootForTesting(root); dictionary = false }
            sql.close()
            if let meetingRoot { try? FileManager.default.removeItem(at: meetingRoot) }
            return true
        }
    }
}
private actor RecoveredReadPlanProbe {
    enum Invalid: Error { case context, request, result, calls }
    let firstPath: String, secondPath: String, child: Bool
    let savedReadOutput: String?
    var calls = 0, held = false, instructionsExact = false, savedResultExact = false, writeOffered = false
    var context: TaskJournalContext?
    private var waiter: CheckedContinuation<Void, Never>?
    init(firstPath: String, secondPath: String, child: Bool, savedReadOutput: String? = nil) {
        self.firstPath = firstPath; self.secondPath = secondPath; self.child = child
        self.savedReadOutput = savedReadOutput
    }
    func complete(_ user: String) async throws -> String {
        calls += 1
        guard let actual = TaskEventJournal.current, actual.attempt == (child ? 1 : 2) else { throw Invalid.context }
        context = actual
        guard let marker = user.range(of: "Current user request:\n", options: .backwards) else { throw Invalid.request }
        let tail = user[marker.upperBound...]
        let done = tail.range(of: "\n\nWhat you have already done:\n")
        let request = String(done.map { tail[..<$0.lowerBound] } ?? tail)
        guard request.contains(TaskRecoveredReadSelfTest.original) else { throw Invalid.request }
        if !child {
            instructionsExact = TaskRecoveredReadSelfTest.corrections.enumerated().allSatisfy { request.contains("\($0.offset + 1). \($0.element)") }
            savedResultExact = savedReadOutput.map { saved in
                !saved.isEmpty && done.map { String(tail[$0.upperBound...]).contains(saved) } == true
            } == true
            guard instructionsExact, savedResultExact else { throw Invalid.result }
        }
        if calls == 1 {
            let arguments = try JSONSerialization.data(withJSONObject: ["path": child ? firstPath : secondPath], options: .sortedKeys)
            let read = "<tool_call>{\"name\":\"filesystem.read\",\"arguments\":" + String(decoding: arguments, as: UTF8.self) + ",\"rationale\":\"Read the authored unfinished document\"}</tool_call>"
            if child { return read }
            // Deliberately out-of-schema provider output exercises the actual runner's READ boundary.
            let writeArguments = try JSONSerialization.data(withJSONObject: ["path": secondPath, "content": "must never be written"], options: .sortedKeys)
            writeOffered = true
            let write = "<tool_call>{\"name\":\"filesystem.write\",\"arguments\":" + String(decoding: writeArguments, as: UTF8.self) + ",\"rationale\":\"Boundary negative: reject this write\"}</tool_call>"
            let priorArguments = try JSONSerialization.data(withJSONObject: ["path": firstPath], options: .sortedKeys)
            let priorRead = "<tool_call>{\"name\":\"filesystem.read\",\"arguments\":" + String(decoding: priorArguments, as: UTF8.self) + ",\"rationale\":\"Use the already completed saved read\"}</tool_call>"
            return write + "\n" + priorRead + "\n" + read
        }
        guard calls == 2 else { throw Invalid.calls }
        if child { held = true; await withCheckedContinuation { waiter = $0 } }
        else { guard done.map({ String(tail[$0.upperBound...]).contains(TaskRecoveredReadSelfTest.secondResult) }) == true else { throw Invalid.result } }
        return "The two authored documents are summarized with their dates, in two short paragraphs, with the key takeaway first."
    }
    func release() { waiter?.resume(); waiter = nil }
}
private struct RecoveredReadPlanProvider: LLMProvider {
    let id = LLMProviderID.appLLM
    let probe: RecoveredReadPlanProbe
    var contextTokens: Int { 8192 }
    var unavailableReason: String? { get async { nil } }
    func countTokens(_ text: String) async throws -> Int { text.count / 4 }
    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        let reply = try await probe.complete(user)
        return LLMCompletion(text: reply, generatedTokens: reply.count, duration: 0)
    }
}
#endif

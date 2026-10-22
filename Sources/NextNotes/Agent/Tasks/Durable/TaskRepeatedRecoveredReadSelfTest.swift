import Foundation
import Darwin

#if !TASK_DURABILITY_STANDALONE
/// Separate repeated explicit READ scenario. The original first26 fixture is unchanged.
@MainActor
enum TaskRepeatedRecoveredReadSelfTest {
    private enum Invalid: Error { case root, child, context, history, drain }
    nonisolated static let additional = "Also read the third authored document before finishing."
    nonisolated static let thirdResult = "Third authored recovered read: keep October 6."
    nonisolated static var instructions: [String] { TaskRecoveredReadSelfTest.corrections + [additional] }

    static func runSecondChild(root: URL, empty: Bool) async -> Never {
        guard TaskRecoveredReadSelfTest.priorIsConfined(), TaskRecoveredReadSelfTest.validRoot(root) else { Darwin._exit(74) }
        do {
            let scope = try TaskRecoveredReadSelfTest.Scope(root: root, initial: false)
            guard scope.install(), let held = scope.manager.tasks.first, held.status == .recovering,
                  held.revision == 3, held.durability?.attempt == 1,
                  let id = UUID(uuidString: held.id), let owner = held.durability?.leaseOwner,
                  let pid = Int32(owner), Darwin.kill(pid, 0) == -1, errno == ESRCH else { throw Invalid.history }
            let saved = scope.receipts.receipts
            let state = RepeatedReadPlanProbe(root: root, stage: 2, empty: empty, saved: saved)
            let host = RealtimeAgent.shared
            host.localModelProviderForTesting = RepeatedReadPlanProvider(probe: state)
            host.coldForTesting = false; host.rememberExplicit = { _ in }
            // Retain SAME operation before any post-admission or model guard.
            guard let operation = scope.bridge.continueRecoveredRead(id: id, displayedRevision: 3, agent: host) else { throw Invalid.context }
            guard scope.manager.typedWorkerSnapshot(id: id)?.task == operation,
                  await TaskRecoveredReadSelfTest.reached({ await state.held }), !operation.isCancelled else { throw Invalid.child }
            let calls = await state.calls
            guard calls == (empty ? 1 : 2),
                  scope.receipts.receipts.count == (empty ? 1 : 2),
                  scope.receipts.receipts.allSatisfy({ $0.status == .completed }),
                  scope.manager.reviseTypedObjective(id: id, correction: additional,
                    bridge: scope.bridge, sessionID: AgentSession.shared.sessionID),
                  scope.manager.task(id: held.id)?.revision == 4,
                  scope.manager.task(id: held.id)?.durability?.attempt == 2 else { throw Invalid.history }
            FileHandle.standardOutput.write(Data("REPEATED_READ_CHILD_READY\n".utf8))
            guard try FileHandle.standardInput.read(upToCount: 1) == Data("x".utf8) else { throw Invalid.child }
            // Real second process exit with SAME planner still suspended; no joined flag admits recovery.
            Darwin._exit(73)
        } catch {
            FileHandle.standardOutput.write(Data("REPEATED_READ_CHILD_INVALID\n".utf8))
            Darwin._exit(74)
        }
    }

    static func run(empty: Bool, sourceChanged: Bool) async -> String {
        guard TaskRecoveredReadSelfTest.priorIsConfined() else { return "TASK_REPEATED_READ_FAILED: INPUT_INVALID prior" }
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let root = temp.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard TaskRecoveredReadSelfTest.validRoot(root), !FileManager.default.fileExists(atPath: root.path),
              let executable = Bundle.main.executableURL else { return "TASK_REPEATED_READ_FAILED: INPUT_INVALID root" }
        let ownerBefore = SelfTestStoreGuard.take()
        let first = Process(), second = Process(), firstInput = Pipe(), secondInput = Pipe()
        var firstLog: FileHandle?, secondLog: FileHandle?
        var firstStarted = false, secondStarted = false, firstExited = false, secondExited = false
        var created = false, joined = false, retired = false
        var scope: TaskRecoveredReadSelfTest.Scope?, state: RepeatedReadPlanProbe?, operation: Task<AgentTurn, Never>?
        var checks = 0, failures: [String] = []
        func check(_ value: Bool, _ label: String) { checks += 1; if !value { failures.append(label) } }
        defer {
            try? firstLog?.close(); try? secondLog?.close()
            try? firstInput.fileHandleForWriting.close(); try? secondInput.fileHandleForWriting.close()
            if let scope, !retired { retired = scope.finish() }
            if created && firstExited && secondExited && joined && retired { try? FileManager.default.removeItem(at: root) }
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false); created = true
            let firstURL = root.appendingPathComponent("first-child.log")
            guard FileManager.default.createFile(atPath: firstURL.path, contents: nil) else { throw Invalid.root }
            let firstOutput = try FileHandle(forWritingTo: firstURL); firstLog = firstOutput
            first.executableURL = executable
            first.arguments = ["--selftest-task-recovery", "--recovered-read-child", root.path]
            first.standardInput = firstInput; first.standardOutput = firstOutput; first.standardError = firstOutput
            try first.run(); firstStarted = true
            guard await TaskRecoveredReadSelfTest.reached({ first.isRunning
                && (try? String(contentsOf: firstURL, encoding: .utf8).contains("RECOVERED_READ_CHILD_READY\n")) == true }) else { throw Invalid.child }
            try firstInput.fileHandleForWriting.write(contentsOf: Data("x".utf8))
            guard await TaskRecoveredReadSelfTest.reached({ !first.isRunning }) else { throw Invalid.child }
            first.waitUntilExit(); firstExited = true
            guard first.terminationStatus == 73, Darwin.kill(first.processIdentifier, 0) == -1, errno == ESRCH else { throw Invalid.child }
            try Data(thirdResult.utf8).write(to: root.appendingPathComponent("third.txt"))
            let secondURL = root.appendingPathComponent("second-child.log")
            guard FileManager.default.createFile(atPath: secondURL.path, contents: nil) else { throw Invalid.root }
            let secondOutput = try FileHandle(forWritingTo: secondURL); secondLog = secondOutput
            second.executableURL = executable
            second.arguments = ["--selftest-task-recovery", "--repeated-recovered-read-child", root.path]
                + (empty ? ["--repeated-read-empty-attempt"] : [])
            second.standardInput = secondInput; second.standardOutput = secondOutput; second.standardError = secondOutput
            try second.run(); secondStarted = true
            guard await TaskRecoveredReadSelfTest.reached({ second.isRunning
                && (try? String(contentsOf: secondURL, encoding: .utf8).contains("REPEATED_READ_CHILD_READY\n")) == true }) else { throw Invalid.child }
            let current = try TaskRecoveredReadSelfTest.Scope(root: root, initial: false); scope = current
            guard current.install(), let held = current.manager.tasks.first, held.status == .recovering,
                  held.revision == 4, held.durability?.attempt == 2,
                  held.durability?.leaseOwner == String(second.processIdentifier),
                  let id = UUID(uuidString: held.id) else { throw Invalid.history }
            let saved = current.receipts.receipts
            let journal = try current.sql.journal(taskID: held.id)
            let receiptBytes = try Data(contentsOf: root.appendingPathComponent("receipts.json"))
            let exportBytes = try Data(contentsOf: root.appendingPathComponent("agent-tasks.json"))
            let cacheBefore = current.manager.tasks
            let stale = current.manager.journalContext(taskID: held.id)
            check(firstExited && first.terminationStatus == 73 && saved.count == (empty ? 1 : 2)
                && saved.allSatisfy({ $0.status == .completed }), "RP01 actual first exit and saved completed native reads")
            check(journal.filter({ $0.draft.kind == .revisionRecorded }).map(\.draft.detail) == instructions.map(Optional.some)
                && journal.filter({ $0.draft.kind == .recoveryHeld }).map(\.draft.attempt) == [1, 2],
                "RP02 actual two attempt holds retain all four instruction facts")
            check(TaskRecoveryPlanner.explicitReadInstructions(task: held, journal: journal, receipts: saved) == instructions,
                "RF01 complete actual repeated history admits exact ordered instruction eligibility")
            check(TaskRecoveryPlanner.explicitReadInstructions(task: held, journal: journal, receipts: []) == nil,
                "RC01 missing saved history stays held")
            var uncertain = saved
            if !uncertain.isEmpty { uncertain[0].status = .fired; uncertain[0].completedAt = nil }
            check(TaskRecoveryPlanner.explicitReadInstructions(task: held, journal: journal, receipts: uncertain) == nil,
                "RC02 uncertain prior fired history stays held")
            var consequential = saved
            if !consequential.isEmpty { consequential[0].intent.risk = .modify }
            check(TaskRecoveryPlanner.explicitReadInstructions(task: held, journal: journal, receipts: consequential) == nil,
                "RC03 consequential prior receipt never widens READ eligibility")
            var orphan = saved
            if var added = saved.first { added.actionID = UUID(); orphan.append(added) }
            check(TaskRecoveryPlanner.explicitReadInstructions(task: held, journal: journal, receipts: orphan) == nil,
                "RC04 extra task receipt cannot be ignored")
            var missingPreparation = saved
            if !missingPreparation.isEmpty { missingPreparation[0].preparedAction = nil }
            check(TaskRecoveryPlanner.explicitReadInstructions(task: held, journal: journal, receipts: missingPreparation) == nil,
                "RC05 missing immutable preparation supplies no reconstruction")
            let missingBoundary = journal.filter { !($0.draft.kind == .workerRecovered && $0.draft.attempt == 2) }
            check(TaskRecoveryPlanner.explicitReadInstructions(task: held, journal: missingBoundary, receipts: saved) == nil,
                "RC06 missing recovered segment boundary stays held")
            let noncontiguous = journal.map { event in
                var draft = event.draft; if draft.attempt == 2 { draft = TaskJournalEventDraft(taskID: draft.taskID,
                    kind: draft.kind, at: draft.at, detail: draft.detail, attempt: 3) }
                return TaskJournalEvent(seq: event.seq, draft: draft)
            }
            check(TaskRecoveryPlanner.explicitReadInstructions(task: held, journal: noncontiguous, receipts: saved) == nil,
                "RC07 noncontiguous attempt history stays held")
            let outOfOrder = journal.map { event in
                TaskJournalEvent(seq: event.draft.kind == .workerStarted && event.draft.attempt == 2
                    ? journal.last!.seq + 1 : event.seq, draft: event.draft)
            }.sorted { $0.seq < $1.seq }
            check(TaskRecoveryPlanner.explicitReadInstructions(task: held, journal: outOfOrder, receipts: saved) == nil,
                "RC08 later workerStarted cannot follow tool facts or hold")
            let extraFact = journal + [TaskJournalEvent(seq: journal.last!.seq + 1,
                draft: TaskJournalEventDraft(taskID: held.id, kind: .permissionApproved, attempt: 2))]
            check(TaskRecoveryPlanner.explicitReadInstructions(task: held, journal: extraFact, receipts: saved) == nil,
                "RC09 permission or late fact never becomes complete native READ history")
            var conflicting = saved
            if !conflicting.isEmpty { conflicting[0].intent.id = UUID() }
            check(TaskRecoveryPlanner.explicitReadInstructions(task: held, journal: journal, receipts: conflicting) == nil,
                "RC10 conflicting immutable intent ID stays held")
            let repeatedHold = journal + [TaskJournalEvent(seq: journal.last!.seq + 1,
                draft: TaskJournalEventDraft(taskID: held.id, kind: .recoveryHeld, attempt: 2))]
            check(TaskRecoveryPlanner.explicitReadInstructions(task: held, journal: repeatedHold, receipts: saved) == nil,
                "RC19 repeated hold cannot become a complete segment")
            let foreignFact = journal + [TaskJournalEvent(seq: journal.last!.seq + 1,
                draft: TaskJournalEventDraft(taskID: UUID().uuidString, kind: .heartbeat, attempt: 2))]
            check(TaskRecoveryPlanner.explicitReadInstructions(task: held, journal: foreignFact, receipts: saved) == nil,
                "RC20 orphan task fact cannot be ignored")
            var foreignNative = saved
            if !foreignNative.isEmpty { foreignNative[0].intent.source = .meeting }
            check(TaskRecoveryPlanner.explicitReadInstructions(task: held, journal: journal, receipts: foreignNative) == nil,
                "RC21 foreign intent provenance remains held")
            if !empty {
                // Malformed pure snapshot only: move the actual second read pair into the first
                // segment with its real saved owner. Counts/order match, but that group mixes owners.
                let moved = journal.filter { $0.draft.attempt == 2 && [.toolStarted, .toolCompleted].contains($0.draft.kind) }
                guard moved.count == 2, saved.count == 2,
                      Set(saved.compactMap(\.taskLeaseOwner)).count == 2 else { throw Invalid.history }
                var bodies: [TaskJournalEventDraft] = []
                for event in journal {
                    if event.draft.attempt == 2 && [.toolStarted, .toolCompleted].contains(event.draft.kind) { continue }
                    if event.draft.attempt == 1 && event.draft.kind == .recoveryHeld {
                        for original in moved { var draft = original.draft; draft.attempt = 1; bodies.append(draft) }
                    }
                    bodies.append(event.draft)
                }
                let malformedOwners = bodies.enumerated().map { TaskJournalEvent(seq: Int64($0.offset + 1), draft: $0.element) }
                var mixedOwners = saved
                for index in mixedOwners.indices { if mixedOwners[index].taskAttempt == 2 { mixedOwners[index].taskAttempt = 1 } }
                check(TaskRecoveryPlanner.explicitReadInstructions(task: held, journal: malformedOwners, receipts: mixedOwners) == nil,
                    "RC22 complete-count native segment cannot mix saved process owners")
            }
            let host = RealtimeAgent.shared
            let resumed = RepeatedReadPlanProbe(root: root, stage: 3, empty: empty, saved: saved); state = resumed
            host.localModelProviderForTesting = RepeatedReadPlanProvider(probe: resumed)
            host.coldForTesting = false; host.rememberExplicit = { _ in }
            check(current.bridge.continueRecoveredRead(id: id, displayedRevision: 3, agent: host) == nil,
                "RC11 stale displayed revision cannot admit next attempt")
            check(current.bridge.continueRecoveredRead(id: id, displayedRevision: 4, agent: host) == nil && second.isRunning,
                "RC12 latest actual live child stays held")
            check(try current.manager.tasks == cacheBefore && current.sql.journal(taskID: held.id) == journal
                && Data(contentsOf: root.appendingPathComponent("receipts.json")) == receiptBytes,
                "RC13 alive refusal preserves cache journal and saved reads")
            try secondInput.fileHandleForWriting.write(contentsOf: Data("x".utf8))
            guard await TaskRecoveredReadSelfTest.reached({ !second.isRunning }) else { throw Invalid.child }
            second.waitUntilExit(); secondExited = true
            guard second.terminationStatus == 73, Darwin.kill(second.processIdentifier, 0) == -1, errno == ESRCH else { throw Invalid.child }
            check(current.manager.typedWorkerSnapshot(id: id) == nil && current.manager.task(id: held.id)?.status == .recovering,
                "RC14 actual latest exit alone dispatches nothing")
            if sourceChanged {
                // Same exact contents, genuinely new file identity: the existing captured source
                // must refuse rather than refreshing itself or treating a missing receipt as safe.
                let receiptURL = root.appendingPathComponent("receipts.json")
                try receiptBytes.write(to: receiptURL, options: .atomic)
                let latestIDs = held.durability!.receiptIDs.filter { value in
                    UUID(uuidString: value).flatMap(current.receipts.receipt(for:))?.taskAttempt == 2
                }
                let observed = current.receipts.currentSourceObservation(taskID: held.id, attempt: 2,
                    leaseOwner: held.durability!.leaseOwner!, receiptIDs: latestIDs)
                let denied = current.bridge.continueRecoveredRead(id: id, displayedRevision: 4, agent: host)
                let calls = await resumed.calls
                check(observed?.state == .changed && denied == nil && calls == 0
                    && current.manager.typedWorkerSnapshot(id: id) == nil, "RC23 changed receipt identity refuses explicit continuation before model or Task")
                check(try current.sql.journal(taskID: held.id) == journal && current.manager.tasks == cacheBefore
                    && Data(contentsOf: receiptURL) == receiptBytes, "RC24 changed-source refusal preserves current primary history and exact saved contents")
                check(SelfTestStoreGuard.diff(ownerBefore, SelfTestStoreGuard.take()).isEmpty, "RC18 owner bytes unchanged")
                joined = true; retired = current.finish(); guard retired else { throw Invalid.drain }
                print("TASK_REPEATED_READ_COUNTS checks=\(checks) problems=\(failures.count) emptyLatest=\(empty) sourceChanged=true priorExited=\(firstExited && secondExited) joined=\(joined)")
                for failure in failures { SelfTest.diagnostic("TASK_REPEATED_READ_WRONG: \(failure)") }
                return failures.isEmpty ? "TASK_REPEATED_READ_OK" : "TASK_REPEATED_READ_FAILED: \(failures.count) assertions"
            }
            let oldBoundary = current.store.migrationBoundaryForTesting
            var refused = true
            current.store.migrationBoundaryForTesting = { name in
                try oldBoundary?(name); if refused && name == "beforePrimaryCommit" { throw Invalid.history }
            }
            let denied = current.bridge.continueRecoveredRead(id: id, displayedRevision: 4, agent: host)
            let callsBefore = await resumed.calls
            check(denied == nil && callsBefore == 0 && current.manager.typedWorkerSnapshot(id: id) == nil,
                "RC15 refused primary starts zero model or map operations")
            check(try current.sql.journal(taskID: held.id) == journal
                && Data(contentsOf: root.appendingPathComponent("agent-tasks.json")) == exportBytes,
                "RC16 refused primary preserves prior exact journal and export")
            refused = false; current.store.migrationBoundaryForTesting = oldBoundary
            operation = current.bridge.continueRecoveredRead(id: id, displayedRevision: 4, agent: host)
            check(operation != nil, "RF02 explicit current click admits actual repeated READ")
            if let actual = operation {
                guard let live = current.manager.typedWorkerSnapshot(id: id), live.task == actual else { throw Invalid.context }
                let row = try current.sql.load().first { $0.id == held.id }
                // Scalar-only observation before the unchanged RF03 admission predicate.
                let cachedStart = current.manager.task(id: held.id)?.durability?.attemptStartedAt
                SelfTest.diagnostic("TASK_REPEATED_ADMISSION_TRACE: revision=\(row?.revision ?? -1) attempt=\(row?.durability?.attempt ?? -1) ownerMatches=\(row?.durability?.leaseOwner == String(ProcessInfo.processInfo.processIdentifier)) sqlStartPresent=\(row?.durability?.attemptStartedAt != nil) oldStartPresent=\(held.durability?.attemptStartedAt != nil) sqlStartDifferent=\(row?.durability?.attemptStartedAt != held.durability?.attemptStartedAt) cacheStartPresent=\(cachedStart != nil) cacheStartDifferent=\(cachedStart != held.durability?.attemptStartedAt) cacheSQLStartSame=\(cachedStart == row?.durability?.attemptStartedAt) originalExact=\(live.work.original == TaskRecoveredReadSelfTest.original) instructionsExact=\(live.work.followUps == instructions) instructionCount=\(live.work.followUps.count)")
                check(row?.revision == 4 && row?.durability?.attempt == 3
                    && row?.durability?.leaseOwner == String(ProcessInfo.processInfo.processIdentifier)
                    && row?.durability?.attemptStartedAt != held.durability?.attemptStartedAt
                    && live.work.original == TaskRecoveredReadSelfTest.original && live.work.followUps == instructions,
                    "RF03 SAME ID revision4 retains complete instructions with new positive attempt3")
                check(current.bridge.continueRecoveredRead(id: id, displayedRevision: 4, agent: host) == nil,
                    "RF04 duplicate current click cannot replace retained SAME Task")
                _ = await actual.value; joined = true
                let finished = try current.sql.load().first { $0.id == held.id }
                let all = try current.sql.journal(taskID: held.id)
                check(finished?.status == .completed && finished?.revision == 4
                    && all.filter({ $0.draft.attempt == 3 }).prefix(2).map(\.draft.kind) == [.workerRecovered, .workerStarted],
                    "RF05 recovered/started commit precedes actual successor completion")
                let observedCalls = await resumed.calls
                let exactInstructions = await resumed.instructionsExact
                let exactSaved = await resumed.savedExact
                let observedContext = await resumed.context
                check(observedCalls == 2 && exactInstructions && exactSaved && observedContext?.attempt == 3,
                    "RF06 actual planner consumes all four instructions and immutable completed read seeds")
                let final = current.receipts.receipts
                let newReads = final.filter { $0.taskAttempt == 3 }
                let expectedPaths = empty ? ["second.txt", "third.txt"] : ["third.txt"]
                check(final.count == 3 && saved.allSatisfy({ final.contains($0) })
                    && newReads.count == expectedPaths.count && newReads.allSatisfy({ $0.status == .completed && $0.toolID == "filesystem.read" })
                    && Set(newReads.compactMap({ $0.intent.arguments["path"] })) == Set(expectedPaths.map({ root.appendingPathComponent($0).path })),
                    "RF07 no saved read refires and actual unfinished authored files are read")
                let writeOffered = await resumed.writeOffered
                check(try writeOffered && PermissionGate.shared.pending == nil && PermissionGate.shared.queuedCount == 0
                    && final.allSatisfy({ $0.toolID == "filesystem.read" })
                    && Data(contentsOf: root.appendingPathComponent("third.txt")) == Data(thirdResult.utf8),
                    "RF08 actual READ ceiling refuses offered write before Gate receipt or backing")
            } else {
                joined = true
                for label in ["RF03 SAME ID revision4 retains complete instructions with new positive attempt3",
                    "RF04 duplicate current click cannot replace retained SAME Task", "RF05 recovered/started commit precedes actual successor completion",
                    "RF06 actual planner consumes all four instructions and immutable completed read seeds",
                    "RF07 no saved read refires and actual unfinished authored files are read",
                    "RF08 actual READ ceiling refuses offered write before Gate receipt or backing"] { check(false, label) }
            }
            let after = try current.sql.journal(taskID: held.id)
            check(try stale?.record(TaskJournalEventDraft(taskID: held.id, kind: .heartbeat, attempt: 2)) == false
                && stale?.isStillValid?() == false && current.sql.journal(taskID: held.id) == after,
                "RC17 old captured reader cannot append to successor history")
            check(SelfTestStoreGuard.diff(ownerBefore, SelfTestStoreGuard.take()).isEmpty, "RC18 owner bytes unchanged")
            retired = current.finish(); guard retired else { throw Invalid.drain }
            print("TASK_REPEATED_READ_COUNTS checks=\(checks) problems=\(failures.count) emptyLatest=\(empty) priorExited=\(firstExited && secondExited) joined=\(joined)")
            for failure in failures { SelfTest.diagnostic("TASK_REPEATED_READ_WRONG: \(failure)") }
            return failures.isEmpty ? "TASK_REPEATED_READ_OK" : "TASK_REPEATED_READ_FAILED: \(failures.count) assertions"
        } catch {
            operation?.cancel(); if let state { await state.release() }
            if let operation { _ = await operation.value }; joined = true
            if firstStarted {
                if first.isRunning { first.terminate() }
                firstExited = await TaskRecoveredReadSelfTest.reached({ !first.isRunning })
                if firstExited { first.waitUntilExit() }
            }
            if secondStarted {
                if second.isRunning { second.terminate() }
                secondExited = await TaskRecoveredReadSelfTest.reached({ !second.isRunning })
                if secondExited { second.waitUntilExit() }
            }
            if let scope { retired = scope.finish() }
            return "TASK_REPEATED_READ_FAILED: INPUT_INVALID \(error)"
        }
    }
}

private actor RepeatedReadPlanProbe {
    enum Invalid: Error { case context, request, seed, calls }
    let root: URL, stage: Int, empty: Bool, saved: [ActionReceipt]
    var calls = 0, held = false, instructionsExact = false, savedExact = false, writeOffered = false
    var context: TaskJournalContext?
    private var waiter: CheckedContinuation<Void, Never>?
    init(root: URL, stage: Int, empty: Bool, saved: [ActionReceipt]) {
        self.root = root; self.stage = stage; self.empty = empty; self.saved = saved
    }
    func complete(_ user: String) async throws -> String {
        calls += 1
        guard let captured = TaskEventJournal.current, captured.attempt == stage else { throw Invalid.context }
        context = captured
        guard let marker = user.range(of: "Current user request:\n", options: .backwards) else { throw Invalid.request }
        let tail = user[marker.upperBound...], done = tail.range(of: "\n\nWhat you have already done:\n")
        let request = String(done.map { tail[..<$0.lowerBound] } ?? tail)
        let expected = stage == 2 ? TaskRecoveredReadSelfTest.corrections : TaskRepeatedRecoveredReadSelfTest.instructions
        instructionsExact = request.contains(TaskRecoveredReadSelfTest.original)
            && expected.enumerated().allSatisfy { request.contains("\($0.offset + 1). \($0.element)") }
        savedExact = !saved.isEmpty && saved.allSatisfy { receipt in
            guard let done else { return false }
            let output = receipt.result
            return String(tail[done.upperBound...]).contains(output)
        }
        guard instructionsExact && savedExact else { throw Invalid.seed }
        if stage == 2 && (empty ? calls == 1 : calls == 2) {
            held = true; await withCheckedContinuation { waiter = $0 }
            return "The held read will not be used after the owned process exits."
        }
        if calls == 1 {
            func call(_ name: String, _ args: [String: String]) throws -> String {
                let bytes = try JSONSerialization.data(withJSONObject: args, options: .sortedKeys)
                return "<tool_call>{\"name\":\"\(name)\",\"arguments\":" + String(decoding: bytes, as: UTF8.self)
                    + ",\"rationale\":\"Read the remaining authored document\"}</tool_call>"
            }
            var planned: [String] = []
            if stage == 3 {
                writeOffered = true
                planned.append(try call("filesystem.write", ["path": root.appendingPathComponent("third.txt").path, "content": "must never be written"]))
            }
            for receipt in saved { planned.append(try call("filesystem.read", receipt.intent.arguments)) }
            if stage == 2 || empty { planned.append(try call("filesystem.read", ["path": root.appendingPathComponent("second.txt").path])) }
            if stage == 3 { planned.append(try call("filesystem.read", ["path": root.appendingPathComponent("third.txt").path])) }
            return planned.joined(separator: "\n")
        }
        guard stage == 3 && calls == 2, let done,
              String(tail[done.upperBound...]).contains(TaskRepeatedRecoveredReadSelfTest.thirdResult) else { throw Invalid.calls }
        return "The three authored documents are summarized in the requested order with their dates."
    }
    func release() { waiter?.resume(); waiter = nil }
}
private struct RepeatedReadPlanProvider: LLMProvider {
    let id = LLMProviderID.appLLM
    let probe: RepeatedReadPlanProbe
    var contextTokens: Int { 8192 }
    var unavailableReason: String? { get async { nil } }
    func countTokens(_ text: String) async throws -> Int { text.count / 4 }
    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        let response = try await probe.complete(user)
        return LLMCompletion(text: response, generatedTokens: response.count, duration: 0)
    }
}
#endif

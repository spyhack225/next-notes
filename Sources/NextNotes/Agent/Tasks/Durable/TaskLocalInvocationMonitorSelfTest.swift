import Foundation

/// Current named local backing-await observation through the actual temporary read.
/// The fire override holds, then calls FilesystemExecutor; fakeForTesting stays nil.
@MainActor
enum TaskLocalInvocationMonitorSelfTest {
    private enum FixtureError: Error { case unsafeRoot, missingContext, timeout, afterOriginalRead }

    @MainActor
    private final class State {
        var entered = 0
        var exited = 0
        var effects = 0
        var contexts: [TaskJournalContext] = []
        var held: CheckedContinuation<Void, Never>?
        var entryObservation: TaskWorkerToolBackingObservation?
        var completionCheckpoint: TaskWorkerToolBackingObservation?
        var invocationReturn: TaskWorkerToolBackingObservation?
        var announcementObservation: TaskWorkerToolBackingObservation?
        var opens = 0
        var expectedReceipt: UUID?
        var entryAlwaysAbsent = true
        var announcements: [String] = []
    }

    private static func reached(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    static func originalCases(root: URL, input: URL, text: String,
                              check: (Bool, String) -> Void) async throws {
        let safeRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard SelfTest.isRunning, safeRoot.path.hasPrefix(temporary.path + "/"),
              input.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(safeRoot.path + "/"),
              !safeRoot.pathComponents.contains("Application Support") else { throw FixtureError.unsafeRoot }
        let oldFake = AgentToolExecutor.fakeForTesting
        let oldFire = AgentToolExecutor.fireOverrideForTesting
        let oldPolicy = AgentToolExecutor.policyOverrideForTesting
        defer {
            AgentToolExecutor.fakeForTesting = oldFake
            AgentToolExecutor.fireOverrideForTesting = oldFire
            AgentToolExecutor.policyOverrideForTesting = oldPolicy
        }
        AgentToolExecutor.fakeForTesting = nil
        AgentToolExecutor.policyOverrideForTesting = .selfTest
        let modes = ["normal", "completion-returned-rejected", "completion-threw-rejected",
                     "completion-and-terminal-rejected", "cancel", "input-successor",
                     "tool-start-rejected", "waiting-input", "receipt-mismatch", "fresh-held"]
        for mode in modes {
            let directory = safeRoot.appendingPathComponent("local-invocation-" + mode, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let sql = TaskStore(root: directory)
            defer { sql.close() }
            let export = directory.appendingPathComponent("agent-tasks.json")
            let store = AgentTaskStore(fileURL: export, mirror: sql)
            guard store.allowsHarnessPersistence else { throw FixtureError.unsafeRoot }
            let receiptFile = directory.appendingPathComponent("action-receipts.json")
            let receipts = ActionReceiptStore(fileURL: receiptFile)
            let manager = AgentTaskManager(store: store, receiptStore: receipts)
            let state = State()
            var freshSQL: TaskStore?
            var freshManager: AgentTaskManager?
            defer { freshSQL?.close() }
            manager.toolInvocationForTesting = { if !$0.invocationInFlight { state.invocationReturn = $0 } }
            var currentSamples: [(TaskWorkerHeartbeatObservation, String)] = []
            manager.heartbeatMonitorForTesting = { currentSamples.append(($0, $1)) }
            manager.backendEntryForTesting = {
                guard let context = TaskEventJournal.current else { throw FixtureError.missingContext }
                state.entered += 1
                state.contexts.append(context)
                state.entryAlwaysAbsent = state.entryAlwaysAbsent
                    && manager.workerToolBackingObservation(taskID: context.taskID) == nil
                if mode == "tool-start-rejected" {
                    try sql.withConnection { db in
                        try TaskStore.exec(db, "CREATE TRIGGER reject_backing_start BEFORE INSERT ON task_event WHEN NEW.kind='toolStarted' BEGIN SELECT RAISE(ABORT,'fixture start rejection'); END")
                    }
                } else if mode.hasPrefix("completion-") {
                    try sql.withConnection { db in
                        try TaskStore.exec(db, "CREATE TRIGGER reject_backing_completion BEFORE INSERT ON task_event WHEN NEW.kind='toolCompleted' BEGIN SELECT RAISE(ABORT,'fixture completion rejection'); END")
                        if mode == "completion-and-terminal-rejected" {
                            try TaskStore.exec(db, "CREATE TRIGGER reject_backing_terminal BEFORE INSERT ON task_event WHEN NEW.kind='jobFailed' BEGIN SELECT RAISE(ABORT,'fixture terminal rejection'); END")
                        }
                    }
                }
            }
            manager.backendExitForTesting = { state.exited += 1 }
            manager.announcementForTesting = { value in
                state.announcements.append(value)
                if let id = state.contexts.last?.taskID,
                   manager.lastPersistenceResult == .sqlFailed {
                    state.announcementObservation = manager.workerToolBackingObservation(taskID: id)
                }
            }
            // Existing native file-binding checkpoint, before primary commit. No new
            // production wait, SQL open, or replacement backend is introduced.
            sql.authorityBoundaryForTesting = { phase, _ in
                if phase == "existingOpened" { state.opens += 1 }
                guard let id = state.contexts.last?.taskID,
                      let observed = manager.workerToolBackingObservation(taskID: id) else { return }
                if observed.state == .backingReturned || observed.state == .backingThrew {
                    state.completionCheckpoint = observed
                }
            }
            AgentToolExecutor.fireOverrideForTesting = { tool, arguments in
                guard let context = TaskEventJournal.current, tool.id == "filesystem.read",
                      arguments == ["path": input.path] else { throw FixtureError.missingContext }
                state.entryObservation = manager.workerToolBackingObservation(taskID: context.taskID)
                state.expectedReceipt = manager.task(id: context.taskID)?.durability?.receiptIDs.last.flatMap { UUID(uuidString: $0) }
                await withCheckedContinuation { state.held = $0 }
                state.effects += 1
                let result = try FilesystemExecutor.run(tool, arguments: arguments)
                if mode == "completion-threw-rejected" { throw FixtureError.afterOriginalRead }
                return result
            }
            let missing = mode == "input-successor" || mode == "waiting-input"
            let submitted = manager.submit(objective: "Observe the admitted original temporary read",
                tool: "filesystem.read", arguments: missing ? [:] : ["path": input.path], source: "selftest")
            check(manager.workerToolBackingObservation(taskID: submitted.id) == nil,
                "tool backing: queued handle invented backing observation (\(mode))")
            if mode == "waiting-input" {
                check(await reached { manager.task(id: submitted.id)?.status == .waitingForInput && state.exited == 1 },
                    "tool backing: original missing-path task did not park")
                check(state.effects == 0 && state.entryAlwaysAbsent
                    && manager.workerToolBackingObservation(taskID: submitted.id) == nil,
                    "tool backing: waiting input invented a live backing")
                await manager.monitorTaskHeartbeats(now: Date())
                check(currentSamples.isEmpty,
                    "local invocation C01 waiting input invented current backing coverage")
                manager.cancel(submitted.id)
                sql.authorityBoundaryForTesting = nil
                continue
            }
            if mode == "tool-start-rejected" {
                check(await reached { state.exited == 1 }, "tool backing: rejected start did not unwind")
                check(state.effects == 0 && state.held == nil && state.entryAlwaysAbsent
                    && manager.workerToolBackingObservation(taskID: submitted.id) == nil,
                    "tool backing: refused primary tool-start leaked backing observation/effect")
                check(try sql.journal(taskID: submitted.id).allSatisfy { $0.draft.kind != .toolStarted },
                    "tool backing: actual SQL trigger did not reject its original start event")
                await manager.monitorTaskHeartbeats(now: Date())
                check(currentSamples.isEmpty,
                    "local invocation C02 refused tool-start invented current backing coverage")
                sql.authorityBoundaryForTesting = nil
                continue
            }
            if mode == "input-successor" {
                guard await reached({ manager.task(id: submitted.id)?.status == .waitingForInput && state.exited == 1 }),
                      case .input(let question) = manager.task(id: submitted.id)?.pendingInteraction else {
                    throw FixtureError.timeout
                }
                check(manager.workerToolBackingObservation(taskID: submitted.id) == nil,
                    "tool backing: exited predecessor retained backing metadata")
                check(manager.respondInput(taskID: submitted.id, text: input.path, requestID: question.id),
                    "tool backing: exact input continuation was refused")
                check(manager.workerToolBackingObservation(taskID: submitted.id) == nil,
                    "tool backing: queued successor inherited predecessor backing metadata")
            }
            var caught: Error?
            do {
                guard await reached({ state.held != nil }), let context = state.contexts.last else {
                    throw FixtureError.timeout
                }
                let observation = state.entryObservation
                let binding = manager.workerBinding(taskID: submitted.id)
                let row = try sql.load().first { $0.id == submitted.id }
                let preparedReceipt = state.expectedReceipt.flatMap { receipts.receipt(for: $0) }
                check(state.entryAlwaysAbsent && state.effects == 0
                    && observation?.state == .entryAdmitted && observation?.binding == binding
                    && observation?.binding.attempt == context.attempt
                    && observation?.receiptID == state.expectedReceipt && observation?.toolID == "filesystem.read",
                    "tool backing: held original read lacked exact admitted-entry receipt/handle observation (\(mode))")
                check(preparedReceipt?.id == state.expectedReceipt && preparedReceipt?.status == .fired
                    && preparedReceipt?.preparedAction?.id == state.expectedReceipt
                    && preparedReceipt?.taskAttempt == context.attempt
                    && row?.durability?.receiptIDs.contains(state.expectedReceipt?.uuidString ?? "") == true,
                    "tool backing: held actual backing lacked the same saved prepared receipt link (\(mode))")
                let tasksBefore = manager.tasks
                let rowsBefore = try sql.load()
                let eventsBefore = try sql.journal(taskID: submitted.id)
                let exportBefore = try Data(contentsOf: export)
                let receiptBefore = try Data(contentsOf: receiptFile)
                let ownerBefore = SelfTestStoreGuard.take()
                await manager.monitorTaskHeartbeats(now: Date())
                let sample = currentSamples.last?.0
                let operand = currentSamples.last?.1 ?? ""
                check(currentSamples.count == 1 && sample?.primary.outcome == .accepted
                    && sample?.binding == binding && sample?.lastToolBoundary?.receiptID == state.expectedReceipt
                    && sample?.lastToolBoundary?.invocationInFlight == true
                    && sample?.evidence.toolInFlight == .yes
                    && sample?.evidence.processAlive == .unknown && sample?.evidence.backendSessionAlive == .unknown
                    && sample?.evidence.receiptCreated == .yes && operand.contains("tool=yes")
                    && !operand.contains(submitted.id) && !operand.contains(input.path),
                    "local invocation F01 current named backing await absent at real held read (\(mode))")
                let opensBefore = state.opens
                var unchanged = true
                for _ in 0..<8 {
                    if manager.workerToolBackingObservation(taskID: submitted.id) != observation { unchanged = false }
                }
                check(unchanged && state.opens == opensBefore && state.effects == 0,
                    "tool backing: cache getter opened SQL/changed backing metadata (\(mode))")
                check(try manager.tasks == tasksBefore && sql.load() == rowsBefore
                    && sql.journal(taskID: submitted.id) == eventsBefore
                    && Data(contentsOf: export) == exportBefore && Data(contentsOf: receiptFile) == receiptBefore,
                    "tool backing: cache getter changed stored primary/journal/export/receipt state (\(mode))")
                check(SelfTestStoreGuard.diff(ownerBefore, SelfTestStoreGuard.take()).isEmpty,
                    "tool backing: observation touched owner state (\(mode))")
                if mode == "fresh-held" {
                    let fresh = TaskStore(root: directory); freshSQL = fresh
                    freshManager = AgentTaskManager(store: AgentTaskStore(fileURL: export, mirror: fresh), receiptStore: receipts)
                    await manager.monitorTaskHeartbeats(now: Date())
                    check(freshManager?.task(id: submitted.id)?.status == .recovering
                        && context.isStillValid?() == false && state.held != nil && state.effects == 0
                        && manager.workerToolBackingObservation(taskID: submitted.id)?.state == .entryAdmitted
                        && currentSamples.count == 2 && currentSamples.last?.0.primary.outcome == .unavailable
                        && currentSamples.last?.0.evidence.toolInFlight == .unknown
                        && currentSamples.last?.0.evidence.receiptCreated == .unknown,
                        "local invocation C03 actual fresh primary hold granted stale tool/receipt authority")
                } else if mode == "cancel" {
                    manager.cancel(submitted.id)
                    check(state.held != nil && state.exited == 0 && state.effects == 0
                        && manager.workerToolBackingObservation(taskID: submitted.id) == nil,
                        "tool backing: cancellation claimed continued handle metadata or backing cessation")
                } else if mode == "input-successor" {
                    guard let old = state.contexts.first, let receiptID = state.expectedReceipt else {
                        throw FixtureError.missingContext
                    }
                    let before = manager.workerToolBackingObservation(taskID: submitted.id)
                    let opens = state.opens
                    old.observeToolInvocation?(receiptID, "filesystem.read", false)
                    let oldAdmitted = old.record(TaskJournalEventDraft(taskID: submitted.id, kind: .toolCompleted,
                        detail: "filesystem.read:returned", attempt: old.attempt, receiptID: receiptID))
                    check(!oldAdmitted && context.attempt == old.attempt + 1 && state.opens == opens
                        && manager.workerToolBackingObservation(taskID: submitted.id) == before,
                        "tool backing: obsolete real context stamped successor with current receipt ID")
                } else if mode == "receipt-mismatch" {
                    guard let receiptID = state.expectedReceipt else { throw FixtureError.missingContext }
                    let before = manager.workerToolBackingObservation(taskID: submitted.id)
                    // Malformed completion metadata only: the original backing stays held.
                    // Existing Bool admission stays unchanged; cache matching is stricter.
                    context.observeToolInvocation?(UUID(), "filesystem.read", false)
                    context.observeToolInvocation?(receiptID, "filesystem.write", false)
                    let wrongReceipt = context.record(TaskJournalEventDraft(taskID: submitted.id,
                        kind: .toolCompleted, detail: "filesystem.read:returned",
                        attempt: context.attempt, receiptID: UUID()))
                    let wrongTool = context.record(TaskJournalEventDraft(taskID: submitted.id,
                        kind: .toolCompleted, detail: "filesystem.write:returned",
                        attempt: context.attempt, receiptID: receiptID))
                    check(wrongReceipt && wrongTool && before?.state == .entryAdmitted
                        && manager.workerToolBackingObservation(taskID: submitted.id) == before
                        && state.effects == 0 && state.held != nil,
                        "tool backing: tool-name-only or wrong-tool completion changed the exact last receipt")
                }
            } catch { caught = error }
            if caught != nil { manager.cancel(submitted.id) }
            let continuation = state.held
            state.held = nil
            continuation?.resume()
            let expectedExits = mode == "input-successor" ? 2 : 1
            check(await reached { state.exited == expectedExits },
                "tool backing: original held worker failed bounded cleanup (\(mode))")
            sql.authorityBoundaryForTesting = nil
            if let caught { throw caught }
            check(manager.workerToolBackingObservation(taskID: submitted.id) == nil,
                "tool backing: exited worker retained a live cache (\(mode))")
            let final = try sql.load().first { $0.id == submitted.id }
            let events = try sql.journal(taskID: submitted.id)
            check(events.allSatisfy { $0.draft.receiptID == nil },
                "tool backing: transient receipt handoff unexpectedly changed persisted journal schema")
            if mode == "cancel" {
                check(state.invocationReturn == nil && state.effects == 1
                    && manager.workerToolBackingObservation(taskID: submitted.id) == nil,
                    "local invocation C06 cancelled handle retained authority or claimed backing cessation")
            } else {
                check(state.invocationReturn?.binding == state.entryObservation?.binding
                    && state.invocationReturn?.receiptID == state.expectedReceipt
                    && state.invocationReturn?.toolID == "filesystem.read"
                    && state.invocationReturn?.state == .entryAdmitted
                    && state.invocationReturn?.invocationInFlight == false,
                    "local invocation F02 actual named return was not acknowledged before journal admission (\(mode))")
            }
            if mode == "fresh-held" {
                let primaryFailure = AgentTaskPersistenceResult.sqlFailed.diagnostic
                let exactPrimaryFailureOnly = state.announcements.count == 1
                    && state.announcements.first == primaryFailure
                    && manager.lastPersistenceResult == .sqlFailed
                let successfulDelivery = state.announcements.contains {
                    $0.contains(text) || $0.hasPrefix("fixture artifact announcement:")
                }
                SelfTest.diagnostic("LOCAL_INVOCATION_HELD_TRACE: effects=\(state.effects) status=\(final?.status.rawValue ?? "missing") resultPresent=\(final?.result != nil) toolCompleted=\(events.filter { $0.draft.kind == .toolCompleted }.count) announcements=\(state.announcements.count) exactPrimaryFailureOnly=\(exactPrimaryFailureOnly) successfulDelivery=\(successfulDelivery) persistenceSQLFailed=\(manager.lastPersistenceResult == .sqlFailed)")
                check(state.effects == 1 && final?.status == .recovering && final?.result == nil
                    && events.allSatisfy { $0.draft.kind != .toolCompleted }
                    && exactPrimaryFailureOnly && !successfulDelivery,
                    "local invocation C04 late held read invented current primary completion/delivery")
                let freshReceipt = state.expectedReceipt.flatMap { ActionReceiptStore(fileURL: receiptFile).receipt(for: $0) }
                check(freshReceipt?.status == .completed && freshReceipt?.taskAttempt == state.contexts.last?.attempt,
                    "local invocation C05 held primary erased actual completed backing receipt")
            } else if mode == "cancel" {
                check(state.effects == 1 && final?.status == .cancelled && final?.result == nil,
                    "tool backing: late cancellation-ignoring original read became successful delivery")
            } else {
                let expected: TaskWorkerToolBackingState = mode == "completion-threw-rejected" ? .backingThrew : .backingReturned
                check(state.effects == 1 && state.completionCheckpoint?.state == expected
                    && state.completionCheckpoint?.invocationInFlight == false
                    && state.completionCheckpoint?.binding == state.entryObservation?.binding
                    && state.completionCheckpoint?.receiptID == state.expectedReceipt
                    && state.completionCheckpoint?.toolID == state.entryObservation?.toolID,
                    "tool backing: actual return/throw lost the exact receipt/handle BEFORE primary completion commit (\(mode))")
                if mode.hasPrefix("completion-") {
                    check(events.contains { $0.draft.kind == .toolStarted }
                        && events.allSatisfy { $0.draft.kind != .toolCompleted }
                        && final?.result == nil
                        && state.announcements.allSatisfy { !$0.contains(text) && !$0.hasPrefix("fixture artifact announcement:") },
                        "tool backing: rejected completion lost original unmatched history or delivered success (\(mode))")
                    if mode == "completion-and-terminal-rejected" {
                        // Reject the existing terminal write too: rollback keeps the live
                        // handle observable at its existing diagnostic callback.
                        check(final?.status == .running
                            && state.announcementObservation?.state == .backingReturned
                            && state.announcementObservation?.invocationInFlight == false
                            && state.announcementObservation?.receiptID == state.expectedReceipt,
                            "tool backing: rejected completion save rolled live return metadata back to entered")
                    } else {
                        check(final?.status == .failed, "tool backing: completion refusal lost actual task failure")
                    }
                } else {
                    check(final?.status == .completed && final?.result?.contains(text) == true,
                        "tool backing: same original temporary read did not complete once")
                }
                if let id = state.expectedReceipt {
                    let freshReceipt = ActionReceiptStore(fileURL: receiptFile).receipt(for: id)
                    check(freshReceipt?.taskAttempt == state.contexts.last?.attempt
                        && freshReceipt?.preparedAction?.id == id
                        && freshReceipt?.status == (mode == "completion-threw-rejected" ? .failed : .completed),
                        "tool backing: actual original read lost its unchanged exact terminal runtime receipt")
                } else {
                    check(false, "tool backing: original read has no saved prepared receipt ID")
                }
            }
        }
    }
}

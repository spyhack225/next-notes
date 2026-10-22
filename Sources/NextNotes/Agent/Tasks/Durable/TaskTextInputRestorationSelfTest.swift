import Foundation

/// Actual missing query -> retained input -> fresh Manager -> admitted answer -> real
/// local search. The supplied folder and backing are confined to this fixture.
@MainActor
enum TaskTextInputRestorationSelfTest {
    private enum FixtureError: Error { case unsafe, absent, timeout }

    private static func reached(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    private static func canonical(_ rows: [AgentTask]) throws -> [AgentTask] {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([AgentTask].self, from: encoder.encode(rows))
    }

    static func run() async -> (checks: Int, failures: [String]) {
        guard SelfTest.isRunning, PermissionGate.shared.pending == nil else {
            return (0, ["text input: empty harness gate required"])
        }
        let beforeOwner = SelfTestStoreGuard.take()
        let oldFake = AgentToolExecutor.fakeForTesting
        let oldFire = AgentToolExecutor.fireOverrideForTesting
        let oldPolicy = AgentToolExecutor.policyOverrideForTesting
        let grants = PermissionGrantStore.shared.grants
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NextNotesTextInput-" + UUID().uuidString, isDirectory: true)
        var cleanupSafe = true
        defer {
            AgentToolExecutor.fakeForTesting = oldFake
            AgentToolExecutor.fireOverrideForTesting = oldFire
            AgentToolExecutor.policyOverrideForTesting = oldPolicy
            if cleanupSafe { try? FileManager.default.removeItem(at: root) }
        }
        var checks = 0; var failures: [String] = []
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if !value { failures.append("text input: " + label) }
        }
        do {
            let safe = root.resolvingSymlinksInPath().standardizedFileURL
            let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
            guard safe.deletingLastPathComponent().path == temp.path,
                  !FileManager.default.fileExists(atPath: root.path) else { throw FixtureError.unsafe }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            AgentToolExecutor.fakeForTesting = nil
            AgentToolExecutor.policyOverrideForTesting = .selfTest
            let owner = String(ProcessInfo.processInfo.processIdentifier)
            let query = "needle"
            let contents = "Authored file contents must not become the name-search result."
            for mode in ["accepted", "tool-start-rejected", "question-rejected"] {
                let modeChecks = checks
                let directory = root.appendingPathComponent(mode, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                let folder = directory.appendingPathComponent("search-target", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                let match = folder.appendingPathComponent("needle-note.txt")
                try Data(contents.utf8).write(to: match)
                let initialArguments = ["folder": folder.path]
                let answeredArguments = ["folder": folder.path, "query": query]
                guard let tool = AgentToolRegistry.shared.tool(named: "filesystem.search") else { throw FixtureError.absent }
                let calibration = ToolCallReviewBuilder.review(id: "search-query-calibration", tool: tool,
                    arguments: initialArguments)
                // A randomly generated path can itself be an unverified token. Do not
                // retry/cherry-pick it or classify invalid review input as feature RED.
                guard calibration.blockers.count == 1, calibration.blockers.first?.name == "query",
                      calibration.blockers.first?.problem == .missing,
                      calibration.field("query")?.kind == .text,
                      calibration.field("query")?.prompt == "What should I look for?" else { throw FixtureError.unsafe }
                let sql = TaskStore(root: directory)
                defer { sql.close() }
                let export = directory.appendingPathComponent("agent-tasks.json")
                let store = AgentTaskStore(fileURL: export, mirror: sql)
                let receiptFile = directory.appendingPathComponent("action-receipts.json")
                let receipts = ActionReceiptStore(fileURL: receiptFile)
                guard store.allowsHarnessPersistence, receipts.sourceObservation?.loadQuality == .missing else {
                    throw FixtureError.unsafe
                }
                let manager = AgentTaskManager(store: store, receiptStore: receipts)
                var firstContext: TaskJournalContext?
                var entryRow: AgentTask?
                var initialEnded = 0
                var fires = 0
                var fireArguments: [[String: String]] = []
                var effectReceipt: ActionReceipt?
                var effectBound = false
                manager.backendEntryForTesting = {
                    firstContext = TaskEventJournal.current
                    entryRow = try sql.load().first
                }
                manager.backendExitForTesting = { initialEnded += 1 }
                AgentToolExecutor.fireOverrideForTesting = { realTool, arguments in
                    guard realTool.id == tool.id, arguments == answeredArguments,
                          URL(fileURLWithPath: arguments["folder"] ?? "").resolvingSymlinksInPath().path == folder.resolvingSymlinksInPath().path,
                          folder.resolvingSymlinksInPath().path.hasPrefix(safe.path + "/") else { throw FixtureError.unsafe }
                    let row = try sql.load().first
                    effectReceipt = receipts.receipts.first
                    effectBound = row?.status == .running && row?.arguments == answeredArguments
                        && row?.durability?.attempt == 2 && row?.durability?.leaseOwner == owner
                        && row?.durability?.receiptIDs == effectReceipt.map { [$0.actionID.uuidString] }
                        && effectReceipt?.status == .fired && effectReceipt?.events.last?.stage == .fired
                        && effectReceipt?.taskAttempt == 2 && effectReceipt?.taskLeaseOwner == owner
                        && effectReceipt?.taskID == row?.id && effectReceipt?.preparedAction?.id == effectReceipt?.actionID
                        && effectReceipt?.preparedAction?.intentID == effectReceipt?.intentID
                        && effectReceipt?.preparedAction?.routing.taskID == row?.id
                        && effectReceipt?.preparedAction?.executionPlan.arguments == answeredArguments
                        && TaskEventJournal.current?.taskID == row?.id && TaskEventJournal.current?.attempt == 2
                    fires += 1; fireArguments.append(arguments)
                    return try FilesystemExecutor.run(realTool, arguments: arguments)
                }
                if mode == "question-rejected" {
                    try sql.withConnection { try TaskStore.exec($0,
                        "CREATE TRIGGER reject_text_question BEFORE INSERT ON task_event WHEN NEW.kind='inputRequested' BEGIN SELECT RAISE(ABORT,'fixture'); END") }
                }
                let submitted = manager.submit(objective: "Search my supplied fixture folder", tool: tool.id,
                    arguments: initialArguments, source: "text")
                guard await reached({ initialEnded == 1 }) else {
                    manager.cancel(submitted.id)
                    guard await reached({ initialEnded == 1 }) else { cleanupSafe = false; throw FixtureError.timeout }
                    throw FixtureError.timeout
                }
                let initialRows = try sql.load()
                let initialEvents = try sql.journal(taskID: submitted.id)
                check(entryRow?.status == .running && entryRow?.durability?.attempt == 1
                    && entryRow?.durability?.leaseOwner == owner && entryRow?.arguments == initialArguments
                    && firstContext?.taskID == submitted.id && firstContext?.attempt == 1
                    && firstContext?.receiptStore === receipts && manager.backendStartsForTesting == 1,
                    mode + " initial real worker bound to primary and injected receipts")
                check(fires == 0 && receipts.receipts.isEmpty && PermissionGate.shared.pending == nil
                    && initialRows.first?.durability?.receiptIDs.isEmpty == true,
                    mode + " missing query runs no backing, receipt or approval")
                let initialMemory = try canonical(manager.tasks)
                check(initialRows == initialMemory, mode + " original transition reaches exact primary")
                if mode == "question-rejected" {
                    check(manager.task(id: submitted.id)?.status == .failed && manager.pendingInputs.isEmpty
                        && initialEvents.allSatisfy { $0.draft.kind != .inputRequested },
                        mode + " rejected question has no retained input or dispatch")
                    try sql.withConnection { try TaskStore.exec($0, "DROP TRIGGER reject_text_question") }
                } else {
                    let question = manager.pendingInputs.first
                    check(manager.task(id: submitted.id)?.status == .waitingForInput
                        && question?.taskID == submitted.id && question?.toolID == tool.id
                        && question?.argumentName == "query" && question?.question == "What should I look for?",
                        mode + " actual missing query emits exact bound question")
                    // Original unsupported producer has no real question. Keep that
                    // measured feature failure; never seed a fabricated continuation.
                    if let liveQuestion = question {
                        guard let firstContext, let parked = initialRows.first,
                              case .input(let question) = parked.pendingInteraction else { throw FixtureError.absent }
                        // The actual writer canonicalizes dates before SQL. Continuation
                        // comparisons use that real primary request, like the existing path fixture.
                        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
                        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                        let canonicalQuestion = try decoder.decode(TaskInputRequest.self, from: encoder.encode(liveQuestion))
                        let idEqual = liveQuestion.id == question.id
                        let taskEqual = liveQuestion.taskID == question.taskID
                        let promptEqual = liveQuestion.question == question.question
                        let toolEqual = liveQuestion.toolID == question.toolID
                        let argumentEqual = liveQuestion.argumentName == question.argumentName
                        let dateEqual = liveQuestion.createdAt == question.createdAt
                        let canonicalEqual = canonicalQuestion == question
                        print("TASK_TEXT_INPUT_PRECISION mode=\(mode) idEqual=\(idEqual) taskEqual=\(taskEqual) promptEqual=\(promptEqual) toolEqual=\(toolEqual) argumentEqual=\(argumentEqual) dateEqual=\(dateEqual) liveDate=\(liveQuestion.createdAt.timeIntervalSince1970) primaryDate=\(question.createdAt.timeIntervalSince1970) canonicalEqual=\(canonicalEqual)")
                        check(parked.pendingInteraction == .input(question) && canonicalEqual
                            && parked.arguments == initialArguments && parked.durability?.attempt == 1
                            && initialEvents.last?.draft.kind == .inputRequested,
                            mode + " exact question persists with prior attempt")
                        let fresh = AgentTaskManager(store: AgentTaskStore(fileURL: export, mirror: sql), receiptStore: receipts)
                        let retainedContext = fresh.journalContext(taskID: submitted.id)
                        check(fresh.pendingInputs == [question] && fresh.backendStartsForTesting == 0
                            && fresh.canRespondInput(taskID: submitted.id, requestID: question.id)
                            && fresh.inputField(taskID: submitted.id, requestID: question.id)?.kind == .text,
                            mode + " fresh reader exposes existing text field without replay")
                        let retainedRows = try sql.load(); let retainedEvents = try sql.journal(taskID: submitted.id)
                        let retainedExport = try Data(contentsOf: export)
                        check(!fresh.respondInput(taskID: submitted.id, text: query, requestID: "stale")
                            && !fresh.respondInput(taskID: submitted.id, text: query)
                            && !fresh.respondInput(taskID: submitted.id, text: "", requestID: question.id)
                            && !fresh.respondInput(taskID: submitted.id, text: "[Name]", requestID: question.id),
                            mode + " stale, missing, blank and placeholder answers refuse")
                        let refusedRows = try sql.load(); let refusedEvents = try sql.journal(taskID: submitted.id)
                        let refusedExport = try Data(contentsOf: export)
                        check(refusedRows == retainedRows && refusedEvents == retainedEvents
                            && refusedExport == retainedExport && fresh.pendingInputs == [question]
                            && fresh.backendStartsForTesting == 0 && fires == 0,
                            mode + " rejected answers preserve exact history and pending input")
                        if mode == "accepted" {
                            try sql.withConnection { try TaskStore.exec($0,
                                "CREATE TRIGGER reject_text_answer BEFORE INSERT ON task_event WHEN NEW.kind='inputProvided' BEGIN SELECT RAISE(ABORT,'fixture'); END") }
                            check(!fresh.respondInput(taskID: submitted.id, text: query, requestID: question.id)
                                && fresh.lastPersistenceResult == .sqlFailed,
                                mode + " rejected primary answer supplies no dispatch")
                            let sqlRefusedRows = try sql.load(); let sqlRefusedEvents = try sql.journal(taskID: submitted.id)
                            let sqlRefusedExport = try Data(contentsOf: export)
                            check(sqlRefusedRows == retainedRows && sqlRefusedEvents == retainedEvents
                                && sqlRefusedExport == retainedExport && fresh.pendingInputs == [question]
                                && fresh.backendStartsForTesting == 0 && receipts.receipts.isEmpty && fires == 0,
                                mode + " failed answer transaction retains card, args and backing")
                            try sql.withConnection { try TaskStore.exec($0, "DROP TRIGGER reject_text_answer") }
                        }
                        var successorEntries = 0; var successorEnds = 0
                        var successorBound = false; var staleRefused = false; var staleUnchanged = false
                        fresh.backendExitForTesting = { successorEnds += 1 }
                        fresh.backendEntryForTesting = {
                            successorEntries += 1
                            let rows = try sql.load(); let events = try sql.journal(taskID: submitted.id)
                            let row = rows.first
                            successorBound = row?.status == .running && row?.arguments == answeredArguments
                                && row?.durability?.attempt == 2 && row?.durability?.leaseOwner == owner
                                && row?.durability?.attemptStartedAt != nil
                                && TaskEventJournal.current?.attempt == 2 && events.last?.draft.kind == .workerStarted
                            staleRefused = [firstContext, retainedContext].compactMap { $0 }.allSatisfy { old in
                                !old.record(TaskJournalEventDraft(taskID: submitted.id, kind: .toolStarted,
                                    detail: tool.id, attempt: old.attempt))
                                    && old.isStillValid?() != true && old.consumePermissionApproval?() != true
                            }
                            let afterRows = try sql.load(); let afterEvents = try sql.journal(taskID: submitted.id)
                            staleUnchanged = rows == afterRows && events == afterEvents
                            if mode == "tool-start-rejected" {
                                try sql.withConnection { try TaskStore.exec($0,
                                    "CREATE TRIGGER reject_text_start BEFORE INSERT ON task_event WHEN NEW.kind='toolStarted' BEGIN SELECT RAISE(ABORT,'fixture'); END") }
                            }
                        }
                        check(fresh.respondInput(taskID: submitted.id, text: query, requestID: question.id),
                            mode + " exact answer commits before successor dispatch")
                        let queued = try sql.load().first
                        check(queued?.status == .queued && queued?.arguments == answeredArguments
                            && fresh.pendingInputs.isEmpty && fresh.backendStartsForTesting == 0
                            && !fresh.consumePermissionApproval(taskID: submitted.id),
                            mode + " queued answer preserves supplied folder and creates no grant")
                        check(!fresh.respondInput(taskID: submitted.id, text: query, requestID: question.id),
                            mode + " duplicate answer does not enqueue twice")
                        guard await reached({ successorEnds == 1 }) else {
                            fresh.cancel(submitted.id)
                            guard await reached({ successorEnds == 1 }) else { cleanupSafe = false; throw FixtureError.timeout }
                            throw FixtureError.timeout
                        }
                        check(successorEntries == 1 && fresh.backendStartsForTesting == 1 && successorBound,
                            mode + " one prior-plus-one attempt reaches real backend")
                        check(retainedContext != nil && staleRefused && staleUnchanged,
                            mode + " prior live/restored callbacks cannot stamp successor")
                        let finalRows = try sql.load(); let finalEvents = try sql.journal(taskID: submitted.id)
                        let persistedReceipts = ActionReceiptStore(fileURL: receiptFile)
                        let receipt = persistedReceipts.receipts.first
                        check(persistedReceipts.receipts.count == 1 && receipt?.taskID == submitted.id
                            && receipt?.taskAttempt == 2 && receipt?.taskLeaseOwner == owner
                            && receipt?.toolID == tool.id
                            && receipt?.preparedAction?.id == receipt?.actionID
                            && receipt?.preparedAction?.intentID == receipt?.intentID
                            && receipt?.preparedAction?.routing.taskID == submitted.id
                            && receipt?.preparedAction?.executionPlan.toolID == tool.id
                            && receipt?.preparedAction?.executionPlan.arguments == answeredArguments
                            && receipt?.events.contains(where: { $0.stage == .fired }) == true,
                            mode + " real successor receipt pins frozen preparation and ownership")
                        check(finalEvents.filter { $0.draft.kind == .workerStarted }.map { $0.draft.attempt } == [1, 2]
                            && finalEvents.filter { $0.draft.kind == .inputProvided }.count == 1
                            && finalRows.first?.durability?.attempt == 2,
                            mode + " answer allocates exactly one persisted successor")
                        if mode == "accepted" {
                            check(fires == 1 && fireArguments == [answeredArguments] && effectBound,
                                mode + " real search backing consumes exact joined fired receipt")
                            check(fresh.task(id: submitted.id)?.status == .completed
                                && fresh.task(id: submitted.id)?.result?.contains(match.path) == true
                                && fresh.task(id: submitted.id)?.result?.contains(contents) == false
                                && receipt?.status == .completed && receipt?.completedAt != nil
                                && finalRows.first?.durability?.receiptIDs == receipt.map { [$0.actionID.uuidString] },
                                mode + " actual filename search completes without reading body")
                        } else {
                            check(fires == 0 && finalRows.first?.status == .failed
                                && finalRows.first?.durability?.receiptIDs.isEmpty == true
                                && finalEvents.allSatisfy { $0.draft.kind != .toolStarted }
                                && receipt?.status == .failed && receipt?.result.isEmpty == true,
                                mode + " refused startup retains failed receipt but runs no search")
                            check(fresh.task(id: submitted.id)?.failure == "The action could not be saved. It was not run.",
                                mode + " refused actual tool admission reports exact failure")
                            try sql.withConnection { try TaskStore.exec($0, "DROP TRIGGER reject_text_start") }
                        }
                        let terminal = AgentTaskManager(store: AgentTaskStore(fileURL: export, mirror: sql), receiptStore: persistedReceipts)
                        let finalMemory = try canonical(fresh.tasks)
                        check(terminal.tasks == finalMemory && terminal.pendingInputs.isEmpty
                            && terminal.backendStartsForTesting == 0
                            && !terminal.respondInput(taskID: submitted.id, text: query, requestID: question.id),
                            mode + " terminal reload neither restores question nor replays effect")
                    }
                }
                let finalFile = try Data(contentsOf: match)
                check(finalFile == Data(contents.utf8) && PermissionGate.shared.pending == nil
                    && PermissionGrantStore.shared.grants == grants && manager.workerBinding(taskID: submitted.id) == nil,
                    mode + " authored backing, grants and released initial owner unchanged")
                print("TASK_TEXT_INPUT_TRACE mode=\(mode) checks=\(checks - modeChecks) question=\(manager.pendingInputs.count) initialEntries=\(manager.backendStartsForTesting) fires=\(fires) receipts=\(receipts.receipts.count)")
            }
        } catch { failures.append("text input: INVALID prerequisite \(error)") }
        check(SelfTestStoreGuard.diff(beforeOwner, SelfTestStoreGuard.take()).isEmpty,
            "owner stores/defaults unchanged")
        print("TASK_TEXT_INPUT_RESULT checks=\(checks) failures=\(failures.count)")
        return (checks, failures)
    }
}

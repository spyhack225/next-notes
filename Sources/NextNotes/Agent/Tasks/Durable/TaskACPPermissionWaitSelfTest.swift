import Foundation

/// Actual two independent typed ACP workers -> Session/Broker -> one visible and one queued Gate wait.
/// The original false projection is a missing diagnostic feature, never a stale-classification bug.
@MainActor
enum TaskACPPermissionWaitSelfTest {
    private enum FixtureError: Error { case unsafeRoot, busyGate, missingContext, missingReceipt, timeout, invalidPeer }

    private static func reached(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    private static func object(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return value
    }

    private static func release(_ url: URL) throws {
        try Data(#"{"release":true}"#.utf8).write(to: url, options: .atomic)
    }

    @MainActor
    private final class OwnedWorker {
        let root: URL
        let sql: TaskStore
        let export: URL
        let receiptFile: URL
        let receipts: ActionReceiptStore
        let manager: AgentTaskManager
        let marker: String
        let objective: String
        var submitted: AgentTask?
        var context: TaskJournalContext?
        var binding: TaskWorkerBinding?
        var entered = 0
        var ended = 0
        var announcements: [String] = []

        init(root: URL, name: String, oldProgress: Date) throws {
            self.root = root
            marker = "Owned permission wait fixture " + name + " finished."
            objective = "Owned permission wait fixture " + name + ": no tools"
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            sql = TaskStore(root: root)
            export = root.appendingPathComponent("agent-tasks.json")
            receiptFile = root.appendingPathComponent("action-receipts.json")
            receipts = ActionReceiptStore(fileURL: receiptFile)
            let store = AgentTaskStore(fileURL: export, mirror: sql)
            guard store.allowsHarnessPersistence else { throw FixtureError.unsafeRoot }
            manager = AgentTaskManager(store: store, receiptStore: receipts)
            manager.progressDateForTesting = { oldProgress }
            manager.announcementForTesting = { [weak self] in self?.announcements.append($0) }
            manager.backendExitForTesting = { [weak self] in self?.ended += 1 }
            manager.backendEntryForTesting = { [weak self] in
                guard let self, let captured = TaskEventJournal.current else { throw FixtureError.missingContext }
                entered += 1
                context = captured
                binding = manager.workerBinding(taskID: captured.taskID)
                let config: [String: Any] = ["taskID": captured.taskID, "objective": objective, "marker": marker]
                try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
                    .write(to: root.appendingPathComponent("config.json"), options: .atomic)
            }
            try TaskACPPermissionWaitSelfTest.peer.write(to: root.appendingPathComponent("owned-permission-wait-peer.py"), atomically: true, encoding: .utf8)
        }

        func start() -> AgentTask {
            let task = manager.submit(objective: objective,
                arguments: ["acpFixture": root.appendingPathComponent("owned-permission-wait-peer.py").path,
                    "acpFixtureAskPermission": "true"], backend: .acp, source: "selftest")
            submitted = task
            return task
        }

        func hasFile(_ name: String) -> Bool {
            FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)
        }
    }

    static func originalCases(root: URL, check: (Bool, String) -> Void) async throws {
        let safe = root.resolvingSymlinksInPath().standardizedFileURL
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard SelfTest.isRunning, safe.isFileURL, safe.path.hasPrefix(temporary.path + "/"),
              !safe.pathComponents.contains("Application Support") else { throw FixtureError.unsafeRoot }
        let gate = PermissionGate.shared
        guard gate.pending == nil, gate.queuedCount == 0 else { throw FixtureError.busyGate }
        let grantsBefore = PermissionGrantStore.shared.grants
        let asksBefore = gate.askCount
        let priorFake = AgentToolExecutor.fakeForTesting
        let priorFire = AgentToolExecutor.fireOverrideForTesting
        defer {
            AgentToolExecutor.fakeForTesting = priorFake
            AgentToolExecutor.fireOverrideForTesting = priorFire
        }
        AgentToolExecutor.fakeForTesting = nil
        var unexpectedTools = 0
        AgentToolExecutor.fireOverrideForTesting = { _, _ in
            unexpectedTools += 1
            throw FixtureError.invalidPeer
        }
        // Exact same old timestamp is admitted by real worker/tool-start producers.
        let oldProgress = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 40 * 86_400)
        let owner = String(ProcessInfo.processInfo.processIdentifier)
        let a = try OwnedWorker(root: safe.appendingPathComponent("permission-wait-A", isDirectory: true), name: "A", oldProgress: oldProgress)
        let b = try OwnedWorker(root: safe.appendingPathComponent("permission-wait-B", isDirectory: true), name: "B", oldProgress: oldProgress)
        defer { a.sql.close(); b.sql.close() }
        let taskA = a.start()
        let taskB = b.start()
        var requestA: PermissionRequest?
        var requestB: PermissionRequest?
        do {
            guard await reached({ a.hasFile("prompt-observed.json") && b.hasFile("prompt-observed.json") }) else { throw FixtureError.timeout }
            guard let contextA = a.context, let contextB = b.context,
                  let bindingA = a.binding, let bindingB = b.binding,
                  let firedA = a.receipts.receipts.first, let firedB = b.receipts.receipts.first else { throw FixtureError.missingContext }
            let rowA = try a.sql.load().first { $0.id == taskA.id }
            let rowB = try b.sql.load().first { $0.id == taskB.id }
            let journalA = try a.sql.journal(taskID: taskA.id)
            let journalB = try b.sql.journal(taskID: taskB.id)
            // L01
            check(a.entered == 1 && b.entered == 1 && a.ended == 0 && b.ended == 0
                && a.manager.backendStartsForTesting == 1 && b.manager.backendStartsForTesting == 1
                && object(a.root.appendingPathComponent("prompt-observed.json"))["taskID"] as? String == taskA.id
                && object(b.root.appendingPathComponent("prompt-observed.json"))["taskID"] as? String == taskB.id,
                "Permission wait: exact two real owned prompts were not held")
            // L02
            check(contextA.taskID == taskA.id && contextB.taskID == taskB.id
                && contextA.attempt == 1 && contextB.attempt == 1
                && contextA.leaseOwner == owner && contextB.leaseOwner == owner
                && contextA.receiptStore === a.receipts && contextB.receiptStore === b.receipts
                && contextA.isStillValid?() == true && contextB.isStillValid?() == true
                && a.manager.workerBinding(taskID: taskA.id) == bindingA
                && b.manager.workerBinding(taskID: taskB.id) == bindingB,
                "Permission wait: actual workers lost exact positive isolated attempt/context")
            // L03
            check(a.manager.workerPermissionWait(taskID: taskA.id) == false
                && b.manager.workerPermissionWait(taskID: taskB.id) == false
                && !gate.hasWaitingRequest(taskID: taskA.id) && !gate.hasWaitingRequest(taskID: taskB.id)
                && gate.pending == nil && gate.queuedCount == 0 && gate.askCount == asksBefore,
                "Permission wait: running workers without approval were reported waiting")
            // L04
            check(!gate.hasWaitingRequest(taskID: "missing-permission-wait")
                && a.manager.workerPermissionWait(taskID: "missing-permission-wait") == nil
                && a.manager.workerPermissionWait(taskID: taskB.id) == nil
                && b.manager.workerPermissionWait(taskID: taskA.id) == nil,
                "Permission wait: unrelated or missing live binding obtained another task wait")
            // L05
            check(rowA?.status == .running && rowB?.status == .running
                && rowA?.durability?.runtimeClass == .acpWorker && rowB?.durability?.runtimeClass == .acpWorker
                && rowA?.durability?.heartbeatAt == oldProgress && rowB?.durability?.heartbeatAt == oldProgress
                && rowA?.durability?.lastProgressAt == oldProgress && rowB?.durability?.lastProgressAt == oldProgress
                && journalA.filter { $0.draft.kind == .toolStarted }.count == 1
                && journalB.filter { $0.draft.kind == .toolStarted }.count == 1,
                "Permission wait: exact forty-day progress was not admitted by original worker/tool producer")
            // L06
            check(firedA.status == .fired && firedB.status == .fired && firedA.result.isEmpty && firedB.result.isEmpty
                && firedA.taskID == taskA.id && firedB.taskID == taskB.id
                && firedA.taskAttempt == 1 && firedB.taskAttempt == 1
                && firedA.taskLeaseOwner == owner && firedB.taskLeaseOwner == owner
                && firedA.preparedAction?.id == firedA.actionID && firedB.preparedAction?.id == firedB.actionID
                && rowA?.durability?.receiptIDs == [firedA.actionID.uuidString]
                && rowB?.durability?.receiptIDs == [firedB.actionID.uuidString],
                "Permission wait: actual startup receipts and exact primary joins were replaced")
            await TaskHeartbeatIntegrationSelfTest.sample(manager: a.manager, binding: bindingA,
                expectedPrimary: .accepted, expectedWait: false, expectedAge: "ageCandidate", check: check)
            await TaskHeartbeatIntegrationSelfTest.sample(manager: b.manager, binding: bindingB,
                expectedPrimary: .accepted, expectedWait: false, expectedAge: "ageCandidate", check: check)
            try release(a.root.appendingPathComponent("release-permission.json"))
            guard await reached({ gate.pending?.taskID == taskA.id && gate.queuedCount == 0 }) else { throw FixtureError.timeout }
            guard let visibleA = gate.pending else { throw FixtureError.invalidPeer }
            requestA = visibleA
            let reviewA = ToolCallReviewStore.shared.review(for: visibleA)
            let expectedOperation = ["toolCallId": "owned-wait-only", "title": "Owned fixture review only",
                "kind": "other", "status": "pending"]
            let operationTextA = visibleA.arguments["toolCall"] ?? ""
            let operationA = operationTextA.data(using: .utf8)
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
            // V01
            check(visibleA.taskID == taskA.id && visibleA.toolID == "mcp.acp_nested_tool"
                && visibleA.arguments["taskID"] == nil && visibleA.arguments.keys.sorted() == ["toolCall"]
                && operationA == expectedOperation && visibleA.detail == operationTextA
                && reviewA.isReadyToRun && reviewA.blockers.isEmpty && reviewA.fields.map(\.name) == ["toolCall"]
                && !a.hasFile("wire-result.json") && b.manager.workerPermissionWait(taskID: taskB.id) == false,
                "Permission wait: first exact actual approval was not ready or unrelated worker waited")
            // V02 original feature RED.
            let visibleProjectionA = a.manager.workerPermissionWait(taskID: taskA.id)
            check(gate.hasWaitingRequest(taskID: taskA.id) && visibleProjectionA == true,
                "Permission wait: visible actual task-owned approval projection unavailable")
            try release(b.root.appendingPathComponent("release-permission.json"))
            guard await reached({ gate.pending?.id == visibleA.id && gate.queuedCount == 1 && b.hasFile("permission-request.json") }) else { throw FixtureError.timeout }
            let queuedRowA = try a.sql.load().first { $0.id == taskA.id }
            let queuedRowB = try b.sql.load().first { $0.id == taskB.id }
            let queuedJournalA = try a.sql.journal(taskID: taskA.id)
            let queuedJournalB = try b.sql.journal(taskID: taskB.id)
            // Q01
            check(gate.pending?.id == visibleA.id && gate.pending?.taskID == taskA.id && gate.queuedCount == 1
                && gate.askCount == asksBefore + 2 && a.ended == 0 && b.ended == 0
                && !a.hasFile("wire-result.json") && !b.hasFile("wire-result.json")
                && object(b.root.appendingPathComponent("permission-request.json"))["taskID"] as? String == taskB.id
                && queuedJournalA.filter { $0.draft.kind == .permissionRequested }.count == 1
                && queuedJournalB.filter { $0.draft.kind == .permissionRequested }.count == 1,
                "Permission wait: second real typed request was not queued behind exact visible first")
            // Q02 original feature RED.
            let queuedProjectionA = a.manager.workerPermissionWait(taskID: taskA.id)
            check(gate.hasWaitingRequest(taskID: taskA.id) && queuedProjectionA == true,
                "Permission wait: active task was lost when another real request queued")
            // Q03 original feature RED.
            let queuedProjectionB = b.manager.workerPermissionWait(taskID: taskB.id)
            check(gate.hasWaitingRequest(taskID: taskB.id) && queuedProjectionB == true,
                "Permission wait: actual queued task-owned approval projection unavailable")
            // Q04 restored-only routing must remain unchanged.
            check(!gate.hasRestoredRequest(taskID: taskA.id) && !gate.hasRestoredRequest(taskID: taskB.id)
                && !gate.hasWaitingRequest(taskID: "missing-permission-wait")
                && queuedRowA?.status == .running && queuedRowB?.status == .running
                && queuedRowA?.durability?.runtimeClass == .acpWorker && queuedRowB?.durability?.runtimeClass == .acpWorker
                && queuedRowA?.durability?.heartbeatAt == oldProgress && queuedRowB?.durability?.heartbeatAt == oldProgress
                && queuedRowA?.durability?.lastProgressAt == oldProgress && queuedRowB?.durability?.lastProgressAt == oldProgress,
                "Permission wait: forty-day live approval was conflated with restored/state/progress policy")
            let beforeExportA = try Data(contentsOf: a.export)
            let beforeExportB = try Data(contentsOf: b.export)
            let beforeReceiptA = try Data(contentsOf: a.receiptFile)
            let beforeReceiptB = try Data(contentsOf: b.receiptFile)
            await TaskHeartbeatIntegrationSelfTest.sample(manager: a.manager, binding: bindingA,
                expectedPrimary: .accepted, expectedWait: true, expectedAge: "waitingOnPerson", check: check)
            await TaskHeartbeatIntegrationSelfTest.sample(manager: b.manager, binding: bindingB,
                expectedPrimary: .accepted, expectedWait: true, expectedAge: "waitingOnPerson", check: check)
            var repeatedWaiting = true
            for _ in 0..<24 {
                let sampleA = a.manager.workerPermissionWait(taskID: taskA.id)
                let sampleB = b.manager.workerPermissionWait(taskID: taskB.id)
                repeatedWaiting = repeatedWaiting && sampleA == true && sampleB == true
            }
            // Q05 original feature RED.
            check(repeatedWaiting, "Permission wait: repeated active/queued current projections unavailable")
            // Q06 no review(for:) call for queued B: that would construct mutable review state.
            check(try a.sql.load().first { $0.id == taskA.id } == queuedRowA
                && b.sql.load().first { $0.id == taskB.id } == queuedRowB
                && a.sql.journal(taskID: taskA.id) == queuedJournalA && b.sql.journal(taskID: taskB.id) == queuedJournalB
                && Data(contentsOf: a.export) == beforeExportA && Data(contentsOf: b.export) == beforeExportB
                && Data(contentsOf: a.receiptFile) == beforeReceiptA && Data(contentsOf: b.receiptFile) == beforeReceiptB
                && gate.pending?.id == visibleA.id && gate.queuedCount == 1
                && ToolCallReviewStore.shared.review(id: visibleA.id) == reviewA
                && PermissionGrantStore.shared.grants == grantsBefore && a.ended == 0 && b.ended == 0,
                "Permission wait: repeated metadata mutated exact row/journal/export/receipt/card/review/choice")
            try a.sql.withConnection { db in
                try TaskStore.exec(db, "CREATE TRIGGER reject_wait_decision BEFORE INSERT ON task_event WHEN NEW.kind='permissionApproved' BEGIN SELECT RAISE(ABORT,'owned decision rejection'); END")
            }
            let rejected = gate.respond(id: visibleA.id, approved: true, duration: .once)
            // D01 exact actual producer refusal, no Task cancellation substitute.
            check(!rejected && gate.pending?.id == visibleA.id && gate.queuedCount == 1
                && ToolCallReviewStore.shared.review(id: visibleA.id) == reviewA
                && a.manager.lastPersistenceResult == .sqlFailed
                && !a.hasFile("wire-result.json") && !b.hasFile("wire-result.json")
                && a.manager.workerBinding(taskID: taskA.id) == bindingA && b.manager.workerBinding(taskID: taskB.id) == bindingB,
                "Permission wait: real rejected primary decision did not retain exact active/queued waiters")
            // D02 original feature RED.
            let rejectedProjectionA = a.manager.workerPermissionWait(taskID: taskA.id)
            let rejectedProjectionB = b.manager.workerPermissionWait(taskID: taskB.id)
            check(gate.hasWaitingRequest(taskID: taskA.id) && gate.hasWaitingRequest(taskID: taskB.id)
                && rejectedProjectionA == true && rejectedProjectionB == true,
                "Permission wait: failed explicit decision erased current approval projection")
            // D03
            check(try a.sql.load().first { $0.id == taskA.id } == queuedRowA
                && b.sql.load().first { $0.id == taskB.id } == queuedRowB
                && a.sql.journal(taskID: taskA.id) == queuedJournalA && b.sql.journal(taskID: taskB.id) == queuedJournalB
                && PermissionGrantStore.shared.grants == grantsBefore && gate.askCount == asksBefore + 2,
                "Permission wait: refused decision changed task history/grants or invented another ask")
            try a.sql.withConnection { try TaskStore.exec($0, "DROP TRIGGER reject_wait_decision") }
            let accepted = gate.respond(id: visibleA.id, approved: true, duration: .once)
            guard let promotedB = gate.pending else { throw FixtureError.invalidPeer }
            requestB = promotedB
            let reviewB = ToolCallReviewStore.shared.review(for: promotedB)
            let operationTextB = promotedB.arguments["toolCall"] ?? ""
            let operationB = operationTextB.data(using: .utf8)
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }
            // P01 advance is synchronous before either worker resumes.
            check(accepted && promotedB.taskID == taskB.id && promotedB.id != visibleA.id && gate.queuedCount == 0
                && promotedB.arguments["taskID"] == nil && promotedB.arguments.keys.sorted() == ["toolCall"]
                && operationB == expectedOperation && promotedB.detail == operationTextB
                && reviewB.isReadyToRun && reviewB.blockers.isEmpty && reviewB.fields.map(\.name) == ["toolCall"]
                && !gate.hasWaitingRequest(taskID: taskA.id)
                && a.manager.workerPermissionWait(taskID: taskA.id) == false && a.ended == 0 && b.ended == 0,
                "Permission wait: genuine first response did not synchronously clear A/promote exact ready B")
            // P02 original feature RED.
            let promotedProjectionB = b.manager.workerPermissionWait(taskID: taskB.id)
            check(gate.hasWaitingRequest(taskID: taskB.id) && promotedProjectionB == true,
                "Permission wait: promoted actual queued waiter lost task-owned projection")
            // P03
            check(try a.sql.journal(taskID: taskA.id).filter { $0.draft.kind == .permissionApproved }.count == 1
                && b.sql.journal(taskID: taskB.id).filter { $0.draft.kind == .permissionApproved || $0.draft.kind == .permissionDenied }.isEmpty
                && PermissionGrantStore.shared.grants == grantsBefore,
                "Permission wait: promotion lost exact durable first approval or fabricated queued decision")
            // Real task-scoped Gate withdrawal, not Task cancellation or a synthetic context.
            gate.cancelPending(taskID: taskB.id)
            // C01 synchronous before resumed callback can finish its protocol.
            check(gate.pending == nil && gate.queuedCount == 0
                && !gate.hasWaitingRequest(taskID: taskA.id) && !gate.hasWaitingRequest(taskID: taskB.id)
                && a.manager.workerPermissionWait(taskID: taskA.id) == false
                && b.manager.workerPermissionWait(taskID: taskB.id) == false
                && a.manager.workerBinding(taskID: taskA.id) == bindingA
                && b.manager.workerBinding(taskID: taskB.id) == bindingB,
                "Permission wait: exact Gate cancellation retained current wait or pretended worker release")
            guard await reached({ a.hasFile("wire-result.json") && b.hasFile("wire-result.json") }) else { throw FixtureError.timeout }
            let wireA = object(a.root.appendingPathComponent("wire-result.json"))
            let wireB = object(b.root.appendingPathComponent("wire-result.json"))
            let resultA = wireA["result"] as? [String: Any] ?? [:]
            let resultB = wireB["result"] as? [String: Any] ?? [:]
            // C02 real owned protocol receives actual decision/cancellation without effects.
            check(resultA["outcome"] as? [String: String] == ["outcome": "selected", "optionId": "fixture-allow-once"]
                && resultB["outcome"] as? [String: String] == ["outcome": "selected", "optionId": "fixture-reject-once"]
                && resultA["optionId"] == nil && resultB["optionId"] == nil
                && wireA["replyCount"] as? Int == 1 && wireB["replyCount"] as? Int == 1
                && wireA["externalEffectCount"] as? Int == 0 && wireB["externalEffectCount"] as? Int == 0,
                "Permission wait: actual peer did not receive exactly one genuine approval/withdrawal reply")
            let afterDecisionJournalA = try a.sql.journal(taskID: taskA.id)
            let afterDecisionJournalB = try b.sql.journal(taskID: taskB.id)
            // C03 cancellation's notApproved records withdrawal, not a human denial claim.
            check(afterDecisionJournalA.filter { $0.draft.kind == .permissionRequested }.count == 1
                && afterDecisionJournalA.filter { $0.draft.kind == .permissionApproved }.count == 1
                && !afterDecisionJournalA.contains { $0.draft.kind == .permissionDenied }
                && afterDecisionJournalB.filter { $0.draft.kind == .permissionRequested }.count == 1
                && afterDecisionJournalB.filter { $0.draft.kind == .permissionDenied && $0.draft.detail == "notApproved" }.count == 1
                && !afterDecisionJournalB.contains { $0.draft.kind == .permissionApproved }
                && a.ended == 0 && b.ended == 0,
                "Permission wait: real exact decision/withdrawal admission was duplicated or lost")
            try release(a.root.appendingPathComponent("release-result.json"))
            try release(b.root.appendingPathComponent("release-result.json"))
            guard await reached({ a.ended == 1 && b.ended == 1 }) else { throw FixtureError.timeout }
            let finalRowA = try a.sql.load().first { $0.id == taskA.id }
            let finalRowB = try b.sql.load().first { $0.id == taskB.id }
            let finalReceiptA = ActionReceiptStore(fileURL: a.receiptFile).receipts.first
            let finalReceiptB = ActionReceiptStore(fileURL: b.receiptFile).receipts.first
            let warning = "\nNext Notes could not independently verify the effect. Inspect the target before retrying."
            // F01
            check(a.entered == 1 && b.entered == 1 && a.ended == 1 && b.ended == 1
                && a.manager.workerBinding(taskID: taskA.id) == nil && b.manager.workerBinding(taskID: taskB.id) == nil
                && a.manager.workerPermissionWait(taskID: taskA.id) == nil
                && b.manager.workerPermissionWait(taskID: taskB.id) == nil,
                "Permission wait: actual released workers retained a current approval sample")
            // F02
            check(finalRowA?.status == .completed && finalRowB?.status == .completed
                && finalRowA?.result == a.marker + warning && finalRowB?.result == b.marker + warning
                && a.announcements.contains(a.marker + warning) && b.announcements.contains(b.marker + warning)
                && finalRowA?.durability?.receiptIDs == [firedA.actionID.uuidString]
                && finalRowB?.durability?.receiptIDs == [firedB.actionID.uuidString],
                "Permission wait: actual harmless original task/result consumers did not complete truthfully")
            // F03
            check(finalReceiptA?.actionID == firedA.actionID && finalReceiptB?.actionID == firedB.actionID
                && finalReceiptA?.preparedAction == firedA.preparedAction && finalReceiptB?.preparedAction == firedB.preparedAction
                && finalReceiptA?.status == .couldNotVerify && finalReceiptB?.status == .couldNotVerify
                && finalReceiptA?.result == a.marker && finalReceiptB?.result == b.marker,
                "Permission wait: real retained exact fired/terminal receipt evidence was substituted")
            contextA.observeACPSession?(ACPSession())
            contextB.observeACPSession?(ACPSession())
            // F04
            check(a.manager.workerPermissionWait(taskID: taskA.id) == nil
                && b.manager.workerPermissionWait(taskID: taskB.id) == nil
                && !gate.hasWaitingRequest(taskID: taskA.id) && !gate.hasWaitingRequest(taskID: taskB.id)
                && contextA.isStillValid?() == false && contextB.isStillValid?() == false,
                "Permission wait: retained released contexts manufactured current waits or live bindings")
            // F05
            check(object(a.root.appendingPathComponent("calls.json"))["methods"] as? [String] == ["initialize", "session/new", "session/prompt"]
                && object(b.root.appendingPathComponent("calls.json"))["methods"] as? [String] == ["initialize", "session/new", "session/prompt"]
                && object(a.root.appendingPathComponent("launch.json"))["launchCount"] as? Int == 1
                && object(b.root.appendingPathComponent("launch.json"))["launchCount"] as? Int == 1
                && !a.hasFile("peer-error.json") && !b.hasFile("peer-error.json"),
                "Permission wait: owned peer restarted, errored or substituted Task cancellation")
            ToolCallReviewStore.shared.remove(id: visibleA.id)
            ToolCallReviewStore.shared.remove(id: promotedB.id)
            SelfTest.diagnostic("TASK_ACP_PERMISSION_WAIT_TRACE: visibleA=\(visibleProjectionA?.description ?? "unknown") queuedA=\(queuedProjectionA?.description ?? "unknown") queuedB=\(queuedProjectionB?.description ?? "unknown") rejectedA=\(rejectedProjectionA?.description ?? "unknown") rejectedB=\(rejectedProjectionB?.description ?? "unknown") promotedB=\(promotedProjectionB?.description ?? "unknown") releasedA=\(a.manager.workerPermissionWait(taskID: taskA.id) == nil) releasedB=\(b.manager.workerPermissionWait(taskID: taskB.id) == nil) oldProgress=\(oldProgress.timeIntervalSince1970) asks=\(gate.askCount - asksBefore) entries=\(a.entered + b.entered) exits=\(a.ended + b.ended)")
        } catch {
            try? a.sql.withConnection { try TaskStore.exec($0, "DROP TRIGGER IF EXISTS reject_wait_decision") }
            try? release(a.root.appendingPathComponent("release-permission.json"))
            try? release(b.root.appendingPathComponent("release-permission.json"))
            try? release(a.root.appendingPathComponent("release-result.json"))
            try? release(b.root.appendingPathComponent("release-result.json"))
            gate.cancelPending(taskID: taskA.id)
            gate.cancelPending(taskID: taskB.id)
            if a.ended == 0 { a.manager.cancel(taskA.id) }
            if b.ended == 0 { b.manager.cancel(taskB.id) }
            let drained = await reached { a.ended == 1 && b.ended == 1 }
            check(drained, "Permission wait: error cleanup failed to drain exact two owned workers")
            if let requestA { ToolCallReviewStore.shared.remove(id: requestA.id) }
            if let requestB { ToolCallReviewStore.shared.remove(id: requestB.id) }
            throw error
        }
        // O01
        check(gate.pending == nil && gate.queuedCount == 0 && gate.askCount == asksBefore + 2
            && PermissionGrantStore.shared.grants == grantsBefore && unexpectedTools == 0,
            "Permission wait: fixture changed Gate/grants or ran external backing")
    }

    private static let peer = #"""
        import json, pathlib, sys, tempfile, time

        root = pathlib.Path(__file__).resolve().parent
        temporary = pathlib.Path(tempfile.gettempdir()).resolve()
        assert root != temporary and temporary in root.parents
        assert 'Application Support' not in root.parts
        config = json.loads((root / 'config.json').read_text())
        session = 'fixture-acp-permission-wait'
        methods = []
        prompt_id = None
        options = [
            {'optionId': 'fixture-allow-once', 'name': 'Allow once', 'kind': 'allow_once'},
            {'optionId': 'fixture-reject-once', 'name': 'Reject', 'kind': 'reject_once'}
        ]

        def write(name, value):
            tmp = root / (name + '.tmp')
            tmp.write_text(json.dumps(value, sort_keys=True))
            tmp.replace(root / name)

        def send(value):
            sys.stdout.write(json.dumps(value) + '\n')
            sys.stdout.flush()

        def wait(name):
            deadline = time.monotonic() + 12
            while not (root / name).exists():
                if time.monotonic() >= deadline:
                    raise TimeoutError('owned release barrier')
                time.sleep(0.005)
            assert json.loads((root / name).read_text()) == {'release': True}

        def main():
            global prompt_id
            assert not (root / 'launch.json').exists()
            write('launch.json', {'launchCount': 1})
            for line in sys.stdin:
                message = json.loads(line)
                mid, method = message.get('id'), message.get('method')
                if method is not None:
                    methods.append(method)
                    write('calls.json', {'methods': methods})
                if method == 'initialize':
                    send({'jsonrpc': '2.0', 'id': mid, 'result': {'protocolVersion': 1, 'agentCapabilities': {}}})
                elif method == 'session/new':
                    send({'jsonrpc': '2.0', 'id': mid, 'result': {'sessionId': session}})
                elif method == 'session/prompt':
                    assert prompt_id is None and message['params']['sessionId'] == session
                    assert message['params']['prompt'][0]['text'] == config['objective']
                    prompt_id = mid
                    write('prompt-observed.json', {'taskID': config['taskID'], 'sessionID': session, 'promptCount': 1})
                    wait('release-permission.json')
                    write('permission-request.json', {'taskID': config['taskID'], 'sessionID': session, 'requestID': 900, 'options': options})
                    send({'jsonrpc': '2.0', 'id': 900, 'method': 'session/request_permission', 'params': {
                        'sessionId': session, 'toolCall': {'toolCallId': 'owned-wait-only',
                            'title': 'Owned fixture review only', 'kind': 'other', 'status': 'pending'}, 'options': options}})
                elif method is None and mid == 900:
                    assert prompt_id is not None and not (root / 'wire-result.json').exists()
                    write('wire-result.json', {'result': message.get('result', {}), 'replyCount': 1, 'externalEffectCount': 0})
                    wait('release-result.json')
                    send({'jsonrpc': '2.0', 'method': 'session/update', 'params': {'sessionId': session,
                        'update': {'sessionUpdate': 'agent_message_chunk', 'content': {'type': 'text', 'text': config['marker']}}}})
                    send({'jsonrpc': '2.0', 'id': prompt_id, 'result': {'stopReason': 'end_turn'}})
                elif method == 'session/cancel':
                    send({'jsonrpc': '2.0', 'id': mid, 'result': {}})
                else:
                    raise ValueError('unexpected owned protocol message')

        try:
            main()
        except Exception as error:
            write('peer-error.json', {'errorClass': type(error).__name__})
            raise
        """#
}

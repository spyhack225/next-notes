import Foundation
import SQLite3

/// Actual producer/store/reopen/card and rejected callback proof. Only the external
/// effect may be replaced by an installed wrapper; fixtures never use owner history.
@MainActor
enum TaskRestorationSelfTest {
    static func run() async -> String {
        guard SelfTest.isRunning else { return "TASK_RESTORATION_FAILED: harness required" }
        let before = SelfTestStoreGuard.take()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NextNotesTaskRestoration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var failures: [String] = []
        var cases = 0
        func check(_ value: Bool, _ message: String) { if !value { failures.append(message) } }
        guard PermissionGate.shared.pending == nil else {
            return "TASK_RESTORATION_FAILED: fixture refused to replace an existing card"
        }
        defer { PermissionGate.shared.cancelPending() }
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        func running(_ id: String, backend: String = "local", source: String = "text") -> AgentTask {
            AgentTask(id: id, objective: "Write the approved fixture note", source: source,
                createdAt: date, status: .running, progress: "Original fixture progress",
                tool: "filesystem.write", arguments: ["path": "/fixture/original.md", "content": "Original fixture content"],
                backend: backend)
        }
        func request(_ task: AgentTask, id: String = "original-request") -> PermissionRequest {
            PermissionRequest(id: id, toolID: "filesystem.write", title: "Save fixture note",
                detail: "Original fixture detail", risk: .modify,
                arguments: ["path": "/fixture/original.md", "content": "Original fixture content", "_authorizationPin": "original fixture pin"],
                scope: PermissionScope(kind: .path, value: "/fixture/original.md"),
                taskID: task.id, createdAt: date, trigger: .youSaid("Write the approved fixture note"))
        }
        func fixture(_ name: String) throws -> (AgentTaskStore, TaskStore, AgentTaskManager) {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            let sql = TaskStore(root: folder)
            let store = AgentTaskStore(fileURL: folder.appendingPathComponent("agent-tasks.json"), mirror: sql)
            guard store.allowsHarnessPersistence else { throw TaskStoreError.invalidRecord }
            return (store, sql, AgentTaskManager(store: store))
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            let (store, sql, manager) = try fixture("permission")
            defer { sql.close() }
            let original = running("restoration-original")
            manager.beginScheduledRun(original) // Existing record-only seam; never dispatches.
            let frozen = request(original)
            let origin = ActionOriginContext(transport: .appUI)
            check(manager.parkPermission(frozen, origin: origin), "original request producer did not commit")
            check(manager.task(id: original.id)?.pendingInteraction == .permission(request: frozen, origin: origin),
                "producer discarded the original request, source or authorization pin")
            check(try sql.load() == manager.tasks, "exact request never reached the primary consumer")
            cases += 1
            let restarted = AgentTaskManager(store: AgentTaskStore(fileURL: store.storageURL, mirror: sql))
            restarted.restorePendingInteractions()
            check(PermissionGate.shared.pending == frozen,
                "fresh manager retained a waiting approval but produced no exact card for its actual consumer")
            check(PermissionGate.shared.pendingReview?.trigger == frozen.trigger,
                "actual review consumer lost original request provenance")
            check(restarted.backendStartsForTesting == 0 && !restarted.consumePermissionApproval(taskID: original.id),
                "restart dispatched unknown work or restored a one-shot grant")
            restarted.restorePendingInteractions()
            check(PermissionGate.shared.queuedCount == 0, "repeat restoration duplicated an existing card")
            cases += 1
            let saved = try sql.load()
            try sql.withConnection { try TaskStore.exec($0,
                "CREATE TRIGGER reject_restoration BEFORE UPDATE ON task BEGIN SELECT RAISE(ABORT,'fixture'); END") }
            check(!restarted.respondRestoredPermission(taskID: original.id, requestID: "stale-request", approved: true,
                arguments: frozen.arguments), "stale request id was accepted")
            check(!restarted.respondRestoredPermission(taskID: original.id, requestID: frozen.id, approved: true,
                arguments: frozen.arguments), "rejected primary commit supplied a one-shot approval")
            check(try restarted.tasks == saved && sql.load() == saved && PermissionGate.shared.pending == frozen
                && restarted.backendStartsForTesting == 0 && !restarted.consumePermissionApproval(taskID: original.id),
                "failed callback changed committed history, lost the live card or dispatched")
            cases += 1
            try sql.withConnection { try TaskStore.exec($0, "DROP TRIGGER reject_restoration") }
            PermissionGate.shared.cancelPending()

            let (inputStore, inputSQL, inputManager) = try fixture("input")
            defer { inputSQL.close() }
            let inputTask = running("input-original")
            inputManager.beginScheduledRun(inputTask)
            check(inputManager.requestInput(taskID: inputTask.id, question: "Which original fixture folder should I use?"),
                "input producer did not commit the original question")
            let inputRestart = AgentTaskManager(store: AgentTaskStore(fileURL: inputStore.storageURL, mirror: inputSQL))
            let question = inputRestart.pendingInputs.first
            check(question?.taskID == inputTask.id && question?.question == "Which original fixture folder should I use?"
                && inputRestart.pendingInputs.count == 1 && inputRestart.backendStartsForTesting == 0,
                "restart lost or fabricated the original input question")
            check(try inputSQL.load() == inputRestart.tasks, "original question did not reach primary history")
            cases += 1
            if let question {
                let retained = inputRestart.tasks
                check(!inputRestart.respondInput(taskID: inputTask.id, text: "Fixture answer", requestID: "stale"),
                    "stale input card changed task state")
                try inputSQL.withConnection { try TaskStore.exec($0,
                    "CREATE TRIGGER reject_input BEFORE UPDATE ON task BEGIN SELECT RAISE(ABORT,'fixture'); END") }
                check(!inputRestart.respondInput(taskID: inputTask.id, text: "Fixture answer", requestID: question.id),
                    "input callback accepted an uncommitted answer")
                check(try inputRestart.tasks == retained && inputSQL.load() == retained && inputRestart.pendingInputs == [question]
                    && inputRestart.backendStartsForTesting == 0, "failed input save hid the exact question or dispatched")
                cases += 1
            }

            let (rejectStore, rejectSQL, rejectManager) = try fixture("rejected-producer")
            defer { rejectSQL.close() }
            let rejectTask = running("rejected-producer")
            rejectManager.beginScheduledRun(rejectTask)
            try rejectSQL.withConnection { try TaskStore.exec($0,
                "CREATE TRIGGER reject_park BEFORE UPDATE ON task BEGIN SELECT RAISE(ABORT,'fixture'); END") }
            check(!rejectManager.parkPermission(request(rejectTask)), "uncommitted permission became a card-bearing state")
            check(try rejectManager.tasks == [rejectTask] && rejectSQL.load() == [rejectTask],
                "rejected request producer overwrote the saved task or exposed phantom state")
            cases += 1
            let failedRestart = AgentTaskManager(store: AgentTaskStore(fileURL: rejectStore.storageURL, mirror: rejectSQL))
            check(failedRestart.tasks == [rejectTask] && failedRestart.historyReadFailure != nil
                && failedRestart.lastPersistenceResult == .sqlFailed && failedRestart.backendStartsForTesting == 0,
                "uncommitted launch decision was treated as durable recovery")
            failedRestart.restorePendingInteractions()
            check(PermissionGate.shared.pending == nil && failedRestart.pendingInputs.isEmpty,
                "uncommitted launch presented a restored request")
            cases += 1

            for kind in ["legacy-permission", "legacy-input", "acp-nested", "remote", "voice", "scheduled"] {
                let (legacyStore, legacySQL, _) = try fixture(kind)
                defer { legacySQL.close() }
                var task = running(kind)
                task.status = kind == "legacy-input" ? .waitingForInput : .waitingForPermission
                if kind == "acp-nested" { task.backend = "acp" }
                if kind == "remote" { task.source = "iMessage" }
                if kind == "voice" { task.source = "voice" }
                if kind == "scheduled" { task.source = AgentTask.scheduledSource; task.scheduleID = UUID() }
                if !kind.hasPrefix("legacy") {
                    task.pendingInteraction = .permission(request: request(task),
                        origin: kind == "remote" ? ActionOriginContext(transport: .iMessage) : nil)
                }
                check(legacyStore.save([task]).primaryCommitted, "uncertain fixture did not save")
                let fresh = AgentTaskManager(store: AgentTaskStore(fileURL: legacyStore.storageURL, mirror: legacySQL))
                fresh.restorePendingInteractions()
                fresh.respondPermission(taskID: task.id, approved: true)
                _ = fresh.respondInput(taskID: task.id, text: "Fixture stale answer")
                check(fresh.tasks == [task] && fresh.pendingInputs.isEmpty && PermissionGate.shared.pending == nil
                    && fresh.backendStartsForTesting == 0 && !fresh.consumePermissionApproval(taskID: task.id),
                    "uncertain or independently owned work acquired local replay: \(kind)")
                cases += 1
            }
            let (compatibilityStore, compatibilitySQL, _) = try fixture("compatibility")
            defer { compatibilitySQL.close() }
            var compatibility = running("compatibility", backend: "acp")
            compatibility.status = .waitingForCompatibilityCLI
            compatibility.compatibilityCLI = "/usr/bin/true"
            compatibility.compatibilityCommand = ACPCompatibilityCLIBackend.commandLine(cli: "/usr/bin/true", objective: compatibility.objective)
            check(compatibilityStore.save([compatibility]).primaryCommitted, "compatibility fixture did not save")
            let compatibilityRestart = AgentTaskManager(store: AgentTaskStore(fileURL: compatibilityStore.storageURL, mirror: compatibilitySQL))
            check(compatibilityRestart.tasks == [compatibility] && ACPCompatibilityCLIBackend.request(for: compatibility) != nil
                && compatibilityRestart.backendStartsForTesting == 0
                && !compatibilityRestart.hasCompatibilityApprovalForTesting(taskID: compatibility.id),
                "compatibility restart changed the frozen command or reused a one-shot token")
            cases += 1
        } catch { failures.append("isolated fixture failed: \(error)") }
        failures += SelfTestStoreGuard.diff(before, SelfTestStoreGuard.take()).map { "owner changed: \($0)" }
        for failure in failures { SelfTest.diagnostic("TASK_RESTORATION_WRONG: \(failure)") }
        return failures.isEmpty ? "TASK_RESTORATION_OK: \(cases) cases" : "TASK_RESTORATION_FAILED: \(failures.count) assertions"
    }
}

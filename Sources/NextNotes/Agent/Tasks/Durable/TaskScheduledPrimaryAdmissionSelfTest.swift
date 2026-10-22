import Foundation

/// SAME ScheduledRunner + Live recorder + Manager + real isolated file backing.
/// Scripted model proves dispatch/admission, not cloud/native model health.
@MainActor
enum TaskScheduledPrimaryAdmissionSelfTest {
    private enum InputError: Error { case unsafe, exportBoundary, unexpectedTool }

    private final class Environment: ScheduledRunEnvironment {
        let manager: AgentTaskManager
        let input: URL
        var calls = 0
        var firstSave: AgentTaskPersistenceResult?
        init(manager: AgentTaskManager, input: URL) { self.manager = manager; self.input = input }
        var isRecording: Bool { false }
        func localModelState() async -> MemoryReviewLocalState { .unavailable }
        func isCloudConfigured() async -> Bool { true }
        func isAppleFoundationAvailable() async -> Bool { false }
        func model(for route: RoutineModelRoute) async -> (any MemoryReviewModel)? { Model(owner: self) }
        func answer() -> String {
            calls += 1
            if calls == 1 {
                firstSave = manager.lastPersistenceResult
                return RoutineAuthoritySelfTest.call("filesystem.read", ["path": input.path])
            }
            return "Owned scheduled read complete."
        }
    }
    private struct Model: MemoryReviewModel {
        let owner: Environment
        var label: String { "owned admission fixture" }
        func complete(system: String, user: String) async throws -> String { await owner.answer() }
    }
    private final class Tools: ScheduledToolRunning {
        let manager: AgentTaskManager
        let receipts: ActionReceiptStore
        let live = LiveScheduledToolRunner()
        var calls = 0
        init(manager: AgentTaskManager, receipts: ActionReceiptStore) { self.manager = manager; self.receipts = receipts }
        func read(_ tool: AgentTool, arguments: [String: String], authority: ActionAuthority,
                  taskID: String) async throws -> AgentToolResult {
            calls += 1
            // This existing scheduled owner remains unbound. Capture its existing context
            // only to keep the receipt store isolated; it creates no worker or attempt.
            guard let context = manager.journalContext(taskID: taskID),
                  context.receiptStore === receipts else { throw InputError.unexpectedTool }
            return try await TaskEventJournal.$current.withValue(context) {
                try await live.read(tool, arguments: arguments, authority: authority, taskID: taskID)
            }
        }
    }

    static func originalCases(root: URL, input: URL, text: String,
                              check: (Bool, String) -> Void) async throws {
        let safe = root.standardizedFileURL.resolvingSymlinksInPath()
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard SelfTest.isRunning, safe.path.hasPrefix(temporary.path + "/"),
              input.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(safe.path + "/"),
              !safe.pathComponents.contains("Application Support") else { throw InputError.unsafe }
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
        let gate = PermissionGate.shared
        guard gate.pending == nil && gate.queuedCount == 0 else { throw InputError.unsafe }
        let grants = PermissionGrantStore.shared.grants
        for mode in ["accepted", "sql-rejected", "export-failed"] {
            let directory = safe.appendingPathComponent("scheduled-admission-" + mode, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let sql = TaskStore(root: directory); defer { sql.close() }
            let export = directory.appendingPathComponent("agent-tasks.json")
            let store = AgentTaskStore(fileURL: export, mirror: sql)
            guard store.allowsHarnessPersistence, store.save([]).primaryCommitted else { throw InputError.unsafe }
            let receiptURL = directory.appendingPathComponent("action-receipts.json")
            let receipts = ActionReceiptStore(fileURL: receiptURL)
            let manager = AgentTaskManager(store: store, receiptStore: receipts)
            let environment = Environment(manager: manager, input: input)
            let tools = Tools(manager: manager, receipts: receipts)
            let recorder = LiveScheduledRunRecorder(taskManager: manager)
            let schedules = ScheduleStore(directory: directory.appendingPathComponent("schedules"))
            let runner = ScheduledRunner(store: schedules, environment: environment,
                tools: tools, recorder: recorder,
                personaStore: PersonaStore(directory: directory, isEnabled: { false }),
                memorySnapshot: MemorySnapshotCache(isEnabled: { false }),
                timeZone: { TimeZone(secondsFromGMT: 0)! })
            var effects = 0
            AgentToolExecutor.fireOverrideForTesting = { tool, arguments in
                guard tool.id == "filesystem.read", arguments == ["path": input.path] else { throw InputError.unexpectedTool }
                effects += 1
                return try FilesystemExecutor.run(tool, arguments: arguments)
            }
            if mode == "sql-rejected" {
                try sql.withConnection { try TaskStore.exec($0,
                    "CREATE TRIGGER reject_scheduled_creation BEFORE INSERT ON task_event WHEN NEW.kind='jobCreated' BEGIN SELECT RAISE(ABORT,'owned scheduled admission refusal'); END") }
            }
            var exportRefused = 0
            if mode == "export-failed" {
                store.migrationBoundaryForTesting = { phase in
                    if phase == "primaryCommitted", exportRefused == 0 {
                        exportRefused += 1
                        throw InputError.exportBoundary
                    }
                }
            }
            let primaryBefore = try sql.load()
            let exportBefore = try Data(contentsOf: export)
            let auditBefore = AgentAuditLog.shared.entries
            let inputBefore = try Data(contentsOf: input)
            var schedule = RoutineAuthoritySelfTest.routine(tools: ["filesystem.read"], model: .cloud, id: UUID())
            schedule.title = "Owned scheduled admission"
            schedule.prompt = "Read the owned temporary fixture once."
            let outcome = await runner.run(schedule, now: Date(timeIntervalSince1970: 1_700_000_000))
            store.migrationBoundaryForTesting = nil
            let rows = try sql.load()
            let ownAudits = AgentAuditLog.shared.entries.filter { $0.taskID == outcome.taskID }
            let rejected = mode == "sql-rejected"
            check(manager.historyReadFailure == nil && primaryBefore.isEmpty && store.allowsHarnessPersistence,
                "scheduled admission C01 original isolated marked primary unavailable (\(mode))")
            check((!rejected || environment.firstSave == .sqlFailed || manager.lastPersistenceResult == .sqlFailed)
                && (mode != "export-failed" || exportRefused == 1 && environment.firstSave == .exportFailed),
                "scheduled admission C02 actual SQL/export refusal did not qualify (\(mode))")
            check(try Data(contentsOf: input) == inputBefore && String(data: inputBefore, encoding: .utf8) == text,
                "scheduled admission C03 original temporary input changed (\(mode))")
            check(gate.pending == nil && gate.queuedCount == 0 && PermissionGrantStore.shared.grants == grants
                && manager.tasks.allSatisfy { manager.workerBinding(taskID: $0.id) == nil },
                "scheduled admission C04 invented grants/worker/periodic authority (\(mode))")
            if rejected {
                check(environment.calls == 0, "scheduled admission F01 rejected primary still invoked model.complete")
                check(tools.calls == 0 && effects == 0, "scheduled admission F02 rejected primary still dispatched actual read")
                check(ownAudits.isEmpty && AgentAuditLog.shared.entries == auditBefore,
                    "scheduled admission F03 rejected primary emitted started/success audit")
                check(try manager.tasks.isEmpty && sql.load() == primaryBefore && Data(contentsOf: export) == exportBefore,
                    "scheduled admission F04 rejected creation retained/published unsaved task")
                check(receipts.receipts.isEmpty && !FileManager.default.fileExists(atPath: receiptURL.path),
                    "scheduled admission F05 rejected primary still prepared/fired receipt")
                check(outcome.status == .failed && outcome.drafts.isEmpty && outcome.text == "This run couldn’t be saved. It wasn’t started.",
                    "scheduled admission F06 rejected creation delivered successful scheduled result")
            } else {
                check(environment.calls == 2 && tools.calls == 1 && effects == 1,
                    "scheduled admission C05 accepted existing model/tool behavior changed (\(mode))")
                check(rows.count == 1 && manager.tasks.count == 1 && rows.first?.id == outcome.taskID
                    && rows.first?.source == AgentTask.scheduledSource && rows.first?.scheduleID == schedule.id,
                    "scheduled admission C06 exact same canonical scheduled task lost (\(mode))")
                check(outcome.status == .reported && outcome.text == "Owned scheduled read complete."
                    && rows.first?.status == .completed && rows.first?.result == outcome.text,
                    "scheduled admission C07 accepted existing result changed (\(mode))")
                check(receipts.receipts.count == 1 && receipts.receipts.first?.status == .completed
                    && receipts.receipts.first?.taskID == outcome.taskID
                    && receipts.receipts.first?.authority == .scheduled(schedule.id),
                    "scheduled admission C08 actual scheduled receipt/authority lost (\(mode))")
                check(ownAudits.count == 3 && ownAudits.allSatisfy { $0.scheduleID == schedule.id },
                    "scheduled admission C09 actual start/read/finish audit lost (\(mode))")
                check(try sql.journal(taskID: outcome.taskID ?? "").first?.draft.kind == .jobCreated
                    && sql.journal(taskID: outcome.taskID ?? "").contains { $0.draft.kind == .jobCompleted },
                    "scheduled admission C10 accepted canonical event chain lost (\(mode))")
            }
            SelfTest.diagnostic("SCHEDULED_ADMISSION_TRACE: mode=\(mode) modelCalls=\(environment.calls) toolCalls=\(tools.calls) backingCalls=\(effects) rows=\(rows.count) receipts=\(receipts.receipts.count) audits=\(ownAudits.count) exportRefused=\(exportRefused)")
        }
    }
}

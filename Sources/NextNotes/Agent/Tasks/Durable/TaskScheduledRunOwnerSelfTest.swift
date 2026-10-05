import Foundation

/// Actual scheduler → SAME ScheduledRunner → real per-run Task → Manager/runtime/read.
/// Scripted completion is an application-await boundary, never native/model health.
@MainActor
enum TaskScheduledRunOwnerSelfTest {
    private enum InputError: Error { case unsafe, timeout, unexpected }
    private static func reached(_ predicate: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while ContinuousClock.now < deadline {
            if predicate() { return true }; await Task.yield()
        }
        return predicate()
    }
    private final class ModelEnvironment: ScheduledRunEnvironment {
        let manager: AgentTaskManager
        let input: URL
        var started: [String] = []
        var ended: [String] = []
        var calls: [String: Int] = [:]
        var activeCalls = 0
        var returnedCalls = 0
        var contexts: [String: TaskJournalContext] = [:]
        var aTaskID: String?
        var bSawAReleased = false
        var held: CheckedContinuation<Void, Never>?
        var released = false
        var throwsA = false
        init(manager: AgentTaskManager, input: URL) { self.manager = manager; self.input = input }
        var isRecording: Bool { false }
        func localModelState() async -> MemoryReviewLocalState { .unavailable }
        func isCloudConfigured() async -> Bool { true }
        func model(for route: RoutineModelRoute) async -> (any MemoryReviewModel)? { Model(owner: self) }
        func answer(user: String) async throws -> String {
            activeCalls += 1
            defer { activeCalls -= 1; returnedCalls += 1 }
            let key = user.contains("Owned owner A") ? "A" : "B"
            calls[key, default: 0] += 1
            let count = calls[key]!
            if count == 1 {
                started.append(key)
                if let context = TaskEventJournal.current { contexts[key] = context }
                if key == "A" {
                    aTaskID = manager.tasks.first { $0.objective == "Owned owner A" }?.id
                    await withCheckedContinuation { held = $0 }
                    try Task.checkCancellation()
                    if throwsA { throw InputError.unexpected }
                } else if let aTaskID { bSawAReleased = manager.retainsScheduledRunOwnerForTesting(taskID: aTaskID) == false }
                return RoutineAuthoritySelfTest.call("filesystem.read", ["path": input.path])
            }
            ended.append(key)
            return "Owned owner \(key) complete."
        }
        func release() { released = true; let continuation = held; held = nil; continuation?.resume() }
    }
    private struct Model: MemoryReviewModel {
        let owner: ModelEnvironment
        var label: String { "owned routine operation" }
        func complete(system: String, user: String) async throws -> String { try await owner.answer(user: user) }
    }
    private final class Tools: ScheduledToolRunning {
        let manager: AgentTaskManager; let receipts: ActionReceiptStore
        let live = LiveScheduledToolRunner()
        var taskIDs: [String] = []
        var activeCalls = 0
        init(manager: AgentTaskManager, receipts: ActionReceiptStore) { self.manager = manager; self.receipts = receipts }
        func read(_ tool: AgentTool, arguments: [String: String], authority: ActionAuthority,
                  taskID: String) async throws -> AgentToolResult {
            taskIDs.append(taskID)
            activeCalls += 1
            defer { activeCalls -= 1 }
            // Original remains genuinely unbound; only confine the SAME receipt owner.
            guard let context = TaskEventJournal.current ?? manager.journalContext(taskID: taskID),
                  context.taskID == taskID, context.receiptStore === receipts else { throw InputError.unexpected }
            return try await TaskEventJournal.$current.withValue(context) {
                try await live.read(tool, arguments: arguments, authority: authority, taskID: taskID)
            }
        }
    }
    private final class ScheduleEnvironmentValue: ScheduleEnvironment {
        let isUserPresent = true; let isRecording = false; let isDictating = false
        let isCallActive = false; let isAgentBusy = false
    }
    private final class System: ReminderSystemRegistering {
        func register(_ schedule: AgentSchedule, slot: Date) async -> Bool { false }
        func withdraw(scheduleID: UUID) {}
        func pendingScheduleIDs() async -> Set<UUID> { [] }
        func isAuthorized() async -> Bool { false }
    }
    private final class Delivery: ScheduleDelivering {
        var delivered: [String] = []
        func deliver(_ value: ScheduleDelivery) async throws { delivered.append(value.body) }
        func notifyProblem(scheduleID: UUID, title: String, body: String) { delivered.append("unexpected problem") }
        func notifyDrafts(_ drafts: [RoutineDraft], scheduleTitle: String) { delivered.append("unexpected drafts") }
        func openSchedules() { delivered.append("unexpected open") }
        func speak(_ text: String) { delivered.append("unexpected speak") }
    }


    static func islandBackgroundCase(root: URL, input: URL, manager: AgentTaskManager,
                                     receipts: ActionReceiptStore,
                                     didDrain: () -> Void, check: (Bool, String) -> Void) async throws {
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-island",
              AgentCaptureController.shared.isSessionActive,
              VoiceSession.shared.state.island == .thinking,
              root.path == root.resolvingSymlinksInPath().standardizedFileURL.path,
              input.deletingLastPathComponent().path == root.path else { throw InputError.unsafe }
        let directory = root.appendingPathComponent("schedule", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let environment = ModelEnvironment(manager: manager, input: input)
        let tools = Tools(manager: manager, receipts: receipts)
        let schedules = ScheduleStore(directory: directory)
        let runner = ScheduledRunner(store: schedules, environment: environment, tools: tools,
            recorder: LiveScheduledRunRecorder(taskManager: manager),
            personaStore: PersonaStore(directory: directory, isEnabled: { false }),
            memorySnapshot: MemorySnapshotCache(isEnabled: { false }), timeZone: { TimeZone(secondsFromGMT: 0)! })
        let delivery = Delivery()
        let scheduler = AgentScheduler(store: schedules, system: System(), deliverer: delivery,
            environment: ScheduleEnvironmentValue(),
            settings: { ScheduleSettingsSnapshot(enabled: true, quietStart: nil, quietEnd: nil, speech: .never) },
            runner: runner, events: AgentTriggerEvents(), heartbeatTaskManager: manager)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var schedule = AgentSchedule(id: UUID(), kind: .routine, title: "Owned owner A",
            plainEnglish: "Read the owned document once.", prompt: "Owned owner A",
            when: ScheduleWhen(repeatRule: .once(now), time: ScheduleLocalTime(hour: 0, minute: 0), timeZone: "UTC"),
            allowedTools: ["filesystem.read"], model: .cloud, delivery: .notify, budget: .standard, createdAt: now)
        schedule.nextRunAt = now
        guard schedules.save(schedule) else { throw InputError.unsafe }
        var caught: Error?
        let before = IslandOwnership.rejected.values.reduce(0, +)
        do {
            await scheduler.runTick(now: now)
            guard await reached({ environment.held != nil }), let id = environment.aTaskID,
                  let context = environment.contexts["A"] else { throw InputError.timeout }
            check(manager.task(id: id)?.source == AgentTask.scheduledSource
                    && manager.workerBinding(taskID: id)?.attempt == 1 && context.isStillValid?() == true
                    && manager.retainsScheduledRunOwnerForTesting(taskID: id) == true,
                "BC06 actual Scheduler retains SAME admitted Manager run")
            environment.release()
            guard await reached({ scheduler.pendingPassesForTesting == 0 && environment.activeCalls == 0 && tools.activeCalls == 0 }) else { throw InputError.timeout }
            check(tools.taskIDs == [id] && manager.task(id: id)?.status == .completed
                    && delivery.delivered == ["Owned owner A complete."],
                "BC07 actual scheduled confined read and completed consumer qualify")
            check(VoiceSession.shared.state.island == .thinking
                    && IslandState.shared.voiceProjection == .thinking
                    && IslandState.shared.avatarState == .thinking
                    && IslandOwnership.rejected.values.reduce(0, +) > before,
                "BF03 actual scheduled tool publication cannot replace conversation")
            check(manager.retainsScheduledRunOwnerForTesting(taskID: id) == false,
                "BC08 actual scheduled run returned before any context reset")
        } catch { caught = error }
        scheduler.stop(); environment.release()
        guard await reached({ scheduler.pendingPassesForTesting == 0 && environment.activeCalls == 0 && tools.activeCalls == 0 }) else { throw InputError.timeout }
        didDrain()
        if let caught { throw caught }
    }

    static func originalCases(root: URL, input: URL, text: String,
                              check checkOut: (Bool, String) -> Void) async throws {
        let safe = root.standardizedFileURL.resolvingSymlinksInPath()
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard SelfTest.isRunning, safe.path.hasPrefix(temporary.path + "/"),
              input.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(safe.path + "/"),
              !safe.pathComponents.contains("Application Support"), PermissionGate.shared.pending == nil,
              PermissionGate.shared.queuedCount == 0 else { throw InputError.unsafe }
        var cases = 0
        func check(_ value: Bool, _ label: String) { cases += 1; checkOut(value, label) }
        let oldFake = AgentToolExecutor.fakeForTesting
        let oldFire = AgentToolExecutor.fireOverrideForTesting
        let oldPolicy = AgentToolExecutor.policyOverrideForTesting
        defer { AgentToolExecutor.fakeForTesting = oldFake; AgentToolExecutor.fireOverrideForTesting = oldFire; AgentToolExecutor.policyOverrideForTesting = oldPolicy }
        AgentToolExecutor.fakeForTesting = nil; AgentToolExecutor.policyOverrideForTesting = .selfTest
        let grants = PermissionGrantStore.shared.grants
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        for mode in ["accepted", "cancel-A", "cancel-rejected", "stop-pass", "fresh-primary", "start-rejected", "terminal-rejected", "model-threw"] {
            let startingCases = cases
            let directory = safe.appendingPathComponent("scheduled-owner-" + mode, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let sql = TaskStore(root: directory); defer { sql.close() }
            let store = AgentTaskStore(fileURL: directory.appendingPathComponent("agent-tasks.json"), mirror: sql)
            guard store.save([]).primaryCommitted else { throw InputError.unsafe }
            let receipts = ActionReceiptStore(fileURL: directory.appendingPathComponent("action-receipts.json"))
            let manager = AgentTaskManager(store: store, receiptStore: receipts)
            manager.progressDateForTesting = { now }
            let environment = ModelEnvironment(manager: manager, input: input)
            environment.throwsA = mode == "model-threw"
            let tools = Tools(manager: manager, receipts: receipts)
            let schedules = ScheduleStore(directory: directory.appendingPathComponent("schedules"))
            let runner = ScheduledRunner(store: schedules, environment: environment, tools: tools,
                recorder: LiveScheduledRunRecorder(taskManager: manager),
                personaStore: PersonaStore(directory: directory, isEnabled: { false }),
                memorySnapshot: MemorySnapshotCache(isEnabled: { false }), timeZone: { TimeZone(secondsFromGMT: 0)! })
            let delivery = Delivery()
            let scheduler = AgentScheduler(store: schedules, system: System(), deliverer: delivery,
                environment: ScheduleEnvironmentValue(),
                settings: { ScheduleSettingsSnapshot(enabled: true, quietStart: nil, quietEnd: nil, speech: .never) },
                runner: runner, events: AgentTriggerEvents(), heartbeatTaskManager: manager)
            defer { scheduler.stop() }
            let when = ScheduleWhen(repeatRule: .once(now), time: ScheduleLocalTime(hour: 0, minute: 0), timeZone: "UTC")
            // createdAt is immutable; inject the SAME intended date at construction.
            var a = AgentSchedule(id: UUID(), kind: .routine, title: "Owned owner A",
                plainEnglish: "Every weekday at 08:00, I'll check my inbox.", prompt: "Owned owner A",
                when: when, allowedTools: ["filesystem.read"], model: .cloud, delivery: .notify,
                budget: .standard, createdAt: now)
            a.nextRunAt = now
            var b = AgentSchedule(id: UUID(), kind: .routine, title: "Owned owner B",
                plainEnglish: "Every weekday at 08:00, I'll check my inbox.", prompt: "Owned owner B",
                when: when, allowedTools: ["filesystem.read"], model: .cloud, delivery: .notify,
                budget: .standard, createdAt: now)
            b.nextRunAt = now
            // ScheduleStore's actual order is explicit and observed below.
            guard schedules.save(a), schedules.save(b) else { throw InputError.unsafe }
            let ordered = schedules.schedules
            guard ordered.map(\.id) == [a.id, b.id] else { throw InputError.unsafe }
            var effects = 0
            var effectTaskIDs: [String] = []
            AgentToolExecutor.fireOverrideForTesting = { tool, arguments in
                guard tool.id == "filesystem.read", arguments == ["path": input.path] else { throw InputError.unexpected }
                guard let context = TaskEventJournal.current else { throw InputError.unexpected }
                effectTaskIDs.append(context.taskID)
                effects += 1
                manager.progressDateForTesting = { now.addingTimeInterval(Double(effects)) }
                return try FilesystemExecutor.run(tool, arguments: arguments)
            }
            if mode == "start-rejected" || mode == "terminal-rejected" {
                let kind = mode == "start-rejected" ? "jobCreated" : "jobCompleted"
                try sql.withConnection { try TaskStore.exec($0, "CREATE TRIGGER reject_owned_phase BEFORE INSERT ON task_event WHEN NEW.kind='\(kind)' AND (SELECT objective FROM task WHERE id=NEW.task_id)='Owned owner A' BEGIN SELECT RAISE(ABORT,'owned refusal'); END") }
            }
            let inputBefore = try Data(contentsOf: input)
            await scheduler.runTick(now: now) // Existing tick returns while SAME pass owns the operation.
            var fresh: AgentTaskManager?
            var freshSQL: TaskStore?
            defer { freshSQL?.close() }
            do {
                if mode == "start-rejected" {
                    guard await reached({ scheduler.pendingPassesForTesting == 0 && environment.activeCalls == 0 && tools.activeCalls == 0 }) else { throw InputError.timeout }
                } else {
                    guard await reached({ environment.held != nil && environment.started == ["A"] }) else { throw InputError.timeout }
                }
                let captured = environment.aTaskID.flatMap { manager.task(id: $0) }
                let binding = environment.aTaskID.flatMap { manager.workerBinding(taskID: $0) }
                check(manager.historyReadFailure == nil && manager.tasks.allSatisfy { $0.source == AgentTask.scheduledSource }, "scheduled owner C01 isolated actual Manager/source invalid (\(mode))")
                check(mode == "start-rejected" || (environment.started == ["A"] && environment.ended.isEmpty && !environment.released), "scheduled owner C02 genuine real model await missing (\(mode))")
                check(mode == "start-rejected" || schedules.schedule(id: b.id)?.nextRunAt == now, "scheduled owner C03 B eligibility changed while A owns current run (\(mode))")
                check(mode == "start-rejected" || (binding?.attempt == 1 && binding?.leaseOwner == String(ProcessInfo.processInfo.processIdentifier) && captured?.durability?.runtimeClass == .scheduledResearch
                    && environment.aTaskID.flatMap { manager.retainsScheduledRunOwnerForTesting(taskID: $0) } == true), "scheduled owner F01 actual task-scoped attempt/handle missing (\(mode))")
                check(mode == "start-rejected" || (environment.contexts["A"]?.attempt == 1 && environment.contexts["A"]?.leaseOwner == binding?.leaseOwner && environment.contexts["A"]?.isStillValid?() == true), "scheduled owner F02 actual model consumer has no admitted context (\(mode))")
                check(try mode == "start-rejected" || sql.journal(taskID: captured?.id ?? "").map(\.draft.kind).contains(.workerStarted), "scheduled owner F03 exact scheduled worker-start admission missing (\(mode))")
                if mode == "cancel-A", let id = captured?.id { manager.cancel(id) }
                if mode == "cancel-rejected", let id = captured?.id {
                    try sql.withConnection { try TaskStore.exec($0, "CREATE TRIGGER reject_owned_cancel BEFORE UPDATE ON task WHEN NEW.state='cancelled' AND NEW.objective='Owned owner A' BEGIN SELECT RAISE(ABORT,'owned cancellation refusal'); END") }
                    let beforeCancelRows = try sql.load()
                    let beforeCancelJournal = try sql.journal(taskID: id)
                    let beforeCancelExport = try Data(contentsOf: directory.appendingPathComponent("agent-tasks.json"))
                    manager.cancel(id)
                    let afterCancelRows = try sql.load()
                    let afterCancelJournal = try sql.journal(taskID: id)
                    let afterCancelExport = try Data(contentsOf: directory.appendingPathComponent("agent-tasks.json"))
                    check(manager.lastPersistenceResult == .sqlFailed
                        && manager.task(id: id)?.status == .running
                        && afterCancelRows == beforeCancelRows
                        && afterCancelJournal == beforeCancelJournal
                        && afterCancelExport == beforeCancelExport,
                        "scheduled owner C11 rejected cancellation changed durable primary/export/journal")
                    check(environment.contexts["A"]?.isStillValid?() == false
                        && manager.workerBinding(taskID: id) == nil
                        && manager.retainsScheduledRunOwnerForTesting(taskID: id) == true,
                        "scheduled owner F10 rejected save left SAME scheduled operation admitted or released before return")
                }
                if mode == "stop-pass" { scheduler.stop() }
                if mode == "fresh-primary" {
                    let reader = TaskStore(root: directory); freshSQL = reader
                    let freshStore = AgentTaskStore(fileURL: directory.appendingPathComponent("agent-tasks.json"), mirror: reader)
                    fresh = AgentTaskManager(store: freshStore, receiptStore: receipts)
                }
                environment.release()
                guard await reached({ scheduler.pendingPassesForTesting == 0 && environment.activeCalls == 0 && tools.activeCalls == 0 }) else { throw InputError.timeout }
                if mode == "stop-pass" {
                    check(environment.calls["B"] == nil && schedules.schedule(id: b.id)?.nextRunAt == now, "scheduled owner C04 wholepass stop lost/claimed unrelated B")
                    await scheduler.runTick(now: now)
                    guard await reached({ scheduler.pendingPassesForTesting == 0 && environment.activeCalls == 0 && tools.activeCalls == 0 }) else { throw InputError.timeout }
                } else { check(true, "scheduled owner C04 wholepass scope retained (\(mode))") }
                let rows = try sql.load()
                let aRow = rows.first { $0.objective == a.title }
                let bRow = rows.first { $0.objective == b.title }
                let suppressA = ["cancel-A", "cancel-rejected", "stop-pass", "fresh-primary", "start-rejected", "terminal-rejected", "model-threw"].contains(mode)
                check(mode == "fresh-primary"
                    ? (bRow == nil && environment.calls["B"] == nil && !delivery.delivered.contains("Owned owner B complete."))
                    : (bRow?.status == .completed && environment.calls["B"] == 2 && delivery.delivered.contains("Owned owner B complete.")), "scheduled owner C05 actual eligible B consumer did not complete (\(mode))")
                check(mode == "fresh-primary"
                    ? (environment.aTaskID.flatMap { manager.retainsScheduledRunOwnerForTesting(taskID: $0) } == false && environment.calls["B"] == nil)
                    : (environment.aTaskID == nil || environment.bSawAReleased), "scheduled owner C06 A handle was not released before B consumer (\(mode))")
                check(scheduler.pendingPassesForTesting == 0 && manager.tasks.allSatisfy { manager.retainsScheduledRunOwnerForTesting(taskID: $0.id) == false }, "scheduled owner C07 exact operation/pass joins incomplete (\(mode))")
                check(mode == "cancel-rejected"
                    ? (aRow?.status == .running && aRow?.result == nil && environment.calls["A"] == 1)
                    : (mode != "cancel-A" || (aRow?.status == .cancelled && environment.calls["A"] == 1)),
                    "scheduled owner F04 cancel A failed to stop SAME run without success (\(mode))")
                check(!suppressA || !delivery.delivered.contains("Owned owner A complete."), "scheduled owner F05 refused/cancelled A result was delivered (\(mode))")
                check(mode != "fresh-primary" || (fresh?.historyReadFailure == nil && aRow?.status == .failed && !effectTaskIDs.contains(captured?.id ?? "")), "scheduled owner F06 held primary authorized late actual read")
                check(mode != "terminal-rejected" || (aRow?.status == .running && schedules.schedule(id: a.id)?.pendingDelivery == nil), "scheduled owner F07 terminal refusal published failure/success or automatic retry")
                check(mode != "start-rejected" || (aRow == nil && environment.calls["A"] == nil && rows.count == 1), "scheduled owner C08 admitted30 rejected start still dispatched A")
                let bReceipts = receipts.receipts.filter { $0.taskID == bRow?.id }
                let bJournal = try bRow.map { try sql.journal(taskID: $0.id) } ?? []
                let bProgressAdvanced: Bool
                if let durability = bRow?.durability, let progress = durability.lastProgressAt,
                   let began = durability.attemptStartedAt { bProgressAdvanced = progress > began }
                else { bProgressAdvanced = false }
                check(mode == "fresh-primary" || (bRow?.durability?.attempt == 1
                    && bProgressAdvanced
                    && bReceipts.count == 1 && bReceipts[0].status == .completed
                    && bReceipts[0].taskAttempt == 1
                    && bReceipts[0].taskLeaseOwner == String(ProcessInfo.processInfo.processIdentifier)
                    && bRow?.durability?.receiptIDs == [bReceipts[0].actionID.uuidString]
                    && bJournal.filter { $0.draft.kind == .toolStarted }.count == 1
                    && bJournal.filter { $0.draft.kind == .toolCompleted }.count == 1
                    && bJournal.filter { $0.draft.kind == .jobCompleted }.count == 1),
                    "scheduled owner F08 actual B receipt/progress/terminal consumer lacks admitted ownership (\(mode))")
                let aReceipts = receipts.receipts.filter { $0.taskID == captured?.id }
                let aRunsRead = mode == "accepted" || mode == "terminal-rejected"
                check(aRunsRead
                    ? (aReceipts.count == 1 && aReceipts[0].status == .completed
                       && aReceipts[0].taskAttempt == 1
                       && aReceipts[0].taskLeaseOwner == String(ProcessInfo.processInfo.processIdentifier)
                       && aRow?.durability?.receiptIDs == [aReceipts[0].actionID.uuidString])
                    : (aReceipts.isEmpty && !effectTaskIDs.contains(captured?.id ?? "")),
                    "scheduled owner F09 current/refused A real backing/receipt contract broken (\(mode))")
                check(environment.activeCalls == 0 && tools.activeCalls == 0
                    && environment.returnedCalls == environment.calls.values.reduce(0,+)
                    && (mode != "model-threw" || (aRow?.status == .failed
                        && aRow?.failure?.isEmpty == false && environment.calls["A"] == 1)),
                    "scheduled owner C10 actual callback returns/throw terminal cleanup incomplete (\(mode))")
                check(try Data(contentsOf: input) == inputBefore && String(data: inputBefore, encoding: .utf8) == text && PermissionGate.shared.pending == nil && PermissionGate.shared.queuedCount == 0 && PermissionGrantStore.shared.grants == grants, "scheduled owner C09 input/Gate/standing choices changed (\(mode))")
                if ["accepted", "model-threw"].contains(mode) {
                    guard let ended = aRow else { throw InputError.unexpected }
                    check([.completed, .failed].contains(ended.status) && ended.durability?.attempt == 1
                        && manager.retainsScheduledRunOwnerForTesting(taskID: ended.id) == false
                        && environment.activeCalls == 0 && tools.activeCalls == 0,
                        "terminal transition C03 actual positive scheduled worker did not qualify (\(mode))")
                    let beforeCancel = try sql.load()
                    let cancelJournal = try sql.journal(taskID: ended.id)
                    let cancelExport = try Data(contentsOf: directory.appendingPathComponent("agent-tasks.json"))
                    manager.cancel(ended.id)
                    check(try sql.load() == beforeCancel && sql.journal(taskID: ended.id) == cancelJournal
                        && Data(contentsOf: directory.appendingPathComponent("agent-tasks.json")) == cancelExport,
                        "terminal transition C04 positive ended worker cancellation changed history (\(mode))")
                    // Same-state metadata remains admitted through the existing update;
                    // the fence does not turn terminal rows into an immutable mirror.
                    manager.finishScheduledRun(id: ended.id, status: ended.status,
                        result: ended.result, failure: ended.failure)
                    check(try manager.lastPersistenceResult?.primaryCommitted == true
                        && sql.load() == beforeCancel && sql.journal(taskID: ended.id) == cancelJournal,
                        "terminal transition C05 same-state scheduled metadata update was refused (\(mode))")
                    let savedRows = try sql.load(); let savedCache = manager.tasks
                    let savedExport = try Data(contentsOf: directory.appendingPathComponent("agent-tasks.json"))
                    let savedAuthority = try sql.probeAuthority(includeTasks: false)?.authority
                    manager.finishScheduledRun(id: ended.id, status: .running, result: nil, failure: nil)
                    check(try manager.tasks == savedCache && sql.load() == savedRows
                        && manager.lastPersistenceResult?.diagnostic == "This task has already ended. Its saved result was kept.",
                        "terminal transition F02 late scheduled callback replaced an actual ended state (\(mode))")
                    check(try sql.journal(taskID: ended.id) == cancelJournal
                        && Data(contentsOf: directory.appendingPathComponent("agent-tasks.json")) == savedExport
                        && sql.probeAuthority(includeTasks: false)?.authority == savedAuthority,
                        "terminal transition F03 rejected scheduled callback changed witness/events/generation (\(mode))")
                }
                SelfTest.diagnostic("SCHEDULED_OWNER_TRACE: mode=\(mode) checks=\(cases-startingCases) cumulative=\(cases) starts=\(environment.started.count) ends=\(environment.ended.count) returned=\(environment.returnedCalls) active=\(environment.activeCalls) modelCalls=\(environment.calls.values.reduce(0,+)) tools=\(tools.taskIDs.count) backing=\(effects) rows=\(rows.count) receipts=\(receipts.receipts.count) pending=\(scheduler.pendingPassesForTesting ?? -1)")
            } catch {
                scheduler.stop(); environment.release()
                guard await reached({ scheduler.pendingPassesForTesting == 0 && environment.activeCalls == 0 && tools.activeCalls == 0 }) else { throw InputError.timeout }
                throw error
            }
        }
        try await invalidCompletionCases(root: safe, input: input, now: now, check: check)
        SelfTest.diagnostic("SCHEDULED_OWNER_RESULT: checks=\(cases)")
    }

    /// Real admitted owner remains at the actual model await while the public
    /// completion boundary receives a nonterminal status. No task row is seeded.
    private static func invalidCompletionCases(root: URL, input: URL, now: Date,
                                               check: (Bool, String) -> Void) async throws {
        for mode in ["public", "admitted"] {
            let directory = root.appendingPathComponent("scheduled-invalid-completion-" + mode, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let sql = TaskStore(root: directory); defer { sql.close() }
            let export = directory.appendingPathComponent("agent-tasks.json")
            let store = AgentTaskStore(fileURL: export, mirror: sql)
            guard store.save([]).primaryCommitted else { throw InputError.unsafe }
            let receipts = ActionReceiptStore(fileURL: directory.appendingPathComponent("action-receipts.json"))
            let manager = AgentTaskManager(store: store, receiptStore: receipts)
            manager.progressDateForTesting = { now }
            let environment = ModelEnvironment(manager: manager, input: input)
            let tools = Tools(manager: manager, receipts: receipts)
            let schedules = ScheduleStore(directory: directory.appendingPathComponent("schedules"))
            let runner = ScheduledRunner(store: schedules, environment: environment, tools: tools,
                recorder: LiveScheduledRunRecorder(taskManager: manager),
                personaStore: PersonaStore(directory: directory, isEnabled: { false }),
                memorySnapshot: MemorySnapshotCache(isEnabled: { false }), timeZone: { TimeZone(secondsFromGMT: 0)! })
            let delivery = Delivery()
            let scheduler = AgentScheduler(store: schedules, system: System(), deliverer: delivery,
                environment: ScheduleEnvironmentValue(),
                settings: { ScheduleSettingsSnapshot(enabled: true, quietStart: nil, quietEnd: nil, speech: .never) },
                runner: runner, events: AgentTriggerEvents(), heartbeatTaskManager: manager)
            defer { scheduler.stop() }
            let when = ScheduleWhen(repeatRule: .once(now), time: ScheduleLocalTime(hour: 0, minute: 0), timeZone: "UTC")
            var schedule = AgentSchedule(id: UUID(), kind: .routine, title: "Owned owner A",
                plainEnglish: "Every weekday at 08:00, I'll check my inbox.", prompt: "Owned owner A",
                when: when, allowedTools: ["filesystem.read"], model: .cloud, delivery: .notify,
                budget: .standard, createdAt: now)
            schedule.nextRunAt = now
            guard schedules.save(schedule) else { throw InputError.unsafe }
            let inputBefore = try Data(contentsOf: input)
            await scheduler.runTick(now: now)
            do {
                guard await reached({ environment.held != nil && environment.started == ["A"] }),
                      let id = environment.aTaskID, let before = manager.task(id: id),
                      let binding = manager.workerBinding(taskID: id),
                      before.status == .running, binding.attempt == 1,
                      environment.contexts["A"]?.isStillValid?() == true,
                      manager.retainsScheduledRunOwnerForTesting(taskID: id) == true
                else { throw InputError.timeout }
                check(before.source == AgentTask.scheduledSource && before.scheduleID == schedule.id
                    && before.durability?.runtimeClass == .scheduledResearch
                    && binding.leaseOwner == String(ProcessInfo.processInfo.processIdentifier)
                    && environment.activeCalls == 1 && !environment.released && tools.taskIDs.isEmpty,
                    "scheduled completion C01 actual current held scheduled owner missing (\(mode))")
                let cached = manager.tasks
                let rows = try sql.load()
                let journal = try sql.journal(taskID: id)
                let bytes = try Data(contentsOf: export)
                let authority = try sql.probeAuthority(includeTasks: false)?.authority
                var admitted: Bool? = nil
                if mode == "public" {
                    manager.finishScheduledRun(id: id, status: .queued, result: "Not a terminal result", failure: nil)
                } else {
                    admitted = manager.finishScheduledRunAdmitted(id: id, status: .queued,
                        result: "Not a terminal result", failure: nil)
                }
                let afterRows = try sql.load()
                let afterJournal = try sql.journal(taskID: id)
                let afterBytes = try Data(contentsOf: export)
                let afterAuthority = try sql.probeAuthority(includeTasks: false)?.authority
                check(manager.tasks == cached && afterRows == rows
                    && manager.lastPersistenceResult?.primaryCommitted == false
                    && manager.lastPersistenceResult?.diagnostic == "This result isn't finished. The task's saved state was kept."
                    && (mode == "public" || admitted == false),
                    "scheduled completion F01 invalid nonterminal callback changed current state/result (\(mode))")
                check(afterJournal == journal && afterBytes == bytes && afterAuthority == authority,
                    "scheduled completion F02 invalid completion changed events/export/generation (\(mode))")
                // Cancel the SAME actual operation before returning its held callback;
                // the old queued mutation is a target failure, not a cleanup input.
                scheduler.stop()
                manager.cancel(id)
                environment.release()
                guard await reached({ scheduler.pendingPassesForTesting == 0
                    && environment.activeCalls == 0 && tools.activeCalls == 0 }) else { throw InputError.timeout }
                check(manager.retainsScheduledRunOwnerForTesting(taskID: id) == false
                    && environment.returnedCalls == 1 && environment.calls["A"] == 1
                    && tools.taskIDs.isEmpty && receipts.receipts.isEmpty && delivery.delivered.isEmpty
                    && (try? Data(contentsOf: input)) == inputBefore,
                    "scheduled completion C02 actual cancelled owner did not return cleanly without backing (\(mode))")
                SelfTest.diagnostic("SCHEDULED_COMPLETION_TRACE: mode=\(mode) before=\(before.status.rawValue) after=\(afterRows.first?.status.rawValue ?? "missing") admitted=\(admitted.map(String.init) ?? "void") modelReturned=\(environment.returnedCalls) backing=\(tools.taskIDs.count)")
            } catch {
                // The existing pass awaits its SAME per-run Task; no second owner.
                scheduler.stop()
                for row in manager.tasks { manager.cancel(row.id) }
                environment.release()
                guard await reached({ scheduler.pendingPassesForTesting == 0
                    && environment.activeCalls == 0 && tools.activeCalls == 0 }) else { throw InputError.timeout }
                throw error
            }
        }
    }
}

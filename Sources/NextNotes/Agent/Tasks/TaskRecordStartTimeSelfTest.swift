import Foundation

/// Task elapsed origin versus real successor attempt start. No question or task row is seeded.
@MainActor
enum TaskRecordStartTimeSelfTest {
    private enum FixtureError: Error { case unsafe, missingRequest, timeout }
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
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-voice-work-lifecycle",
              AgentSession.shared.fileURL == nil, PermissionGate.shared.pending == nil else {
            return (0, ["task time: INVALID isolated diagnostic required"])
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NextNotesTaskTime-" + UUID().uuidString, isDirectory: true)
        let safe = root.resolvingSymlinksInPath().standardizedFileURL
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard safe.deletingLastPathComponent().path == temp.path,
              !FileManager.default.fileExists(atPath: root.path) else { return (0, ["task time: INVALID unsafe root"]) }
        let owner = SelfTestStoreGuard.take()
        let oldFake = AgentToolExecutor.fakeForTesting
        let oldFire = AgentToolExecutor.fireOverrideForTesting
        let oldPolicy = AgentToolExecutor.policyOverrideForTesting
        var checks = 0; var failures: [String] = []
        func check(_ value: Bool, _ label: String) {
            checks += 1; if !value { failures.append("task time: " + label) }
        }
        defer {
            PermissionGate.shared.resetForRestartTesting()
            AgentToolExecutor.fakeForTesting = oldFake
            AgentToolExecutor.fireOverrideForTesting = oldFire
            AgentToolExecutor.policyOverrideForTesting = oldPolicy
            try? FileManager.default.removeItem(at: root)
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            for mode in ["input", "permission", "answer-refused", "start-refused"] {
                let initialClock = Date(timeIntervalSince1970: 1_000)
                let nextClock = Date(timeIntervalSince1970: 2_000)
                var clock = initialClock
                let directory = root.appendingPathComponent(mode, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                let sql = TaskStore(root: directory); defer { sql.close() }
                let file = directory.appendingPathComponent("agent-tasks.json")
                let store = AgentTaskStore(fileURL: file, mirror: sql)
                guard store.allowsHarnessPersistence, store.save([]).primaryCommitted else { throw FixtureError.unsafe }
                let receipts = ActionReceiptStore(fileURL: directory.appendingPathComponent("action-receipts.json"))
                var manager = AgentTaskManager(store: store, receiptStore: receipts)
                manager.progressDateForTesting = { clock }
                manager.announcementForTesting = { _ in }
                var backendEnded = 0; var effects = 0; var successor: AgentTask?
                manager.backendExitForTesting = { backendEnded += 1 }
                manager.backendEntryForTesting = {
                    if TaskEventJournal.current?.attempt == 2 { successor = try sql.load().first }
                }
                let payload = "Owned task time content."
                let target = directory.appendingPathComponent("owned.txt")
                if mode != "permission" { try payload.write(to: target, atomically: true, encoding: .utf8) }
                AgentToolExecutor.fakeForTesting = nil
                AgentToolExecutor.policyOverrideForTesting = mode == "permission" ? .denyMutations : .selfTest
                AgentToolExecutor.fireOverrideForTesting = { tool, arguments in
                    guard arguments["path"] == target.path,
                          tool.id == (mode == "permission" ? "filesystem.write" : "filesystem.read"),
                          mode != "permission" || arguments["text"] == payload else { throw FixtureError.unsafe }
                    effects += 1
                    return try FilesystemExecutor.run(tool, arguments: arguments)
                }
                let words = mode == "permission" ? "Write \(payload) to \(target.path)." : "Read my chosen fixture file."
                AgentSession.shared.recordUser(words, source: .text)
                let task = manager.submit(objective: words,
                    tool: mode == "permission" ? "filesystem.write" : "filesystem.read",
                    arguments: mode == "permission" ? ["path": target.path, "text": payload] : [:],
                    source: "text", origin: .typed, userWords: words)
                if mode == "permission" {
                    guard await reached({ manager.task(id: task.id)?.status == .waitingForPermission
                        && PermissionGate.shared.pending?.taskID == task.id }) else { throw FixtureError.missingRequest }
                    // The actual saved request survives loss of its original live approval.
                    // Join its existing backend, then restore it through the same primary.
                    PermissionGate.shared.resetForRestartTesting()
                    guard await reached({ backendEnded == 1 }) else { throw FixtureError.timeout }
                    manager = AgentTaskManager(store: AgentTaskStore(fileURL: file, mirror: sql), receiptStore: receipts)
                    manager.progressDateForTesting = { clock }
                    manager.announcementForTesting = { _ in }
                    manager.backendExitForTesting = { backendEnded += 1 }
                    manager.backendEntryForTesting = {
                        if TaskEventJournal.current?.attempt == 2 { successor = try sql.load().first }
                    }
                    manager.restorePendingInteractions()
                }
                guard await reached({ backendEnded == 1 }), let first = try sql.load().first,
                      let pending = first.pendingInteraction else { throw FixtureError.missingRequest }
                let firstLiveCanonical = try canonical(manager.tasks).first
                let question: TaskInputRequest?
                let permission: PermissionRequest?
                switch pending {
                case .input(let request): question = request; permission = nil
                case .permission(let request, _, _): question = nil; permission = request
                }
                check(first.status == (mode == "permission" ? .waitingForPermission : .waitingForInput)
                    && effects == 0 && (mode == "permission" ? permission?.taskID == task.id : question?.taskID == task.id),
                    "C01 actual pending producer/control did not qualify (\(mode))")
                check(first.durability?.attempt == 1 && first.durability?.attemptStartedAt == initialClock
                    && (mode == "permission" ? manager.backendStartsForTesting == 0 : manager.backendStartsForTesting == 1),
                    "C02 original attempt did not bind actual initial clock (\(mode))")
                check(first.startedAt == initialClock, "F01 task elapsed origin missing at first actual attempt (\(mode))")
                check(first.finishedAt == nil && first.pendingInteraction == firstLiveCanonical?.pendingInteraction,
                    "C03 pending task invented terminal time or altered question (\(mode))")
                clock = nextClock
                if mode == "answer-refused" {
                    guard let question else { throw FixtureError.missingRequest }
                    let before = try Data(contentsOf: file); let events = try sql.journal(taskID: task.id)
                    try sql.withConnection { try TaskStore.exec($0, "CREATE TRIGGER reject_answer BEFORE UPDATE ON task BEGIN SELECT RAISE(ABORT,'owned answer refusal'); END") }
                    let accepted = manager.respondInput(taskID: task.id, text: target.path, requestID: question.id)
                    let afterRows = try sql.load(); let afterBytes = try Data(contentsOf: file); let afterEvents = try sql.journal(taskID: task.id)
                    check(!accepted && manager.lastPersistenceResult == .sqlFailed && afterRows == [first]
                        && afterBytes == before && afterEvents == events,
                        "C04 refused answer changed primary/export/journal (\(mode))")
                    check(afterRows.first?.startedAt == initialClock && manager.task(id: task.id)?.startedAt == initialClock,
                        "F02 refused continuation changed task elapsed origin (\(mode))")
                    check(manager.task(id: task.id)?.durability?.attempt == 1 && manager.backendStartsForTesting == 1,
                        "C05 refused answer advanced attempt or started successor (\(mode))")
                    check(effects == 0 && receipts.receipts.allSatisfy { $0.status != .fired && $0.status != .completed },
                        "C06 refused answer reached backing or saved effect receipt (\(mode))")
                    try sql.withConnection { try TaskStore.exec($0, "DROP TRIGGER reject_answer") }
                } else {
                    if mode == "start-refused" {
                        try sql.withConnection { try TaskStore.exec($0, "CREATE TRIGGER reject_start BEFORE UPDATE ON task WHEN NEW.state='running' BEGIN SELECT RAISE(ABORT,'owned successor start refusal'); END") }
                    }
                    if let question {
                        guard manager.respondInput(taskID: task.id, text: target.path, requestID: question.id) else { throw FixtureError.missingRequest }
                    } else if permission != nil {
                        manager.respondPermission(taskID: task.id, approved: true)
                    } else { throw FixtureError.missingRequest }
                    let queued = try sql.load(); let queuedBytes = try Data(contentsOf: file); let queuedEvents = try sql.journal(taskID: task.id)
                    if mode == "start-refused" {
                        guard await reached({ manager.task(id: task.id)?.status == .failed }) else { throw FixtureError.timeout }
                        let afterRows = try sql.load(); let afterBytes = try Data(contentsOf: file); let afterEvents = try sql.journal(taskID: task.id)
                        check(afterRows == queued && afterBytes == queuedBytes && afterEvents == queuedEvents
                            && manager.lastPersistenceResult == .sqlFailed,
                            "C04 refused successor start changed accepted queued primary (\(mode))")
                        check(afterRows.first?.startedAt == initialClock && manager.task(id: task.id)?.startedAt == initialClock,
                            "F02 refused successor start changed task elapsed origin (\(mode))")
                        check(afterRows.first?.durability?.attempt == 1 && successor == nil && manager.backendStartsForTesting == 1,
                            "C05 refused start advanced durable attempt or reached backend (\(mode))")
                        check(effects == 0 && receipts.receipts.allSatisfy { $0.status != .fired && $0.status != .completed },
                            "C06 refused start reached backing or saved effect receipt (\(mode))")
                        try sql.withConnection { try TaskStore.exec($0, "DROP TRIGGER reject_start") }
                    } else {
                        guard await reached({ backendEnded == 2 }), let final = try sql.load().first,
                              let successor else { throw FixtureError.timeout }
                        check(successor.status == .running && successor.id == first.id && final.status == .completed,
                            "C04 actual accepted successor/default backing did not complete (\(mode))")
                        let completedAt = try sql.journal(taskID: task.id).last { $0.draft.kind == .jobCompleted }?.draft.at
                        check(successor.startedAt == initialClock && final.startedAt == initialClock
                            && completedAt != nil && final.finishedAt == completedAt,
                            "F02 successor reset task elapsed origin or terminal clock (\(mode))")
                        check(successor.durability?.attempt == 2 && successor.durability?.attemptStartedAt == nextClock
                            && manager.backendStartsForTesting == (mode == "permission" ? 1 : 2),
                            "C05 successor attempt clock was not independent/current (\(mode))")
                        check(effects == 1 && receipts.receipts.contains { $0.taskID == task.id && $0.taskAttempt == 2 && $0.status == .completed },
                            "C06 actual one backing/terminal receipt did not join successor (\(mode))")
                    }
                }
                print("TASK_RECORD_TIME_TRACE mode=\(mode) checks=8 initialAttempt=\(first.durability?.attempt ?? -1) successorAttempt=\(successor?.durability?.attempt ?? -1) effects=\(effects) backendEnded=\(backendEnded)")
                PermissionGate.shared.resetForRestartTesting()
            }
            check(SelfTestStoreGuard.diff(owner, SelfTestStoreGuard.take()).isEmpty, "C07 owner stores/defaults/grants changed")
        } catch { failures.append("task time: INVALID actual prerequisite: \(error)") }
        print("TASK_RECORD_TIME_RESULT checks=\(checks) problems=\(failures.count)")
        return (checks, failures)
    }
}

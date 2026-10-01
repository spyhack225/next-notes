import Foundation
import SQLite3

/// Actual legacy reader and fresh manager proof. Held history is not worker recovery.
@MainActor
enum TaskRecoverySelfTest {
    static func run() -> String {
        let before = SelfTestStoreGuard.take()
        let pure = TaskRecoveryPlannerSelfTest.run()
        var failures = pure.failures
        var cases = pure.cases
        func check(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NextNotesTaskRecovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            let file = root.appendingPathComponent("agent-tasks.json")
            let mirror = TaskStore(root: root)
            defer { mirror.close() }
            let store = AgentTaskStore(fileURL: file, mirror: mirror)
            guard store.allowsHarnessPersistence else { throw TaskStoreError.invalidRecord }
            check(try store.load().isEmpty, "missing legacy history was not fresh empty history")
            cases += 1
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            var durability = TaskDurability()
            durability.attempt = 3
            durability.receiptIDs = ["fixture-existing-receipt"]
            let rows = [
                AgentTask(id: "typed-running", objective: "Private interrupted objective", source: "text",
                    createdAt: date, status: .running, artifacts: ["fixture://existing"], backend: "acp", durability: durability),
                AgentTask(id: "typed-queued", objective: "Private queued objective", source: "user", createdAt: date),
                AgentTask(id: "input", objective: "Private pending input", createdAt: date, status: .waitingForInput,
                    arguments: ["existing": "Private existing input"]),
                AgentTask(id: "permission", objective: "Private approval", createdAt: date,
                    status: .waitingForPermission, tool: "filesystem.write"),
                AgentTask(id: "compatibility", objective: "Private compatibility", createdAt: date,
                    status: .waitingForCompatibilityCLI, backend: "acp", compatibilityCommand: "fixture --frozen",
                    compatibilityCLI: "fixture-cli", compatibilityDirectory: "/fixture/frozen"),
                AgentTask(id: "completed", objective: "Private result", createdAt: date, status: .completed, result: "Private result"),
                AgentTask(id: "failed", objective: "Private failed", createdAt: date, status: .failed, failure: "Private failure"),
                AgentTask(id: "cancelled", objective: "Private stopped", createdAt: date, status: .cancelled),
                AgentTask(id: "voice", objective: "Private voice", source: "voice", createdAt: date, status: .running),
                AgentTask(id: "scheduled", objective: "Private routine", source: "scheduled", createdAt: date,
                    status: .running, scheduleID: UUID()),
                AgentTask(id: "remote", objective: "Private remote", source: "iMessage", createdAt: date, status: .running),
                AgentTask(id: "unknown", objective: "Private unknown", source: "unknown", createdAt: date, status: .queued)
            ]
            check(store.save(rows) == .saved, "restart fixture did not save")
            let manager = AgentTaskManager(store: AgentTaskStore(fileURL: file, mirror: mirror))
            check(manager.task(id: "typed-running")?.status.rawValue == "recovering", "typed running record was not held recovering")
            check(manager.task(id: "typed-running")?.artifacts == rows[0].artifacts
                && manager.task(id: "typed-running")?.durability == rows[0].durability,
                "held restart lost existing attempt/receipt/artifact metadata")
            check(manager.task(id: "typed-queued")?.status == .failed
                && manager.task(id: "typed-queued")?.failure?.contains("safe to run again") == true,
                "queued unbound record was not failed with a truthful safety reason")
            cases += 2
            for failure in ["json-write", "mirror-contention"] {
                let folder = root.appendingPathComponent(failure, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                let file = folder.appendingPathComponent("agent-tasks.json")
                let sql = TaskStore(root: folder)
                let persisted = AgentTaskStore(fileURL: file, mirror: sql)
                let interrupted = rows[0]
                check(persisted.save([interrupted]) == .saved, "restart persistence failure fixture did not save")
                let original = try Data(contentsOf: file)
                if failure == "json-write" {
                    // Keep the existing WAL connection alive before blocking atomic
                    // export replacement. The directory failure remains at the JSON
                    // writer boundary, rather than preventing a primary journal open.
                    check(try sql.load() == [interrupted], "restart export fixture lost its primary row")
                    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
                    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
                    let held = AgentTaskManager(store: persisted)
                    check(held.task(id: interrupted.id)?.status == .recovering && held.lastPersistenceResult == .exportFailed,
                        "restart export failure was not visible alongside the committed held state")
                    check(try Data(contentsOf: file) == original && sql.load() == held.tasks
                        && persisted.load() == held.tasks,
                        "failed restart export changed original JSON or hid committed primary history")
                    let heldEvents = try sql.journal(taskID: interrupted.id)
                    check(heldEvents.map(\.draft.kind) == [.recoveryHeld]
                        && heldEvents.allSatisfy { $0.draft.attempt == 3 },
                        "failed restart export lost or fabricated the committed held event")
                } else {
                    let writer = TaskStore(root: folder)
                    defer { writer.close() }
                    try writer.withConnection { db in
                        try TaskStore.exec(db, "BEGIN IMMEDIATE")
                        defer { try? TaskStore.exec(db, "ROLLBACK") }
                        let held = AgentTaskManager(store: persisted)
                        check(held.task(id: interrupted.id) == interrupted && held.lastPersistenceResult == .sqlFailed
                            && held.historyReadFailure != nil && held.backendStartsForTesting == 0,
                            "restart primary contention exposed an uncommitted held state or allowed dispatch")
                        // Read through the other connection; writer's connection lock is
                        // intentionally held by this failure-injection closure.
                        check(try persisted.load() == [interrupted] && sql.load() == [interrupted]
                            && sql.journal(taskID: interrupted.id).isEmpty
                            && Data(contentsOf: file) == original,
                            "contended restart changed committed primary history, journal or export")
                    }
                }
                sql.close()
                cases += 1
            }
            for row in rows[2...7] { check(manager.task(id: row.id) == row, "pending/terminal record changed: \(row.id)") }
            check(!manager.consumePermissionApproval(taskID: "permission"), "restart supplied a reusable one-shot approval")
            cases += 2
            for row in rows[8...] {
                check(manager.task(id: row.id)?.status == .failed
                    && manager.task(id: row.id)?.failure == "Next Notes quit while this task was running.",
                    "out-of-scope owner record falsely remained live or acquired recovery: \(row.id)")
            }
            cases += 1
            check(try AgentTaskStore(fileURL: file, mirror: mirror).load() == manager.tasks,
                "actual held restart decision did not reach authoritative history")
            let second = TaskStore(root: root)
            defer { second.close() }
            check(try second.load() == manager.tasks, "actual held restart did not reach second SQLite reader")
            let events = try second.journal(taskID: "typed-running")
            check(events.map(\.draft.kind.rawValue) == ["recoveryHeld"] && events.first?.draft.attempt == 3,
                "held restart fabricated recovery or lost actual attempt metadata")
            check(!events.compactMap(\.draft.detail).joined().contains("Private"), "held journal copied private content")
            let again = AgentTaskManager(store: AgentTaskStore(fileURL: file, mirror: mirror))
            check(again.tasks == manager.tasks, "second restart changed held/pending/terminal history")
            check(try second.journal(taskID: "typed-running") == events, "second restart fabricated another held transition")
            cases += 2
            for status in [AgentTaskStatus.recovering, .completed] {
                for response in ["input", "permission"] {
                    let folder = root.appendingPathComponent("stale-\(response)-\(status.rawValue)", isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                    let snapshot = AgentTask(id: "stale", objective: "Private frozen work", createdAt: date,
                        status: status, tool: "filesystem.write")
                    let staleStore = AgentTaskStore(fileURL: folder.appendingPathComponent("agent-tasks.json"))
                    check(staleStore.save([snapshot]) == .saved, "stale response fixture did not save")
                    let staleManager = AgentTaskManager(store: staleStore)
                    if response == "input" { staleManager.respondInput(taskID: snapshot.id, text: "Private stale input") }
                    else {
                        staleManager.respondPermission(taskID: snapshot.id, approved: false)
                        staleManager.respondPermission(taskID: snapshot.id, approved: true)
                        check(!staleManager.consumePermissionApproval(taskID: snapshot.id),
                            "stale approval supplied a live one-shot token")
                    }
                    check(staleManager.tasks == [snapshot], "stale \(response) changed \(status.rawValue) work")
                    check(try staleStore.load() == [snapshot], "stale \(response) persisted a false transition")
                    cases += 1
                }
            }
            for references in [[String](), ["fixture://existing"]] {
                let unknownEffect = AgentTask(objective: "Private uncertain effect", status: .failed,
                    artifacts: references, failure: "Known failure reason.")
                check(unknownEffect.failureSummary == "Known failure reason.",
                    "failure summary inferred an effect from artifact absence")
                check(unknownEffect.failureUndoLine == "Review any changes before trying again.",
                    "failure undo line inferred an undo outcome from artifact history")
                let blankReason = AgentTask(objective: "Private uncertain effect", status: .failed, artifacts: references)
                check(blankReason.failureSummary == "This task did not finish.", "blank failure fabricated effect certainty")
                cases += 1
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            for (name, contents) in [("corrupt", Data("{broken legacy history".utf8)),
                                      ("duplicate", try encoder.encode([rows[5], rows[5]]))] {
                let folder = root.appendingPathComponent(name, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                let damaged = folder.appendingPathComponent("agent-tasks.json")
                try contents.write(to: damaged)
                let failedStore = AgentTaskStore(fileURL: damaged)
                do { _ = try failedStore.load(); check(false, "\(name) legacy history was silently accepted") } catch {}
                let failedManager = AgentTaskManager(store: failedStore)
                check(failedManager.historyReadFailure != nil && failedManager.lastPersistenceResult == .loadFailed,
                    "\(name) failed history initialization was invisible")
                let rejected = failedManager.submit(objective: "Private rejected work", tool: "filesystem.read")
                check(rejected.status == .failed && failedManager.tasks.isEmpty,
                    "\(name) failed initialization accepted new executable work")
                check(try Data(contentsOf: damaged) == contents, "\(name) failed submit overwrote original history")
                failedManager.beginScheduledRun(rows[5])
                failedManager.beginVoiceObjective(id: UUID(), objective: "Private rejected voice record")
                failedManager.respondInput(taskID: "missing", text: "Private ignored input")
                failedManager.respondPermission(taskID: "missing", approved: false)
                check(failedManager.tasks.isEmpty, "\(name) failed initialization allowed ordinary record mutation")
                check(failedStore.save([]) != .saved, "\(name) failed load did not block empty save")
                check(try Data(contentsOf: damaged) == contents, "\(name) blocked save erased original history")
                check(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("agent-tasks.sqlite").path),
                    "\(name) failed load/save created or migrated SQLite")
                cases += 1
            }
            let unreadableRoot = root.appendingPathComponent("unreadable-legacy", isDirectory: true)
            try FileManager.default.createDirectory(at: unreadableRoot, withIntermediateDirectories: false)
            let unreadable = unreadableRoot.appendingPathComponent("not-a-history-file", isDirectory: true)
            try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: false)
            do { _ = try AgentTaskStore(fileURL: unreadable).load(); check(false, "unreadable legacy file became empty history") } catch {}
            var retainedDirectory: ObjCBool = false
            check(FileManager.default.fileExists(atPath: unreadable.path, isDirectory: &retainedDirectory)
                && retainedDirectory.boolValue, "unreadable legacy directory was replaced or removed")
            check(!FileManager.default.fileExists(atPath: unreadableRoot.appendingPathComponent(TaskStore.fileName).path),
                "unreadable legacy history created SQLite")
            cases += 1
        } catch { failures.append("isolated recovery fixture failed: \(error.localizedDescription)") }
        failures += SelfTestStoreGuard.diff(before, SelfTestStoreGuard.take()).map { "owner store changed: \($0)" }
        if failures.isEmpty { return "TASK_RECOVERY_OK: \(cases) cases" }
        for failure in failures { SelfTest.diagnostic("TASK_RECOVERY_WRONG: \(failure)") }
        return "TASK_RECOVERY_FAILED: \(failures.count) assertions"
    }

#if !TASK_DURABILITY_STANDALONE
    /// Real explicit text route exercises the injected manager's rejection, not the
    /// uninjected harness simulation. Root registers and runs this app-only boundary.
    static func runIncludingDelegation() async -> String {
        let marker = run()
        guard marker.hasPrefix("TASK_RECOVERY_OK:") else { return marker }
        let before = SelfTestStoreGuard.take()
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }
        let agent = RealtimeAgent.shared
        let oldManager = agent.taskManagerForTesting
        let oldProbe = AgentHarnessRouter.shared.availabilityProbe
        defer {
            agent.taskManagerForTesting = oldManager
            AgentHarnessRouter.shared.availabilityProbe = oldProbe
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NextNotesRecoveryRoute-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let duplicate = AgentTask(id: "duplicate", objective: "Private fixture", status: .completed)
            for (name, contents) in [("corrupt", Data("{broken fixture".utf8)),
                                      ("duplicate", try encoder.encode([duplicate, duplicate])),
                                      ("unreadable", Data())] {
                let folder = root.appendingPathComponent(name, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                let file = folder.appendingPathComponent("agent-tasks.json")
                if name == "unreadable" {
                    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
                    try Data("Original placeholder".utf8).write(to: file.appendingPathComponent("sentinel"))
                } else { try contents.write(to: file) }
                let store = AgentTaskStore(fileURL: file)
                guard store.allowsHarnessPersistence else { throw TaskStoreError.invalidRecord }
                let manager = AgentTaskManager(store: store)
                agent.taskManagerForTesting = manager
                AgentHarnessRouter.shared.availabilityProbe = { _ in true }
                let taskAudits = AgentAuditLog.shared.entries.filter { $0.kind == .task }.count
                let turn = await agent.handle("Use OpenCode to inspect this fixture.", source: .text)
                await Task.yield()
                check(!turn.delegated, "\(name) rejected submit falsely returned delegated")
                check(turn.reply == manager.historyReadFailure,
                    "\(name) rejected submit lost the plain history diagnostic or promised background work")
                check(manager.tasks.isEmpty && manager.lastPersistenceResult == .loadFailed,
                    "\(name) actual delegate inserted or executed rejected work")
                check(AgentAuditLog.shared.entries.filter { $0.kind == .task }.count == taskAudits,
                    "\(name) rejected work emitted a success task audit")
                if name == "unreadable" {
                    check(try Data(contentsOf: file.appendingPathComponent("sentinel")) == Data("Original placeholder".utf8),
                        "unreadable route changed original history directory")
                } else { check(try Data(contentsOf: file) == contents, "\(name) route overwrote original history") }
                for suffix in ["", "-wal", "-shm"] {
                    check(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("agent-tasks.sqlite" + suffix).path),
                        "\(name) rejected route created or migrated SQL")
                }
            }
        } catch { failures.append("isolated actual delegate fixture failed: \(error.localizedDescription)") }
        failures += SelfTestStoreGuard.diff(before, SelfTestStoreGuard.take()).map { "owner store changed: \($0)" }
        if failures.isEmpty {
            let count = Int(marker.split(separator: " ")[1]) ?? 0
            return "TASK_RECOVERY_OK: \(count + 3) cases"
        }
        for failure in failures { SelfTest.diagnostic("TASK_RECOVERY_WRONG: \(failure)") }
        return "TASK_RECOVERY_FAILED: \(failures.count) assertions"
    }
#endif
}

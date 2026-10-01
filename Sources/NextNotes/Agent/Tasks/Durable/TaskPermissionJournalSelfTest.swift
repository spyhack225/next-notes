import Foundation

/// Direct, in-place approval facts. The manager/backend execution-context proof
/// remains in TaskStoreSelfTest; this fixture does not stand in for that call site.
@MainActor
enum TaskPermissionJournalSelfTest {
    static func run() async -> (cases: Int, failures: [String]) {
        let before = SelfTestStoreGuard.take()
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NextNotesJournalPermission-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let oldFake = AgentToolExecutor.fakeForTesting
        let oldFire = AgentToolExecutor.fireOverrideForTesting
        let oldPolicy = AgentToolExecutor.policyOverrideForTesting
        defer {
            AgentToolExecutor.fakeForTesting = oldFake
            AgentToolExecutor.fireOverrideForTesting = oldFire
            AgentToolExecutor.policyOverrideForTesting = oldPolicy
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let mirror = TaskStore(root: directory)
            defer { mirror.close() }
            let store = AgentTaskStore(fileURL: directory.appendingPathComponent("agent-tasks.json"), mirror: mirror)
            guard store.allowsHarnessPersistence else {
                return (0, ["permission fixture was not bound to temporary storage"])
            }
            let manager = AgentTaskManager(store: store)
            let observer = TaskStore(root: directory)
            defer { observer.close() }
            AgentToolExecutor.fakeForTesting = nil
            AgentToolExecutor.policyOverrideForTesting = .denyMutations
            var fires = 0
            AgentToolExecutor.fireOverrideForTesting = { _, _ in
                fires += 1
                return AgentToolResult(summary: "Private fixture result", verification: "Fixture effect recorded")
            }

            for decision in ["approve", "deny", "cancel", "incomplete"] {
                var durability = TaskDurability()
                durability.attempt = 3 // Fixture metadata, not proof of a production lease.
                let task = AgentTask(id: "permission-\(decision)", objective: "Private fixture objective",
                    status: .running, durability: durability)
                manager.beginScheduledRun(task)
                let context = manager.journalContext(taskID: task.id)
                let initialFires = fires
                var finished = false
                var returned = false
                let operation = Task { @MainActor in
                    await TaskEventJournal.$current.withValue(context) {
                        do {
                            _ = try await AgentToolExecutor.run("computer.press_key",
                                arguments: decision == "incomplete" ? [:] : ["key": "tab"],
                                policy: .denyMutations, taskID: task.id, promptIfNeeded: true)
                            returned = true
                        } catch { /* Only the bounded outcome is checked, never private error text. */ }
                    }
                    finished = true
                }
                defer {
                    operation.cancel()
                    PermissionGate.shared.cancelPending(taskID: task.id)
                }
                check(await eventually { PermissionGate.shared.pending?.taskID == task.id },
                    "\(decision): real approval broker did not admit the request")
                let parked = try observer.journal(taskID: task.id)
                check(parked.map(\.draft.kind) == [.jobCreated, .workerStarted, .permissionRequested],
                    "\(decision): admitted in-place approval had no factual requested row")
                check(parked.allSatisfy { $0.draft.attempt == 3 },
                    "\(decision): permission facts lost their captured attempt")
                if let request = PermissionGate.shared.pending, request.taskID == task.id {
                    switch decision {
                    case "approve":
                        check(PermissionGate.shared.respond(id: request.id, approved: true),
                            "valid fixture approval was refused")
                    case "deny":
                        check(PermissionGate.shared.respond(id: request.id, approved: false),
                            "fixture denial was refused")
                    case "cancel": PermissionGate.shared.cancelPending(id: request.id)
                    default:
                        check(!PermissionGate.shared.respond(id: request.id, approved: true),
                            "incomplete review accepted approval")
                        check(!finished && PermissionGate.shared.pending?.id == request.id,
                            "refused approval released its waiter")
                        check(try observer.journal(taskID: task.id) == parked,
                            "refused approval fabricated a resolved event")
                        PermissionGate.shared.cancelPending(id: request.id)
                    }
                } else { operation.cancel() }
                check(await eventually { finished }, "\(decision): approval operation did not settle")
                let events = try observer.journal(taskID: task.id)
                let expected: [TaskEventKind] = decision == "approve"
                    ? [.jobCreated, .workerStarted, .permissionRequested, .permissionApproved, .toolStarted, .toolCompleted]
                    : [.jobCreated, .workerStarted, .permissionRequested, .permissionDenied]
                check(events.map(\.draft.kind) == expected,
                    "\(decision): in-place permission/tool fact order changed")
                check(returned == (decision == "approve") && fires - initialFires == (decision == "approve" ? 1 : 0),
                    "\(decision): incorrect final execution count")
                if decision != "approve" {
                    check(events.last?.draft.detail == "notApproved",
                        "false/cancel outcome did not retain its bounded notApproved detail")
                }
                check(events.allSatisfy { !($0.draft.detail ?? "").contains("Private") },
                    "approval journal copied a private title/body/result")
            }
        } catch { failures.append("permission journal fixture could not read its isolated store") }
        failures += SelfTestStoreGuard.diff(before, SelfTestStoreGuard.take()).map { "owner store changed: \($0)" }
        return (4, failures)
    }

    private static func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while clock.now < deadline {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
}

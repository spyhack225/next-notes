import Foundation

/// P6-01 characterizes today's restart behavior. It does not resume or retry work.
@MainActor
enum TaskStoreSelfTest {
    private enum FixtureError: Error { case unsafeStoreLocation }

    static func run() -> String {
        let before = SelfTestStoreGuard.take()
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NextNotesTaskDurability-\(UUID().uuidString)", isDirectory: true)
        let file = directory.appendingPathComponent("agent-tasks.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            // Establish the exact isolated file before saving any task. The injected store
            // never retries against its default path if this directory/write is unavailable.
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let fixtureStore = AgentTaskStore(fileURL: file)
            guard fixtureStore.storageURL.standardizedFileURL == file.standardizedFileURL else {
                throw FixtureError.unsafeStoreLocation
            }
            check(!FileManager.default.fileExists(atPath: file.path), "fixture ledger was not fresh")
            check(fixtureStore.load().isEmpty, "fresh isolated store was not empty")

            // Whole-second dates survive the production ISO-8601 round trip exactly.
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            let fixtures = [
                AgentTask(id: "durability-running", objective: "Fixture running task", source: "selftest",
                    createdAt: date, status: .running, progress: "Fixture progress"),
                AgentTask(id: "durability-queued", objective: "Fixture queued task", source: "selftest",
                    createdAt: date, status: .queued),
                AgentTask(id: "durability-permission", objective: "Fixture permission task", source: "selftest",
                    createdAt: date, status: .waitingForPermission, progress: "Waiting for you", tool: "fixture.write"),
                AgentTask(id: "durability-completed", objective: "Fixture completed task", source: "selftest",
                    createdAt: date, contextReferences: ["fixture://reference"], status: .completed,
                    progress: "Finished", result: "Fixture result", artifacts: ["fixture://result"],
                    tool: "fixture.read", arguments: ["fixture": "value"],
                    meetingID: UUID(uuidString: "11111111-1111-1111-1111-111111111111"), backend: "acp",
                    acpCLI: "fixture-cli", compatibilityCommand: "fixture-cli fixture-command",
                    compatibilityCLI: "fixture-cli", compatibilityDirectory: "fixture://project",
                    scheduleID: UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
            ]
            fixtureStore.save(fixtures)
            let reopenedStore = AgentTaskStore(fileURL: file)
            guard reopenedStore.storageURL.standardizedFileURL == file.standardizedFileURL else {
                throw FixtureError.unsafeStoreLocation
            }
            check(reopenedStore !== fixtureStore, "restart reused the same store instance")
            check(reopenedStore.load() == fixtures, "fresh store cannot reach the exact persisted ledger")

            // Use the actual fresh-manager initializer, not a duplicated recovery table.
            let restarted = AgentTaskManager(store: reopenedStore)
            let quitMessage = "Next Notes quit while this task was running."
            for id in ["durability-running", "durability-queued"] {
                check(restarted.task(id: id)?.status == .failed, "\(id) did not become failed")
                check(restarted.task(id: id)?.failure == quitMessage, "\(id) lost the exact quit message")
            }
            check(restarted.task(id: "durability-permission") == fixtures[2], "permission record changed on restart")
            check(!restarted.consumePermissionApproval(taskID: "durability-permission"),
                "persisted permission record incorrectly supplied a live one-shot approval")
            check(restarted.task(id: "durability-completed") == fixtures[3], "completed task changed on restart")
            check(restarted.tasks.count == fixtures.count, "restart added or dropped a task")

            // Today the restart mapping is in memory; initialization does not rewrite JSON.
            check(AgentTaskStore(fileURL: file).load() == fixtures, "restart unexpectedly rewrote the persisted ledger")
        } catch {
            failures.append("isolated fixture construction failed: \(error.localizedDescription)")
        }

        failures += SelfTestStoreGuard.diff(before, SelfTestStoreGuard.take()).map { "owner store changed: \($0)" }
        if failures.isEmpty { return "TASK_DURABILITY_OK: 5 cases" }
        for failure in failures { SelfTest.diagnostic("TASK_DURABILITY_WRONG: \(failure)") }
        return "TASK_DURABILITY_FAILED: \(failures.count) assertions"
    }
}

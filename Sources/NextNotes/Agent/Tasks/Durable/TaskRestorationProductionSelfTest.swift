import Foundation
import SQLite3

/// Installed proof through the real request producer, gate, edit store and local
/// backend. Only the external effect is replaced, and it is restricted to this
/// explicitly created temporary file. Reopening managers is not a power-loss test.
@MainActor
enum TaskRestorationProductionSelfTest {
    private enum FixtureError: Error { case unsafeEffect, absentRequest }

    static func run() async -> String {
        let foundation = await TaskRestorationSelfTest.run()
        guard foundation.hasPrefix("TASK_RESTORATION_OK:") else { return foundation }
        let baseCount = Int(foundation.split(separator: " ")[1]) ?? 0
        guard SelfTest.isRunning, PermissionGate.shared.pending == nil else {
            return "TASK_RESTORATION_FAILED: production fixture requires an empty harness gate"
        }
        let before = SelfTestStoreGuard.take()
        let oldFake = AgentToolExecutor.fakeForTesting
        let oldFire = AgentToolExecutor.fireOverrideForTesting
        let oldPolicy = AgentToolExecutor.policyOverrideForTesting
        let grants = PermissionGrantStore.shared.grants
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NextNotesTaskRestorationProduction-\(UUID().uuidString)", isDirectory: true)
        defer {
            PermissionGate.shared.resetForRestartTesting()
            AgentToolExecutor.fakeForTesting = oldFake
            AgentToolExecutor.fireOverrideForTesting = oldFire
            AgentToolExecutor.policyOverrideForTesting = oldPolicy
            try? FileManager.default.removeItem(at: root)
        }
        var failures: [String] = []
        var cases = 0
        func check(_ value: Bool, _ message: String) { if !value { failures.append(message) } }
        func fixture(_ name: String) throws -> (AgentTaskStore, TaskStore, AgentTaskManager) {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let sql = TaskStore(root: directory)
            let store = AgentTaskStore(fileURL: directory.appendingPathComponent("agent-tasks.json"), mirror: sql)
            guard store.allowsHarnessPersistence else { throw FixtureError.unsafeEffect }
            return (store, sql, AgentTaskManager(store: store))
        }
        AgentToolExecutor.fakeForTesting = nil
        AgentToolExecutor.policyOverrideForTesting = .denyMutations
        var fires = 0
        var firedArguments: [[String: String]] = []
        var allowedPath: String?
        var allowedText: String?
        AgentToolExecutor.fireOverrideForTesting = { tool, arguments in
            guard tool.id == "filesystem.write", let path = allowedPath, let text = allowedText,
                  arguments["path"] == path, arguments["text"] == text,
                  URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else {
                throw FixtureError.unsafeEffect
            }
            fires += 1
            firedArguments.append(arguments)
            try Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
            return AgentToolResult(summary: "Fixture note saved", reference: path, verification: "Fixture file written")
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            let output = root.appendingPathComponent("original-approved-note.md")
            let initial = "Original proposed fixture text"
            let edited = "Exact text entered on the restored review"
            let objective = "Write \(initial) to \(output.path)."
            AgentSession.shared.recordUser(objective, source: .text)
            let (store, sql, originalManager) = try fixture("approved-flow")
            defer { sql.close() }
            let submitted = originalManager.submit(objective: objective, tool: "filesystem.write",
                arguments: ["path": output.path, "text": initial, "_fixturePin": "original authorization pin"], source: "text")
            check(await eventually { originalManager.task(id: submitted.id)?.status == .waitingForPermission
                    && PermissionGate.shared.pending?.taskID == submitted.id },
                "real ActionOrchestrator did not commit and present the original local request")
            guard let original = try sql.load().first,
                  case .permission(let request, let origin, let firstReview) = original.pendingInteraction,
                  let firstReview else { throw FixtureError.absentRequest }
            check(original.source == "text" && request.taskID == submitted.id && request.toolID == "filesystem.write"
                && request.arguments["path"] == output.path && request.arguments["text"] == initial
                && request.arguments["_fixturePin"] == "original authorization pin" && firstReview.id == request.id,
                "real producer changed original payload, source or authorization pin")
            check(ActionReceiptStore.shared.receipts.contains { $0.taskID == submitted.id && $0.status == .waitingPermission }
                && fires == 0 && !FileManager.default.fileExists(atPath: output.path),
                "original approval was not genuinely parked before the external effect")
            check(try sql.load().first?.pendingInteraction == original.pendingInteraction,
                "exact real request did not reach SQL authority")
            cases += 1

            PermissionGate.shared.resetForRestartTesting()
            let firstRestart = AgentTaskManager(store: AgentTaskStore(fileURL: store.storageURL, mirror: sql))
            firstRestart.restorePendingInteractions()
            check(PermissionGate.shared.pending == request && PermissionGate.shared.pendingReview == firstReview
                && firstRestart.backendStartsForTesting == 0 && !firstRestart.consumePermissionApproval(taskID: submitted.id),
                "first actual gate restore lost the frozen request/review or supplied a one-shot grant")
            ToolCallReviewStore.shared.update(id: request.id, field: "text", to: edited)
            // Re-confirm the original path through the genuine review producer so no
            // missing/ungrounded target can make this approval fixture accidentally pass.
            ToolCallReviewStore.shared.confirm(id: request.id, field: "path")
            guard let savedReview = PermissionGate.shared.pendingReview else { throw FixtureError.absentRequest }
            check(savedReview.isReadyToRun && savedReview.field("text")?.value == edited && savedReview.wasEdited,
                "genuine review edit did not produce a complete approved payload")
            check(try sql.load().first?.pendingInteraction == .permission(request: request, origin: origin, review: savedReview),
                "actual review edit was accepted without reaching the durable producer")
            cases += 1

            PermissionGate.shared.resetForRestartTesting()
            let secondRestart = AgentTaskManager(store: AgentTaskStore(fileURL: store.storageURL, mirror: sql))
            secondRestart.restorePendingInteractions()
            check(PermissionGate.shared.pending == request && PermissionGate.shared.pendingReview == savedReview,
                "second restart dropped user-entered values or their confirmed provenance")
            let expected = savedReview.executionArguments(mergedOver: request.arguments)
            allowedPath = output.path
            allowedText = edited
            check(PermissionGate.shared.respond(id: request.id, approved: true), "genuine restored approval was refused")
            check(await eventually { secondRestart.task(id: submitted.id)?.status == .completed },
                "real LocalAgentBackend failed to consume its owning manager's one-shot token")
            check(fires == 1 && firedArguments == [expected]
                && (try? String(contentsOf: output, encoding: .utf8)) == edited,
                "the final actual tool boundary did not execute exactly the reviewed payload once")
            check(secondRestart.backendStartsForTesting == 1 && !secondRestart.consumePermissionApproval(taskID: submitted.id)
                && PermissionGate.shared.pending == nil && PermissionGrantStore.shared.grants == grants,
                "one approved run retained a card, reusable grant or unused token")
            check(try sql.load().first?.status == .completed && sql.load().first?.pendingInteraction == nil,
                "actual completion or retired pending state did not reach primary history")
            check(!PermissionGate.shared.respond(id: request.id, approved: true), "stale card approved another action")
            let completedRestart = AgentTaskManager(store: AgentTaskStore(fileURL: store.storageURL, mirror: sql))
            completedRestart.restorePendingInteractions()
            check(completedRestart.backendStartsForTesting == 0 && PermissionGate.shared.pending == nil && fires == 1,
                "completed history replayed a previously approved effect")
            cases += 1

            // Actual manager-produced active/queued requests, using genuine producer
            // capture and genuine gate callbacks. No fake tool/run bypass is involved.
            let (negativeStore, negativeSQL, negativeManager) = try fixture("rejected-cards")
            defer { negativeSQL.close() }
            var ids: [String] = []
            for number in 0..<2 {
                let path = root.appendingPathComponent("negative-\(number).md").path
                let text = "Negative fixture text \(number)"
                AgentSession.shared.recordUser("Write \(text) to \(path).", source: .text)
                let item = negativeManager.submit(objective: "Save negative fixture note", tool: "filesystem.write",
                    arguments: ["path": path, "text": text], source: "text")
                ids.append(item.id)
                check(await eventually { negativeManager.task(id: item.id)?.status == .waitingForPermission },
                    "negative fixture never reached genuine parked permission state")
            }
            check(PermissionGate.shared.pending != nil && PermissionGate.shared.queuedCount == 1,
                "genuine independent requests did not use the one ordered gate queue")
            guard let active = PermissionGate.shared.pending, let review = PermissionGate.shared.pendingReview else {
                throw FixtureError.absentRequest
            }
            check(review.isReadyToRun, "negative fixture approval was incomplete and would mask commit checks")
            let retained = try negativeSQL.load()
            let memoryRetained = negativeManager.tasks
            check(!PermissionGate.shared.respond(id: active.id, approved: true, duration: .alwaysThisAction)
                && !PermissionGate.shared.respond(id: active.id, approved: true, duration: .thisTask)
                && PermissionGate.shared.pending == active && PermissionGrantStore.shared.grants == grants,
                "restored card accepted a standing-grant duration or silently downgraded it to once")
            cases += 1
            negativeManager.respondPermission(taskID: ids[0], approved: true, duration: .alwaysThisAction)
            check(PermissionGate.shared.pending == active && negativeManager.tasks == memoryRetained
                && PermissionGrantStore.shared.grants == grants && fires == 1,
                "manager API bypassed restored one-shot duration contract")
            cases += 1
            try negativeSQL.withConnection { try TaskStore.exec($0,
                "CREATE TRIGGER reject_decisions BEFORE UPDATE ON task BEGIN SELECT RAISE(ABORT,'fixture'); END") }
            check(!PermissionGate.shared.respond(id: active.id, approved: true)
                && PermissionGate.shared.pending == active && PermissionGate.shared.queuedCount == 1,
                "failed primary approval hid its real card or advanced the queue")
            cases += 1
            ToolCallReviewStore.shared.update(id: active.id, field: "text", to: "Uncommitted replacement")
            check(PermissionGate.shared.pendingReview == review && negativeManager.tasks == memoryRetained,
                "failed review edit changed the real card or manager snapshot")
            check(try negativeSQL.load() == retained && fires == 1, "failed edit changed primary history or fired")
            cases += 1
            negativeManager.cancel(ids[0])
            check(PermissionGate.shared.pending == active && negativeManager.tasks == memoryRetained,
                "manager stop bypassed the rejected card decision")
            PermissionGate.shared.cancelPending(taskID: ids[0])
            check(PermissionGate.shared.pending == active && PermissionGate.shared.queuedCount == 1,
                "targeted failed cancellation hid the exact active card")
            PermissionGate.shared.cancelPending()
            check(PermissionGate.shared.pending == active && PermissionGate.shared.queuedCount == 1
                && negativeManager.tasks == memoryRetained && fires == 1,
                "global failed cancellation discarded retained active/queued cards")
            check(try negativeSQL.load() == retained, "rejected cancellation changed primary history")
            cases += 1
            try negativeSQL.withConnection { try TaskStore.exec($0, "DROP TRIGGER reject_decisions") }
            PermissionGate.shared.cancelPending()
            check(PermissionGate.shared.pending == nil && PermissionGate.shared.queuedCount == 0
                && ids.allSatisfy { negativeManager.task(id: $0)?.status == .cancelled } && fires == 1,
                "committed cancellation did not retire every genuine restored card without fire")
            check(try negativeSQL.load().allSatisfy { $0.status == .cancelled && $0.pendingInteraction == nil },
                "committed cancellation did not reach durable retained history")
            let cancelledRestart = AgentTaskManager(store: AgentTaskStore(fileURL: negativeStore.storageURL, mirror: negativeSQL))
            cancelledRestart.restorePendingInteractions()
            check(PermissionGate.shared.pending == nil && cancelledRestart.backendStartsForTesting == 0,
                "cancelled requests returned after restart")
            cases += 1
        } catch { failures.append("real production restoration fixture: \(error)") }
        failures += SelfTestStoreGuard.diff(before, SelfTestStoreGuard.take()).map { "owner changed: \($0)" }
        for failure in failures { SelfTest.diagnostic("TASK_RESTORATION_WRONG: \(failure)") }
        return failures.isEmpty ? "TASK_RESTORATION_OK: \(baseCount + cases) cases"
            : "TASK_RESTORATION_FAILED: \(failures.count) assertions"
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

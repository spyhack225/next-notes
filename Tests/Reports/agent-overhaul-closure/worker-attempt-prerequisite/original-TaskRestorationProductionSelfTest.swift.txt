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
        let input = await runInputClarification()
        guard input.hasPrefix("TASK_INPUT_CLARIFICATION_OK:") else { return input }
        let inputCount = Int(input.split(separator: " ")[1]) ?? 0
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
            guard let restoredContext = secondRestart.journalContext(taskID: submitted.id) else {
                throw FixtureError.absentRequest
            }
            check(restoredContext.restoredPermission == request && restoredContext.restoredArguments == expected,
                "actual owning manager did not bind its exact retained request and edited arguments")
            var changed = expected
            changed["_fixturePin"] = "changed authorization pin"
            var changedDenied = false
            do {
                _ = try await TaskEventJournal.$current.withValue(restoredContext) {
                    try await AgentToolExecutor.run("filesystem.write", arguments: changed,
                        policy: .denyMutations, taskID: submitted.id, permissionAlreadyGranted: true)
                }
            } catch let error as AgentError {
                if case .permissionDenied(let reason) = error {
                    changedDenied = reason == "The action changed since you reviewed it. Please review it again."
                }
            } catch { }
            check(changedDenied && fires == 0 && !FileManager.default.fileExists(atPath: output.path),
                "actual executor accepted a changed authorization pin or reached the effect before exact-payload denial")
            check(secondRestart.tasks.first?.status == .waitingForPermission && PermissionGate.shared.pending == request,
                "negative final-boundary validation consumed the original waiting card")
            cases += 1
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

            // An ephemeral remote-origin context is not permission to restore remote
            // work. This calls the genuine executor/runtime/broker to prove the origin
            // reaches the broker's narrower budget, even beside an approval Boolean.
            // The effect override refuses every shell command before any backing runs.
            let remoteContext = TaskJournalContext(taskID: "origin-budget-fixture", attempt: 0,
                record: { _ in }, restoredOrigin: ActionOriginContext(transport: .iMessage))
            var remoteDenied = false
            do {
                _ = try await TaskEventJournal.$current.withValue(remoteContext) {
                    try await AgentToolExecutor.run("shell.run", arguments: ["command": "sudo /usr/bin/true"],
                        policy: .denyMutations, taskID: remoteContext.taskID, permissionAlreadyGranted: true)
                }
            } catch let error as AgentError {
                if case .permissionDenied(let reason) = error { remoteDenied = reason == RemoteAccessPolicy.sudoDenied }
            } catch { }
            check(remoteDenied && fires == 1 && PermissionGate.shared.pending == nil,
                "actual executor/runtime lost origin before the real broker's remote denial")
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
                check(await eventually {
                    negativeManager.task(id: item.id)?.status == .waitingForPermission
                        && PermissionGate.shared.hasRestoredRequest(taskID: item.id)
                }, "negative fixture never reached its genuine parked request and actual gate consumer")
                SelfTest.diagnostic("TASK_RESTORATION_QUEUE_PROBE: request=\(number) parked=\(negativeManager.task(id: item.id)?.status == .waitingForPermission) restored=\(PermissionGate.shared.hasRestoredRequest(taskID: item.id)) queued=\(PermissionGate.shared.queuedCount)")
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

            // The existing gate queue also holds live continuations. A failed durable
            // cancellation must retain its own card without trapping an unrelated live
            // waiter, regardless of which request was visible first.
            for restoredFirst in [true, false] {
                let (_, mixedSQL, mixedManager) = try fixture(restoredFirst ? "restored-first" : "live-first")
                defer { mixedSQL.close() }
                let task = AgentTask(id: "mixed-\(restoredFirst)", objective: "Save isolated mixed-queue note",
                    source: "text", createdAt: Date(timeIntervalSince1970: 1_700_000_000), status: .running, tool: "filesystem.write",
                    arguments: ["path": root.appendingPathComponent("mixed-\(restoredFirst).md").path,
                                "text": "Isolated mixed-queue fixture"])
                mixedManager.beginScheduledRun(task)
                let retainedRequest = PermissionRequest(id: "retained-\(restoredFirst)", toolID: task.tool!,
                    title: "Save isolated fixture", detail: "Isolated mixed-queue note", risk: .modify,
                    arguments: task.arguments, taskID: task.id, createdAt: task.createdAt, trigger: .youSaid(task.objective))
                check(mixedManager.parkPermission(retainedRequest), "mixed-queue producer did not commit its real request")
                let retainedRows = mixedManager.tasks
                if restoredFirst { mixedManager.restorePendingInteractions() }
                let liveRequest = PermissionRequest(id: "live-\(restoredFirst)", toolID: "filesystem.write",
                    title: "Save separate fixture", detail: "Independent live waiter", risk: .modify,
                    arguments: ["path": root.appendingPathComponent("live-\(restoredFirst).md").path,
                                "text": "Independent live request"], taskID: "live-only-\(restoredFirst)")
                var liveAnswer: Bool?
                let liveWaiter = Task { @MainActor in liveAnswer = await PermissionGate.shared.ask(liveRequest) }
                defer { liveWaiter.cancel() }
                check(await eventually {
                    restoredFirst ? PermissionGate.shared.queuedCount == 1
                        : PermissionGate.shared.pending?.id == liveRequest.id
                }, "mixed fixture never reached the real live continuation")
                if !restoredFirst { mixedManager.restorePendingInteractions() }
                check(PermissionGate.shared.queuedCount == 1, "mixed queue duplicated or lost a request")
                try mixedSQL.withConnection { try TaskStore.exec($0,
                    "CREATE TRIGGER reject_mixed BEFORE UPDATE ON task BEGIN SELECT RAISE(ABORT,'fixture'); END") }
                PermissionGate.shared.cancelPending()
                check(await eventually { liveAnswer == false }, "failed durable cancellation trapped an unrelated live waiter")
                check(PermissionGate.shared.pending == retainedRequest && PermissionGate.shared.queuedCount == 0
                    && !PermissionGate.shared.pendingAllowsStandingGrant && mixedManager.tasks == retainedRows,
                    "mixed global cancellation discarded or widened the retained durable card")
                check(try mixedSQL.load() == retainedRows && mixedManager.backendStartsForTesting == 0 && fires == 1,
                    "mixed cancellation changed durable history or dispatched an effect")
                try mixedSQL.withConnection { try TaskStore.exec($0, "DROP TRIGGER reject_mixed") }
                PermissionGate.shared.cancelPending()
                check(PermissionGate.shared.pending == nil && mixedManager.task(id: task.id)?.status == .cancelled,
                    "mixed retained card did not retire after its decision committed")
                // A broken continuation is an assertion failure, not an unbounded
                // await that prevents the flag from ever printing its verdict.
                if liveAnswer == nil { PermissionGate.shared.resetForRestartTesting() }
                cases += 1
            }

            // This harness-only restart seam drops ephemeral continuations without
            // claiming any persisted approval or cancellation. Verify it against the
            // real gate so teardown cannot leave an indefinitely suspended waiter.
            let resetRequest = PermissionRequest(id: "reset-live", toolID: "filesystem.write",
                title: "Save reset fixture", detail: "Harness reset only", risk: .modify,
                arguments: ["path": root.appendingPathComponent("reset.md").path, "text": "Reset fixture"])
            var resetAnswer: Bool?
            let resetWaiter = Task { @MainActor in resetAnswer = await PermissionGate.shared.ask(resetRequest) }
            defer { resetWaiter.cancel() }
            check(await eventually { PermissionGate.shared.pending == resetRequest }, "reset fixture did not suspend a real waiter")
            PermissionGate.shared.resetForRestartTesting()
            check(await eventually { resetAnswer == false }, "restart reset left the real continuation suspended")
            check(PermissionGate.shared.pending == nil && PermissionGate.shared.queuedCount == 0
                && PermissionGrantStore.shared.grants == grants && fires == 1,
                "restart reset supplied authority, retained a card or fired an effect")
            cases += 1
        } catch { failures.append("real production restoration fixture: \(error)") }
        failures += SelfTestStoreGuard.diff(before, SelfTestStoreGuard.take()).map { "owner changed: \($0)" }
        for failure in failures { SelfTest.diagnostic("TASK_RESTORATION_WRONG: \(failure)") }
        return failures.isEmpty ? "TASK_RESTORATION_OK: \(baseCount + cases + inputCount) cases"
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

    /// Actual missing-argument producer, retained bound question and explicit answer.
    /// Only the final backing is overridden, and it calls the real filesystem reader
    /// against one exact temporary file. No owner file or network can be read.
    static func runInputClarification() async -> String {
        guard SelfTest.isRunning, PermissionGate.shared.pending == nil else {
            return "TASK_INPUT_CLARIFICATION_FAILED: empty harness required"
        }
        let before = SelfTestStoreGuard.take()
        let oldFake = AgentToolExecutor.fakeForTesting
        let oldFire = AgentToolExecutor.fireOverrideForTesting
        let oldPolicy = AgentToolExecutor.policyOverrideForTesting
        let grants = PermissionGrantStore.shared.grants
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NextNotesTaskInputProduction-\(UUID().uuidString)", isDirectory: true)
        defer {
            AgentToolExecutor.fakeForTesting = oldFake
            AgentToolExecutor.fireOverrideForTesting = oldFire
            AgentToolExecutor.policyOverrideForTesting = oldPolicy
            PermissionGate.shared.resetForRestartTesting()
            try? FileManager.default.removeItem(at: root)
        }
        var failures: [String] = []
        var cases = 0
        var fires = 0
        var firedArguments: [[String: String]] = []
        func check(_ value: Bool, _ message: String) {
            cases += 1
            if !value { failures.append(message) }
        }
        func settled(_ manager: AgentTaskManager, _ id: String) async -> Bool {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while [.queued, .running].contains(manager.task(id: id)?.status ?? .failed), ContinuousClock.now < deadline {
                await Task.yield()
            }
            return ![.queued, .running].contains(manager.task(id: id)?.status ?? .failed)
        }
        // The existing store contract uses ISO8601 seconds for Codable timestamps.
        // Compare that canonical projection without hiding any pending payload field.
        func canonical(_ rows: [AgentTask]) throws -> [AgentTask] {
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([AgentTask].self, from: encoder.encode(rows))
        }
        func fixture(_ name: String) throws -> (AgentTaskStore, TaskStore, AgentTaskManager) {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let sql = TaskStore(root: directory)
            let store = AgentTaskStore(fileURL: directory.appendingPathComponent("agent-tasks.json"), mirror: sql)
            guard store.allowsHarnessPersistence else { throw FixtureError.unsafeEffect }
            return (store, sql, AgentTaskManager(store: store))
        }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            let file = root.appendingPathComponent("original.txt")
            let contents = "Original local read clarification fixture"
            try contents.write(to: file, atomically: true, encoding: .utf8)
            AgentToolExecutor.fakeForTesting = nil
            AgentToolExecutor.policyOverrideForTesting = .selfTest
            AgentToolExecutor.fireOverrideForTesting = { tool, arguments in
                guard tool.id == "filesystem.read", arguments == ["path": file.path] else {
                    throw FixtureError.unsafeEffect
                }
                fires += 1
                firedArguments.append(arguments)
                return try FilesystemExecutor.run(tool, arguments: arguments)
            }
            let (store, sql, manager) = try fixture("original")
            defer { sql.close() }
            let original = manager.submit(objective: "Read my chosen fixture file", tool: "filesystem.read", source: "text")
            check(await settled(manager, original.id), "original missing-path producer did not settle")
            let question = manager.pendingInputs.first
            check(manager.task(id: original.id)?.status == .waitingForInput
                && question?.question == "Which file?" && question?.toolID == "filesystem.read"
                && question?.argumentName == "path" && question?.taskID == original.id,
                "actual missing-path producer failed instead of asking its bound review question")
            check(fires == 0 && manager.backendStartsForTesting == 1 && PermissionGate.shared.pending == nil,
                "incomplete read fired or introduced a permission confirmation")
            check(try sql.load() == canonical(manager.tasks) && sql.journal(taskID: original.id).last?.draft.kind == .inputRequested,
                "actual question never reached the primary row and journal")
            let primaryQuestion = try sql.load().first.flatMap { row -> TaskInputRequest? in
                if case .input(let request) = row.pendingInteraction { return request }
                return nil
            }
            if let question = primaryQuestion {
                let fresh = AgentTaskManager(store: AgentTaskStore(fileURL: store.storageURL, mirror: sql))
                check(fresh.pendingInputs == [question] && fresh.backendStartsForTesting == 0
                    && fresh.canRespondInput(taskID: original.id, requestID: question.id)
                    && fresh.inputField(taskID: original.id, requestID: question.id)?.kind == .file,
                    "fresh manager lost the exact bound question or automatically executed it")
                let retained = fresh.tasks
                check(!fresh.respondInput(taskID: original.id, text: file.path, requestID: "stale")
                    && !fresh.respondInput(taskID: original.id, text: file.path)
                    && !fresh.respondInput(taskID: original.id, text: "", requestID: question.id)
                    && !fresh.respondInput(taskID: original.id, text: "[Name]", requestID: question.id),
                    "stale, unidentified, blank or placeholder answer acquired execution")
                check(fresh.tasks == retained && fresh.pendingInputs == [question] && fires == 0
                    && fresh.backendStartsForTesting == 0,
                    "rejected answer changed retained question state")
                let witness = try Data(contentsOf: store.storageURL)
                try sql.withConnection { try TaskStore.exec($0,
                    "CREATE TRIGGER reject_input_answer BEFORE UPDATE ON task BEGIN SELECT RAISE(ABORT,'fixture'); END") }
                check(!fresh.respondInput(taskID: original.id, text: file.path, requestID: question.id)
                    && fresh.lastPersistenceResult == .sqlFailed, "answer accepted an uncommitted transition")
                check(try fresh.tasks == retained && sql.load() == retained && fresh.pendingInputs == [question]
                    && Data(contentsOf: store.storageURL) == witness && fresh.backendStartsForTesting == 0 && fires == 0,
                    "rejected answer commit hid its card, changed history or dispatched")
                try sql.withConnection { try TaskStore.exec($0, "DROP TRIGGER reject_input_answer") }
                check(fresh.respondInput(taskID: original.id, text: file.path, requestID: question.id),
                    "accepted exact answer did not use its bound continuation")
                let accepted = try sql.load().first
                check(accepted?.status == .queued && accepted?.arguments == ["path": file.path]
                    && fresh.pendingInputs.isEmpty && fresh.backendStartsForTesting == 0
                    && !fresh.consumePermissionApproval(taskID: original.id),
                    "answer did not commit the exact schema key before dispatch, or minted permission")
                check(!fresh.respondInput(taskID: original.id, text: file.path, requestID: question.id),
                    "duplicate answer queued a second execution")
                check(await settled(fresh, original.id), "answered read did not settle")
                check(fresh.task(id: original.id)?.status == .completed && fresh.task(id: original.id)?.result == contents
                    && fresh.backendStartsForTesting == 1 && fires == 1 && firedArguments == [["path": file.path]],
                    "actual backend/executor did not consume the answered path exactly once")
                let terminal = AgentTaskManager(store: AgentTaskStore(fileURL: store.storageURL, mirror: sql))
                check(try terminal.tasks == canonical(fresh.tasks) && terminal.pendingInputs.isEmpty && terminal.backendStartsForTesting == 0,
                    "terminal restart restored the old question or replayed the read")
            }

            let legacy = TaskInputRequest(id: "legacy-question", taskID: "legacy", question: "Original unknown question",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000))
            let encoder = JSONEncoder()
            var oldObject = try JSONSerialization.jsonObject(with: encoder.encode(legacy)) as! [String: Any]
            oldObject.removeValue(forKey: "toolID")
            oldObject.removeValue(forKey: "argumentName")
            let oldPayload = try JSONDecoder().decode(TaskInputRequest.self, from: JSONSerialization.data(withJSONObject: oldObject))
            check(oldPayload == legacy && oldPayload.toolID == nil && oldPayload.argumentName == nil,
                "old question decoding invented or discarded its binding/content")
            let (legacyStore, legacySQL, _) = try fixture("legacy")
            defer { legacySQL.close() }
            let legacyTask = AgentTask(id: legacy.taskID, objective: "Original unknown read", source: "text",
                createdAt: legacy.createdAt, status: .waitingForInput, tool: "filesystem.read", pendingInteraction: .input(oldPayload))
            check(legacyStore.save([legacyTask]).primaryCommitted, "legacy question fixture did not save")
            let heldLegacy = AgentTaskManager(store: AgentTaskStore(fileURL: legacyStore.storageURL, mirror: legacySQL))
            check(heldLegacy.pendingInputs == [legacy] && !heldLegacy.canRespondInput(taskID: legacy.taskID, requestID: legacy.id)
                && heldLegacy.inputAnswerProblem(taskID: legacy.taskID, requestID: legacy.id, text: file.path) != nil
                && !heldLegacy.respondInput(taskID: legacy.taskID, text: file.path, requestID: legacy.id)
                && heldLegacy.tasks == [legacyTask] && heldLegacy.backendStartsForTesting == 0,
                "legacy question lost its content or dispatched guessed generic input")

            for kind in ["changed-tool", "unknown-field", "mutating", "remote", "acp", "unsupported-search", "unsupported-directory"] {
                let (heldStore, heldSQL, _) = try fixture(kind)
                defer { heldSQL.close() }
                let id = "held-" + kind
                let scopedTool = kind == "unsupported-search" ? "filesystem.search"
                    : kind == "unsupported-directory" ? "filesystem.tree" : "filesystem.read"
                let bound = TaskInputRequest(id: id, taskID: id, question: "Which file?", createdAt: legacy.createdAt,
                    toolID: kind == "changed-tool" ? "filesystem.search" : kind == "mutating" ? "filesystem.write" : scopedTool,
                    argumentName: kind == "unknown-field" ? "unknown" : kind == "unsupported-search" ? "query" : "path")
                let held = AgentTask(id: id, objective: "Retain this original request",
                    source: kind == "remote" ? "iMessage" : "text", createdAt: legacy.createdAt, status: .waitingForInput,
                    tool: kind == "mutating" ? "filesystem.write" : scopedTool,
                    backend: kind == "acp" ? "acp" : "local", pendingInteraction: .input(bound))
                check(heldStore.save([held]).primaryCommitted, "held question fixture did not save: \(kind)")
                let rejected = AgentTaskManager(store: AgentTaskStore(fileURL: heldStore.storageURL, mirror: heldSQL))
                check(!rejected.canRespondInput(taskID: id, requestID: bound.id)
                    && !rejected.respondInput(taskID: id, text: file.path, requestID: bound.id)
                    && rejected.tasks == [held] && rejected.backendStartsForTesting == 0,
                    "changed, unknown or independently owned binding acquired replay: \(kind)")
            }

            // A one-answer file question must not claim to repair another tool's
            // incomplete call or offer a file-only picker for a directory.
            for (name, tool, arguments) in [
                ("search-with-placeholder-folder", "filesystem.search", ["folder": "TBD"]),
                ("directory-without-path", "filesystem.tree", [String: String]()),
            ] {
                let (_, unsupportedSQL, unsupported) = try fixture(name)
                defer { unsupportedSQL.close() }
                let initialFires = fires
                let rejected = unsupported.submit(objective: "Keep unsupported clarification explicit",
                    tool: tool, arguments: arguments, source: "text")
                check(await settled(unsupported, rejected.id), "unsupported missing-argument producer did not settle: \(name)")
                check(try unsupported.task(id: rejected.id)?.status == .failed && unsupported.pendingInputs.isEmpty
                    && unsupported.task(id: rejected.id)?.pendingInteraction == nil
                    && unsupportedSQL.journal(taskID: rejected.id).allSatisfy { $0.draft.kind != .inputRequested }
                    && fires == initialFires && unsupported.backendStartsForTesting == 1,
                    "unsupported incomplete read parked an unanswerable file question: \(name)")
            }

            let (cancelStore, cancelSQL, _) = try fixture("cancel")
            defer { cancelSQL.close() }
            let cancelledQuestion = TaskInputRequest(id: "cancel-request", taskID: "cancel-task", question: "Which file?", createdAt: legacy.createdAt,
                toolID: "filesystem.read", argumentName: "path")
            let waiting = AgentTask(id: "cancel-task", objective: "Cancel this read question", source: "text",
                createdAt: legacy.createdAt, status: .waitingForInput, tool: "filesystem.read", pendingInteraction: .input(cancelledQuestion))
            check(cancelStore.save([waiting]).primaryCommitted, "cancel question fixture did not save")
            let cancelManager = AgentTaskManager(store: AgentTaskStore(fileURL: cancelStore.storageURL, mirror: cancelSQL))
            try cancelSQL.withConnection { try TaskStore.exec($0,
                "CREATE TRIGGER reject_input_cancel BEFORE UPDATE ON task BEGIN SELECT RAISE(ABORT,'fixture'); END") }
            cancelManager.cancel(waiting.id)
            check(try cancelManager.tasks == [waiting] && cancelSQL.load() == [waiting]
                && cancelManager.pendingInputs == [cancelledQuestion] && cancelManager.backendStartsForTesting == 0,
                "rejected cancellation lost the exact input card or dispatched")
            try cancelSQL.withConnection { try TaskStore.exec($0, "DROP TRIGGER reject_input_cancel") }
            cancelManager.cancel(waiting.id)
            check(cancelManager.task(id: waiting.id)?.status == .cancelled && cancelManager.pendingInputs.isEmpty
                && !cancelManager.respondInput(taskID: waiting.id, text: file.path, requestID: cancelledQuestion.id),
                "cancelled input accepted a stale answer")

            let (producerStore, producerSQL, producerManager) = try fixture("rejected-question")
            defer { producerSQL.close() }
            try producerSQL.withConnection { try TaskStore.exec($0,
                "CREATE TRIGGER reject_input_question BEFORE INSERT ON task_event WHEN NEW.kind='inputRequested' BEGIN SELECT RAISE(ABORT,'fixture'); END") }
            let failedQuestion = producerManager.submit(objective: "Read without an admitted question", tool: "filesystem.read", source: "text")
            check(await settled(producerManager, failedQuestion.id), "rejected question did not settle")
            check(try producerManager.pendingInputs.isEmpty && producerManager.task(id: failedQuestion.id)?.status == .failed
                && producerSQL.journal(taskID: failedQuestion.id).allSatisfy { $0.draft.kind != .inputRequested }
                && producerStore.load() == canonical(producerManager.tasks) && fires == 1,
                "uncommitted producer question reached a card or read effect")
            check(PermissionGate.shared.pending == nil && PermissionGrantStore.shared.grants == grants,
                "read clarification created a second confirmation or changed a stored grant")
        } catch { failures.append("actual input fixture: \(error)") }
        failures += SelfTestStoreGuard.diff(before, SelfTestStoreGuard.take()).map { "owner changed: \($0)" }
        for failure in failures { SelfTest.diagnostic("TASK_INPUT_CLARIFICATION_WRONG: \(failure)") }
        return failures.isEmpty ? "TASK_INPUT_CLARIFICATION_OK: \(cases) cases"
            : "TASK_INPUT_CLARIFICATION_FAILED: \(failures.count) assertions"
    }

}

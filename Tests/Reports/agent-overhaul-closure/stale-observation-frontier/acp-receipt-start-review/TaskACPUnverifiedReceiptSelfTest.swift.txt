import Foundation

/// Off-source fixture for root registration: actual Manager -> ACP -> owned peer -> receipt.
/// Freeze unchanged for original/fixed. Does not prove effect outcome, retry or crash durability.
@MainActor
enum TaskACPUnverifiedReceiptSelfTest {
    private enum FixtureError: Error { case unsafeRoot, missingContext, missingRow, timeout, missingSnapshot }

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

    // Real writer uses ISO8601 seconds; compare persisted representation, not subsecond memory dates.
    private static func canonicalReceipt(_ receipt: ActionReceipt) throws -> ActionReceipt {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ActionReceipt.self, from: encoder.encode(receipt))
    }

    private static func peerDiagnostic(directory: URL, mode: String) {
        let stderr = (try? String(contentsOf: directory.appendingPathComponent("peer-stderr.txt"), encoding: .utf8)) ?? "missing"
        let detail = String(stderr.prefix(8192)).replacingOccurrences(of: "\n", with: " | ")
        SelfTest.diagnostic("TASK_ACP_UNVERIFIED_PEER: mode=\(mode) stderr=\(detail)")
    }

    static func originalCases(root: URL, check: (Bool, String) -> Void) async throws {
        let safe = root.resolvingSymlinksInPath().standardizedFileURL
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard SelfTest.isRunning, safe.isFileURL, safe.path.hasPrefix(temporary.path + "/"),
              !safe.pathComponents.contains("Application Support") else { throw FixtureError.unsafeRoot }
        let owner = String(ProcessInfo.processInfo.processIdentifier)
        let objective = "Owned ACP unverified receipt fixture: no tools or external effects"
        let marker = "Owned ACP unverified fixture reply."
        let sessionID = "fixture-unverified-receipt"
        let warning = "\nNext Notes could not independently verify the effect. Inspect the target before retrying."
        let failure = "The action ran, but its result could not be saved. Check it before trying again."
        for mode in ["accepted", "terminal-write-rejected"] {
            let directory = safe.appendingPathComponent("acp-unverified-" + mode, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let sql = TaskStore(root: directory)
            defer { sql.close() }
            let export = directory.appendingPathComponent("agent-tasks.json")
            let store = AgentTaskStore(fileURL: export, mirror: sql)
            guard store.allowsHarnessPersistence else { throw FixtureError.unsafeRoot }
            let receiptFile = directory.appendingPathComponent("action-receipts.json")
            let snapshotFile = directory.appendingPathComponent("prompt-fired-snapshot.json")
            let retainedFile = directory.appendingPathComponent("retained-fired.json")
            let script = directory.appendingPathComponent("owned-peer.py")
            let configFile = directory.appendingPathComponent("config.json")
            try peer.write(to: script, atomically: true, encoding: .utf8)
            let receipts = ActionReceiptStore(fileURL: receiptFile)
            let manager = AgentTaskManager(store: store, receiptStore: receipts)
            var context: TaskJournalContext?
            var rowAtEntry: AgentTask?
            var bindingAtEntry: TaskWorkerBinding?
            var entered = 0
            var ended = 0
            var announcements: [String] = []
            manager.announcementForTesting = { announcements.append($0) }
            manager.backendExitForTesting = { ended += 1 }
            manager.backendEntryForTesting = {
                entered += 1
                guard let captured = TaskEventJournal.current else { throw FixtureError.missingContext }
                context = captured
                let reader = TaskStore(root: directory)
                defer { reader.close() }
                guard let row = try reader.load().first(where: { $0.id == captured.taskID }) else {
                    throw FixtureError.missingRow
                }
                rowAtEntry = row
                bindingAtEntry = manager.workerBinding(taskID: captured.taskID)
                // Real task ID is produced by submit. Config is a sibling JSON file read by the peer.
                let config: [String: Any] = ["mode": mode, "marker": marker, "objective": objective,
                    "taskID": captured.taskID, "taskAttempt": 1, "taskLeaseOwner": owner,
                    "database": sql.fileURL.path]
                try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
                    .write(to: configFile, options: .atomic)
            }
            let submitted = manager.submit(objective: objective, arguments: ["acpFixture": script.path],
                backend: .acp, source: "selftest")
            do {
                guard await reached({ ended == 1 }) else {
                    peerDiagnostic(directory: directory, mode: mode)
                    manager.cancel(submitted.id)
                    let drained = await reached { ended == 1 }
                    check(drained, "ACP unverified: same owned worker did not drain after timeout cleanup (\(mode))")
                    throw FixtureError.timeout
                }
                let final = manager.task(id: submitted.id)
                let freshSQL = TaskStore(root: directory)
                defer { freshSQL.close() }
                let primary = try freshSQL.load().first { $0.id == submitted.id }
                let events = try freshSQL.journal(taskID: submitted.id)
                let launch = object(directory.appendingPathComponent("launch.json"))
                let consumed = object(directory.appendingPathComponent("prompt-consumed.json"))
                let observedPrimary = object(directory.appendingPathComponent("prompt-primary.json"))
                let observedDurability = observedPrimary["durability"] as? [String: Any] ?? [:]
                let calls = (try? JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("calls.json")))) as? [String]
                let snapshot = ActionReceiptStore(fileURL: snapshotFile)
                guard snapshot.receipts.count == 1, let fired = snapshot.receipts.first else {
                    peerDiagnostic(directory: directory, mode: mode)
                    throw FixtureError.missingSnapshot
                }
                let memory = receipts.receipt(for: fired.actionID)
                let snapshotBytes = try Data(contentsOf: snapshotFile)
                let stderr = (try? String(contentsOf: directory.appendingPathComponent("peer-stderr.txt"), encoding: .utf8)) ?? "missing"
                check(entered == 1 && ended == 1 && manager.backendStartsForTesting == 1
                    && launch["launchCount"] as? Int == 1
                    && calls == ["initialize", "session/new", "session/prompt"] && stderr.isEmpty,
                    "ACP unverified: actual owned protocol did not initialize/new/prompt exactly once (\(mode))")
                check(rowAtEntry?.status == .running && rowAtEntry?.durability?.attempt == 1
                    && rowAtEntry?.durability?.leaseOwner == owner
                    && rowAtEntry?.durability?.runtimeClass == .acpWorker
                    && rowAtEntry?.durability?.attemptStartedAt != nil
                    && rowAtEntry?.durability?.resumePolicy == .neverAuto,
                    "ACP unverified: original backend lacked committed positive ACP ownership (\(mode))")
                check(context?.taskID == submitted.id && context?.attempt == 1
                    && context?.leaseOwner == owner && context?.receiptStore === receipts
                    && context?.isStillValid != nil && bindingAtEntry?.taskID == submitted.id
                    && bindingAtEntry?.attempt == 1 && bindingAtEntry?.leaseOwner == owner,
                    "ACP unverified: original context/handle did not bind the injected receipt writer (\(mode))")
                check(observedPrimary["taskID"] as? String == submitted.id
                    && observedPrimary["state"] as? String == "running"
                    && observedDurability["attempt"] as? Int == 1
                    && observedDurability["leaseOwner"] as? String == owner
                    && observedDurability["runtimeClass"] as? String == "acpWorker"
                    && observedDurability["attemptStartedAt"] != nil,
                    "ACP unverified: actual peer prompt did not see current primary ownership (\(mode))")
                check(fired.taskID == submitted.id && fired.taskAttempt == 1 && fired.taskLeaseOwner == owner
                    && fired.status == .fired && fired.events.last?.stage == .fired
                    && fired.toolID == "mcp.acp_session" && fired.preparedAction?.id == fired.actionID
                    && fired.preparedAction?.routing.taskID == submitted.id
                    && fired.preparedAction?.executionPlan.toolID == fired.toolID
                    && fired.preparedAction?.executionPlan.arguments["objective"] == objective
                    && consumed["actionID"] as? String == fired.actionID.uuidString
                    && consumed["taskID"] as? String == submitted.id
                    && consumed["objective"] as? String == objective
                    && consumed["sessionID"] as? String == sessionID,
                    "ACP unverified: actual prompt lacked exact saved fired receipt ownership (\(mode))")
                check(primary?.durability?.attempt == 1 && primary?.durability?.leaseOwner == owner
                    && final?.durability?.attempt == 1 && final?.durability?.leaseOwner == owner
                    && primary?.durability?.receiptIDs == [fired.actionID.uuidString]
                    && final?.durability?.receiptIDs == primary?.durability?.receiptIDs,
                    "ACP unverified: terminal history changed admitted ACP attempt or lost the exact startup receipt join (\(mode))")
                if mode == "accepted" {
                    let persisted = ActionReceiptStore(fileURL: receiptFile).receipt(for: fired.actionID)
                    check(final?.status == .completed && primary?.status == .completed
                        && final?.result == marker + warning && primary?.result == final?.result
                        && final?.artifacts == [sessionID] && primary?.artifacts == [sessionID],
                        "ACP unverified: accepted control did not consume the real session reply/artifact")
                    let canonicalMemory = try memory.map(canonicalReceipt)
                    check(persisted?.status == .couldNotVerify && persisted?.result == marker
                        && persisted?.artifacts == [sessionID] && persisted?.completedAt != nil
                        && persisted?.verification == "Unverified; inspect the target before retrying"
                        && persisted == canonicalMemory,
                        "ACP unverified: accepted control lost actual unverified terminal result persistence")
                    check(announcements.contains(marker + warning)
                        && announcements.contains("fixture artifact announcement: 1")
                        && events.contains { $0.draft.kind == .jobCompleted }
                        && !events.contains { $0.draft.kind == .jobFailed },
                        "ACP unverified: accepted control missed actual result/artifact task delivery")
                } else {
                    let retained = ActionReceiptStore(fileURL: retainedFile).receipt(for: fired.actionID)
                    let retainedBytes = try Data(contentsOf: retainedFile)
                    let refusedContents = try FileManager.default.contentsOfDirectory(atPath: receiptFile.path)
                    let canonicalMemory = try memory.map(canonicalReceipt)
                    check(retainedBytes == snapshotBytes && refusedContents.isEmpty
                        && retained == fired && canonicalMemory == fired,
                        "ACP unverified: rejected terminal writer changed exact admitted fired bytes/state")
                    check(final?.status == .failed && primary?.status == .failed
                        && final?.result == nil && primary?.result == nil
                        && final?.artifacts.isEmpty == true && primary?.artifacts.isEmpty == true,
                        "ACP unverified: actual task completed after its terminal receipt save failed")
                    check(!announcements.contains { $0.contains(marker) || $0.contains("fixture artifact announcement") }
                        && !events.contains { $0.draft.kind == .jobCompleted }
                        && events.contains { $0.draft.kind == .jobFailed },
                        "ACP unverified: rejected terminal receipt delivered real session result or task success")
                    check(final?.failure == failure && primary?.failure == failure && announcements.contains(failure),
                        "ACP unverified: rejection did not report action-ran/result-not-saved through actual task delivery")
                }
                check(manager.workerBinding(taskID: submitted.id) == nil && context?.isStillValid?() == false,
                    "ACP unverified: terminal consumer left its original handle/context live (\(mode))")
                let callsBeforeReload = try Data(contentsOf: directory.appendingPathComponent("calls.json"))
                let reloadReceipts = ActionReceiptStore(fileURL: mode == "accepted" ? receiptFile : retainedFile)
                let reloadSQL = TaskStore(root: directory)
                defer { reloadSQL.close() }
                let reloaded = AgentTaskManager(store: AgentTaskStore(fileURL: export, mirror: reloadSQL),
                    receiptStore: reloadReceipts)
                for _ in 0..<16 { await Task.yield() }
                let afterReload = try reloadSQL.load().first { $0.id == submitted.id }
                let callsAfterReload = try Data(contentsOf: directory.appendingPathComponent("calls.json"))
                check(reloaded.backendStartsForTesting == 0 && afterReload == primary
                    && object(directory.appendingPathComponent("launch.json"))["launchCount"] as? Int == 1
                    && callsAfterReload == callsBeforeReload,
                    "ACP unverified: fresh actual manager replayed its terminal owned session (\(mode))")
                SelfTest.diagnostic("TASK_ACP_UNVERIFIED_TRACE: mode=\(mode) terminal=\(final?.status.rawValue ?? "absent") attempt=\(primary?.durability?.attempt ?? 0) starts=\(manager.backendStartsForTesting) delivered=\(announcements.contains { $0.contains(marker) }) retainedFired=\(memory?.status == .fired)")
                peerDiagnostic(directory: directory, mode: mode)
            } catch {
                peerDiagnostic(directory: directory, mode: mode)
                if ended == 0 {
                    manager.cancel(submitted.id)
                    let drained = await reached { ended == 1 }
                    check(drained, "ACP unverified: same owned worker failed error cleanup (\(mode))")
                }
                throw error
            }
        }
    }

    // The same peer bytes as owned-peer.py below, embedded only for a self-contained fixture.
    // All varying values are read from sibling config.json, never interpolated Python literals.
    private static let peer = #"""
        """Off-source proposal only; root must copy into an admitted temp fixture before use.

        Sibling config.json keys: mode, marker, objective, taskID, taskAttempt, taskLeaseOwner,
        database. Modes: accepted / terminal-write-rejected. Current typed ACP attempt is bound.
        This peer has not been run through the app and is not original/fixed evidence.
        """
        import json
        import pathlib
        import sqlite3
        import sys
        import tempfile
        import urllib.parse

        root = pathlib.Path(__file__).resolve().parent
        temporary = pathlib.Path(tempfile.gettempdir()).resolve()
        assert root != temporary and temporary in root.parents
        assert "Application Support" not in root.parts
        sys.stderr = (root / "peer-stderr.txt").open("a", buffering=1)
        config = json.loads((root / "config.json").read_text())
        mode = config["mode"]
        assert mode in ("accepted", "terminal-write-rejected")
        marker = config["marker"]
        objective = config["objective"]
        assert config["taskAttempt"] == 1
        assert config["taskLeaseOwner"].isdigit()
        database = pathlib.Path(config["database"]).resolve()
        assert database.parent == root and database.is_file()
        session = "fixture-unverified-receipt"
        calls = []
        receipt_file = root / "action-receipts.json"
        launch_file = root / "launch.json"
        prior = json.loads(launch_file.read_text()) if launch_file.exists() else {}
        launch_file.write_text(json.dumps({"launchCount": prior.get("launchCount", 0) + 1}))


        def primary():
            conn = sqlite3.connect("file:" + urllib.parse.quote(str(database)) + "?mode=ro", uri=True)
            rows = conn.execute("SELECT id,state,durability FROM task").fetchall()
            conn.close()
            assert len(rows) == 1 and rows[0][0] == config["taskID"]
            durability = json.loads(rows[0][2])
            assert rows[0][1] == "running"
            assert durability["attempt"] == config["taskAttempt"]
            assert durability["leaseOwner"] == config["taskLeaseOwner"]
            assert durability["runtimeClass"] == "acpWorker"
            assert durability.get("attemptStartedAt") is not None
            return {"taskID": rows[0][0], "state": rows[0][1], "durability": durability}


        def send(value):
            sys.stdout.write(json.dumps(value) + "\n")
            sys.stdout.flush()


        for line in sys.stdin:
            message = json.loads(line)
            mid, method = message.get("id"), message.get("method")
            params = message.get("params") or {}
            calls.append(method)
            (root / "calls.json").write_text(json.dumps(calls))
            if method == "initialize":
                send({"jsonrpc": "2.0", "id": mid, "result": {
                    "protocolVersion": 1, "agentCapabilities": {}}})
            elif method == "session/new":
                send({"jsonrpc": "2.0", "id": mid, "result": {"sessionId": session}})
            elif method == "session/prompt":
                assert params["sessionId"] == session
                assert params["prompt"] == [{"type": "text", "text": objective}]
                assert calls == ["initialize", "session/new", "session/prompt"]
                assert receipt_file.resolve().parent == root and receipt_file.is_file()
                fired_bytes = receipt_file.read_bytes()
                receipts = json.loads(fired_bytes)
                assert len(receipts) == 1
                receipt = receipts[0]
                assert receipt["status"] == "fired"
                assert receipt["toolID"] == "mcp.acp_session"
                assert receipt["preparedAction"]["title"] == objective
                assert receipt["preparedAction"]["routing"]["taskID"] == receipt["taskID"]
                assert receipt["taskID"] == config["taskID"]
                assert receipt["taskAttempt"] == config["taskAttempt"]
                assert receipt["taskLeaseOwner"] == config["taskLeaseOwner"]
                assert receipt["events"][-1]["stage"] == "fired"
                (root / "prompt-primary.json").write_text(json.dumps(primary(), sort_keys=True))
                (root / "prompt-fired-snapshot.json").write_bytes(fired_bytes)
                if mode == "terminal-write-rejected":
                    receipt_file.rename(root / "retained-fired.json")
                    receipt_file.mkdir()
                (root / "prompt-consumed.json").write_text(json.dumps({
                    "taskID": receipt["taskID"], "actionID": receipt["actionID"],
                    "objective": objective, "sessionID": session, "mode": mode}))
                send({"jsonrpc": "2.0", "method": "session/update", "params": {
                    "sessionId": session, "update": {"sessionUpdate": "agent_message_chunk",
                        "content": {"type": "text", "text": marker}}}})
                send({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "end_turn"}})
            elif method == "session/cancel":
                send({"jsonrpc": "2.0", "id": mid, "result": {}})
            elif mid is not None:
                send({"jsonrpc": "2.0", "id": mid,
                      "error": {"code": -32601, "message": method or "unknown"}})
        """#
}

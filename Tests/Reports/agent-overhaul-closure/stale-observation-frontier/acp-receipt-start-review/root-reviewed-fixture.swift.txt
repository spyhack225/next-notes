import Foundation

/// Actual Manager -> ACP -> owned peer; identical original/fixed startup inputs.
/// Startup receipt admission only. Does not prove completion admission or effect outcome.
@MainActor
enum TaskACPReceiptStartSelfTest {
    private enum FixtureError: Error { case unsafeRoot, missingContext, missingRow, timeout, missingReceipt, invalidPeer }

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

    static func originalCases(root: URL, check: (Bool, String) -> Void) async throws {
        let safe = root.resolvingSymlinksInPath().standardizedFileURL
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard SelfTest.isRunning, safe.isFileURL, safe.path.hasPrefix(temporary.path + "/"),
              !safe.pathComponents.contains("Application Support") else { throw FixtureError.unsafeRoot }
        let owner = String(ProcessInfo.processInfo.processIdentifier)
        let objective = "Owned protocol fixture: no tools or external effects"
        let marker = "Owned ACP fixture finished."
        let sessionID = "fixture-acp-receipt-start"
        let warning = "\nNext Notes could not independently verify the effect. Inspect the target before retrying."
        let failure = "The action could not be saved. It was not run."
        for mode in ["accepted", "tool-start-rejected"] {
            let directory = safe.appendingPathComponent("acp-receipt-start-" + mode, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let sql = TaskStore(root: directory)
            defer { sql.close() }
            let export = directory.appendingPathComponent("agent-tasks.json")
            let store = AgentTaskStore(fileURL: export, mirror: sql)
            guard store.allowsHarnessPersistence else { throw FixtureError.unsafeRoot }
            let receiptFile = directory.appendingPathComponent("action-receipts.json")
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
            var rejectionInstalled = false
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
                // IDs and paths are real admitted producer outputs, in sibling JSON, not Python literals.
                let config: [String: Any] = ["marker": marker, "objective": objective,
                    "taskID": captured.taskID, "taskAttempt": captured.attempt,
                    "taskLeaseOwner": captured.leaseOwner ?? "", "database": sql.fileURL.path,
                    "receipts": receiptFile.path]
                try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
                    .write(to: configFile, options: .atomic)
                if mode == "tool-start-rejected" {
                    try sql.withConnection { db in
                        try TaskStore.exec(db, "CREATE TRIGGER reject_acp_tool_start BEFORE INSERT ON task_event WHEN NEW.kind='toolStarted' BEGIN SELECT RAISE(ABORT,'fixture ACP tool-start rejection'); END")
                    }
                    rejectionInstalled = true
                }
            }
            let submitted = manager.submit(objective: objective, arguments: ["acpFixture": script.path],
                backend: .acp, source: "selftest")
            do {
                guard await reached({ ended == 1 }) else {
                    manager.cancel(submitted.id)
                    let drained = await reached { ended == 1 }
                    check(drained, "ACP receipt start: timeout cleanup did not drain same owned worker (\(mode))")
                    throw FixtureError.timeout
                }
                // Peer parsing/protocol invalidity is harness failure, not missing-feature evidence.
                guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent("peer-error.json").path) else {
                    throw FixtureError.invalidPeer
                }
                let final = manager.task(id: submitted.id)
                let freshSQL = TaskStore(root: directory)
                defer { freshSQL.close() }
                let primary = try freshSQL.load().first { $0.id == submitted.id }
                let events = try freshSQL.journal(taskID: submitted.id)
                let persistedReceipts = ActionReceiptStore(fileURL: receiptFile)
                guard persistedReceipts.receipts.count == 1, let receipt = persistedReceipts.receipts.first else {
                    throw FixtureError.missingReceipt
                }
                let ids = [receipt.actionID.uuidString]
                let launched = FileManager.default.fileExists(atPath: directory.appendingPathComponent("launch.json").path)
                let callsFile = directory.appendingPathComponent("calls.json")
                let calls = (try? JSONSerialization.jsonObject(with: Data(contentsOf: callsFile))) as? [String]
                check(entered == 1 && ended == 1 && manager.backendStartsForTesting == 1,
                    "ACP receipt start: actual admitted backend did not enter/exit exactly once (\(mode))")
                check(rowAtEntry?.status == .running && rowAtEntry?.durability?.attempt == 1
                    && rowAtEntry?.durability?.leaseOwner == owner
                    && rowAtEntry?.durability?.runtimeClass == .acpWorker
                    && rowAtEntry?.durability?.attemptStartedAt != nil
                    && rowAtEntry?.durability?.resumePolicy == .neverAuto,
                    "ACP receipt start: backend lacked committed positive ACP attempt (\(mode))")
                check(context?.taskID == submitted.id && context?.attempt == 1 && context?.leaseOwner == owner
                    && context?.receiptStore === receipts && context?.isStillValid != nil
                    && bindingAtEntry?.taskID == submitted.id && bindingAtEntry?.attempt == 1
                    && bindingAtEntry?.leaseOwner == owner,
                    "ACP receipt start: actual context/handle lost injected exact receipt ownership (\(mode))")
                check(rowAtEntry?.durability?.receiptIDs.isEmpty == true,
                    "ACP receipt start: task unexpectedly joined a receipt before real runtime preparation (\(mode))")
                check(receipt.taskID == submitted.id && receipt.taskAttempt == 1 && receipt.taskLeaseOwner == owner
                    && receipt.toolID == "mcp.acp_session" && receipt.preparedAction?.id == receipt.actionID
                    && receipt.preparedAction?.intentID == receipt.intentID
                    && receipt.preparedAction?.routing.taskID == submitted.id
                    && receipt.preparedAction?.executionPlan.toolID == receipt.toolID
                    && receipt.preparedAction?.executionPlan.arguments["objective"] == objective
                    && receipt.events.contains { $0.stage == .fired },
                    "ACP receipt start: real retained receipt lost exact prepared task/attempt identity (\(mode))")
                check(primary?.durability?.attempt == 1 && primary?.durability?.leaseOwner == owner
                    && final?.durability?.attempt == 1 && final?.durability?.leaseOwner == owner,
                    "ACP receipt start: terminal path changed original positive ACP attempt (\(mode))")
                if mode == "accepted" {
                    guard launched, calls == ["initialize", "session/new", "session/prompt"] else {
                        throw FixtureError.invalidPeer
                    }
                    let snapshotFile = directory.appendingPathComponent("startup-fired-snapshot.json")
                    let snapshot = ActionReceiptStore(fileURL: snapshotFile)
                    guard snapshot.receipts.count == 1, let fired = snapshot.receipts.first else {
                        throw FixtureError.missingReceipt
                    }
                    let observed = object(directory.appendingPathComponent("startup-primary.json"))
                    let durability = observed["durability"] as? [String: Any] ?? [:]
                    let starts = observed["toolStartEvents"] as? [[String: Any]] ?? []
                    check(object(directory.appendingPathComponent("launch.json"))["launchCount"] as? Int == 1,
                        "ACP receipt start: accepted owned peer launched more than once")
                    check(fired.actionID == receipt.actionID && fired.status == .fired
                        && fired.events.last?.stage == .fired && fired.taskID == submitted.id
                        && fired.taskAttempt == 1 && fired.taskLeaseOwner == owner
                        && fired.preparedAction == receipt.preparedAction,
                        "ACP receipt start: process startup did not consume exact saved fired preparation")
                    check(observed["taskID"] as? String == submitted.id && observed["state"] as? String == "running"
                        && observed["actionID"] as? String == receipt.actionID.uuidString
                        && durability["attempt"] as? Int == 1 && durability["leaseOwner"] as? String == owner
                        && durability["receiptIDs"] as? [String] == ids,
                        "ACP receipt start: actual process started before exact receipt UUID joined primary attempt")
                    check(starts.count == 1 && starts.first?["kind"] as? String == "toolStarted"
                        && starts.first?["detail"] as? String == "mcp.acp_session"
                        && starts.first?["attempt"] as? Int == 1,
                        "ACP receipt start: actual peer startup lacked exact admitted tool-start event")
                    check(primary?.durability?.receiptIDs == ids && final?.durability?.receiptIDs == ids
                        && events.filter { $0.draft.kind == .toolStarted }.count == 1
                        && events.first { $0.draft.kind == .toolStarted }?.draft.detail == "mcp.acp_session"
                        && events.first { $0.draft.kind == .toolStarted }?.draft.attempt == 1,
                        "ACP receipt start: terminal consumer lost exact startup join or duplicated admitted event")
                    check(final?.status == .completed && primary?.status == .completed
                        && final?.result == marker + warning && primary?.result == final?.result
                        && final?.artifacts == [sessionID] && primary?.artifacts == [sessionID],
                        "ACP receipt start: accepted real protocol reply/artifact did not reach actual task")
                    check(receipt.status == .couldNotVerify && receipt.result == marker
                        && receipt.artifacts == [sessionID] && receipt.completedAt != nil,
                        "ACP receipt start: accepted original unverified receipt contract changed")
                    check(announcements.contains(marker + warning)
                        && events.contains { $0.draft.kind == .jobCompleted }
                        && !events.contains { $0.draft.kind == .jobFailed },
                        "ACP receipt start: accepted actual task result delivery failed")
                } else {
                    check(rejectionInstalled,
                        "ACP receipt start: original real tool-start INSERT trigger was not installed")
                    check(!launched && !FileManager.default.fileExists(atPath: callsFile.path)
                        && !FileManager.default.fileExists(atPath: directory.appendingPathComponent("startup-primary.json").path)
                        && !FileManager.default.fileExists(atPath: directory.appendingPathComponent("startup-fired-snapshot.json").path),
                        "ACP receipt start: actual owned process launched despite rejected tool-start admission")
                    check(primary?.durability?.receiptIDs.isEmpty == true && final?.durability?.receiptIDs.isEmpty == true
                        && !events.contains { $0.draft.kind == .toolStarted },
                        "ACP receipt start: rejected admission retained a receipt join or tool-start event")
                    check(final?.status == .failed && primary?.status == .failed
                        && final?.result == nil && primary?.result == nil
                        && final?.artifacts.isEmpty == true && primary?.artifacts.isEmpty == true,
                        "ACP receipt start: actual task completed after rejected startup admission")
                    check(final?.failure == failure && primary?.failure == failure && announcements.contains(failure),
                        "ACP receipt start: rejection did not deliver the actual not-run failure")
                    check(receipt.status == .failed && receipt.result.isEmpty && receipt.artifacts.isEmpty
                        && !announcements.contains { $0.contains(marker) || $0.contains("fixture artifact announcement") }
                        && !events.contains { $0.draft.kind == .jobCompleted }
                        && events.contains { $0.draft.kind == .jobFailed },
                        "ACP receipt start: rejected admission delivered session success or lost real failed receipt")
                }
                check(manager.workerBinding(taskID: submitted.id) == nil && context?.isStillValid?() == false,
                    "ACP receipt start: released terminal context remained live (\(mode))")
                let callBytes = try? Data(contentsOf: callsFile)
                let reloadSQL = TaskStore(root: directory)
                defer { reloadSQL.close() }
                let reloaded = AgentTaskManager(store: AgentTaskStore(fileURL: export, mirror: reloadSQL),
                    receiptStore: ActionReceiptStore(fileURL: receiptFile))
                for _ in 0..<16 { await Task.yield() }
                check(reloaded.task(id: submitted.id)?.durability?.receiptIDs == primary?.durability?.receiptIDs
                    && reloaded.task(id: submitted.id)?.status == primary?.status
                    && reloaded.backendStartsForTesting == 0 && (try? reloadSQL.load().first { $0.id == submitted.id }) == primary
                    && (try? Data(contentsOf: callsFile)) == callBytes,
                    "ACP receipt start: fresh actual manager lost admitted history or replayed session (\(mode))")
                SelfTest.diagnostic("TASK_ACP_RECEIPT_START_TRACE: mode=\(mode) terminal=\(final?.status.rawValue ?? "absent") joined=\(primary?.durability?.receiptIDs.count ?? 0) launched=\(launched) starts=\(manager.backendStartsForTesting) receiptStage=\(receipt.status.rawValue) receiptEmpty=\(receipt.result.isEmpty) receiptArtifacts=\(receipt.artifacts.count)")
            } catch {
                if ended == 0 {
                    manager.cancel(submitted.id)
                    let drained = await reached { ended == 1 }
                    check(drained, "ACP receipt start: error cleanup did not drain same owned worker (\(mode))")
                }
                throw error
            }
        }
    }

    // Identical owned-start-peer.py.txt bytes, with raw Swift delimiter: no slash unescaping.
    private static let peer = #"""
        import json, pathlib, sqlite3, sys, tempfile, urllib.parse
        root = pathlib.Path(__file__).resolve().parent
        temporary = pathlib.Path(tempfile.gettempdir()).resolve()
        assert root != temporary and temporary in root.parents
        assert 'Application Support' not in root.parts
        config = json.loads((root / 'config.json').read_text())
        assert pathlib.Path(config['database']).resolve().parent == root
        assert pathlib.Path(config['receipts']).resolve().parent == root
        launch_file = root / 'launch.json'
        prior = json.loads(launch_file.read_text()) if launch_file.exists() else {}
        launch_file.write_text(json.dumps({'launchCount': prior.get('launchCount', 0) + 1}))

        def send(value):
            sys.stdout.write(json.dumps(value) + '\n')
            sys.stdout.flush()

        def main():
            # These are explicitly owned config paths, never cwd or an owner store.
            conn = sqlite3.connect('file:' + urllib.parse.quote(config['database']) + '?mode=ro', uri=True)
            row = conn.execute('SELECT id,state,durability FROM task WHERE id=?', (config['taskID'],)).fetchone()
            assert row is not None
            events = conn.execute('SELECT kind,detail,attempt FROM task_event WHERE task_id=? ORDER BY seq', (config['taskID'],)).fetchall()
            conn.close()
            receipt_file = pathlib.Path(config['receipts'])
            receipt_bytes = receipt_file.read_bytes()
            receipts = json.loads(receipt_bytes)
            assert len(receipts) == 1
            receipt = receipts[0]
            prepared = receipt['preparedAction']
            assert receipt['taskID'] == config['taskID']
            assert receipt['taskAttempt'] == config['taskAttempt']
            assert receipt['taskLeaseOwner'] == config['taskLeaseOwner']
            assert receipt['status'] == 'fired' and receipt['events'][-1]['stage'] == 'fired'
            assert receipt['toolID'] == 'mcp.acp_session'
            assert prepared['id'] == receipt['actionID']
            assert prepared['routing']['taskID'] == config['taskID']
            assert prepared['intentID'] == receipt['intentID']
            assert prepared['executionPlan']['toolID'] == receipt['toolID']
            assert prepared['executionPlan']['arguments']['objective'] == config['objective']
            # Missing join/start event MUST remain data on original; never abort the original peer.
            durability = json.loads(row[2]) if row[2] else {}
            (root / 'startup-fired-snapshot.json').write_bytes(receipt_bytes)
            (root / 'startup-primary.json').write_text(json.dumps({
                'taskID': row[0], 'state': row[1], 'durability': durability,
                'actionID': receipt['actionID'], 'toolStartEvents': [
                    {'kind': kind, 'detail': detail, 'attempt': attempt}
                    for kind, detail, attempt in events if kind == 'toolStarted'
                ]}, sort_keys=True))
            calls = []
            session = 'fixture-acp-receipt-start'
            for line in sys.stdin:
                message = json.loads(line)
                mid, method = message.get('id'), message.get('method')
                calls.append(method)
                (root / 'calls.json').write_text(json.dumps(calls))
                if method == 'initialize':
                    send({'jsonrpc':'2.0','id':mid,'result':{'protocolVersion':1,'agentCapabilities':{}}})
                elif method == 'session/new':
                    send({'jsonrpc':'2.0','id':mid,'result':{'sessionId':session}})
                elif method == 'session/prompt':
                    params = message['params']
                    assert params['sessionId'] == session
                    assert params['prompt'][0]['text'] == config['objective']
                    send({'jsonrpc':'2.0','method':'session/update','params':{'sessionId':session,'update':{
                        'sessionUpdate':'agent_message_chunk','content':{'type':'text','text':config['marker']}}}})
                    send({'jsonrpc':'2.0','id':mid,'result':{'stopReason':'end_turn'}})
                elif method == 'session/cancel':
                    send({'jsonrpc':'2.0','id':mid,'result':{}})

        try:
            main()
        except Exception as error:
            # Only a generic error class from the OWN peer; no prompt/result/path in diagnostics.
            (root / 'peer-error.json').write_text(json.dumps({'errorClass':type(error).__name__}))
            raise
        """#
}

import Foundation

/// Actual Manager -> ACPBackend -> Session -> owned peer, same original/fixed inputs.
/// Entry authority only; neither Gate durability nor nested effect execution is proved.
@MainActor
enum TaskACPNestedAttemptSelfTest {
    private enum FixtureError: Error {
        case unsafeRoot, busyGate, missingContext, missingRow, missingReceipt, timeout, invalidPeer
    }

    private static func reached(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }

    // Match the existing AgentTaskStore canonical ISO export before its SQL save.
    // Live handle identity keeps the exact original in-memory producer timestamp.
    private static func canonicalDate(_ date: Date) throws -> Date {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Date.self, from: encoder.encode(date))
    }

    private static func object(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    static func originalCases(root: URL, check: (Bool, String) -> Void) async throws {
        let safe = root.resolvingSymlinksInPath().standardizedFileURL
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard SelfTest.isRunning, safe.isFileURL, safe.path.hasPrefix(temporary.path + "/"),
              !safe.pathComponents.contains("Application Support") else { throw FixtureError.unsafeRoot }
        guard PermissionGate.shared.pending == nil, PermissionGate.shared.queuedCount == 0 else {
            throw FixtureError.busyGate
        }
        let ownerBefore = SelfTestStoreGuard.take()
        let priorFake = AgentToolExecutor.fakeForTesting
        let priorFire = AgentToolExecutor.fireOverrideForTesting
        defer {
            AgentToolExecutor.fakeForTesting = priorFake
            AgentToolExecutor.fireOverrideForTesting = priorFire
        }
        AgentToolExecutor.fakeForTesting = nil
        var unexpectedTools = 0
        AgentToolExecutor.fireOverrideForTesting = { _, _ in
            unexpectedTools += 1
            throw FixtureError.invalidPeer
        }
        let owner = String(ProcessInfo.processInfo.processIdentifier)
        let objective = "Owned ACP nested review fixture: no tools or external effects"
        let marker = "Owned ACP nested fixture finished."
        let sessionID = "fixture-acp-nested-attempt"
        let warning = "\nNext Notes could not independently verify the effect. Inspect the target before retrying."

        for mode in ["accepted", "fresh-primary-held"] {
            let heldMode = mode == "fresh-primary-held"
            let directory = safe.appendingPathComponent("acp-nested-attempt-" + mode, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let sql = TaskStore(root: directory)
            defer { sql.close() }
            let export = directory.appendingPathComponent("agent-tasks.json")
            let store = AgentTaskStore(fileURL: export, mirror: sql)
            guard store.allowsHarnessPersistence else { throw FixtureError.unsafeRoot }
            let receiptFile = directory.appendingPathComponent("action-receipts.json")
            let script = directory.appendingPathComponent("owned-peer.py")
            let configFile = directory.appendingPathComponent("config.json")
            let releaseFile = directory.appendingPathComponent("release-permission.json")
            let wireFile = directory.appendingPathComponent("wire-result.json")
            let callsFile = directory.appendingPathComponent("calls.json")
            try peer.write(to: script, atomically: true, encoding: .utf8)
            let receipts = ActionReceiptStore(fileURL: receiptFile)
            let manager = AgentTaskManager(store: store, receiptStore: receipts)
            var context: TaskJournalContext?
            var rowAtEntry: AgentTask?
            var bindingAtEntry: TaskWorkerBinding?
            var entryValid = false
            var entered = 0
            var ended = 0
            var announcements: [String] = []
            var holdingSQL: TaskStore?
            var holdingManager: AgentTaskManager?
            defer { holdingSQL?.close() }
            let askBefore = PermissionGate.shared.askCount
            let toolsBefore = unexpectedTools
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
                entryValid = captured.isStillValid?() == true
                let config: [String: Any] = ["marker": marker, "objective": objective,
                    "taskID": captured.taskID, "taskAttempt": captured.attempt,
                    "taskLeaseOwner": captured.leaseOwner ?? "", "database": sql.fileURL.path,
                    "receipts": receiptFile.path]
                try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
                    .write(to: configFile, options: .atomic)
            }
            // Existing fixture path auto-approves. No alternative Gate route or cancellation input.
            let submitted = manager.submit(objective: objective, arguments: ["acpFixture": script.path],
                backend: .acp, source: "selftest")
            do {
                guard await reached({ FileManager.default.fileExists(atPath:
                    directory.appendingPathComponent("prompt-observed.json").path) }) else { throw FixtureError.timeout }
                guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent("peer-error.json").path),
                      let captured = context, let binding = bindingAtEntry else { throw FixtureError.invalidPeer }
                let startupReceipts = ActionReceiptStore(fileURL:
                    directory.appendingPathComponent("startup-fired-snapshot.json"))
                guard startupReceipts.receipts.count == 1, let fired = startupReceipts.receipts.first else {
                    throw FixtureError.missingReceipt
                }
                let joined = [fired.actionID.uuidString]
                let startup = object(directory.appendingPathComponent("startup-primary.json"))
                let startupDurability = startup["durability"] as? [String: Any] ?? [:]
                let startupEvents = startup["toolStartEvents"] as? [[String: Any]] ?? []
                let prompt = object(directory.appendingPathComponent("prompt-observed.json"))
                // C01
                check(entered == 1 && ended == 0 && manager.backendStartsForTesting == 1,
                    "ACP nested attempt: actual backend was not suspended in its first prompt (\(mode))")
                // C02
                check(rowAtEntry?.status == .running && rowAtEntry?.durability?.attempt == 1
                    && rowAtEntry?.durability?.leaseOwner == owner
                    && rowAtEntry?.durability?.runtimeClass == .acpWorker
                    && rowAtEntry?.durability?.resumePolicy == .neverAuto
                    && rowAtEntry?.durability?.attemptStartedAt != nil,
                    "ACP nested attempt: original backend lacked admitted normal typed ACP ownership (\(mode))")
                let canonicalBindingStart = try canonicalDate(binding.startedAt)
                SelfTest.diagnostic("TASK_ACP_NESTED_ENTRY_TRACE: mode=\(mode) entryValid=\(entryValid) receiptOwner=\(captured.receiptStore === receipts) memoryStart=\(binding.startedAt.timeIntervalSince1970) diskStart=\(rowAtEntry?.durability?.attemptStartedAt?.timeIntervalSince1970 ?? -1) canonicalStart=\(canonicalBindingStart.timeIntervalSince1970)")
                // C03
                check(captured.taskID == submitted.id && captured.attempt == 1 && captured.leaseOwner == owner
                    && captured.receiptStore === receipts && entryValid
                    && binding.taskID == submitted.id && binding.attempt == 1 && binding.leaseOwner == owner
                    && binding.startedAt == manager.task(id: submitted.id)?.durability?.attemptStartedAt
                    && canonicalBindingStart == rowAtEntry?.durability?.attemptStartedAt,
                    "ACP nested attempt: original live context lost exact owning manager/receipt/handle (\(mode))")
                // C04
                check(rowAtEntry?.durability?.receiptIDs.isEmpty == true,
                    "ACP nested attempt: receipt was joined before real preparation (\(mode))")
                // C05
                check(prompt["taskID"] as? String == submitted.id && prompt["sessionID"] as? String == sessionID
                    && prompt["promptCount"] as? Int == 1,
                    "ACP nested attempt: peer did not observe the real exact first prompt (\(mode))")
                // C06
                check(fired.taskID == submitted.id && fired.taskAttempt == 1 && fired.taskLeaseOwner == owner
                    && fired.status == .fired && fired.events.last?.stage == .fired
                    && fired.toolID == "mcp.acp_session" && fired.preparedAction?.id == fired.actionID
                    && fired.preparedAction?.routing.taskID == submitted.id
                    && fired.preparedAction?.intentID == fired.intentID
                    && fired.preparedAction?.executionPlan.toolID == fired.toolID
                    && fired.preparedAction?.executionPlan.arguments["objective"] == objective,
                    "ACP nested attempt: owned process lacked exact actual saved fired preparation (\(mode))")
                // C07
                check(startup["taskID"] as? String == submitted.id && startup["state"] as? String == "running"
                    && startup["actionID"] as? String == fired.actionID.uuidString
                    && startupDurability["attempt"] as? Int == 1
                    && startupDurability["leaseOwner"] as? String == owner
                    && startupDurability["receiptIDs"] as? [String] == joined
                    && startupEvents.count == 1 && startupEvents.first?["detail"] as? String == "mcp.acp_session"
                    && startupEvents.first?["attempt"] as? Int == 1,
                    "ACP nested attempt: actual startup missed exact primary receipt/tool-start join (\(mode))")
                // C08: workerBinding itself refuses a cancelled handle.
                check(manager.workerBinding(taskID: submitted.id) == binding
                    && !FileManager.default.fileExists(atPath: wireFile.path),
                    "ACP nested attempt: original handle was cancelled or permission ran before release (\(mode))")
                if heldMode {
                    let freshSQL = TaskStore(root: directory)
                    holdingSQL = freshSQL
                    let freshStore = AgentTaskStore(fileURL: export, mirror: freshSQL)
                    guard freshStore.allowsHarnessPersistence else { throw FixtureError.unsafeRoot }
                    let freshManager = AgentTaskManager(store: freshStore,
                        receiptStore: ActionReceiptStore(fileURL: receiptFile))
                    holdingManager = freshManager
                    let held = try freshSQL.load().first { $0.id == submitted.id }
                    // H01
                    check(freshManager.historyReadFailure == nil && freshManager.lastPersistenceResult?.primaryCommitted == true
                        && freshManager.task(id: submitted.id)?.status == .recovering && held?.status == .recovering
                        && freshManager.backendStartsForTesting == 0,
                        "ACP nested attempt: real fresh manager did not commit held primary without dispatch")
                    // H02
                    check(held?.durability?.attempt == 1 && held?.durability?.leaseOwner == owner
                        && held?.durability?.attemptStartedAt == rowAtEntry?.durability?.attemptStartedAt
                        && held?.durability?.receiptIDs == joined && held?.result == nil,
                        "ACP nested attempt: real hold changed admitted attempt/start/receipt identity")
                    // H03
                    check(manager.task(id: submitted.id)?.status == .running
                        && manager.workerBinding(taskID: submitted.id) == binding
                        && captured.isStillValid?() == false && !FileManager.default.fileExists(atPath: wireFile.path),
                        "ACP nested attempt: held case was substituted with cancelled/released handle or early wire result")
                } else {
                    // A01
                    check(captured.isStillValid?() == true && manager.workerBinding(taskID: submitted.id) == binding,
                        "ACP nested attempt: accepted original attempt lost current primary validity")
                }
                guard let releaseRow = try sql.load().first(where: { $0.id == submitted.id }) else {
                    throw FixtureError.missingRow
                }
                let releaseJournal = try sql.journal(taskID: submitted.id)
                // C09
                check(releaseRow.status == (heldMode ? .recovering : .running)
                    && releaseRow.durability?.attempt == 1 && releaseRow.durability?.receiptIDs == joined
                    && releaseJournal.filter { $0.draft.kind == .recoveryHeld }.count == (heldMode ? 1 : 0),
                    "ACP nested attempt: release did not follow the real admitted current/held primary (\(mode))")
                try JSONSerialization.data(withJSONObject: ["release": true], options: [.sortedKeys])
                    .write(to: releaseFile, options: .atomic)
                guard await reached({ FileManager.default.fileExists(atPath: wireFile.path) }) else { throw FixtureError.timeout }
                let wire = object(wireFile)
                let result = wire["result"] as? [String: Any] ?? [:]
                let outcome = result["outcome"] as? [String: String]
                let request = object(directory.appendingPathComponent("permission-request.json"))
                let options = request["options"] as? [[String: String]] ?? []
                let permissionPrimary = object(directory.appendingPathComponent("permission-primary.json"))
                // C10
                check(wire["cancelBeforeVerdict"] as? Bool == false && wire["replyCount"] as? Int == 1
                    && wire["requestCount"] as? Int == 1 && wire["promptCount"] as? Int == 1,
                    "ACP nested attempt: wire verdict was replaced by cancellation/duplicate request (\(mode))")
                // C11
                check(request["taskID"] as? String == submitted.id && request["sessionID"] as? String == sessionID
                    && request["requestID"] as? Int == 900 && request["requestCount"] as? Int == 1
                    && options == [["optionId": "fixture-allow-once", "name": "Allow once", "kind": "allow_once"],
                                   ["optionId": "fixture-reject-once", "name": "Reject", "kind": "reject_once"]],
                    "ACP nested attempt: real request lost exact offered options or matched session (\(mode))")
                // C12: intended original failure is held mode's offered allow.
                check(outcome == ["outcome": "selected", "optionId": heldMode ? "fixture-reject-once" : "fixture-allow-once"],
                    "ACP nested attempt: stale held attempt still received an authorizing nested wire result (\(mode))")
                // C13
                check(result["optionId"] == nil && permissionPrimary["taskID"] as? String == submitted.id
                    && permissionPrimary["state"] as? String == (heldMode ? "recovering" : "running"),
                    "ACP nested attempt: conforming wire or actual primary-before-request control failed (\(mode))")
                // C14
                check(PermissionGate.shared.askCount == askBefore && PermissionGate.shared.pending == nil
                    && PermissionGate.shared.queuedCount == 0,
                    "ACP nested attempt: entry fixture unexpectedly relayed to Gate (\(mode))")
                // C15
                check(unexpectedTools == toolsBefore && wire["externalEffectCount"] as? Int == 0,
                    "ACP nested attempt: owned review fixture executed a tool/external effect (\(mode))")
                guard await reached({ ended == 1 }) else { throw FixtureError.timeout }
                guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent("peer-error.json").path) else {
                    throw FixtureError.invalidPeer
                }
                let final = manager.task(id: submitted.id)
                let primary = try sql.load().first { $0.id == submitted.id }
                let journal = try sql.journal(taskID: submitted.id)
                let persisted = ActionReceiptStore(fileURL: receiptFile)
                guard persisted.receipts.count == 1, let receipt = persisted.receipts.first else { throw FixtureError.missingReceipt }
                let calls = (try? JSONSerialization.jsonObject(with: Data(contentsOf: callsFile))) as? [String]
                // C16
                check(entered == 1 && ended == 1 && manager.backendStartsForTesting == 1,
                    "ACP nested attempt: actual owned backend failed to join exactly once (\(mode))")
                // C17
                check(calls == ["initialize", "session/new", "session/prompt"],
                    "ACP nested attempt: request/cancel/control protocol changed before actual completion (\(mode))")
                // C18
                check(object(directory.appendingPathComponent("launch.json"))["launchCount"] as? Int == 1,
                    "ACP nested attempt: actual peer launched more than once (\(mode))")
                // C19
                check(receipt.actionID == fired.actionID && receipt.taskID == submitted.id && receipt.taskAttempt == 1
                    && receipt.taskLeaseOwner == owner && receipt.preparedAction == fired.preparedAction
                    && receipt.events.contains { $0.stage == .fired },
                    "ACP nested attempt: actual runtime lost exact retained fired receipt (\(mode))")
                // C20
                check(primary?.durability?.attempt == 1 && primary?.durability?.leaseOwner == owner
                    && primary?.durability?.receiptIDs == joined,
                    "ACP nested attempt: old completion changed authoritative attempt/receipt link (\(mode))")
                // C21
                check(manager.workerBinding(taskID: submitted.id) == nil && captured.isStillValid?() == false,
                    "ACP nested attempt: completed owned backend retained live handle authority (\(mode))")
                if heldMode {
                    // H04: old memory may still be running after rejected terminal writes.
                    check(primary == releaseRow && journal == releaseJournal
                        && !announcements.contains { $0.contains(marker) || $0.hasPrefix("fixture artifact announcement:") },
                        "ACP nested attempt: old worker changed held primary or delivered task success")
                    // H05
                    check(holdingManager?.task(id: submitted.id)?.status == .recovering
                        && holdingManager?.backendStartsForTesting == 0,
                        "ACP nested attempt: holding manager dispatched or lost its exact held task")
                    // H06
                    check(receipt.status == .couldNotVerify && receipt.result == marker
                        && receipt.artifacts == [sessionID] && receipt.completedAt != nil,
                        "ACP nested attempt: retained actual protocol return evidence changed after primary hold")
                } else {
                    // A02
                    check(final?.status == .completed && primary?.status == .completed
                        && final?.result == marker + warning && primary?.result == final?.result
                        && final?.artifacts == [sessionID] && primary?.artifacts == [sessionID],
                        "ACP nested attempt: accepted original protocol result failed its actual task consumer")
                    // A03
                    check(receipt.status == .couldNotVerify && receipt.result == marker
                        && receipt.artifacts == [sessionID] && receipt.completedAt != nil,
                        "ACP nested attempt: accepted actual unverified receipt behavior changed")
                    // A04
                    check(announcements.contains(marker + warning)
                        && journal.contains { $0.draft.kind == .jobCompleted }
                        && !journal.contains { $0.draft.kind == .recoveryHeld },
                        "ACP nested attempt: accepted actual task success delivery changed")
                }
                let callBytes = try Data(contentsOf: callsFile)
                let freshSQL = TaskStore(root: directory)
                defer { freshSQL.close() }
                let reread = AgentTaskManager(store: AgentTaskStore(fileURL: export, mirror: freshSQL),
                    receiptStore: ActionReceiptStore(fileURL: receiptFile))
                for _ in 0..<16 { await Task.yield() }
                let reloadedPrimary = try freshSQL.load().first { $0.id == submitted.id }
                let callBytesAfter = try Data(contentsOf: callsFile)
                // C22
                check(reread.task(id: submitted.id) == primary && reloadedPrimary == primary
                    && reread.backendStartsForTesting == 0 && callBytesAfter == callBytes,
                    "ACP nested attempt: actual fresh reread changed held/terminal history or replayed peer (\(mode))")
                SelfTest.diagnostic("TASK_ACP_NESTED_ATTEMPT_TRACE: mode=\(mode) wireOutcome=\(outcome?["outcome"] ?? "absent") wireOption=\(outcome?["optionId"] ?? "absent") primary=\(primary?.status.rawValue ?? "absent") originalMemory=\(final?.status.rawValue ?? "absent") heldStarts=\(holdingManager?.backendStartsForTesting ?? 0) starts=\(manager.backendStartsForTesting) ended=\(ended) joined=\(primary?.durability?.receiptIDs.count ?? 0) receiptStage=\(receipt.status.rawValue)")
            } catch {
                // Cancellation is error cleanup only, AFTER the original input became invalid.
                try? JSONSerialization.data(withJSONObject: ["release": true]).write(to: releaseFile, options: .atomic)
                if ended == 0 {
                    manager.cancel(submitted.id)
                    let drained = await reached { ended == 1 }
                    check(drained, "ACP nested attempt: error cleanup failed to drain same owned worker (\(mode))")
                }
                throw error
            }
        }
        // O01
        check(SelfTestStoreGuard.diff(ownerBefore, SelfTestStoreGuard.take()).isEmpty,
            "ACP nested attempt: owned fixture changed owner stores/defaults")
    }

    private static let peer = #"""
        import json, pathlib, sqlite3, sys, tempfile, time, urllib.parse

        root = pathlib.Path(__file__).resolve().parent
        temporary = pathlib.Path(tempfile.gettempdir()).resolve()
        assert root != temporary and temporary in root.parents
        assert 'Application Support' not in root.parts
        config = json.loads((root / 'config.json').read_text())
        assert pathlib.Path(config['database']).resolve().parent == root
        assert pathlib.Path(config['receipts']).resolve().parent == root
        session = 'fixture-acp-nested-attempt'
        options = [
            {'optionId': 'fixture-allow-once', 'name': 'Allow once', 'kind': 'allow_once'},
            {'optionId': 'fixture-reject-once', 'name': 'Reject', 'kind': 'reject_once'}
        ]
        calls = []
        prompt_id = None
        permission_requests = 0
        permission_replies = 0
        cancel_before_verdict = False

        def write(name, value):
            temporary_file = root / (name + '.tmp')
            temporary_file.write_text(json.dumps(value, sort_keys=True))
            temporary_file.replace(root / name)

        def send(value):
            sys.stdout.write(json.dumps(value) + '\n')
            sys.stdout.flush()

        def primary():
            connection = sqlite3.connect('file:' + urllib.parse.quote(config['database']) + '?mode=ro', uri=True)
            try:
                row = connection.execute('SELECT id,state,durability FROM task WHERE id=?', (config['taskID'],)).fetchone()
                assert row is not None
                events = connection.execute('SELECT kind,detail,attempt FROM task_event WHERE task_id=? ORDER BY seq', (config['taskID'],)).fetchall()
            finally:
                connection.close()
            return {'taskID': row[0], 'state': row[1], 'durability': json.loads(row[2]) if row[2] else {},
                    'toolStartEvents': [{'kind': kind, 'detail': detail, 'attempt': attempt}
                                        for kind, detail, attempt in events if kind == 'toolStarted']}

        def main():
            global prompt_id, permission_requests, permission_replies, cancel_before_verdict
            assert not (root / 'launch.json').exists()
            write('launch.json', {'launchCount': 1})
            receipt_bytes = pathlib.Path(config['receipts']).read_bytes()
            receipts = json.loads(receipt_bytes)
            assert len(receipts) == 1
            receipt = receipts[0]
            prepared = receipt['preparedAction']
            assert receipt['taskID'] == config['taskID'] and receipt['taskAttempt'] == config['taskAttempt']
            assert receipt['taskLeaseOwner'] == config['taskLeaseOwner']
            assert receipt['status'] == 'fired' and receipt['events'][-1]['stage'] == 'fired'
            assert receipt['toolID'] == 'mcp.acp_session'
            assert prepared['id'] == receipt['actionID'] and prepared['routing']['taskID'] == config['taskID']
            assert prepared['intentID'] == receipt['intentID']
            assert prepared['executionPlan']['toolID'] == receipt['toolID']
            assert prepared['executionPlan']['arguments']['objective'] == config['objective']
            (root / 'startup-fired-snapshot.json').write_bytes(receipt_bytes)
            snapshot = primary()
            snapshot['actionID'] = receipt['actionID']
            write('startup-primary.json', snapshot)
            for line in sys.stdin:
                message = json.loads(line)
                mid, method = message.get('id'), message.get('method')
                if method is not None:
                    calls.append(method)
                    write('calls.json', calls)
                if method == 'initialize':
                    send({'jsonrpc': '2.0', 'id': mid, 'result': {'protocolVersion': 1, 'agentCapabilities': {}}})
                elif method == 'session/new':
                    send({'jsonrpc': '2.0', 'id': mid, 'result': {'sessionId': session}})
                elif method == 'session/prompt':
                    assert prompt_id is None
                    assert message['params']['sessionId'] == session
                    assert message['params']['prompt'][0]['text'] == config['objective']
                    prompt_id = mid
                    write('prompt-observed.json', {'taskID': config['taskID'], 'sessionID': session, 'promptCount': 1})
                    deadline = time.monotonic() + 10
                    while not (root / 'release-permission.json').exists():
                        if time.monotonic() >= deadline:
                            raise TimeoutError('owned fixture release barrier')
                        time.sleep(0.005)
                    release = json.loads((root / 'release-permission.json').read_text())
                    assert release == {'release': True}
                    write('permission-primary.json', primary())
                    permission_requests += 1
                    write('permission-request.json', {'taskID': config['taskID'], 'sessionID': session,
                            'requestCount': permission_requests, 'requestID': 900, 'options': options})
                    send({'jsonrpc': '2.0', 'id': 900, 'method': 'session/request_permission', 'params': {
                        'sessionId': session,
                        'toolCall': {'toolCallId': 'owned-review-only', 'title': 'Owned fixture review only',
                                     'kind': 'other', 'status': 'pending'}, 'options': options}})
                elif method is None and mid == 900:
                    assert prompt_id is not None and permission_replies == 0
                    permission_replies += 1
                    write('wire-result.json', {'result': message.get('result', {}), 'replyCount': permission_replies,
                            'requestCount': permission_requests, 'cancelBeforeVerdict': cancel_before_verdict,
                            'externalEffectCount': 0, 'promptCount': 1})
                    # SAME control for old allow and future reject. No tool is executed.
                    send({'jsonrpc': '2.0', 'method': 'session/update', 'params': {'sessionId': session, 'update': {
                        'sessionUpdate': 'agent_message_chunk', 'content': {'type': 'text', 'text': config['marker']}}}})
                    send({'jsonrpc': '2.0', 'id': prompt_id, 'result': {'stopReason': 'end_turn'}})
                elif method == 'session/cancel':
                    if permission_replies == 0:
                        cancel_before_verdict = True
                    send({'jsonrpc': '2.0', 'id': mid, 'result': {}})
                else:
                    raise ValueError('unexpected owned protocol message')

        try:
            main()
        except Exception as error:
            write('peer-error.json', {'errorClass': type(error).__name__})
            raise
        """#
}

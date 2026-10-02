import Foundation

/// Actual Manager -> Registry -> ACP -> owned protocol peer.
/// Does not prove nested permission durability, complete invocation fencing or retry.
@MainActor
enum TaskACPPrimaryAdmissionSelfTest {
    private enum FixtureError: Error { case unsafeRoot, missingContext, missingRow, timeout }
    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var titles: [String] = []
        func append(_ event: AgentBackendEvent) { lock.withLock { titles.append(event.title) } }
        func contains(_ title: String) -> Bool { lock.withLock { titles.contains(title) } }
    }
    private static func reached(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
    private static func literal(_ value: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
    private static func marker(_ url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return value
    }
    private static func writePeer(root: URL, database: URL?, mode: String) throws -> (URL, URL) {
        let script = root.appendingPathComponent("owned-peer.py")
        let output = root.appendingPathComponent("owned-launch.json")
        let header = "OWN_DATABASE = " + (try database.map { try literal($0.path) } ?? "None")
            + "\nOWN_MARKER = " + (try literal(output.path))
            + "\nMODE = " + (try literal(mode)) + "\n"
        try (header + peer).write(to: script, atomically: true, encoding: .utf8)
        return (script, output)
    }
    // The task store's existing canonical ISO8601 export truncates subsecond dates.
    // Pin that representation exactly, plus the original exact in-memory producer time.
    private static func canonicalDate(_ date: Date) throws -> Date {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Date.self, from: encoder.encode(date))
    }
    static func originalCases(root: URL, check: (Bool, String) -> Void) async throws {
        let canonical = root.resolvingSymlinksInPath().standardizedFileURL
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard SelfTest.isRunning, canonical.path.hasPrefix(temporary.path + "/"),
              !canonical.pathComponents.contains("Application Support") else { throw FixtureError.unsafeRoot }
        for mode in ["positive", "sql-reject", "stale-state", "stale-attempt", "cancel-held"] {
            let flow = canonical.appendingPathComponent("acp-" + mode, isDirectory: true)
            try FileManager.default.createDirectory(at: flow, withIntermediateDirectories: false)
            let sql = TaskStore(root: flow)
            defer { sql.close() }
            let store = AgentTaskStore(fileURL: flow.appendingPathComponent("agent-tasks.json"), mirror: sql)
            guard store.allowsHarnessPersistence else { throw FixtureError.unsafeRoot }
            let receipts = ActionReceiptStore(fileURL: flow.appendingPathComponent("action-receipts.json"))
            let manager = AgentTaskManager(store: store, receiptStore: receipts)
            let (script, output) = try writePeer(root: flow, database: sql.fileURL,
                mode: mode == "cancel-held" ? "hold" : "normal")
            var context: TaskJournalContext?
            var rowAtEntry: AgentTask?
            var producerStart: Date?
            var canonicalStart: Date?
            var bindingAtEntry: TaskWorkerBinding?
            var successor: AgentTask?
            var entered = 0
            var ended = false
            var announcements: [String] = []
            manager.backendExitForTesting = { ended = true }
            manager.announcementForTesting = { announcements.append($0) }
            manager.backendEntryForTesting = {
                entered += 1
                guard let captured = TaskEventJournal.current else { throw FixtureError.missingContext }
                context = captured
                let reader = TaskStore(root: flow)
                defer { reader.close() }
                guard let row = try reader.load().first(where: { $0.id == captured.taskID }) else {
                    throw FixtureError.missingRow
                }
                rowAtEntry = row
                bindingAtEntry = manager.workerBinding(taskID: captured.taskID)
                producerStart = manager.task(id: captured.taskID)?.durability?.attemptStartedAt
                canonicalStart = try producerStart.map(canonicalDate)
                if mode == "stale-state" {
                    try sql.withConnection { db in
                        try TaskStore.run(db, "UPDATE task SET state='cancelled' WHERE id=?", [.text(captured.taskID)])
                    }
                    successor = try reader.load().first { $0.id == captured.taskID }
                } else if mode == "stale-attempt" {
                    var replacement = row.durability ?? TaskDurability()
                    replacement.attempt += 1
                    replacement.leaseOwner = "fixture-successor-owner"
                    replacement.attemptStartedAt = Date(timeIntervalSince1970: 1_000)
                    replacement.runtimeClass = .acpWorker
                    let encoded = String(decoding: try JSONEncoder().encode(replacement), as: UTF8.self)
                    try sql.withConnection { db in
                        try TaskStore.run(db, "UPDATE task SET durability=? WHERE id=?", [.text(encoded), .text(captured.taskID)])
                    }
                    successor = try reader.load().first { $0.id == captured.taskID }
                }
            }
            if mode == "sql-reject" {
                try sql.withConnection { db in
                    try TaskStore.exec(db, "CREATE TRIGGER reject_acp_running BEFORE UPDATE ON task WHEN NEW.state='running' BEGIN SELECT RAISE(ABORT,'fixture running rejection'); END")
                }
            }
            let task = manager.submit(objective: "Owned protocol fixture: no tools or external effects",
                arguments: ["acpFixture": script.path], backend: .acp, source: "selftest")
            if mode == "sql-reject" {
                check(await reached { manager.task(id: task.id)?.status == .failed },
                    "ACP primary: rejected running save did not settle its card")
                let row = try sql.load().first { $0.id == task.id }
                check(entered == 0 && manager.backendStartsForTesting == 0
                    && !FileManager.default.fileExists(atPath: output.path),
                    "ACP primary: actual process/backend entered after rejected running SQL")
                check(row?.status == .queued && receipts.receipts.isEmpty
                    && !announcements.contains { $0.contains("Owned ACP fixture finished") },
                    "ACP primary: running rejection changed admitted queued SQL or delivered success")
                continue
            }
            if mode == "cancel-held" {
                guard await reached({ marker(output)["phase"] as? String == "prompt" }) else {
                    manager.cancel(task.id)
                    throw FixtureError.timeout
                }
                manager.cancel(task.id) // Cancellation control only, never the stale intervention.
                check(manager.task(id: task.id)?.status == .cancelled
                    && manager.workerBinding(taskID: task.id) == nil,
                    "ACP primary: held cancellation did not commit/revoke its live binding")
            }
            guard await reached({ ended }) else {
                manager.cancel(task.id)
                throw FixtureError.timeout
            }
            let row = try sql.load().first { $0.id == task.id }
            let ownMarker = marker(output)
            if mode == "positive" {
                let owner = String(ProcessInfo.processInfo.processIdentifier)
                check(entered == 1 && rowAtEntry?.status == .running
                    && rowAtEntry?.durability?.attempt == 1 && rowAtEntry?.durability?.leaseOwner == owner
                    && rowAtEntry?.durability?.attemptStartedAt != nil
                    && rowAtEntry?.durability?.runtimeClass == .acpWorker
                    && rowAtEntry?.durability?.resumePolicy == .neverAuto,
                    "ACP primary: actual backend entered without committed positive ACP attempt")
                check(context?.attempt == 1 && context?.leaseOwner == owner && context?.isStillValid != nil
                    && bindingAtEntry?.attempt == 1 && bindingAtEntry?.leaseOwner == owner
                    && bindingAtEntry?.startedAt == producerStart
                    && rowAtEntry?.durability?.attemptStartedAt == canonicalStart,
                    "ACP primary: actual context/handle did not bind that exact admitted attempt")
                check(ownMarker["state"] as? String == "running" && ownMarker["attempt"] as? Int == 1
                    && ownMarker["leaseOwner"] as? String == owner
                    && ownMarker["runtimeClass"] as? String == "acpWorker"
                    && ownMarker["hasStart"] as? Bool == true
                    && ownMarker["launchCount"] as? Int == 1 && ownMarker["promptCount"] as? Int == 1,
                    "ACP primary: original process boundary did not consume committed ACP ownership")
                check(row?.status == .completed && row?.result?.contains("Owned ACP fixture finished") == true,
                    "ACP primary: actual Manager did not consume the owned protocol result")
                check(manager.workerBinding(taskID: task.id) == nil && context?.isStillValid?() == false,
                    "ACP primary: terminal result retained live binding or validity")
                let receipt = receipts.receipts.last { $0.taskID == task.id }
                check(receipt?.taskAttempt == 1 && receipt?.taskLeaseOwner == owner
                    && receipt?.events.contains { $0.stage == .fired } == true,
                    "ACP primary: actual ACP runtime did not consume the injected attempt receipt store")
            } else if mode == "cancel-held" {
                check(entered == 1 && ownMarker["launchCount"] as? Int == 1
                    && ownMarker["promptCount"] as? Int == 1 && row?.status == .cancelled
                    && !announcements.contains { $0.contains("Owned ACP fixture finished") },
                    "ACP primary: cancelled held process changed SQL or delivered success")
                check(manager.workerBinding(taskID: task.id) == nil && context?.isStillValid?() == false,
                    "ACP primary: held cancellation/cleanup restored an old live binding")
            } else {
                check(entered == 1 && successor != nil,
                    "ACP primary: stale case missed its original actual backend-entry intervention")
                check(!FileManager.default.fileExists(atPath: output.path),
                    "ACP primary: actual owned process launched after primary state/attempt changed")
                check(row == successor && !announcements.contains { $0.contains("Owned ACP fixture finished") },
                    "ACP primary: stale outcome overwrote successor SQL or delivered success")
                check(context?.isStillValid?() == false && manager.workerBinding(taskID: task.id) == nil,
                    "ACP primary: old context or terminal release retained successor authority")
                check(receipts.receipts.allSatisfy { !$0.events.contains { $0.stage == .fired } },
                    "ACP primary: stale pre-process attempt gained an actual fired receipt")
            }
        }
        // Additional API boundary negative; not a substitute for the actual Manager flows.
        let directRoot = canonical.appendingPathComponent("acp-positive-without-context", isDirectory: true)
        try FileManager.default.createDirectory(at: directRoot, withIntermediateDirectories: false)
        let (directScript, directMarker) = try writePeer(root: directRoot, database: nil, mode: "normal")
        var directTask = AgentTask(objective: "Owned direct boundary negative: no tools",
            source: "selftest", arguments: ["acpFixture": directScript.path], backend: AgentBackendKind.acp.rawValue)
        var directMetadata = TaskDurability()
        directMetadata.attempt = 1
        directMetadata.leaseOwner = String(ProcessInfo.processInfo.processIdentifier)
        directMetadata.attemptStartedAt = Date()
        directMetadata.runtimeClass = .acpWorker
        directTask.durability = directMetadata
        var directRefused = false
        do { _ = try await ACPAgentBackend().submit(directTask) }
        catch { directRefused = error.localizedDescription.contains("can’t safely continue") }
        check(directRefused, "ACP primary: positive direct attempt without captured context was not refused")
        check(!FileManager.default.fileExists(atPath: directMarker.path),
            "ACP primary: positive direct attempt without captured context launched its peer")
        try await declineAndLateControl(root: canonical, check: check)
    }
    private static func declineAndLateControl(root: URL, check: (Bool, String) -> Void) async throws {
        let flow = root.appendingPathComponent("acp-real-decline", isDirectory: true)
        try FileManager.default.createDirectory(at: flow, withIntermediateDirectories: false)
        let (script, output) = try writePeer(root: flow, database: nil, mode: "decline")
        let session = ACPSession()
        let events = Events()
        let token = await session.subscribe { events.append($0) }
        let taskID = "selftest-acp-decline-" + UUID().uuidString
        try await session.start(command: AgentStdioFixtures.python, arguments: [script.path],
            directory: flow.path, taskID: taskID, approvePermissions: false)
        let prompt = Task { @MainActor in try await session.prompt("Owned decline fixture: no effect") }
        guard await reached({ PermissionGate.shared.pending?.taskID == taskID }) else {
            prompt.cancel()
            await session.close()
            throw FixtureError.timeout
        }
        guard let pending = PermissionGate.shared.pending else { throw FixtureError.missingContext }
        let declined = PermissionGate.shared.respond(id: pending.id, approved: false)
        check(declined, "ACP control: actual permission gate did not accept the decline")
        let reply = try await prompt.value
        check(marker(output)["permissionOption"] as? String == "reject-once"
            && reply == "Owned ACP fixture finished." && PermissionGate.shared.pending?.taskID != taskID,
            "ACP control: real decline did not reach the same peer or drain review")
        check(await reached { events.contains("Late fixture notification") },
            "ACP control: valid same-session notification after final reply was discarded")
        await session.unsubscribe(token)
        await session.close()
    }

    private static let peer = """
        # Off-source fixture only. Swift inserts OWN_DATABASE, OWN_MARKER, MODE literals.
        import json, pathlib, sqlite3, sys, urllib.parse
        marker = pathlib.Path(OWN_MARKER)
        prior = json.loads(marker.read_text()) if marker.exists() else {}
        state = {'launchCount': prior.get('launchCount', 0) + 1, 'promptCount': 0, 'phase': 'launched'}
        if OWN_DATABASE is not None:
            conn = sqlite3.connect('file:' + urllib.parse.quote(OWN_DATABASE) + '?mode=ro', uri=True)
            rows = conn.execute('SELECT state,durability FROM task').fetchall()
            conn.close()
            assert len(rows) == 1
            raw_state, encoded = rows[0]
            durability = json.loads(encoded) if encoded else {}
            state.update({'state':raw_state, 'attempt':durability.get('attempt',0),
                          'leaseOwner':durability.get('leaseOwner'),
                          'runtimeClass':durability.get('runtimeClass'),
                          'hasStart':durability.get('attemptStartedAt') is not None})
        marker.write_text(json.dumps(state, sort_keys=True))
        session = 'fixture-acp-primary'
        waiting = None
        
        def save(): marker.write_text(json.dumps(state, sort_keys=True))
        def send(value):
            sys.stdout.write(json.dumps(value) + '\\n')
            sys.stdout.flush()
        def update(value):
            send({'jsonrpc':'2.0','method':'session/update','params':{'sessionId':session,'update':value}})
        def finish(mid):
            update({'sessionUpdate':'agent_message_chunk','content':{'type':'text','text':'Owned ACP fixture finished.'}})
            send({'jsonrpc':'2.0','id':mid,'result':{'stopReason':'end_turn'}})
            if MODE == 'decline':
                update({'sessionUpdate':'tool_call_update','toolCallId':'fixture-decline',
                        'title':'Late fixture notification','status':'failed'})
        for line in sys.stdin:
            msg = json.loads(line)
            mid, method = msg.get('id'), msg.get('method')
            if method == 'initialize':
                send({'jsonrpc':'2.0','id':mid,'result':{'protocolVersion':1,'agentCapabilities':{}}})
            elif method == 'session/new':
                send({'jsonrpc':'2.0','id':mid,'result':{'sessionId':session}})
            elif method == 'session/prompt':
                assert msg['params']['sessionId'] == session
                state['promptCount'] += 1
                state['phase'] = 'prompt'
                save()
                if MODE == 'decline':
                    waiting = mid
                    send({'jsonrpc':'2.0','id':900,'method':'session/request_permission','params':{
                        'sessionId':session,
                        'toolCall':{'toolCallId':'fixture-decline','title':'Decline owned fixture','kind':'other'},
                        'options':[{'optionId':'allow-once','name':'Allow once','kind':'allow_once'},
                                   {'optionId':'reject-once','name':'Reject','kind':'reject_once'}]}})
                elif MODE == 'hold':
                    waiting = mid
                else:
                    finish(mid)
            elif method is None and mid == 900:
                result = msg.get('result', {})
                state['permissionOption'] = result.get('optionId') or result.get('outcome',{}).get('optionId')
                state['permissionWireHasOutcome'] = isinstance(result.get('outcome'),dict)
                save()
                finish(waiting)
                waiting = None
            elif method == 'session/cancel':
                send({'jsonrpc':'2.0','id':mid,'result':{}})
                if waiting is not None:
                    send({'jsonrpc':'2.0','id':waiting,'result':{'stopReason':'cancelled'}})
                    waiting = None
        """
}

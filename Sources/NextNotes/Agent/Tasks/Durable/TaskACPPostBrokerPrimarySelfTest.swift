import Foundation

/// Real admitted Manager/ACPBackend/Session/Broker/grant and an owned stdio peer.
/// A successor primary is a committed row, not a claimed second live process.
@MainActor
enum TaskACPPostBrokerPrimarySelfTest {
    private enum Invalid: Error { case scope, owner, worker, gate, boundary }
    private static func reached(_ predicate: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline { if predicate() { return true }; await Task.yield() }
        return predicate()
    }
    private static func object(_ file: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] ?? [:]
    }
    private static func release(_ root: URL, _ file: String) throws {
        try Data(#"{"release":true}"#.utf8).write(to: root.appendingPathComponent(file), options: .atomic)
    }
    @MainActor
    private final class State {
        let mode: String, root: URL, sql: TaskStore, store: AgentTaskStore, receipts: ActionReceiptStore
        let manager: AgentTaskManager
        var row: AgentTask?, context: TaskJournalContext?, task: Task<Void, Never>?, binding: TaskWorkerBinding?
        var freshSQL: TaskStore?, freshManager: AgentTaskManager?, successorStore: AgentTaskStore?
        var entered = 0, ended = 0, boundaries = 0, wrongBoundary = 0
        var beforeValid = false, afterValid = false, primaryAdmitted = false, primaryRefused = false
        var atBoundary: AgentTask?, journalAtBoundary: [TaskJournalEvent] = []
        var boundaryError = false
        var announcements: [String] = []
        init(root: URL, mode: String) throws {
            self.root = root; self.mode = mode
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            sql = TaskStore(root: root)
            store = AgentTaskStore(fileURL: root.appendingPathComponent("agent-tasks.json"), mirror: sql)
            guard store.allowsHarnessPersistence else { throw Invalid.scope }
            receipts = ActionReceiptStore(fileURL: root.appendingPathComponent("action-receipts.json"))
            manager = AgentTaskManager(store: store, receiptStore: receipts)
            manager.backendEntryForTesting = { [weak self] in
                guard let self, let captured = TaskEventJournal.current else { throw Invalid.owner }
                entered += 1; context = captured; binding = manager.workerBinding(taskID: captured.taskID)
                task = manager.capturedACPTaskForTesting(id: captured.taskID)
                guard task != nil else { throw Invalid.worker }
                try JSONSerialization.data(withJSONObject: ["objective": "Owned Broker primary boundary: no effects", "taskID": captured.taskID], options: [.sortedKeys])
                    .write(to: root.appendingPathComponent("config.json"), options: .atomic)
            }
            manager.backendExitForTesting = { [weak self] in self?.ended += 1 }
            manager.announcementForTesting = { [weak self] in self?.announcements.append($0) }
        }
        func boundary(toolID: String, taskID: String) {
            guard toolID == "mcp.acp_nested_tool", taskID == row?.id, let context else { wrongBoundary += 1; return }
            boundaries += 1
            guard boundaries == 1 else { boundaryError = true; return }
            beforeValid = context.isStillValid?() == true
            do {
                if mode == "held" || mode == "refused-hold" {
                    if mode == "refused-hold" {
                        try sql.withConnection { try TaskStore.exec($0, "CREATE TRIGGER reject_broker_hold BEFORE UPDATE ON task WHEN NEW.state='recovering' BEGIN SELECT RAISE(ABORT,'owned hold refusal'); END") }
                    }
                    let fresh = TaskStore(root: root); freshSQL = fresh
                    let freshStore = AgentTaskStore(fileURL: root.appendingPathComponent("agent-tasks.json"), mirror: fresh)
                    guard freshStore.allowsHarnessPersistence else { throw Invalid.scope }
                    let held = AgentTaskManager(store: freshStore, receiptStore: receipts); freshManager = held
                    primaryAdmitted = held.lastPersistenceResult?.primaryCommitted == true
                    primaryRefused = held.lastPersistenceResult == .sqlFailed
                    if mode == "refused-hold" { try sql.withConnection { try TaskStore.exec($0, "DROP TRIGGER reject_broker_hold") } }
                } else if mode == "successor-primary" {
                    // Positively commit a successor row through the SAME real store.
                    // No worker/process is minted and this does not claim recovery.
                    let fresh = TaskStore(root: root); freshSQL = fresh
                    let writer = AgentTaskStore(fileURL: root.appendingPathComponent("agent-tasks.json"), mirror: fresh); successorStore = writer
                    var rows = try fresh.load()
                    guard let index = rows.firstIndex(where: { $0.id == taskID }), rows[index].durability?.attempt == context.attempt else { throw Invalid.owner }
                    rows[index].durability?.attempt += 1
                    rows[index].durability?.attemptStartedAt = Date()
                    let next = context.attempt + 1
                    primaryAdmitted = writer.save(rows, events: [.init(taskID: taskID, kind: .workerStarted, attempt: next)]).primaryCommitted
                } else if mode == "waiting-person" {
                    primaryAdmitted = manager.requestInput(taskID: taskID, question: "Which owned document should I use?")
                } else { primaryAdmitted = true }
                atBoundary = try sql.load().first { $0.id == taskID }
                journalAtBoundary = try sql.journal(taskID: taskID)
                afterValid = context.isStillValid?() == true
            } catch { boundaryError = true }
        }
    }
    static func originalCases(root: URL, check: (Bool, String) -> Void) async throws {
        let safe = root.resolvingSymlinksInPath().standardizedFileURL
        let temp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let gate = PermissionGate.shared, grants = PermissionGrantStore.shared
        guard SelfTest.isRunning, SelfTest.requested == "--selftest-task-worker-attempt",
              safe.path.hasPrefix(temp.path + "/"), !safe.pathComponents.contains("Application Support"),
              safe.path == root.standardizedFileURL.path, gate.pending == nil, gate.queuedCount == 0,
              grants.grants.isEmpty else { throw Invalid.scope }
        let ownerBefore = SelfTestStoreGuard.take()
        let oldFake = AgentToolExecutor.fakeForTesting, oldFire = AgentToolExecutor.fireOverrideForTesting
        AgentToolExecutor.fakeForTesting = nil
        var unexpectedBacking = 0
        AgentToolExecutor.fireOverrideForTesting = { _, _ in unexpectedBacking += 1; throw Invalid.owner }
        defer { AgentToolExecutor.fakeForTesting = oldFake; AgentToolExecutor.fireOverrideForTesting = oldFire }
        for mode in ["current", "held", "successor-primary", "waiting-person", "refused-hold"] {
            let dir = safe.appendingPathComponent("post-broker-" + mode, isDirectory: true)
            let state = try State(root: dir, mode: mode)
            let script = dir.appendingPathComponent("owned-peer.py")
            try peer.write(to: script, atomically: true, encoding: .utf8)
            let asksBefore = gate.askCount
            var caught: Error?, requestID: String?, grantID: String?
            var boundaryInstalled = false
            state.row = state.manager.submit(objective: "Owned Broker primary boundary: no effects",
                arguments: ["acpFixture": script.path, "acpFixtureAskPermission": "true"], backend: .acp, source: "selftest")
            if let id = state.row?.id { state.task = state.manager.capturedACPTaskForTesting(id: id) }
            do {
                guard await reached({ gate.pending?.taskID == state.row?.id }),
                      let request = gate.pending, let submitted = state.row, let context = state.context,
                      let operation = state.task, let binding = state.binding else { throw Invalid.worker }
                requestID = request.id
                let runtime = await state.manager.workerACPRuntimeObservation(taskID: submitted.id)
                check(state.entered == 1 && state.ended == 0 && context.taskID == submitted.id && context.attempt == 1
                    && context.leaseOwner == String(ProcessInfo.processInfo.processIdentifier) && !operation.isCancelled
                    && context.isStillValid?() == true && (runtime?.processID ?? 0) > 0 && runtime?.transportClosed == false,
                    "Post-Broker C01 actual admitted current ACP owner/peer (\(mode))")
                check(request.toolID == "mcp.acp_nested_tool" && gate.pendingReview?.isReadyToRun == true
                    && gate.respond(id: request.id, approved: true, duration: .thisTask),
                    "Post-Broker C02 actual first Gate creates task-scoped grant (\(mode))")
                guard await reached({ FileManager.default.fileExists(atPath: dir.appendingPathComponent("first-wire.json").path) }),
                      let grant = grants.grants.first(where: { $0.taskID == submitted.id && $0.toolID == request.toolID }) else { throw Invalid.gate }
                grantID = grant.id
                let firstWire = try object(dir.appendingPathComponent("first-wire.json"))
                guard let startupReceipt = state.receipts.receipts.first,
                      state.receipts.receipts.count == 1,
                      startupReceipt.status == .fired,
                      startupReceipt.taskID == submitted.id,
                      startupReceipt.taskAttempt == context.attempt,
                      startupReceipt.taskLeaseOwner == context.leaseOwner else { throw Invalid.owner }
                let joinedReceiptIDs = [startupReceipt.actionID.uuidString]
                let startedPrimary = try state.sql.load().first { $0.id == submitted.id }
                check(grant.duration == .thisTask && grants.grants.count == 1
                    && state.manager.workerBinding(taskID: submitted.id) == binding && context.isStillValid?() == true
                    && firstWire["optionId"] as? String == "allow-once"
                    && startedPrimary?.durability?.receiptIDs == joinedReceiptIDs,
                    "Post-Broker C03 actual grant/wire retains same initial owner (\(mode))")
                boundaryInstalled = await PermissionBroker.shared.setGrantBoundaryForTesting({ toolID, taskID in
                    await state.boundary(toolID: toolID, taskID: taskID)
                }, root: dir)
                guard boundaryInstalled else { throw Invalid.boundary }
                try release(dir, "release-second.json")
                guard await reached({ FileManager.default.fileExists(atPath: dir.appendingPathComponent("second-wire.json").path) }) else { throw Invalid.boundary }
                let restored = await PermissionBroker.shared.setGrantBoundaryForTesting(nil, root: dir)
                boundaryInstalled = !restored
                let stillCurrent = mode == "current" || mode == "refused-hold"
                let wire = try object(dir.appendingPathComponent("second-wire.json"))
                check(restored && state.boundaries == 1 && state.wrongBoundary == 0 && !state.boundaryError && state.beforeValid,
                    "Post-Broker C04 actual standing-grant return boundary qualified (\(mode))")
                let primaryQualified: Bool
                switch mode {
                case "held": primaryQualified = state.atBoundary?.status == .recovering && state.atBoundary?.durability?.attempt == context.attempt
                case "successor-primary": primaryQualified = state.atBoundary?.status == .running && state.atBoundary?.durability?.attempt == context.attempt + 1
                case "waiting-person": primaryQualified = state.atBoundary?.status == .waitingForInput && state.atBoundary?.durability?.attempt == context.attempt
                default: primaryQualified = state.atBoundary == startedPrimary
                }
                let samePeer = await state.manager.workerACPRuntimeObservation(taskID: submitted.id)
                // Waiting-on-person intentionally has no RUNNING binding/runtime getter.
                // The actual peer wire PID and SAME retained Task prove only this owned response.
                let capturedSameTask = state.manager.capturedACPTaskForTesting(id: submitted.id) == operation
                let sameWirePeer = (wire["processID"] as? Int) == Int(runtime?.processID ?? 0)
                    && (firstWire["processID"] as? Int) == Int(runtime?.processID ?? 0)
                let currentMetadata = mode == "waiting-person"
                    ? samePeer == nil && state.manager.workerBinding(taskID: submitted.id) == nil
                    : samePeer?.processID == runtime?.processID && samePeer?.transportClosed == false
                        && state.manager.workerBinding(taskID: submitted.id) == binding
                check(primaryQualified && state.afterValid == stillCurrent && (mode == "refused-hold" ? state.primaryRefused && !state.primaryAdmitted : state.primaryAdmitted)
                    && currentMetadata && capturedSameTask && sameWirePeer && !operation.isCancelled,
                    "Post-Broker C05 same uncancelled handle with real primary admission/refusal (\(mode))")
                check(wire["outcome"] as? String == "selected" && wire["optionId"] as? String == (stillCurrent ? "allow-once" : "reject-once"),
                    "Post-Broker F01 offered wire cannot authorize stale primary (\(mode))")
                check(gate.askCount == asksBefore + 1 && gate.pending == nil && gate.queuedCount == 0
                    && grants.grants.count == 1 && grants.grants.first?.id == grant.id && unexpectedBacking == 0,
                    "Post-Broker C06 no new card/grant/backing/replay (\(mode))")
                try release(dir, "release-result.json")
                await operation.value
                let final = try state.sql.load().first { $0.id == submitted.id }
                let events = try state.sql.journal(taskID: submitted.id)
                check(state.entered == 1 && state.ended == 1 && (stillCurrent ? final?.status == .completed : final == state.atBoundary && events == state.journalAtBoundary),
                    "Post-Broker C07 final actual consumer preserves stale primary (\(mode))")
                check(state.receipts.receipts.count == 1 && state.receipts.receipts.first?.taskID == submitted.id
                    && state.receipts.receipts.first?.taskAttempt == context.attempt
                    && state.receipts.receipts.first?.actionID == startupReceipt.actionID
                    && state.receipts.receipts.first?.taskLeaseOwner == context.leaseOwner
                    && state.atBoundary?.durability?.receiptIDs == joinedReceiptIDs
                    && final?.durability?.receiptIDs == joinedReceiptIDs,
                    "Post-Broker C08 actual startup receipt binding is retained (\(mode))")
                SelfTest.diagnostic("TASK_ACP_POST_BROKER_TRACE mode=\(mode) boundaries=\(state.boundaries) primaryBefore=\(state.beforeValid) primaryAfter=\(state.afterValid) primaryAccepted=\(state.primaryAdmitted) primaryRefused=\(state.primaryRefused) wireAllowed=\(wire["optionId"] as? String == "allow-once") asks=\(gate.askCount - asksBefore) entries=\(state.entered) exits=\(state.ended) liveSuccessorClaim=false effects=\(unexpectedBacking)")
            } catch { caught = error }
            // Capture actual existing operation before cancel/release on every exit.
            if state.task == nil, let id = state.row?.id { state.task = state.manager.capturedACPTaskForTesting(id: id) }
            if boundaryInstalled { boundaryInstalled = !(await PermissionBroker.shared.setGrantBoundaryForTesting(nil, root: dir)) }
            try? state.sql.withConnection { try TaskStore.exec($0, "DROP TRIGGER IF EXISTS reject_broker_hold") }
            if let id = state.row?.id { gate.cancelPending(taskID: id); if state.ended == 0 { state.manager.cancel(id) } }
            try? release(dir, "release-second.json"); try? release(dir, "release-result.json")
            await state.task?.value
            if let requestID { ToolCallReviewStore.shared.remove(id: requestID) }
            if let grantID { grants.revoke(id: grantID) }
            check(!boundaryInstalled && state.ended == 1 && gate.pending == nil && gate.queuedCount == 0 && grants.grants.isEmpty,
                "Post-Broker C09 exact operation/boundary/Gate/grant cleanup (\(mode))")
            // Refuse verdict/removal until the actual operation was captured and joined.
            // The parent fixture owns the outer root; no unjoined child may return here.
            guard state.task != nil, state.ended == 1, !boundaryInstalled else { throw Invalid.worker }
            state.freshSQL?.close(); state.sql.close()
            if let caught { throw caught }
            try FileManager.default.removeItem(at: dir)
        }
        check(SelfTestStoreGuard.diff(ownerBefore, SelfTestStoreGuard.take()).isEmpty,
            "Post-Broker O01 owner persistence/default invariance")
    }
    private static let peer = #"""
        import json, os, pathlib, sys, time
        root = pathlib.Path(__file__).resolve().parent
        config = json.loads((root / 'config.json').read_text())
        session, prompt = 'owned-post-broker-primary', None
        def write(name, value):
            target = root / name
            tmp = target.with_suffix('.tmp')
            tmp.write_text(json.dumps(value, sort_keys=True))
            tmp.replace(target)
        def send(value):
            sys.stdout.write(json.dumps(value) + '\n'); sys.stdout.flush()
        def wait(name):
            until = time.monotonic() + 12
            while not (root / name).exists():
                if time.monotonic() >= until: raise TimeoutError('owned release')
                time.sleep(.005)
        def permission(mid):
            send({'jsonrpc':'2.0','id':mid,'method':'session/request_permission','params':{'sessionId':session,
              'toolCall':{'toolCallId':'owned-review-only','title':'Owned protocol review only','kind':'other','status':'pending'},
              'options':[{'optionId':'allow-once','name':'Allow once','kind':'allow_once'},
                         {'optionId':'reject-once','name':'Reject','kind':'reject_once'}]}})
        for line in sys.stdin:
            msg=json.loads(line);mid=msg.get('id');method=msg.get('method')
            if method=='initialize': send({'jsonrpc':'2.0','id':mid,'result':{'protocolVersion':1,'agentCapabilities':{}}})
            elif method=='session/new': send({'jsonrpc':'2.0','id':mid,'result':{'sessionId':session}})
            elif method=='session/prompt':
                assert msg['params']['prompt'][0]['text']==config['objective'];prompt=mid;permission(900)
            elif method is None and mid in (900,901):
                result=msg.get('result',{}).get('outcome',{});result['processID']=os.getpid()
                write('first-wire.json' if mid==900 else 'second-wire.json',result)
                if mid==900: wait('release-second.json');permission(901)
                else:
                    wait('release-result.json')
                    send({'jsonrpc':'2.0','method':'session/update','params':{'sessionId':session,
                        'update':{'sessionUpdate':'agent_message_chunk','content':{'type':'text','text':'Owned protocol result only.'}}}})
                    send({'jsonrpc':'2.0','id':prompt,'result':{'stopReason':'end_turn'}})
            elif method=='session/cancel': send({'jsonrpc':'2.0','id':mid,'result':{}})
        """#
}

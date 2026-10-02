import Foundation

/// Actual typed Manager/Backend/Session peer plus explicitly standalone idle-EOF controls.
/// Nil original getter is a missing feature; no liveness, health or retry policy is asserted.
@MainActor
enum TaskACPRuntimeObservationSelfTest {
    private enum FixtureError: Error { case unsafeRoot, busyGate, missingContext, missingReceipt, timeout, invalidPeer }

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

    private static func release(_ url: URL) throws {
        try Data(#"{"release":true}"#.utf8).write(to: url, options: .atomic)
    }

    static func originalCases(root: URL, check: (Bool, String) -> Void) async throws {
        let safe = root.resolvingSymlinksInPath().standardizedFileURL
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard SelfTest.isRunning, safe.isFileURL, safe.path.hasPrefix(temporary.path + "/"),
              !safe.pathComponents.contains("Application Support") else { throw FixtureError.unsafeRoot }
        guard PermissionGate.shared.pending == nil, PermissionGate.shared.queuedCount == 0 else { throw FixtureError.busyGate }
        let grantsBefore = PermissionGrantStore.shared.grants
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
        let objective = "Owned ACP runtime observation fixture: no tools"
        let marker = "Owned ACP runtime observation finished."
        let sessionID = "fixture-acp-runtime-observation"
        let warning = "\nNext Notes could not independently verify the effect. Inspect the target before retrying."

        for mode in ["accepted", "fresh-primary-held"] {
            let heldMode = mode == "fresh-primary-held"
            let directory = safe.appendingPathComponent("acp-runtime-" + mode, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let sql = TaskStore(root: directory)
            defer { sql.close() }
            let export = directory.appendingPathComponent("agent-tasks.json")
            let store = AgentTaskStore(fileURL: export, mirror: sql)
            guard store.allowsHarnessPersistence else { throw FixtureError.unsafeRoot }
            let receiptFile = directory.appendingPathComponent("action-receipts.json")
            let receipts = ActionReceiptStore(fileURL: receiptFile)
            let manager = AgentTaskManager(store: store, receiptStore: receipts)
            let script = directory.appendingPathComponent("owned-runtime-peer.py")
            let releaseResult = directory.appendingPathComponent("release-result.json")
            try peer.write(to: script, atomically: true, encoding: .utf8)
            var captured: TaskJournalContext?
            var bindingAtEntry: TaskWorkerBinding?
            var entryRow: AgentTask?
            var entered = 0
            var ended = 0
            var announcements: [String] = []
            var holdingSQL: TaskStore?
            var holdingManager: AgentTaskManager?
            defer { holdingSQL?.close() }
            manager.announcementForTesting = { announcements.append($0) }
            manager.backendExitForTesting = { ended += 1 }
            manager.backendEntryForTesting = {
                entered += 1
                guard let context = TaskEventJournal.current else { throw FixtureError.missingContext }
                captured = context
                bindingAtEntry = manager.workerBinding(taskID: context.taskID)
                entryRow = try sql.load().first { $0.id == context.taskID }
                let config: [String: Any] = ["kind": "worker", "objective": objective,
                    "marker": marker, "taskID": context.taskID]
                try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
                    .write(to: directory.appendingPathComponent("config.json"), options: .atomic)
            }
            let submitted = manager.submit(objective: objective, arguments: ["acpFixture": script.path],
                backend: .acp, source: "selftest")
            do {
                guard await reached({ FileManager.default.fileExists(atPath: directory.appendingPathComponent("prompt-observed.json").path) }) else { throw FixtureError.timeout }
                guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent("peer-error.json").path),
                      let context = captured, let binding = bindingAtEntry else { throw FixtureError.invalidPeer }
                let prompt = object(directory.appendingPathComponent("prompt-observed.json"))
                let launch = object(directory.appendingPathComponent("launch.json"))
                let peerPID = (launch["pid"] as? Int).map(Int32.init)
                guard let fired = receipts.receipts.first, receipts.receipts.count == 1 else { throw FixtureError.missingReceipt }
                let joined = [fired.actionID.uuidString]
                // C01
                check(entered == 1 && ended == 0 && manager.backendStartsForTesting == 1
                    && prompt["taskID"] as? String == submitted.id && prompt["sessionID"] as? String == sessionID
                    && prompt["objective"] as? String == objective && prompt["promptCount"] as? Int == 1,
                    "ACP runtime: real exact first prompt was not held silently (\(mode))")
                // C02
                check(entryRow?.status == .running && entryRow?.durability?.attempt == 1
                    && entryRow?.durability?.leaseOwner == owner && entryRow?.durability?.runtimeClass == .acpWorker
                    && context.taskID == submitted.id && context.attempt == 1 && context.leaseOwner == owner
                    && context.receiptStore === receipts && context.observeACPSession != nil
                    && binding.taskID == submitted.id && binding.attempt == 1 && binding.leaseOwner == owner
                    && manager.workerBinding(taskID: submitted.id) == binding && context.isStillValid?() == true,
                    "ACP runtime: silent prompt lost exact positive typed owner/context (\(mode))")
                let primaryAtPrompt = try sql.load().first { $0.id == submitted.id }
                let journalAtPrompt = try sql.journal(taskID: submitted.id)
                // C03
                check(fired.status == .fired && fired.result.isEmpty && fired.taskID == submitted.id
                    && fired.taskAttempt == 1 && fired.taskLeaseOwner == owner && fired.toolID == "mcp.acp_session"
                    && fired.preparedAction?.id == fired.actionID && primaryAtPrompt?.durability?.receiptIDs == joined
                    && journalAtPrompt.filter { $0.draft.kind == .toolStarted }.count == 1,
                    "ACP runtime: exact real startup receipt/primary join was substituted (\(mode))")
                // C04: intended missing-feature original RED, never inferred from handle/app PID.
                let live = await manager.workerACPRuntimeObservation(taskID: submitted.id)
                check(live?.processID == peerPID && peerPID != nil && peerPID != ProcessInfo.processInfo.processIdentifier
                    && live?.isRunning == true && live?.transportClosed == false && live?.outputEOF == false
                    && live?.pendingRequestCount == 1,
                    "ACP runtime: current owned child/open silent prompt observation unavailable (\(mode))")
                context.observeACPSession?(ACPSession())
                let afterCompetingAttach = await manager.workerACPRuntimeObservation(taskID: submitted.id)
                // C13: inert separate Session must not replace the SAME admitted slot.
                check(afterCompetingAttach == live && afterCompetingAttach?.processID == peerPID,
                    "ACP runtime: second inert Session replaced actual owned live probe (\(mode))")
                let wrongID = await manager.workerACPRuntimeObservation(taskID: "missing-runtime-fixture")
                // C05
                check(wrongID == nil, "ACP runtime: unrelated task obtained a current Session (\(mode))")
                let beforeRow = try sql.load().first { $0.id == submitted.id }
                let beforeJournal = try sql.journal(taskID: submitted.id)
                let beforeExport = try Data(contentsOf: export)
                let beforeReceipts = try Data(contentsOf: receiptFile)
                var repeatedMatches = true
                for _ in 0..<12 {
                    let sample = await manager.workerACPRuntimeObservation(taskID: submitted.id)
                    repeatedMatches = repeatedMatches && sample == live
                }
                await TaskHeartbeatIntegrationSelfTest.sample(manager: manager, binding: binding,
                    expectedPrimary: .accepted, expectedWait: false, expectedAge: "withinWindow", check: check)
                // C06
                check(repeatedMatches && live != nil,
                    "ACP runtime: repeated current owned samples are missing or changed silently (\(mode))")
                // C07
                check(try sql.load().first { $0.id == submitted.id } == beforeRow
                    && sql.journal(taskID: submitted.id) == beforeJournal
                    && Data(contentsOf: export) == beforeExport && Data(contentsOf: receiptFile) == beforeReceipts
                    && manager.workerBinding(taskID: submitted.id) == binding && ended == 0,
                    "ACP runtime: read-only samples changed primary/journal/export/receipt/worker (\(mode))")
                if heldMode {
                    let freshSQL = TaskStore(root: directory)
                    holdingSQL = freshSQL
                    let fresh = AgentTaskManager(store: AgentTaskStore(fileURL: export, mirror: freshSQL),
                        receiptStore: ActionReceiptStore(fileURL: receiptFile))
                    holdingManager = fresh
                    let heldRow = try sql.load().first { $0.id == submitted.id }
                    let heldJournal = try sql.journal(taskID: submitted.id)
                    // H01
                    check(fresh.task(id: submitted.id)?.status == .recovering && fresh.backendStartsForTesting == 0
                        && fresh.lastPersistenceResult?.primaryCommitted == true && heldRow?.status == .recovering
                        && heldRow?.durability?.attempt == 1 && heldRow?.durability?.receiptIDs == joined
                        && heldJournal.filter { $0.draft.kind == .recoveryHeld }.count == 1,
                        "ACP runtime: fresh manager did not hold exact real primary without dispatch")
                    // H02
                    check(manager.task(id: submitted.id)?.status == .running && manager.workerBinding(taskID: submitted.id) == binding
                        && context.isStillValid?() == false && ended == 0,
                        "ACP runtime: primary hold was substituted with Task cancellation/release")
                    let heldLive = await manager.workerACPRuntimeObservation(taskID: submitted.id)
                    await TaskHeartbeatIntegrationSelfTest.sample(manager: manager, binding: binding,
                        expectedPrimary: .unavailable, expectedWait: false, expectedAge: nil,
                        expectedReceipt: false, check: check)
                    // H03
                    check(heldLive == live && heldLive?.processID == peerPID && heldLive?.isRunning == true
                        && heldLive?.transportClosed == false && heldLive?.pendingRequestCount == 1,
                        "ACP runtime: live owned process was conflated with held primary authority")
                    // H04
                    check(try sql.load().first { $0.id == submitted.id } == heldRow
                        && sql.journal(taskID: submitted.id) == heldJournal
                        && holdingManager?.backendStartsForTesting == 0,
                        "ACP runtime: held observation changed history or started a successor")
                }
                let boundaryRow = try sql.load().first { $0.id == submitted.id }
                let boundaryJournal = try sql.journal(taskID: submitted.id)
                try release(releaseResult)
                guard await reached({ ended == 1 }) else { throw FixtureError.timeout }
                let finalRow = try sql.load().first { $0.id == submitted.id }
                let finalJournal = try sql.journal(taskID: submitted.id)
                let persisted = ActionReceiptStore(fileURL: receiptFile)
                guard let finalReceipt = persisted.receipts.first else { throw FixtureError.missingReceipt }
                // C08
                check(entered == 1 && ended == 1 && manager.backendStartsForTesting == 1
                    && manager.workerBinding(taskID: submitted.id) == nil,
                    "ACP runtime: actual worker failed to complete/release once (\(mode))")
                // C09
                let afterCleanup = await manager.workerACPRuntimeObservation(taskID: submitted.id)
                check(afterCleanup == nil, "ACP runtime: released worker exposed an old current Session (\(mode))")
                check(await manager.workerHeartbeatObservation(taskID: submitted.id) == nil,
                    "Heartbeat integration: released actual worker exposed an old sample")
                context.observeACPSession?(ACPSession())
                let afterLateAttach = await manager.workerACPRuntimeObservation(taskID: submitted.id)
                // C10
                check(afterLateAttach == nil && manager.workerBinding(taskID: submitted.id) == nil,
                    "ACP runtime: retained old context attached a Session after release (\(mode))")
                // C11
                check(finalReceipt.actionID == fired.actionID && finalReceipt.preparedAction == fired.preparedAction
                    && finalReceipt.status == .couldNotVerify && finalReceipt.result == marker
                    && finalReceipt.artifacts == [sessionID] && finalReceipt.taskID == submitted.id
                    && finalReceipt.taskAttempt == 1 && finalReceipt.taskLeaseOwner == owner
                    && finalRow?.durability?.receiptIDs == joined,
                    "ACP runtime: actual protocol result lost truthful exact retained receipt (\(mode))")
                // C12
                check(object(directory.appendingPathComponent("calls.json"))["methods"] as? [String]
                    == ["initialize", "session/new", "session/prompt"] && launch["launchCount"] as? Int == 1
                    && !FileManager.default.fileExists(atPath: directory.appendingPathComponent("peer-error.json").path),
                    "ACP runtime: peer restarted, changed protocol or reported invalid controls (\(mode))")
                if heldMode {
                    // H05
                    check(finalRow == boundaryRow && finalJournal == boundaryJournal
                        && finalRow?.status == .recovering
                        && !announcements.contains { $0.contains(marker) }
                        && !finalJournal.contains { $0.draft.kind == .jobCompleted },
                        "ACP runtime: held original worker changed primary or delivered task success")
                } else {
                    // A01
                    check(finalRow?.status == .completed && manager.task(id: submitted.id)?.status == .completed
                        && finalRow?.result == marker + warning && finalRow?.artifacts == [sessionID]
                        && announcements.contains(marker + warning)
                        && finalJournal.filter { $0.draft.kind == .jobCompleted }.count == 1,
                        "ACP runtime: accepted real prompt consumer no longer completes truthfully")
                }
                SelfTest.diagnostic("TASK_ACP_RUNTIME_TRACE: mode=\(mode) observed=\(live != nil) running=\(live?.isRunning.description ?? "unknown") closed=\(live?.transportClosed.description ?? "unknown") pending=\(live?.pendingRequestCount ?? -1) primary=\(finalRow?.status.rawValue ?? "absent") entered=\(entered) ended=\(ended)")
            } catch {
                try? release(releaseResult)
                if ended == 0 {
                    manager.cancel(submitted.id)
                    let drained = await reached { ended == 1 }
                    check(drained, "ACP runtime: error cleanup failed to drain exact owned worker (\(mode))")
                }
                throw error
            }
        }

        // Supplementary SAME standalone Session: no worker-EOF claim or production pause hook.
        let idleRoot = safe.appendingPathComponent("acp-runtime-idle-eof", isDirectory: true)
        try FileManager.default.createDirectory(at: idleRoot, withIntermediateDirectories: false)
        let idleScript = idleRoot.appendingPathComponent("owned-runtime-peer.py")
        try peer.write(to: idleScript, atomically: true, encoding: .utf8)
        try JSONSerialization.data(withJSONObject: ["kind": "idle"], options: [.sortedKeys])
            .write(to: idleRoot.appendingPathComponent("config.json"), options: .atomic)
        let idleSession = ACPSession()
        do {
            try await idleSession.start(command: AgentStdioFixtures.python, arguments: [idleScript.path],
                taskID: "standalone-runtime-fixture", approvePermissions: false)
            let idlePID = (object(idleRoot.appendingPathComponent("launch.json"))["pid"] as? Int).map(Int32.init)
            // S01
            let idleInitialized = await idleSession.didInitialize
            let idleSessionID = await idleSession.sessionID
            check(idleInitialized && idleSessionID == sessionID
                && object(idleRoot.appendingPathComponent("calls.json"))["methods"] as? [String] == ["initialize", "session/new"],
                "ACP runtime standalone: actual same Session handshake did not finish")
            let idleOpen = await idleSession.currentRuntimeObservation()
            // S02
            check(idleOpen?.processID == idlePID && idlePID != nil && idleOpen?.isRunning == true
                && idleOpen?.transportClosed == false && idleOpen?.outputEOF == false && idleOpen?.pendingRequestCount == 0,
                "ACP runtime standalone: current actual idle child observation missing")
            try release(idleRoot.appendingPathComponent("release-eof.json"))
            guard await reached({ FileManager.default.fileExists(atPath: idleRoot.appendingPathComponent("eof-observed.json").path) }) else { throw FixtureError.timeout }
            var atEOF = await idleSession.currentRuntimeObservation()
            if atEOF != nil {
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                while atEOF?.outputEOF != true && ContinuousClock.now < deadline {
                    await Task.yield()
                    atEOF = await idleSession.currentRuntimeObservation()
                }
            }
            // S03
            check(atEOF?.processID == idlePID && atEOF?.isRunning == true && atEOF?.transportClosed == true
                && atEOF?.outputEOF == true && atEOF?.pendingRequestCount == 0,
                "ACP runtime standalone: output EOF was conflated with actual child exit")
            // S04
            check(!FileManager.default.fileExists(atPath: idleRoot.appendingPathComponent("exit-observed.json").path)
                && object(idleRoot.appendingPathComponent("eof-observed.json"))["pid"] as? Int == idlePID.map(Int.init),
                "ACP runtime standalone: fixture did not preserve owned EOF-live barrier")
            try release(idleRoot.appendingPathComponent("release-exit.json"))
            guard await reached({ FileManager.default.fileExists(atPath: idleRoot.appendingPathComponent("exit-observed.json").path) }) else { throw FixtureError.timeout }
            var atExit = await idleSession.currentRuntimeObservation()
            if atExit != nil {
                let deadline = ContinuousClock.now.advanced(by: .seconds(3))
                while atExit?.isRunning != false && ContinuousClock.now < deadline {
                    await Task.yield()
                    atExit = await idleSession.currentRuntimeObservation()
                }
            }
            // S05
            check(atExit?.processID == idlePID && atExit?.isRunning == false && atExit?.transportClosed == true
                && atExit?.outputEOF == true && atExit?.pendingRequestCount == 0,
                "ACP runtime standalone: same owned Process exit was unavailable or inferred from EOF")
            await idleSession.close()
            let absent = await idleSession.currentRuntimeObservation()
            // S06
            check(absent == nil, "ACP runtime standalone: closed client returned current facts instead of unavailable")
            // S07
            check(object(idleRoot.appendingPathComponent("calls.json"))["methods"] as? [String] == ["initialize", "session/new"]
                && object(idleRoot.appendingPathComponent("launch.json"))["launchCount"] as? Int == 1
                && !FileManager.default.fileExists(atPath: idleRoot.appendingPathComponent("peer-error.json").path),
                "ACP runtime standalone: owned EOF/exit controls mutated protocol or relaunched")
            SelfTest.diagnostic("TASK_ACP_RUNTIME_STANDALONE_TRACE: open=\(idleOpen != nil) eofRunning=\(atEOF?.isRunning.description ?? "unknown") eofClosed=\(atEOF?.transportClosed.description ?? "unknown") exited=\(atExit?.isRunning == false) absent=\(absent == nil)")
        } catch {
            try? release(idleRoot.appendingPathComponent("release-eof.json"))
            try? release(idleRoot.appendingPathComponent("release-exit.json"))
            await idleSession.close()
            _ = await reached { FileManager.default.fileExists(atPath: idleRoot.appendingPathComponent("exit-observed.json").path) }
            throw error
        }
        // O01
        check(unexpectedTools == 0 && PermissionGate.shared.pending == nil
            && PermissionGate.shared.queuedCount == 0 && PermissionGrantStore.shared.grants == grantsBefore,
            "ACP runtime: fixture changed grants/Gate or executed backing")
    }

    private static let peer = #"""
        import json, os, pathlib, signal, sys, tempfile, time

        root = pathlib.Path(__file__).resolve().parent
        temporary = pathlib.Path(tempfile.gettempdir()).resolve()
        assert root != temporary and temporary in root.parents
        assert 'Application Support' not in root.parts
        config = json.loads((root / 'config.json').read_text())
        assert config['kind'] in ('worker', 'idle')
        session = 'fixture-acp-runtime-observation'
        methods = []

        def write(name, value):
            target = root / name
            tmp = root / (name + '.tmp')
            tmp.write_text(json.dumps(value, sort_keys=True))
            tmp.replace(target)

        def send(value):
            sys.stdout.write(json.dumps(value) + '\n')
            sys.stdout.flush()

        def wait(name):
            deadline = time.monotonic() + 12
            while not (root / name).exists():
                if time.monotonic() >= deadline:
                    raise TimeoutError('owned release barrier')
                time.sleep(0.005)
            assert json.loads((root / name).read_text()) == {'release': True}

        def main():
            assert not (root / 'launch.json').exists()
            write('launch.json', {'launchCount': 1, 'pid': os.getpid()})
            if config['kind'] == 'idle':
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
            for line in sys.stdin:
                message = json.loads(line)
                mid, method = message.get('id'), message.get('method')
                assert mid is not None and method is not None
                methods.append(method)
                write('calls.json', {'methods': methods})
                if method == 'initialize':
                    send({'jsonrpc': '2.0', 'id': mid, 'result': {'protocolVersion': 1, 'agentCapabilities': {}}})
                elif method == 'session/new':
                    send({'jsonrpc': '2.0', 'id': mid, 'result': {'sessionId': session}})
                    if config['kind'] == 'idle':
                        wait('release-eof.json')
                        os.close(1)
                        write('eof-observed.json', {'pid': os.getpid()})
                        # Product close's SIGTERM intentionally cannot substitute for observed exit.
                        # Owned release or bounded escape always exits this exact peer; no PID lookup/kill.
                        deadline = time.monotonic() + 8
                        while not (root / 'release-exit.json').exists() and time.monotonic() < deadline:
                            time.sleep(0.005)
                        if (root / 'release-exit.json').exists():
                            assert json.loads((root / 'release-exit.json').read_text()) == {'release': True}
                        write('exit-observed.json', {'pid': os.getpid()})
                        os._exit(0)
                elif method == 'session/prompt':
                    assert config['kind'] == 'worker' and methods == ['initialize', 'session/new', 'session/prompt']
                    assert message['params']['sessionId'] == session
                    assert message['params']['prompt'][0]['text'] == config['objective']
                    write('prompt-observed.json', {'taskID': config['taskID'], 'sessionID': session,
                        'objective': config['objective'], 'promptCount': 1})
                    wait('release-result.json')
                    send({'jsonrpc': '2.0', 'method': 'session/update', 'params': {'sessionId': session,
                        'update': {'sessionUpdate': 'agent_message_chunk', 'content': {'type': 'text', 'text': config['marker']}}}})
                    send({'jsonrpc': '2.0', 'id': mid, 'result': {'stopReason': 'end_turn'}})
                elif method == 'session/cancel':
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

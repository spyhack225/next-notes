import Foundation

/// Actual silent owned ACP -> existing scheduler tick -> conditioned heartbeat-only transaction.
/// No progress, stale/health/effect/retry verdict or additional scheduler is authorized.
@MainActor
enum TaskACPPeriodicHeartbeatSelfTest {
    private enum InputError: Error { case unsafe, busy, timeout, invalid }
    private static func reached(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while ContinuousClock.now < deadline {
            if condition() { return true }; await Task.yield()
        }
        return condition()
    }
    private static func finish(_ directory: URL) throws {
        try Data(#"{"release":true}"#.utf8).write(to: directory.appendingPathComponent("release-result.json"), options: .atomic)
    }
    static func originalCases(root: URL, check checkOut: (Bool, String) -> Void) async throws {
        var cases = 0
        func check(_ value: Bool, _ label: String) { cases += 1; checkOut(value, label) }
        let safe = root.standardizedFileURL.resolvingSymlinksInPath()
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard SelfTest.isRunning, safe.path.hasPrefix(temporary.path + "/"),
              !safe.pathComponents.contains("Application Support") else { throw InputError.unsafe }
        let gate = PermissionGate.shared
        guard gate.pending == nil, gate.queuedCount == 0 else { throw InputError.busy }
        let oldFake = AgentToolExecutor.fakeForTesting
        let oldFire = AgentToolExecutor.fireOverrideForTesting
        let grants = PermissionGrantStore.shared.grants
        defer { AgentToolExecutor.fakeForTesting = oldFake; AgentToolExecutor.fireOverrideForTesting = oldFire }
        AgentToolExecutor.fakeForTesting = nil
        var unexpectedTools = 0
        AgentToolExecutor.fireOverrideForTesting = { _, _ in unexpectedTools += 1; throw InputError.invalid }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let owner = String(ProcessInfo.processInfo.processIdentifier)
        for mode in ["candidate", "recent", "person-wait", "fresh-held", "changed-receipt", "future-clock", "released", "rejected-save", "cloud-class"] {
            let directory = safe.appendingPathComponent("acp-periodic-" + mode, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let sql = TaskStore(root: directory)
            defer { sql.close() }
            let export = directory.appendingPathComponent("agent-tasks.json")
            let receiptsURL = directory.appendingPathComponent("action-receipts.json")
            let store = AgentTaskStore(fileURL: export, mirror: sql)
            let receipts = ActionReceiptStore(fileURL: receiptsURL)
            guard store.allowsHarnessPersistence else { throw InputError.unsafe }
            let manager = AgentTaskManager(store: store, receiptStore: receipts)
            var entered = 0; var ended = 0
            var context: TaskJournalContext?
            var records: [(TaskWorkerHeartbeatObservation, String)] = []
            var periodic: [(TaskWorkerBinding, Bool?)] = []
            var heldSQL: TaskStore?
            var heldManager: AgentTaskManager?
            defer { heldSQL?.close() }
            manager.progressDateForTesting = { start }
            manager.backendEntryForTesting = {
                entered += 1
                guard let current = TaskEventJournal.current else { throw InputError.invalid }
                context = current
                try JSONSerialization.data(withJSONObject: ["objective": "OWNED_MONITOR_OBJECTIVE_DO_NOT_LOG",
                    "marker": "Owned monitor reply.", "taskID": current.taskID, "taskAttempt": current.attempt,
                    "taskLeaseOwner": owner, "phases": 0, "burstCount": 0, "permissionWait": mode == "person-wait"], options: .sortedKeys)
                    .write(to: directory.appendingPathComponent("config.json"), options: .atomic)
            }
            manager.backendExitForTesting = { ended += 1 }
            manager.heartbeatMonitorForTesting = { records.append(($0, $1)) }
            manager.periodicHeartbeatForTesting = { periodic.append(($0, $1)) }
            let script = directory.appendingPathComponent("owned-monitor-peer.py")
            try peer.write(to: script, atomically: true, encoding: .utf8)
            let task = manager.submit(objective: "OWNED_MONITOR_OBJECTIVE_DO_NOT_LOG", arguments: ["acpFixture": script.path, "acpFixtureAskPermission": mode == "person-wait" ? "true" : "false"],
                backend: .acp, source: "selftest")
            let system = SystemRecorder(); let delivery = DeliveryRecorder()
            let scheduler = AgentScheduler(store: ScheduleStore(directory: directory.appendingPathComponent("schedules")),
                system: system, deliverer: delivery, environment: Environment(),
                settings: { ScheduleSettingsSnapshot(enabled: false, quietStart: nil, quietEnd: nil, speech: .never) },
                events: AgentTriggerEvents(), heartbeatTaskManager: manager)
            do {
                guard await reached({ FileManager.default.fileExists(atPath: directory.appendingPathComponent("prompt-observed.json").path) }),
                      let binding = manager.workerBinding(taskID: task.id), let context,
                      let fired = receipts.receipts.first else { throw InputError.timeout }
                check(entered == 1 && ended == 0 && binding.attempt == 1 && binding.leaseOwner == owner
                    && fired.taskID == task.id && fired.taskAttempt == 1 && fired.taskLeaseOwner == owner
                    && fired.status == .fired && context.taskID == task.id && context.isStillValid?() == true,
                    "ACP periodic C01 actual owned live startup missing (\(mode))")
                if mode == "person-wait" {
                    guard await reached({ gate.hasWaitingRequest(taskID: task.id) && gate.pending?.taskID == task.id }) else { throw InputError.timeout }
                }
                check(mode != "person-wait" || gate.pending?.taskID == task.id,
                    "ACP periodic C02 actual task-bound person wait missing (\(mode))")
                if mode == "fresh-held" {
                    let fresh = TaskStore(root: directory); heldSQL = fresh
                    heldManager = AgentTaskManager(store: AgentTaskStore(fileURL: export, mirror: fresh), receiptStore: receipts)
                    check(heldManager?.task(id: task.id)?.status == .recovering && manager.workerBinding(taskID: task.id) == binding
                        && context.isStillValid?() == false && ended == 0,
                        "ACP periodic C03 fresh hold replaced genuine live owner")
                }
                if mode == "changed-receipt" {
                    try Data("{OWNED_CHANGED_RECEIPT_SOURCE".utf8).write(to: receiptsURL, options: .atomic)
                }
                if mode == "released" {
                    try finish(directory)
                    guard await reached({ ended == 1 }) else { throw InputError.timeout }
                    check(manager.workerBinding(taskID: task.id) == nil && manager.task(id: task.id)?.status == .completed,
                        "ACP periodic C04 actual terminal owner not released")
                }
                if mode == "cloud-class" {
                    var rows = try sql.load()
                    guard rows.count == 1 else { throw InputError.invalid }
                    rows[0].durability?.runtimeClass = .cloudModel
                    guard store.save(rows).primaryCommitted else { throw InputError.invalid }
                }
                if mode == "rejected-save" {
                    try sql.withConnection { try TaskStore.exec($0,
                        "CREATE TRIGGER reject_periodic BEFORE INSERT ON task_event WHEN NEW.kind='heartbeat' BEGIN SELECT RAISE(ABORT,'owned periodic fixture'); END") }
                }
                let tasksBefore = manager.tasks
                let sqlBefore = try sql.load()
                let journalBefore = try sql.journal(taskID: task.id)
                let exportBefore = try Data(contentsOf: export)
                let receiptBefore = try Data(contentsOf: receiptsURL)
                let now = mode == "person-wait" ? start.addingTimeInterval(40 * 86_400)
                    : mode == "recent" ? start.addingTimeInterval(224)
                    : mode == "future-clock" ? start.addingTimeInterval(-1) : start.addingTimeInterval(225)
                // Actual existing scheduler iteration, not a direct private-helper invocation.
                await scheduler.runTick(now: now)
                guard await reached({ scheduler.lastPassAt == now }) else { throw InputError.timeout }
                check(scheduler.lastPassAt == now && system.calls == 0 && delivery.calls == 0,
                    "ACP periodic C05 disabled reminder pass unchanged (\(mode))")
                let live = mode != "released"
                let observation = records.first?.0
                check(records.count == (live ? 1 : 0) && (!live ||
                    (observation?.binding == binding && observation?.runtime?.isRunning == true
                     && observation?.runtime?.transportClosed == false && observation?.runtime?.outputEOF == false
                     && (observation?.runtime?.pendingRequestCount ?? 0) > 0)),
                    "ACP periodic C06 actual silent current owned prompt qualification missing (\(mode))")
                let expectedAdmission = ["candidate", "changed-receipt"].contains(mode)
                let attempted = expectedAdmission || mode == "rejected-save"
                let reported = periodic.first?.1
                check(periodic.count == (live ? 1 : 0) &&
                    (attempted ? reported == expectedAdmission : reported == nil)
                    && (mode != "rejected-save" || manager.lastPersistenceResult == .sqlFailed),
                    "ACP periodic F01 actual due/refused heartbeat admission missing (\(mode))")
                let sqlAfter = try sql.load()
                let journalAfter = try sql.journal(taskID: task.id)
                let exportAfter = try Data(contentsOf: export)
                let receiptAfter = try Data(contentsOf: receiptsURL)
                check(sqlAfter.first?.durability?.heartbeatAt == (expectedAdmission ? now : sqlBefore.first?.durability?.heartbeatAt)
                    && sqlAfter.first?.durability?.lastProgressAt == sqlBefore.first?.durability?.lastProgressAt,
                    "ACP periodic F02 actual saved beat missing or progress invented (\(mode))")
                var expectedMemory = tasksBefore
                if expectedAdmission { expectedMemory[0].durability?.heartbeatAt = now }
                check(manager.tasks == expectedMemory,
                    "ACP periodic F03 exact Manager beat missing or unrelated state changed (\(mode))")
                let added = Array(journalAfter.dropFirst(journalBefore.count))
                check(journalAfter.prefix(journalBefore.count).elementsEqual(journalBefore)
                    && added.count == (expectedAdmission ? 1 : 0)
                    && (!expectedAdmission || (added.first?.draft.kind == .heartbeat
                        && added.first?.draft.detail == "acp.periodic" && added.first?.draft.at == now
                        && added.first?.draft.taskID == task.id && added.first?.draft.attempt == 1)),
                    "ACP periodic F04 exact conditioned periodic event missing (\(mode))")
                var normalized = sqlAfter
                if normalized.count == sqlBefore.count { normalized[0].durability?.heartbeatAt = sqlBefore[0].durability?.heartbeatAt }
                check(normalized == sqlBefore && (mode != "rejected-save" || (exportAfter == exportBefore
                        && journalAfter == journalBefore && manager.tasks == tasksBefore)),
                    "ACP periodic C07 retained state/progress/identity or native rollback changed (\(mode))")
                let reader = AgentTaskStore(fileURL: export, mirror: sql)
                let freshRows = try reader.load()
                check(freshRows == sqlAfter && receiptAfter == receiptBefore,
                    "ACP periodic C08 fresh primary or exact receipt bytes lost (\(mode))")
                let memoryAfter = manager.tasks
                await scheduler.runTick(now: now)
                let repeatedRows = try sql.load(); let repeatedEvents = try sql.journal(taskID: task.id)
                let repeatedExport = try Data(contentsOf: export)
                let repeatedReceipts = try Data(contentsOf: receiptsURL)
                check(manager.tasks == memoryAfter && repeatedRows == sqlAfter && repeatedEvents == journalAfter
                    && repeatedExport == exportAfter && repeatedReceipts == receiptAfter,
                    "ACP periodic C09 same tick duplicated beat or changed retained evidence (\(mode))")
                let label = records.first?.1 ?? ""
                check(!live || (label.contains("session=unknown tool=unknown")
                    && !label.contains(task.id) && !label.contains("OWNED_MONITOR_OBJECTIVE")),
                    "ACP periodic C10 current log invented health or leaked payload (\(mode))")
                if mode == "rejected-save" {
                    try sql.withConnection { try TaskStore.exec($0, "DROP TRIGGER reject_periodic") }
                }
                if mode == "person-wait" { manager.cancel(task.id) }
                try finish(directory)
                guard await reached({ ended == 1 }) else { throw InputError.timeout }
                check(entered == 1 && ended == 1 && manager.workerBinding(taskID: task.id) == nil
                    && !gate.hasWaitingRequest(taskID: task.id),
                    "ACP periodic C08 actual original owner/Gate cleanup failed (\(mode))")
                SelfTest.diagnostic("ACP_PERIODIC_TRACE: mode=\(mode) observations=\(records.count) callbacks=\(periodic.count) started=\(entered) ended=\(ended) reminderCalls=\(system.calls + delivery.calls)")
            } catch {
                SelfTest.diagnostic("ACP_PERIODIC_INVALID: mode=\(mode) started=\(entered) ended=\(ended) observations=\(records.count)")
                try? finish(directory); manager.cancel(task.id)
                guard await reached({ ended == 1 }) else { throw InputError.timeout }; throw error
            }
        }
        check(unexpectedTools == 0 && gate.pending == nil && gate.queuedCount == 0
            && PermissionGrantStore.shared.grants == grants, "ACP periodic E01 left tools/Gate/standing choices")
        SelfTest.diagnostic("ACP_PERIODIC_RESULT: checks=\(cases)")
    }
    private final class Environment: ScheduleEnvironment {
        let isUserPresent = true; let isRecording = false; let isDictating = false
        let isCallActive = false; let isAgentBusy = false
    }
    private final class SystemRecorder: ReminderSystemRegistering {
        var calls = 0
        func register(_ schedule: AgentSchedule, slot: Date) async -> Bool { calls += 1; return false }
        func withdraw(scheduleID: UUID) { calls += 1 }
        func pendingScheduleIDs() async -> Set<UUID> { calls += 1; return [] }
        func isAuthorized() async -> Bool { calls += 1; return false }
    }
    private final class DeliveryRecorder: ScheduleDelivering {
        var calls = 0
        func deliver(_ delivery: ScheduleDelivery) async throws { calls += 1 }
        func notifyProblem(scheduleID: UUID, title: String, body: String) { calls += 1 }
        func notifyDrafts(_ drafts: [RoutineDraft], scheduleTitle: String) { calls += 1 }
        func openSchedules() { calls += 1 }
        func speak(_ text: String) { calls += 1 }
    }
    private static let peer = #"""
    import json, os, pathlib, sys, tempfile, time, uuid
    root = pathlib.Path(__file__).resolve().parent
    tmp = pathlib.Path(tempfile.gettempdir()).resolve()
    assert root != tmp and tmp in root.parents and 'Application Support' not in root.parts
    config = json.loads((root / 'config.json').read_text())
    assert isinstance(config['taskID'], str) and str(uuid.UUID(config['taskID'])).lower() == config['taskID'].lower()
    assert config['taskAttempt'] == 1 and config['taskLeaseOwner'] == str(os.getppid())
    session = 'fixture-acp-activity-heartbeat'
    methods = []
    def write(name, value):
        target = root / name
        temporary = root / (name + '.tmp')
        temporary.write_text(json.dumps(value, sort_keys=True))
        temporary.replace(target)
    def send(value):
        sys.stdout.write(json.dumps(value) + '\n')
        sys.stdout.flush()
    def wait(name):
        deadline = time.monotonic() + 12
        while not (root / name).exists():
            if time.monotonic() >= deadline:
                raise TimeoutError('owned phase release')
            time.sleep(0.005)
        assert json.loads((root / name).read_text()) == {'release': True}
    def activity(sid, title):
        send({'jsonrpc':'2.0','method':'session/update','params':{'sessionId':sid,
            'update':{'sessionUpdate':'tool_call_update','title':title}}})
    try:
        assert not (root / 'launch.json').exists()
        write('launch.json', {'launchCount':1, 'pid':os.getpid(), 'parentPID':os.getppid()})
        for line in sys.stdin:
            request = json.loads(line)
            mid, method = request.get('id'), request.get('method')
            if mid == 900 and method is None and config['permissionWait']:
                outcome = request.get('result', {}).get('outcome', {})
                assert outcome == {'outcome':'cancelled'} or outcome == {'outcome':'selected', 'optionId':'fixture-reject-once'}
                write('permission-response.json', {'cancelledOrRejected':True})
                continue
            assert mid is not None and method is not None
            methods.append(method)
            write('calls.json', {'methods':methods})
            if method == 'initialize':
                send({'jsonrpc':'2.0','id':mid,'result':{'protocolVersion':1,'agentCapabilities':{}}})
            elif method == 'session/new':
                send({'jsonrpc':'2.0','id':mid,'result':{'sessionId':session}})
            elif method == 'session/prompt':
                assert methods == ['initialize','session/new','session/prompt']
                assert request['params']['sessionId'] == session
                assert request['params']['prompt'][0]['text'] == config['objective']
                write('prompt-observed.json', {'taskID':config['taskID'],'promptCount':1})
                if config['permissionWait']:
                    write('permission-request.json', {'taskID': config['taskID']})
                    send({'jsonrpc':'2.0','id':900,'method':'session/request_permission','params':{
                        'sessionId':session, 'toolCall':{'toolCallId':'owned-monitor-wait',
                        'title':'Owned monitor review only','kind':'other','status':'pending'},
                        'options':[{'optionId':'fixture-reject-once','name':'No','kind':'reject_once'},
                                   {'optionId':'fixture-allow-once','name':'Yes','kind':'allow_once'}]}})
                if config['phases']:
                    wait('release-phase1.json')
                    activity('wrong-session', 'Do not attribute this status')
                    # Actual non-message progress is unbounded in the producer. Bound this workload only.
                    for index in range(config['burstCount']):
                        activity(session, 'Owned fixture phase one ' + str(index))
                    # These native message/thought updates must not become durable progress events.
                    send({'jsonrpc':'2.0','method':'session/update','params':{'sessionId':session,
                        'update':{'sessionUpdate':'agent_thought_chunk','content':{'type':'text','text':'owned thought'}}}})
                    send({'jsonrpc':'2.0','method':'session/update','params':{'sessionId':session,
                        'update':{'sessionUpdate':'agent_message_chunk','content':{'type':'text','text':''}}}})
                if config['phases'] == 2:
                    wait('release-phase2.json')
                    activity(session, 'Owned fixture phase two')
                wait('release-result.json')
                send({'jsonrpc':'2.0','method':'session/update','params':{'sessionId':session,
                    'update':{'sessionUpdate':'agent_message_chunk','content':{'type':'text','text':config['marker']}}}})
                send({'jsonrpc':'2.0','id':mid,'result':{'stopReason':'end_turn'}})
            elif method == 'session/cancel':
                send({'jsonrpc':'2.0','id':mid,'result':{}})
            else:
                raise ValueError('unexpected owned protocol method')
    except Exception as error:
        write('peer-error.json', {'errorClass':type(error).__name__})
        raise
    """#
}

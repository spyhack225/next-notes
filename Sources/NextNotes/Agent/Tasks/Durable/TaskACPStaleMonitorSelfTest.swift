import Foundation

/// Actual existing scheduler iteration -> current owned worker observations -> log operand.
/// No stale/retry/effect verdict or state/heartbeat write is authorized by this consumer.
@MainActor
enum TaskACPStaleMonitorSelfTest {
    private enum InputError: Error { case unsafe, busy, timeout, invalid }
    private struct SavedRows: Decodable { let tasks: [AgentTask] }
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
    static func originalCases(root: URL, check: (Bool, String) -> Void) async throws {
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
        for mode in ["candidate", "recent", "person-wait", "fresh-held", "changed-receipt", "future-clock", "released"] {
            let directory = safe.appendingPathComponent("acp-monitor-" + mode, isDirectory: true)
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
            let script = directory.appendingPathComponent("owned-monitor-peer.py")
            try peer.write(to: script, atomically: true, encoding: .utf8)
            let task = manager.submit(objective: "OWNED_MONITOR_OBJECTIVE_DO_NOT_LOG", arguments: ["acpFixture": script.path,
                    "acpFixtureAskPermission": mode == "person-wait" ? "true" : "false"],
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
                    "ACP monitor C01 actual owned live startup missing (\(mode))")
                if mode == "person-wait" {
                    guard await reached({ gate.hasWaitingRequest(taskID: task.id) && gate.pending?.taskID == task.id }) else { throw InputError.timeout }
                }
                check(mode != "person-wait" || gate.pending?.taskID == task.id,
                    "ACP monitor C02 actual task-bound person wait missing (\(mode))")
                if mode == "fresh-held" {
                    let fresh = TaskStore(root: directory); heldSQL = fresh
                    heldManager = AgentTaskManager(store: AgentTaskStore(fileURL: export, mirror: fresh), receiptStore: receipts)
                    check(heldManager?.task(id: task.id)?.status == .recovering && manager.workerBinding(taskID: task.id) == binding
                        && context.isStillValid?() == false && ended == 0,
                        "ACP monitor C03 fresh hold replaced genuine live owner")
                }
                if mode == "changed-receipt" {
                    try Data("{OWNED_CHANGED_RECEIPT_SOURCE".utf8).write(to: receiptsURL, options: .atomic)
                }
                if mode == "released" {
                    try finish(directory)
                    guard await reached({ ended == 1 }) else { throw InputError.timeout }
                    check(manager.workerBinding(taskID: task.id) == nil && manager.task(id: task.id)?.status == .completed,
                        "ACP monitor C04 actual terminal owner not released")
                }
                let tasksBefore = manager.tasks
                let sqlBefore = try sql.load()
                let journalBefore = try sql.journal(taskID: task.id)
                let exportBefore = try Data(contentsOf: export)
                let receiptBefore = try Data(contentsOf: receiptsURL)
                let now = mode == "person-wait" ? start.addingTimeInterval(40 * 86_400)
                    : mode == "recent" ? start.addingTimeInterval(1)
                    : mode == "future-clock" ? start.addingTimeInterval(-1) : start.addingTimeInterval(1801)
                // SAME method invoked by the existing normal scheduler loop. No start()
                // or notification center / wake observer / extra timer is constructed.
                await scheduler.runTick(now: now)
                guard await reached({ scheduler.lastPassAt == now }) else { throw InputError.timeout }
                check(scheduler.lastPassAt == now && !scheduler.store.schedules.contains { $0.enabled }
                    && system.calls == 0 && delivery.calls == 0,
                    "ACP monitor C05 disabled existing scheduler pass changed behavior (\(mode))")
                if mode == "released" {
                    check(records.isEmpty, "ACP monitor C06 released task gained observations")
                } else {
                    check(records.count == 1, "ACP monitor F01 actual scheduler consumer missed current observation (\(mode))")
                    let observed = records.first?.0
                    let age = mode == "person-wait" ? "waitingOnPerson"
                        : mode == "recent" ? "withinWindow"
                        : ["fresh-held", "future-clock"].contains(mode) ? "unknown" : "ageCandidate"
                    check(observed?.binding == binding && (observed?.age?.diagnosticName ?? "unknown") == age
                        && observed?.permissionWait == (mode == "person-wait")
                        && (mode != "fresh-held" || observed?.primary.outcome == .unavailable),
                        "ACP monitor F02 current age/wait/held authority not consumed (\(mode))")
                    let receipt: TaskHeartbeatFact = ["fresh-held", "changed-receipt"].contains(mode) ? .unknown : .yes
                    check(observed?.evidence.processAlive == .yes && observed?.evidence.backendSessionAlive == .unknown
                        && observed?.evidence.toolInFlight == .unknown && observed?.evidence.receiptCreated == receipt,
                        "ACP monitor F03 four independent current questions lost unknowns (\(mode))")
                    let label = records.first?.1 ?? ""
                    let primary = mode == "fresh-held" ? "unavailable" : "accepted"
                    check(label == "primary=\(primary) age=\(age) process=yes session=unknown tool=unknown receipt=\(receipt.rawValue)"
                        && !label.contains(task.id) && !label.contains("OWNED_MONITOR_OBJECTIVE"),
                        "ACP monitor F04 exact production log operand leaked or claimed health (\(mode))")
                }
                let sqlAfter = try sql.load()
                let journalAfter = try sql.journal(taskID: task.id)
                let exportAfter = try Data(contentsOf: export)
                let receiptAfter = try Data(contentsOf: receiptsURL)
                // COMMON expectation-only upgrade: monitor remains observation-only,
                // while its SAME existing pass may now admit one separately prescribed
                // due ACP owner beat. No other row/progress/receipt change is accepted.
                let added = Array(journalAfter.dropFirst(journalBefore.count))
                let beat = added.count == 1 && added.first?.draft.kind == .heartbeat
                    && added.first?.draft.detail == "acp.periodic"
                    && added.first?.draft.taskID == task.id && added.first?.draft.attempt == 1
                    && added.first?.draft.at == now
                var expectedMemory = tasksBefore; var expectedSQL = sqlBefore
                if beat {
                    expectedMemory[0].durability?.heartbeatAt = now
                    expectedSQL[0].durability?.heartbeatAt = now
                }
                let witnessDecoder = JSONDecoder(); witnessDecoder.dateDecodingStrategy = .iso8601
                let compatible = beat ? (["candidate", "changed-receipt"].contains(mode)
                    && journalAfter.prefix(journalBefore.count).elementsEqual(journalBefore)
                    && (try? witnessDecoder.decode(SavedRows.self, from: exportAfter).tasks) == expectedSQL)
                    : journalAfter == journalBefore && exportAfter == exportBefore
                check(manager.tasks == expectedMemory && sqlAfter == expectedSQL
                    && compatible && receiptAfter == receiptBefore,
                    "ACP monitor C07 observation/declared heartbeat changed unrelated state/progress/journal/receipt (\(mode))")
                if mode == "person-wait" { manager.cancel(task.id) }
                try finish(directory)
                guard await reached({ ended == 1 }) else { throw InputError.timeout }
                check(entered == 1 && ended == 1 && manager.workerBinding(taskID: task.id) == nil
                    && !gate.hasWaitingRequest(taskID: task.id),
                    "ACP monitor C08 actual original owner/Gate cleanup failed (\(mode))")
                SelfTest.diagnostic("ACP_MONITOR_TRACE: mode=\(mode) observations=\(records.count) started=\(entered) ended=\(ended) reminderCalls=\(system.calls + delivery.calls)")
            } catch {
                SelfTest.diagnostic("ACP_MONITOR_INVALID: mode=\(mode) started=\(entered) ended=\(ended) observations=\(records.count)")
                try? finish(directory); manager.cancel(task.id)
                guard await reached({ ended == 1 }) else { throw InputError.timeout }; throw error
            }
        }
        check(unexpectedTools == 0 && gate.pending == nil && gate.queuedCount == 0
            && PermissionGrantStore.shared.grants == grants, "ACP monitor E01 left tools/Gate/standing choices")
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

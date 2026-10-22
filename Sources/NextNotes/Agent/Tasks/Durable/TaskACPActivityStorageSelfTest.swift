import Foundation
import SQLite3

/// Supplemental actual live Manager/ACP context storage boundaries. The unchanged
/// real notification/burst86 remains the production consumer and latency proof.
@MainActor
enum TaskACPActivityStorageSelfTest {
    private enum InputError: Error { case unsafe, timeout, owner, injected }
    private struct Witness: Decodable { let tasks: [AgentTask] }
    private static func canonical(_ tasks: [AgentTask]) throws -> [AgentTask] {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([AgentTask].self, from: encoder.encode(tasks))
    }
    private static func reached(_ predicate: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while ContinuousClock.now < deadline {
            if predicate() { return true }; await Task.yield()
        }
        return predicate()
    }
    static func originalCases(root: URL, check checkOut: (Bool, String) -> Void) async throws {
        var cases = 0
        func check(_ value: Bool, _ label: String) { cases += 1; checkOut(value, label) }
        let safe = root.standardizedFileURL.resolvingSymlinksInPath()
        let temp = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard SelfTest.isRunning, safe.path.hasPrefix(temp.path + "/"),
              !safe.pathComponents.contains("Application Support"), PermissionGate.shared.pending == nil,
              PermissionGate.shared.queuedCount == 0 else { throw InputError.unsafe }
        let grants = PermissionGrantStore.shared.grants
        let oldFake = AgentToolExecutor.fakeForTesting; let oldFire = AgentToolExecutor.fireOverrideForTesting
        defer { AgentToolExecutor.fakeForTesting = oldFake; AgentToolExecutor.fireOverrideForTesting = oldFire }
        AgentToolExecutor.fakeForTesting = nil
        var unexpected = 0
        AgentToolExecutor.fireOverrideForTesting = { _, _ in unexpected += 1; throw InputError.owner }
        let owner = String(ProcessInfo.processInfo.processIdentifier)
        let modes = ["own-cache", "corrupt-witness", "deleted-witness", "changed-valid-witness", "higher-witness-generation",
                     "generation-mismatch", "row-mismatch", "event-rejected", "export-failure", "load-invalidation", "fractional"]
        for mode in modes {
            let modeCases = cases
            let directory = safe.appendingPathComponent("acp-storage-" + mode, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let sql = TaskStore(root: directory)
            defer { sql.authorityBoundaryForTesting = nil; sql.close() }
            let export = directory.appendingPathComponent("agent-tasks.json")
            let store = AgentTaskStore(fileURL: export, mirror: sql)
            let receiptURL = directory.appendingPathComponent("action-receipts.json")
            let receipts = ActionReceiptStore(fileURL: receiptURL)
            guard store.allowsHarnessPersistence else { throw InputError.unsafe }
            let start = Date(timeIntervalSince1970: 1_700_000_000 + (mode == "fractional" ? 0.375 : 0))
            let archived = (0..<3).map { n in AgentTask(objective: "Owned \"tasks\" : [ { } ] \\ \n unicode é \(n)",
                source: "selftest", createdAt: start, status: .completed, progress: "Finished",
                result: "Owned braces {\"tasks\":[\"quoted\"]} \\ \n",
                artifacts: [directory.appendingPathComponent("owned-archived-\(n).txt").path]) }
            let canonicalArchived = try canonical(archived)
            guard store.save(archived).primaryCommitted else { throw InputError.owner }
            let manager = AgentTaskManager(store: store, receiptStore: receipts)
            var context: TaskJournalContext?; var entered = 0; var ended = 0
            var clock = start
            manager.progressDateForTesting = { clock }
            manager.backendEntryForTesting = {
                entered += 1
                guard let current = TaskEventJournal.current else { throw InputError.owner }
                context = current
                try JSONSerialization.data(withJSONObject: ["objective":"Owned storage fixture", "marker":"Owned storage reply.",
                    "taskID":current.taskID, "taskAttempt":current.attempt, "taskLeaseOwner":owner,
                    "phases":0,"burstCount":0,"permissionWait":false], options: .sortedKeys)
                    .write(to: directory.appendingPathComponent("config.json"), options: .atomic)
            }
            manager.backendExitForTesting = { ended += 1 }
            let script = directory.appendingPathComponent("owned-storage-peer.py")
            try peer.write(to: script, atomically: true, encoding: .utf8)
            let task = manager.submit(objective: "Owned storage fixture", arguments: ["acpFixture":script.path], backend: .acp, source: "selftest")
            do {
                guard await reached({ FileManager.default.fileExists(atPath: directory.appendingPathComponent("prompt-observed.json").path) }),
                      let context, let binding = manager.workerBinding(taskID: task.id) else { throw InputError.timeout }
                check(entered == 1 && ended == 0 && binding.attempt == 1 && binding.leaseOwner == owner
                    && context.taskID == task.id && context.attempt == 1 && context.isStillValid?() == true,
                    "ACP storage C01 real live bound context missing (\(mode))")
                let beforeRows = try sql.load(); let beforeEvents = try sql.journal(taskID: task.id)
                let beforeMemory = manager.tasks; let beforeExport = try Data(contentsOf: export)
                let beforeReceipt = try Data(contentsOf: receiptURL)
                if mode == "corrupt-witness" { try Data("{owned corrupt export".utf8).write(to: export, options: .atomic) }
                if mode == "deleted-witness" { try FileManager.default.removeItem(at: export) }
                if ["changed-valid-witness", "higher-witness-generation"].contains(mode) {
                    guard var object = try JSONSerialization.jsonObject(with: beforeExport) as? [String: Any],
                          var authority = object["preparedAuthority"] as? [String: Any], let generation = authority["generation"] as? Int else { throw InputError.owner }
                    if mode == "higher-witness-generation" { authority["generation"] = generation + 1; object["preparedAuthority"] = authority }
                    else { object["tasks"] = ["owned ignored export payload"] }
                    try JSONSerialization.data(withJSONObject: object, options: .sortedKeys).write(to: export, options: .atomic)
                }
                if mode == "generation-mismatch" {
                    try sql.withConnection { try TaskStore.exec($0, "UPDATE task_authority SET generation=generation+1 WHERE singleton=1") }
                }
                if mode == "row-mismatch" {
                    try sql.withConnection { db in try TaskStore.run(db,
                        "UPDATE task SET durability=json_set(durability,'$.lastProgressAt',?) WHERE id=?",
                        [.real(start.addingTimeInterval(-10).timeIntervalSince1970), .text(task.id)]) }
                }
                if mode == "event-rejected" {
                    try sql.withConnection { try TaskStore.exec($0, "CREATE TRIGGER reject_storage_activity BEFORE INSERT ON task_event WHEN NEW.kind='heartbeat' BEGIN SELECT RAISE(ABORT,'owned activity rejection'); END") }
                }
                if mode == "export-failure" { store.migrationBoundaryForTesting = { if $0 == "primaryCommitted" { throw InputError.injected } } }
                if mode == "load-invalidation" { let loaded = try store.load(); guard loaded == beforeRows else { throw InputError.owner } }
                let atRows = try sql.load(); let atEvents = try sql.journal(taskID: task.id)
                let atExport = try? Data(contentsOf: export)
                var primaryChanges: [Int32] = []
                sql.authorityBoundaryForTesting = { stage, db in
                    if stage == "beforeAuthorityCommit", let db { primaryChanges.append(sqlite3_total_changes(db)) }
                }
                clock = start.addingTimeInterval(40)
                let admitted = context.record(TaskJournalEventDraft(taskID: task.id, kind: .heartbeat,
                    detail: "acp.activity", attempt: 1))
                sql.authorityBoundaryForTesting = nil
                let refused = ["higher-witness-generation", "generation-mismatch", "row-mismatch", "event-rejected"].contains(mode)
                check(admitted == !refused, "ACP storage F01 exact changed-source or row admission wrong (\(mode))")
                let afterRows = try sql.load(); let afterEvents = try sql.journal(taskID: task.id)
                let afterExport = try? Data(contentsOf: export)
                check(admitted || (afterRows == atRows && afterEvents == atEvents && afterExport == atExport
                    && manager.tasks == beforeMemory && primaryChanges.isEmpty),
                    "ACP storage C02 rejected activity changed retained primary/memory/export (\(mode))")
                let canonicalClock = try canonical([AgentTask(objective: "clock", source: "selftest", createdAt: clock)])[0].createdAt
                check(refused || (afterRows.first?.durability?.heartbeatAt == canonicalClock
                    && afterRows.first?.durability?.lastProgressAt == canonicalClock
                    && afterEvents.count == beforeEvents.count + 1 && afterEvents.last?.draft.kind == .heartbeat
                    && afterEvents.last?.draft.detail == "acp.activity" && afterEvents.last?.draft.attempt == 1),
                    "ACP storage C03 exact committed canonical timestamps/event lost (\(mode))")
                check(Array(afterRows.dropFirst()) == canonicalArchived && afterRows.map(\.id) == beforeRows.map(\.id)
                    && afterRows.first?.durability?.receiptIDs == beforeRows.first?.durability?.receiptIDs,
                    "ACP storage C04 unrelated escaped fields/order/children changed (\(mode))")
                check(mode != "own-cache" || primaryChanges == [3],
                    "ACP storage F02 admitted cached activity rewrote unrelated SQL rows")
                let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
                if !refused && mode != "export-failure" {
                    guard let bytes = afterExport else { throw InputError.owner }
                    let witness = try decoder.decode(Witness.self, from: bytes)
                    check(witness.tasks == afterRows && manager.lastPersistenceResult == .saved,
                        "ACP storage C05 actual JSON witness lost canonical fields/order (\(mode))")
                } else {
                    check(mode != "export-failure" || (afterExport == beforeExport && manager.lastPersistenceResult == .exportFailed),
                        "ACP storage C05 SQL-accepted export failure erased witness or admission")
                }
                check((try Data(contentsOf: receiptURL)) == beforeReceipt && manager.workerBinding(taskID: task.id) == binding,
                    "ACP storage C06 storage change altered receipt or live binding (\(mode))")
                if ["event-rejected", "export-failure"].contains(mode) {
                    store.migrationBoundaryForTesting = nil
                    if mode == "event-rejected" { try sql.withConnection { try TaskStore.exec($0, "DROP TRIGGER reject_storage_activity") } }
                    clock = clock.addingTimeInterval(1)
                    let retry = context.record(TaskJournalEventDraft(taskID: task.id, kind: .heartbeat, detail: "acp.activity", attempt: 1))
                    check(retry && manager.lastPersistenceResult == .saved,
                        "ACP storage C07 invalidated cache blocks later real independent activity (\(mode))")
                    let currentRows = try sql.load(); let bytes = try Data(contentsOf: export)
                    check(try decoder.decode(Witness.self, from: bytes).tasks == currentRows,
                        "ACP storage C08 fallback export disagrees with accepted SQL (\(mode))")
                }
                store.migrationBoundaryForTesting = nil
                try Data(#"{"release":true}"#.utf8).write(to: directory.appendingPathComponent("release-result.json"), options: .atomic)
                guard await reached({ ended == 1 }) else { throw InputError.timeout }
                check(entered == 1 && ended == 1 && manager.workerBinding(taskID: task.id) == nil,
                    "ACP storage C09 exact worker cleanup failed (\(mode))")
                SelfTest.diagnostic("ACP_STORAGE_TRACE: mode=\(mode) checks=\(cases - modeCases) admitted=\(admitted) commits=\(primaryChanges.count) changes=\(primaryChanges.first ?? 0) ended=\(ended)")
            } catch {
                store.migrationBoundaryForTesting = nil; sql.authorityBoundaryForTesting = nil
                try? Data(#"{"release":true}"#.utf8).write(to: directory.appendingPathComponent("release-result.json"), options: .atomic)
                manager.cancel(task.id)
                guard await reached({ ended == 1 }) else { throw InputError.timeout }
                SelfTest.diagnostic("ACP_STORAGE_INVALID: mode=\(mode) entered=\(entered) ended=\(ended)")
                throw error
            }
        }
        check(unexpected == 0 && PermissionGate.shared.pending == nil && PermissionGate.shared.queuedCount == 0
            && PermissionGrantStore.shared.grants == grants, "ACP storage E01 left tools/Gate/standing choices")
        SelfTest.diagnostic("ACP_STORAGE_RESULT: checks=\(cases)")
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

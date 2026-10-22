import Foundation

/// Real existing scheduler pass/runner ownership while an owned ACP prompt is pending.
/// Scripted ScheduledRunning models a long routine; this is no native/model health proof.
@MainActor
enum TaskACPSchedulerCadenceSelfTest {
    private enum InputError: Error { case unsafe, timeout, invalid }
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
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard SelfTest.isRunning, safe.path.hasPrefix(temporary.path + "/"),
              !safe.pathComponents.contains("Application Support"), PermissionGate.shared.pending == nil,
              PermissionGate.shared.queuedCount == 0 else { throw InputError.unsafe }
        let grants = PermissionGrantStore.shared.grants
        let oldFake = AgentToolExecutor.fakeForTesting; let oldFire = AgentToolExecutor.fireOverrideForTesting
        defer { AgentToolExecutor.fakeForTesting = oldFake; AgentToolExecutor.fireOverrideForTesting = oldFire }
        AgentToolExecutor.fakeForTesting = nil
        var tools = 0
        AgentToolExecutor.fireOverrideForTesting = { _, _ in tools += 1; throw InputError.invalid }
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let owner = String(ProcessInfo.processInfo.processIdentifier)
        for mode in ["held-release", "cancel-stop", "foreground-run-now"] {
            let directory = safe.appendingPathComponent("acp-cadence-" + mode, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let sql = TaskStore(root: directory); defer { sql.close() }
            let export = directory.appendingPathComponent("agent-tasks.json")
            let store = AgentTaskStore(fileURL: export, mirror: sql)
            let receiptURL = directory.appendingPathComponent("action-receipts.json")
            let receipts = ActionReceiptStore(fileURL: receiptURL)
            let manager = AgentTaskManager(store: store, receiptStore: receipts)
            var entered = 0; var ended = 0
            var observations: [TaskWorkerHeartbeatObservation] = []
            manager.progressDateForTesting = { start }
            manager.heartbeatMonitorForTesting = { observed, _ in observations.append(observed) }
            manager.backendEntryForTesting = {
                entered += 1
                guard let current = TaskEventJournal.current else { throw InputError.invalid }
                try JSONSerialization.data(withJSONObject: ["objective":"Owned scheduler cadence fixture",
                    "marker":"Owned cadence reply.","taskID":current.taskID,"taskAttempt":current.attempt,
                    "taskLeaseOwner":owner,"phases":0,"burstCount":0,"permissionWait":false], options: .sortedKeys)
                    .write(to: directory.appendingPathComponent("config.json"), options: .atomic)
            }
            manager.backendExitForTesting = { ended += 1 }
            let script = directory.appendingPathComponent("owned-cadence-peer.py")
            try peer.write(to: script, atomically: true, encoding: .utf8)
            let task = manager.submit(objective:"Owned scheduler cadence fixture", arguments:["acpFixture":script.path], backend:.acp, source:"selftest")
            let schedules = ScheduleStore(directory: directory.appendingPathComponent("schedules", isDirectory: true))
            let runner = HeldRunner(); let system = SystemRecorder(); let delivery = DeliveryRecorder()
            let now = start.addingTimeInterval(225)
            var schedule = AgentSchedule(kind:.routine, title:"Owned held routine", plainEnglish:"Run owned fixture once",
                prompt:"Owned scripted routine", when:ScheduleWhen(repeatRule:.once(now), time:ScheduleLocalTime(hour:0,minute:0), timeZone:"UTC"),
                delivery:.notify, createdAt:start)
            schedule.nextRunAt = now
            guard schedules.save(schedule) else { throw InputError.invalid }
            let scheduler = AgentScheduler(store:schedules, system:system, deliverer:delivery, environment:Environment(),
                settings:{ ScheduleSettingsSnapshot(enabled:true,quietStart:nil,quietEnd:nil,speech:.never) },
                runner:runner,events:AgentTriggerEvents(),heartbeatTaskManager:manager)
            defer { scheduler.stop() }
            var firstReturned = false; var secondReturned = false; var foregroundReturned = false
            var first: Task<Void,Never>?; var second: Task<Void,Never>?; var foreground: Task<Void,Never>?
            do {
                guard await reached({ FileManager.default.fileExists(atPath: directory.appendingPathComponent("prompt-observed.json").path) }),
                      let binding = manager.workerBinding(taskID:task.id),
                      let qualified = await manager.workerHeartbeatObservation(taskID:task.id,now:start),
                      qualified.primary.outcome == .accepted, qualified.runtime?.isRunning == true,
                      qualified.runtime?.transportClosed == false, qualified.runtime?.outputEOF == false,
                      (qualified.runtime?.pendingRequestCount ?? 0) > 0 else { throw InputError.timeout }
                check(entered == 1 && ended == 0 && binding.attempt == 1 && binding.leaseOwner == owner
                    && receipts.receipts.first?.status == .fired, "ACP cadence C01 actual pending owner missing (\(mode))")
                let before = try sql.load(); let beforeEvents = try sql.journal(taskID:task.id)
                let beforeReceipt = try Data(contentsOf:receiptURL)
                first = Task { @MainActor in await scheduler.runTick(now:now); firstReturned = true }
                guard await reached({ runner.started == 1 && scheduler.pendingPassesForTesting == 1 }) else { throw InputError.timeout }
                check(schedules.schedule(id:schedule.id)?.lastRun?.outcome == .started
                    && schedules.schedule(id:schedule.id)?.nextRunAt == nil && runner.ended == 0,
                    "ACP cadence C02 real routine claim/held owner missing (\(mode))")
                second = Task { @MainActor in await scheduler.runTick(now:now.addingTimeInterval(30)); secondReturned = true }
                // One unchanged bounded observation; original starvation is a feature RED,
                // not a reason to release the long runner before measuring it.
                _ = await reached({ firstReturned && secondReturned && observations.count == 2 })
                check(firstReturned && secondReturned && observations.count == 2,
                    "ACP cadence F01 shared tick waited for held routine before current observation (\(mode))")
                check(scheduler.pendingPassesForTesting == 1 && secondReturned,
                    "ACP cadence F02 shared tick queued another pass behind held owner (\(mode))")
                let during = try sql.load(); let events = try sql.journal(taskID:task.id)
                check(during.first?.durability?.heartbeatAt == now
                    && during.first?.durability?.lastProgressAt == before.first?.durability?.lastProgressAt
                    && events.count == beforeEvents.count + 1 && events.last?.draft.detail == "acp.periodic",
                    "ACP cadence F03 actual due owner beat starved or duplicated (\(mode))")
                check(runner.started == 1 && runner.ended == 0 && !runner.released,
                    "ACP cadence C03 model-return hold was not genuine (\(mode))")
                var normalized = during; normalized[0].durability?.heartbeatAt = before[0].durability?.heartbeatAt
                check(normalized == before && manager.workerBinding(taskID:task.id) == binding,
                    "ACP cadence C04 observation changed unrelated primary/binding (\(mode))")
                if mode == "foreground-run-now" {
                    foreground = Task { @MainActor in
                        _ = try? await scheduler.runNow(id:schedule.id,now:now.addingTimeInterval(60))
                        foregroundReturned = true
                    }
                    guard await reached({ (scheduler.pendingPassesForTesting ?? 0) >= 2 }) else { throw InputError.timeout }
                }
                check(mode != "foreground-run-now" || (!foregroundReturned && runner.started == 1),
                    "ACP cadence C05 foreground Run now bypassed existing claim order")
                if mode == "cancel-stop" {
                    scheduler.stop()
                    _ = await reached({ runner.cancelled == 1 && runner.ended == 1 })
                }
                check(mode != "cancel-stop" || (runner.cancelled == 1 && runner.ended == 1),
                    "ACP cadence F04 stop did not cancel same retained routine owner")
                // Always finish the actual existing operation before the self-test can exit.
                // This release follows the verdict and is shared by original/fixed.
                runner.released = true
                await first?.value; await second?.value; await foreground?.value
                guard await reached({ scheduler.pendingPassesForTesting == 0 }) else { throw InputError.timeout }
                check(runner.started == (mode == "foreground-run-now" ? 2 : 1)
                    && runner.ended == runner.started && firstReturned && secondReturned,
                    "ACP cadence C06 exact existing routine/tick/foreground joins incomplete (\(mode))")
                check(schedules.schedule(id:schedule.id)?.nextRunAt == nil
                    && schedules.schedule(id:schedule.id)?.prompt == schedule.prompt,
                    "ACP cadence C07 claim slot/payload changed or replay enabled (\(mode))")
                let history = schedules.runs(for:schedule.id,limit:10)
                let expectedRuns = runner.cancelled == 1 ? 0 : mode == "foreground-run-now" ? 2 : 1
                check(history.count == expectedRuns && delivery.calls == 0,
                    "ACP cadence C08 cancelled publication or extra result delivery (\(mode))")
                // Existing serialized remove joins the same retained owner; no test-only waiter.
                let retainedReceipt = try Data(contentsOf:receiptURL) == beforeReceipt
                try await scheduler.remove(id:schedule.id)
                try Data(#"{"release":true}"#.utf8).write(to: directory.appendingPathComponent("release-result.json"), options:.atomic)
                guard await reached({ ended == 1 && manager.workerBinding(taskID:task.id) == nil }) else { throw InputError.timeout }
                check(manager.workerBinding(taskID:task.id) == nil && entered == 1 && ended == 1
                    && scheduler.pendingPassesForTesting == 0 && schedules.schedules.isEmpty
                    && retainedReceipt,
                    "ACP cadence C09 exact temporary owners cleanup incomplete (\(mode))")
                SelfTest.diagnostic("ACP_CADENCE_TRACE: mode=\(mode) starts=\(runner.started) ends=\(runner.ended) cancelled=\(runner.cancelled) observations=\(observations.count) pending=\(scheduler.pendingPassesForTesting ?? -1)")
            } catch {
                scheduler.stop(); runner.released = true
                await first?.value; await second?.value; await foreground?.value
                try? Data(#"{"release":true}"#.utf8).write(to:directory.appendingPathComponent("release-result.json"),options:.atomic)
                manager.cancel(task.id)
                guard await reached({ ended == 1 && scheduler.pendingPassesForTesting == 0 }) else { throw InputError.timeout }
                SelfTest.diagnostic("ACP_CADENCE_INVALID: mode=\(mode) started=\(runner.started) ended=\(runner.ended)")
                throw error
            }
        }
        check(tools == 0 && PermissionGate.shared.pending == nil && PermissionGate.shared.queuedCount == 0
            && PermissionGrantStore.shared.grants == grants,"ACP cadence E01 left tools/Gate/standing choices")
        SelfTest.diagnostic("ACP_CADENCE_RESULT: checks=\(cases)")
    }
    private final class HeldRunner: ScheduledRunning {
        var started = 0; var ended = 0; var cancelled = 0; var released = false
        func run(_ schedule:AgentSchedule,now:Date) async -> ScheduledRunOutcome {
            started += 1
            if started == 1 {
                while !released && !Task.isCancelled { await Task.yield() }
            }
            if Task.isCancelled { cancelled += 1 }
            ended += 1
            return ScheduledRunOutcome(status:.nothingToReport,text:"")
        }
    }
    private final class Environment: ScheduleEnvironment {
        let isUserPresent = true; let isRecording = false; let isDictating = false
        let isCallActive = false; let isAgentBusy = false
    }
    private final class SystemRecorder: ReminderSystemRegistering {
        func register(_ schedule:AgentSchedule,slot:Date) async -> Bool { false }
        func withdraw(scheduleID:UUID) {}
        func pendingScheduleIDs() async -> Set<UUID> { [] }
        func isAuthorized() async -> Bool { false }
    }
    private final class DeliveryRecorder: ScheduleDelivering {
        var calls = 0
        func deliver(_ delivery:ScheduleDelivery) async throws { calls += 1 }
        func notifyProblem(scheduleID:UUID,title:String,body:String) { calls += 1 }
        func notifyDrafts(_ drafts:[RoutineDraft],scheduleTitle:String) { calls += 1 }
        func openSchedules() { calls += 1 }
        func speak(_ text:String) { calls += 1 }
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
        deadline = time.monotonic() + 60
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

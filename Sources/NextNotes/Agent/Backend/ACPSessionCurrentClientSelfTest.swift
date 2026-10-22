import Foundation

/// SAME actual Session -> Broker -> Gate -> originating wire on both producer versions.
/// Both owned peers only acknowledge protocol messages; neither executes a tool.
@MainActor
enum ACPSessionCurrentClientSelfTest {
    private enum FixtureError: Error { case unsafeRoot, busyGate, invalid(String) }
    private final class PromptResult {
        var finished = false
        var cleanupRequested = false
        var count = 0
        var reply = ""
        var failed = false
    }
    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [AgentBackendEvent] = []
        func append(_ event: AgentBackendEvent) { lock.withLock { values.append(event) } }
        func snapshot() -> [AgentBackendEvent] { lock.withLock { values } }
    }
    private static func reached(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
    }
    private static func outcome(_ file: URL) throws -> [String: String]? {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        return object?["outcome"] as? [String: String]
    }
    static func originalCases(root: URL, check: (Bool, String) -> Void) async throws {
        let safe = root.resolvingSymlinksInPath().standardizedFileURL
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard SelfTest.isRunning, safe.path.hasPrefix(temporary.path + "/"),
              !safe.pathComponents.contains("Application Support") else { throw FixtureError.unsafeRoot }
        guard PermissionGate.shared.pending == nil, PermissionGate.shared.queuedCount == 0 else {
            throw FixtureError.busyGate
        }
        let ownerBefore = SelfTestStoreGuard.take()
        let script = safe.appendingPathComponent("current-client-peer-" + UUID().uuidString + ".py")
        try peer.write(to: script, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: script) }
        for mode in ["current-allow", "current-decline", "replaced-task", "replaced-same-task"] {
            let replaced = mode.hasPrefix("replaced-")
            let approved = mode != "current-decline"
            let session = ACPSession()
            let oldTaskID = "selftest-acp-current-client-" + mode
            let newTaskID = mode == "replaced-same-task" ? oldTaskID : oldTaskID + "-successor"
            let scope = safe.appendingPathComponent("CurrentClient-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: false)
            let oldAck = scope.appendingPathComponent("old.json")
            let newAck = scope.appendingPathComponent("current.json")
            let events = Events()
            let subscription = await session.subscribe { event in events.append(event) }
            let old = PromptResult(), current = PromptResult()
            var oldPrompt: Task<Void, Never>?
            var currentPrompt: Task<Void, Never>?
            var caught: Error?
            let askBefore = PermissionGate.shared.askCount
            do {
                try await session.start(command: AgentStdioFixtures.python,
                    arguments: [script.path, "old", oldAck.path], directory: scope.path,
                    taskID: oldTaskID, approvePermissions: false)
                let initialID = await session.sessionID
                check(initialID == "fixture-reused-client-session", "C01 actual first handshake (\(mode))")
                // Retain the actual prompt Task before any held-entry qualification.
                // Its await retains the old real transport through client replacement.
                oldPrompt = Task { @MainActor in
                    guard !old.cleanupRequested else { old.count += 1; old.finished = true; return }
                    do { old.reply = try await session.prompt("First owned permission request") }
                    catch { old.failed = true }
                    old.count += 1; old.finished = true
                }
                guard await reached({ PermissionGate.shared.pending?.taskID == oldTaskID }),
                      let oldRequest = PermissionGate.shared.pending else {
                    throw FixtureError.invalid("old actual Gate entry missing")
                }
                check(PermissionGate.shared.askCount == askBefore + 1,
                    "C02 old request entered actual Gate once (\(mode))")
                if replaced {
                    try await session.start(command: AgentStdioFixtures.python,
                        arguments: [script.path, "current", newAck.path], directory: scope.path,
                        taskID: newTaskID, approvePermissions: false)
                    let replacementID = await session.sessionID
                    check(replacementID == initialID && PermissionGate.shared.pending?.id == oldRequest.id,
                        "C03 same-session-ID replacement retains exact old card (\(mode))")
                } else {
                    check(PermissionGate.shared.pending?.id == oldRequest.id,
                        "C03 exact current card retained (\(mode))")
                }
                check(PermissionGate.shared.respond(id: oldRequest.id, approved: approved, duration: .once),
                    "C04 actual old card decision accepted (\(mode))")
                guard await reached({ old.finished }) else {
                    throw FixtureError.invalid("old actual prompt did not return")
                }
                await oldPrompt?.value
                check(old.count == 1 && !old.failed,
                    "C05 originating prompt settled exactly once (\(mode))")
                let oldWire = try outcome(oldAck)
                let expectedOld = replaced ? ["outcome": "cancelled"] :
                    ["outcome": "selected", "optionId": approved ? "allow-once" : "reject-once"]
                check(oldWire == expectedOld,
                    "F01 exact originating wire refuses replaced client (\(mode))")
                // Old notifications precede its prompt response in the actual transport.
                // The existing response-drain join is the ordering barrier, not a sleep.
                let oldTitle = await session.lastPublicTitle
                let oldReply = await session.lastReply
                let observedOldActivity = events.snapshot().filter { $0.kind == "activity" && $0.title == "old-client-activity" }
                check(replaced ? oldTitle.isEmpty && oldReply.isEmpty && observedOldActivity.isEmpty :
                    oldTitle == "old-client-activity" && oldReply == "Old owned reply." &&
                        observedOldActivity.count == 1 && observedOldActivity.first?.taskID == oldTaskID,
                    "F02 old transport cannot publish into current owner (\(mode))")
                check(PermissionGate.shared.pending == nil && PermissionGate.shared.queuedCount == 0,
                    "C06 old waiter released without successor card (\(mode))")
                if replaced {
                    currentPrompt = Task { @MainActor in
                        guard !current.cleanupRequested else { current.count += 1; current.finished = true; return }
                        do { current.reply = try await session.prompt("Current owned permission request") }
                        catch { current.failed = true }
                        current.count += 1; current.finished = true
                    }
                    guard await reached({ PermissionGate.shared.pending?.taskID == newTaskID }),
                          let currentRequest = PermissionGate.shared.pending else {
                        throw FixtureError.invalid("current actual Gate entry missing")
                    }
                    check(currentRequest.id != oldRequest.id && PermissionGate.shared.askCount == askBefore + 2,
                        "C07 exact new client owns fresh current request (\(mode))")
                    check(PermissionGate.shared.respond(id: currentRequest.id, approved: true, duration: .once),
                        "C08 actual current card decision accepted (\(mode))")
                    guard await reached({ current.finished }) else {
                        throw FixtureError.invalid("current actual prompt did not return")
                    }
                    await currentPrompt?.value
                    check(try outcome(newAck) == ["outcome": "selected", "optionId": "allow-once"],
                        "C09 unchanged current offered authorization (\(mode))")
                    check(current.count == 1 && !current.failed && current.reply == "Current owned reply.",
                        "F03 actual current consumer receives only its own reply (\(mode))")
                    let currentActivity = events.snapshot().filter { $0.kind == "activity" && $0.title == "current-client-activity" }
                    check(currentActivity.count == 1 && currentActivity.first?.taskID == newTaskID,
                        "C10 unchanged current activity attribution (\(mode))")
                }
                SelfTest.diagnostic("ACP_CURRENT_CLIENT_TRACE: mode=\(mode) replaced=\(replaced) oldAllowed=\(oldWire?["optionId"] == "allow-once") oldCancelled=\(oldWire?["outcome"] == "cancelled") oldActivityCount=\(observedOldActivity.count) oldReplyEmpty=\(oldReply.isEmpty) oldReturns=\(old.count) currentReturns=\(current.count)")
            } catch { caught = error }
            // Cancellation releases any entered old/current Gate waiter. Every captured
            // actual prompt is joined before its owned peer root can be removed.
            old.cleanupRequested = true; current.cleanupRequested = true
            PermissionGate.shared.cancelPending(taskID: oldTaskID)
            PermissionGate.shared.cancelPending(taskID: newTaskID)
            await session.cancel()
            await session.close()
            await oldPrompt?.value
            await currentPrompt?.value
            await session.unsubscribe(subscription)
            check((oldPrompt == nil || old.finished && old.count == 1) &&
                  (currentPrompt == nil || current.finished && current.count == 1) &&
                  PermissionGate.shared.pending == nil && PermissionGate.shared.queuedCount == 0,
                "C11 same captured prompts and Gate waiters drained (\(mode))")
            try FileManager.default.removeItem(at: scope)
            if let caught { throw caught }
        }
        try await failedReplacementCase(root: safe, script: script, check: check)
        check(SelfTestStoreGuard.diff(ownerBefore, SelfTestStoreGuard.take()).isEmpty,
            "C12 owned peer fixture changed owner store/default")
    }
    private static func failedReplacementCase(root: URL, script: URL,
                                               check: (Bool, String) -> Void) async throws {
        let scope = root.appendingPathComponent("FailedClientStart-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scope, withIntermediateDirectories: false)
        let acknowledgement = scope.appendingPathComponent("old.json")
        let missingCommand = scope.appendingPathComponent("no-replacement-executable")
        let originTaskID = "selftest-acp-failed-start-original"
        let failedTaskID = "selftest-acp-failed-start-replacement"
        let session = ACPSession(), result = PromptResult(), events = Events()
        let subscription = await session.subscribe { event in events.append(event) }
        var prompt: Task<Void, Never>?
        var caught: Error?
        let askBefore = PermissionGate.shared.askCount
        do {
            try await session.start(command: AgentStdioFixtures.python,
                arguments: [script.path, "old", acknowledgement.path], directory: scope.path,
                taskID: originTaskID, approvePermissions: false)
            let initialID = await session.sessionID
            let initialRuntime = await session.currentRuntimeObservation()
            check(initialID == "fixture-reused-client-session" && (initialRuntime?.processID ?? 0) > 0,
                "C13 actual old peer exists before failed replacement")
            guard !FileManager.default.fileExists(atPath: missingCommand.path) else {
                throw FixtureError.invalid("missing replacement executable unexpectedly exists")
            }
            var startupFailed = false
            do {
                // Actual Process.run failure, not a scripted handler result or fake client.
                try await session.start(command: missingCommand.path, directory: scope.path,
                    taskID: failedTaskID, approvePermissions: false)
            } catch { startupFailed = true }
            check(startupFailed, "C14 actual replacement Process start fails")
            guard startupFailed else { throw FixtureError.invalid("replacement unexpectedly started") }
            let retainedID = await session.sessionID
            let retainedRuntime = await session.currentRuntimeObservation()
            check(retainedID == initialID && retainedRuntime?.processID == initialRuntime?.processID
                  && retainedRuntime?.isRunning == true && retainedRuntime?.transportClosed == false,
                "C15 exact original owned peer remains after failed start")
            // Request only AFTER the actual failed launch. The still-retained original
            // client must retain its original published task and permission choice.
            prompt = Task { @MainActor in
                guard !result.cleanupRequested else { result.count += 1; result.finished = true; return }
                do { result.reply = try await session.prompt("Owned request after failed replacement") }
                catch { result.failed = true }
                result.count += 1; result.finished = true
            }
            guard await reached({ result.finished || PermissionGate.shared.pending?.taskID == failedTaskID
                    || PermissionGate.shared.pending?.taskID == originTaskID }) else {
                throw FixtureError.invalid("failed-start old peer neither returned nor reached Gate")
            }
            let offered = PermissionGate.shared.pending
            let wrongTaskOffered = offered?.taskID == failedTaskID
            check(offered?.taskID == originTaskID && !wrongTaskOffered && PermissionGate.shared.askCount == askBefore + 1,
                "F04 failed Process start preserves original task permission owner")
            // Both versions answer their actual real card once. Its independently
            // measured task identity, wire and notifications distinguish publication.
            let answered: Bool
            if let offered {
                answered = PermissionGate.shared.respond(
                    id: offered.id, approved: true, duration: .once)
            } else { answered = true }
            check(answered, "C16 real offered card is answered or absent without a synthetic grant")
            guard await reached({ result.finished }) else {
                throw FixtureError.invalid("failed-start old peer prompt did not return")
            }
            await prompt?.value
            check(result.count == 1 && !result.failed,
                "C17 retained old prompt returns once after actual wire reply")
            let wire = try outcome(acknowledgement)
            check(offered?.taskID == originTaskID && wire == ["outcome": "selected", "optionId": "allow-once"],
                "F05 retained original permission reaches its exact offered wire")
            let title = await session.lastPublicTitle, reply = await session.lastReply
            let activities = events.snapshot().filter { $0.kind == "activity" }
            check(title == "old-client-activity" && reply == "Old owned reply." && result.reply == "Old owned reply."
                    && activities.count == 1 && activities.first?.taskID == originTaskID
                    && !events.snapshot().contains(where: { $0.taskID == failedTaskID }),
                "F06 failed Process start preserves actual old notification attribution")
            check(PermissionGate.shared.pending == nil && PermissionGate.shared.queuedCount == 0,
                "C18 failed-start current Gate is drained")
            SelfTest.diagnostic("ACP_FAILED_START_TRACE: launchFailed=\(startupFailed) sameProcess=\(retainedRuntime?.processID == initialRuntime?.processID) wrongTaskOffered=\(wrongTaskOffered) originalTaskOffered=\(offered?.taskID == originTaskID) cancelledWire=\(wire?["outcome"] == "cancelled") activityCount=\(activities.count) titleEmpty=\(title.isEmpty) replyEmpty=\(reply.isEmpty) returns=\(result.count)")
        } catch { caught = error }
        result.cleanupRequested = true
        PermissionGate.shared.cancelPending(taskID: originTaskID)
        PermissionGate.shared.cancelPending(taskID: failedTaskID)
        await session.cancel(); await session.close()
        await prompt?.value
        await session.unsubscribe(subscription)
        check((prompt == nil || result.finished && result.count == 1)
              && PermissionGate.shared.pending == nil && PermissionGate.shared.queuedCount == 0,
            "C19 same retained failed-start prompt and Gate waiter joined")
        try FileManager.default.removeItem(at: scope)
        if let caught { throw caught }
    }

    private static let peer = """
        import json, pathlib, sys
        role, acknowledgement = sys.argv[1:]
        session = 'fixture-reused-client-session'
        waiting = None
        def send(value):
            sys.stdout.write(json.dumps(value) + '\\n')
            sys.stdout.flush()
        for line in sys.stdin:
            message = json.loads(line)
            mid, method = message.get('id'), message.get('method')
            if method == 'initialize':
                send({'jsonrpc':'2.0','id':mid,'result':{'protocolVersion':1,'agentCapabilities':{}}})
            elif method == 'session/new':
                send({'jsonrpc':'2.0','id':mid,'result':{'sessionId':session}})
            elif method == 'session/prompt':
                assert message['params']['sessionId'] == session
                waiting = mid
                send({'jsonrpc':'2.0','id':900,'method':'session/request_permission','params':{
                    'sessionId':session,'toolCall':{'toolCallId':role + '-tool',
                        'title':'Owned current-client review only','kind':'other','status':'pending'},
                    'options':[{'optionId':'allow-once','name':'Allow once','kind':'allow_once'},
                        {'optionId':'reject-once','name':'Reject','kind':'reject_once'}]}})
            elif method is None and mid == 900:
                pathlib.Path(acknowledgement).write_text(json.dumps(message.get('result', {}), sort_keys=True))
                send({'jsonrpc':'2.0','method':'session/update','params':{'sessionId':session,
                    'update':{'sessionUpdate':'tool_call','title':role + '-client-activity'}}})
                send({'jsonrpc':'2.0','method':'session/update','params':{'sessionId':session,
                    'update':{'sessionUpdate':'agent_message_chunk',
                        'content':{'type':'text','text':'Old owned reply.' if role == 'old' else 'Current owned reply.'}}}})
                send({'jsonrpc':'2.0','id':waiting,'result':{'stopReason':'end_turn'}})
                waiting = None
            elif method == 'session/cancel':
                send({'jsonrpc':'2.0','id':mid,'result':{}})
        """
}

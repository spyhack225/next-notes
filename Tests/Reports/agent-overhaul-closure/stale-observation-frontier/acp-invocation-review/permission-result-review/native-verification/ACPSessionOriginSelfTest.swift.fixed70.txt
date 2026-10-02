import Foundation

/// Actual Session + owned peer; no private-handler call, tools or approval granted.
/// Preparation only. Immediate-new is a real ordering control, not a known pass.
@MainActor
enum ACPSessionOriginSelfTest {
    private enum FixtureError: Error { case unsafeRoot, busyGate }
    private final class PromptResult {
        var finished = false
        var completions = 0
        var reply = ""
        var error = ""
    }
    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [AgentBackendEvent] = []
        func append(_ value: AgentBackendEvent) {
            lock.lock(); defer { lock.unlock() }
            values.append(value)
        }
        func snapshot() -> [AgentBackendEvent] {
            lock.lock(); defer { lock.unlock() }
            return values
        }
    }

    private static func reached(_ predicate: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if predicate() { return true }
            await Task.yield()
        }
        return predicate()
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
        let script = safe.appendingPathComponent("session-origin-peer.py")
        try peer.write(to: script, atomically: true, encoding: .utf8)

        for mode in ["wrong", "missing", "blank", "nonstring", "valid", "immediate-new"] {
            let valid = mode == "valid" || mode == "immediate-new"
            let session = ACPSession()
            let events = Events()
            let taskID = "selftest-acp-origin-" + mode
            let ack = safe.appendingPathComponent(mode + "-permission.json")
            let askBefore = PermissionGate.shared.askCount
            let token = await session.subscribe { events.append($0) }
            let result = PromptResult()
            var prompt: Task<Void, Never>?
            var decline: Task<Int, Never>?
            var caught: Error?
            do {
                try await session.start(command: AgentStdioFixtures.python,
                    arguments: [script.path, mode, ack.path], directory: safe.path,
                    taskID: taskID, approvePermissions: false)
                let initialized = await session.didInitialize
                let sessionID = await session.sessionID
                check(initialized && sessionID == "fixture-session-identity",
                    "ACP origin: actual handshake failed (\(mode))")

                // Actual existing API gives a notification-tail barrier, without a
                // new Session/transport test hook. Peer sends updates with no prompt.
                await session.cancel()
                check(events.snapshot().contains { $0.title == "Valid outside prompt" },
                    "ACP origin: matched update outside prompt was dropped (\(mode))")
                if mode == "immediate-new" {
                    check(events.snapshot().contains { $0.title == "Valid immediate new" },
                        "ACP origin: legitimate immediate session/new update was dropped before ID establishment")
                }

                // Existing ACP flag uses this real Gate seam. This fixture only
                // records and declines its own requests, never creates a grant.
                decline = Task { @MainActor in
                    var count = 0
                    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                    while !Task.isCancelled && ContinuousClock.now < deadline {
                        if let pending = PermissionGate.shared.pending, pending.taskID == taskID {
                            count += 1
                            _ = PermissionGate.shared.respond(id: pending.id, approved: false)
                        }
                        if FileManager.default.fileExists(atPath: ack.path) { return count }
                        await Task.yield()
                    }
                    return count
                }
                prompt = Task { @MainActor in
                    do { result.reply = try await session.prompt("Owned identity fixture: no tools") }
                    catch { result.error = error.localizedDescription }
                    result.completions += 1
                    result.finished = true
                }
                let finished = await reached { result.finished }
                check(finished && result.error.isEmpty,
                    "ACP origin: actual prompt did not finish normally (\(mode))")
                if !finished { await session.close() }
                let expectedReply = valid ? "Valid prefix. Valid answer." : "Valid answer."
                check(result.reply == expectedReply,
                    "ACP origin: foreign session text reached actual prompt reply (\(mode))")
                let declined = await decline?.value ?? 0
                check(declined == (valid ? 1 : 0)
                    && PermissionGate.shared.askCount == askBefore + (valid ? 1 : 0),
                    "ACP origin: session identity did not fence permission callbacks (\(mode))")
                let ackData = try Data(contentsOf: ack)
                let wire = try JSONSerialization.jsonObject(with: ackData) as? [String: Any]
                // Retain the exact offered decline and origin controls under the
                // protocol's nested response contract (original flat bytes archived).
                check(wire?["outcome"] as? [String: String]
                    == ["outcome": "selected", "optionId": "reject-once"] && wire?["optionId"] == nil,
                    "ACP origin: actual permission reply was not the offered decline (\(mode))")
                let relayed = await session.permissionRelayed
                check(relayed == valid,
                    "ACP origin: wrong session was marked permission-relayed (\(mode))")
                await session.cancel() // Valid late tool update after prompt completion.
                let observed = events.snapshot()
                check(observed.contains { $0.title == "Valid after prompt" },
                    "ACP origin: matched late update after prompt was dropped (\(mode))")
                check(!observed.contains { $0.title.hasPrefix("Wrong ") },
                    "ACP origin: wrong session activity was attributed to current task (\(mode))")
                check(observed.filter { $0.kind == "permission" }.count == (valid ? 1 : 0)
                    && observed.allSatisfy { $0.taskID == taskID },
                    "ACP origin: published permission callback attribution was incorrect (\(mode))")
            } catch { caught = error }
            decline?.cancel()
            PermissionGate.shared.cancelPending(taskID: taskID)
            await session.unsubscribe(token)
            await session.close()
            await session.close()
            let joined = await reached { result.finished || prompt == nil }
            check(joined && (prompt == nil || result.completions == 1),
                "ACP origin: same owned prompt failed exactly-once cleanup (\(mode))")
            if joined { await prompt?.value }
            _ = await decline?.value
            if let caught { throw caught }
        }
        check(SelfTestStoreGuard.diff(ownerBefore, SelfTestStoreGuard.take()).isEmpty,
            "ACP origin: isolated fixture changed owner store/default")
    }

    private static let peer = """
        import json, pathlib, sys
        mode, acknowledgement = sys.argv[1:]
        session = 'fixture-session-identity'
        valid = mode in ('valid', 'immediate-new')
        waiting = None
        cancellations = 0
        def send(value):
            sys.stdout.write(json.dumps(value) + '\\n')
            sys.stdout.flush()
        def scope(params):
            if mode != 'missing':
                params['sessionId'] = session if valid else {
                    'wrong':'fixture-other-session', 'blank':'', 'nonstring':42}[mode]
            return params
        def update(title, matched=False):
            params = {'update':{'sessionUpdate':'tool_call_update',
                'toolCallId':'fixture-origin-tool', 'title':title, 'status':'completed'}}
            if matched:
                params['sessionId'] = session
            else:
                params = scope(params)
            return {'jsonrpc':'2.0','method':'session/update','params':params}
        def chunk(text, matched=False):
            params = {'update':{'sessionUpdate':'agent_message_chunk',
                'content':{'type':'text','text':text}}}
            if matched:
                params['sessionId'] = session
            else:
                params = scope(params)
            send({'jsonrpc':'2.0','method':'session/update','params':params})
        for line in sys.stdin:
            message = json.loads(line)
            mid, method = message.get('id'), message.get('method')
            if method == 'initialize':
                send({'jsonrpc':'2.0','id':mid,'result':{'protocolVersion':1,'agentCapabilities':{}}})
            elif method == 'session/new':
                response = {'jsonrpc':'2.0','id':mid,'result':{'sessionId':session}}
                if mode == 'immediate-new':
                    # One OS write: legitimate update directly follows new result.
                    sys.stdout.write(json.dumps(response) + '\\n' +
                        json.dumps(update('Valid immediate new', matched=True)) + '\\n')
                    sys.stdout.flush()
                else:
                    send(response)
            elif method == 'session/cancel':
                assert message['params']['sessionId'] == session
                cancellations += 1
                phase = 'outside prompt' if cancellations == 1 else 'after prompt'
                send(update(('Valid ' if valid else 'Wrong ') + phase))
                send(update('Valid ' + phase, matched=True))
                send({'jsonrpc':'2.0','id':mid,'result':{}})
            elif method == 'session/prompt':
                assert message['params']['sessionId'] == session
                waiting = mid
                send(update('Valid fixture activity' if valid else 'Wrong fixture activity'))
                chunk('Valid prefix. ' if valid else 'Foreign reply marker. ')
                send({'jsonrpc':'2.0','id':900,'method':'session/request_permission','params':scope({
                    'toolCall':{'toolCallId':'fixture-origin-tool','title':'Owned fixture permission','kind':'other'},
                    'options':[{'optionId':'allow-once','name':'Allow once','kind':'allow_once'},
                        {'optionId':'reject-once','name':'Reject','kind':'reject_once'}]})})
            elif method is None and mid == 900:
                pathlib.Path(acknowledgement).write_text(json.dumps(message.get('result', {}), sort_keys=True))
                chunk('Valid answer.', matched=True)
                send({'jsonrpc':'2.0','id':waiting,'result':{'stopReason':'end_turn'}})
                waiting = None
        """
}

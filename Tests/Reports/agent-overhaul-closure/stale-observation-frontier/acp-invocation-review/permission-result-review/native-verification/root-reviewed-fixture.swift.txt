import Foundation

/// Actual Session/Gate/wire regression with identical original/fixed inputs. No tool executes.
@MainActor
enum ACPSessionPermissionResultSelfTest {
    private enum FixtureError: Error { case unsafeRoot, busyGate }
    private final class Result {
        var finished = false
        var count = 0
        var reply = ""
        var cancelled = false
        var error = ""
    }
    private static func reached(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            await Task.yield()
        }
        return condition()
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
        let script = safe.appendingPathComponent("permission-result-peer.py")
        try peer.write(to: script, atomically: true, encoding: .utf8)
        for mode in ["allow", "decline", "cancel"] {
            let session = ACPSession()
            let taskID = "selftest-acp-permission-result-" + mode
            let acknowledgement = safe.appendingPathComponent(mode + "-result.json")
            let askBefore = PermissionGate.shared.askCount
            let result = Result()
            var prompt: Task<Void, Never>?
            var decision: Task<Bool, Never>?
            var caught: Error?
            do {
                try await session.start(command: AgentStdioFixtures.python,
                    arguments: [script.path, mode, acknowledgement.path], directory: safe.path,
                    taskID: taskID, approvePermissions: false)
                let initialized = await session.didInitialize
                let sessionID = await session.sessionID
                check(initialized && sessionID == "fixture-permission-result",
                    "ACP result: actual matched handshake failed (\(mode))")
                decision = Task { @MainActor in
                    let ready = await reached { PermissionGate.shared.pending?.taskID == taskID }
                    guard ready, let request = PermissionGate.shared.pending else { return false }
                    if mode == "cancel" {
                        // Actual Session cancel, not cancellation of its independently
                        // scheduled incoming-handler Task. No effect exists to stop.
                        await session.cancel()
                    } else {
                        _ = PermissionGate.shared.respond(id: request.id,
                            approved: mode == "allow", duration: .once)
                    }
                    return true
                }
                prompt = Task { @MainActor in
                    do { result.reply = try await session.prompt("Owned permission result fixture") }
                    catch {
                        result.error = error.localizedDescription
                        result.cancelled = error is CancellationError
                    }
                    result.count += 1
                    result.finished = true
                }
                let acted = await decision?.value ?? false
                check(acted, "ACP result: real owned Gate callback was not answered (\(mode))")
                let finished = await reached { result.finished }
                check(finished && (mode == "cancel" ? result.cancelled :
                    result.error.isEmpty && result.reply == "Permission fixture done."),
                    "ACP result: actual prompt/cancel control failed (\(mode))")
                if !finished { await session.close() }
                let data = try Data(contentsOf: acknowledgement)
                let wire = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                SelfTest.diagnostic("ACP_PERMISSION_RESULT_TRACE: mode=\(mode) result=\(String(data: data, encoding: .utf8) ?? "unavailable")")
                let outcome = wire?["outcome"] as? [String: String]
                let expected = mode == "cancel" ? ["outcome": "cancelled"] :
                    ["outcome": "selected", "optionId": mode == "allow" ? "allow-once" : "reject-once"]
                check(outcome == expected && wire?["optionId"] == nil,
                    "ACP result: actual peer received a nonconforming permission outcome (\(mode))")
                check(PermissionGate.shared.askCount == askBefore + 1,
                    "ACP result: matched permission did not reach Gate exactly once (\(mode))")
                check(PermissionGate.shared.pending == nil && PermissionGate.shared.queuedCount == 0,
                    "ACP result: owned review remained pending after decision (\(mode))")
            } catch { caught = error }
            decision?.cancel()
            PermissionGate.shared.cancelPending(taskID: taskID)
            await session.close()
            await session.close()
            let joined = await reached { result.finished || prompt == nil }
            check(joined && (prompt == nil || result.count == 1),
                "ACP result: same owned prompt did not join exactly once (\(mode))")
            if joined { await prompt?.value }
            _ = await decision?.value
            if let caught { throw caught }
        }
        check(SelfTestStoreGuard.diff(ownerBefore, SelfTestStoreGuard.take()).isEmpty,
            "ACP result: isolated peer changed owner store/default")
    }

    private static let peer = """
        import json, pathlib, sys
        mode, acknowledgement = sys.argv[1:]
        session = 'fixture-permission-result'
        waiting = None
        permission = False
        cancellation = False
        def send(value):
            sys.stdout.write(json.dumps(value) + '\\n')
            sys.stdout.flush()
        def complete_if_ready():
            global waiting
            if waiting is None or not permission or (mode == 'cancel' and not cancellation):
                return
            if mode != 'cancel':
                send({'jsonrpc':'2.0','method':'session/update','params':{'sessionId':session,
                    'update':{'sessionUpdate':'agent_message_chunk',
                        'content':{'type':'text','text':'Permission fixture done.'}}}})
            send({'jsonrpc':'2.0','id':waiting,'result':{'stopReason':
                'cancelled' if mode == 'cancel' else 'end_turn'}})
            waiting = None
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
                    'sessionId':session,'toolCall':{'toolCallId':'fixture-result-tool',
                        'title':'Owned fixture review only','kind':'other','status':'pending'},
                    'options':[{'optionId':'allow-once','name':'Allow once','kind':'allow_once'},
                        {'optionId':'reject-once','name':'Reject','kind':'reject_once'}]}})
            elif method == 'session/cancel':
                assert message['params']['sessionId'] == session
                cancellation = True
                send({'jsonrpc':'2.0','id':mid,'result':{}})
                complete_if_ready()
            elif method is None and mid == 900:
                # Original flat and future nested bytes are both retained verbatim.
                # Complete the same control; do not substitute malformed-response timeout.
                pathlib.Path(acknowledgement).write_text(json.dumps(message.get('result', {}), sort_keys=True))
                permission = True
                complete_if_ready()
        """
}

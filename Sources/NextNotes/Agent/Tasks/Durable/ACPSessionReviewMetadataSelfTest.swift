import Foundation

/// Actual standalone Session -> Broker -> Gate -> owned peer; no Manager ID override or effect.
@MainActor
enum ACPSessionReviewMetadataSelfTest {
    private enum FixtureError: Error { case unsafeRoot, busyGate, invalidControl, timeout }
    private final class Result {
        var finished = false
        var count = 0
        var reply = ""
        var error = ""
    }
    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [AgentBackendEvent] = []
        func append(_ event: AgentBackendEvent) { lock.lock(); defer { lock.unlock() }; values.append(event) }
        func snapshot() -> [AgentBackendEvent] { lock.lock(); defer { lock.unlock() }; return values }
    }
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
    static func originalCases(root: URL, check: (Bool, String) -> Void) async throws {
        let safe = root.resolvingSymlinksInPath().standardizedFileURL
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard SelfTest.isRunning, safe.isFileURL, safe.path.hasPrefix(temporary.path + "/"),
              !safe.pathComponents.contains("Application Support") else { throw FixtureError.unsafeRoot }
        let gate = PermissionGate.shared
        guard gate.pending == nil, gate.queuedCount == 0 else { throw FixtureError.busyGate }
        let ownerBefore = SelfTestStoreGuard.take()
        let grantsBefore = PermissionGrantStore.shared.grants
        let priorFake = AgentToolExecutor.fakeForTesting
        let priorFire = AgentToolExecutor.fireOverrideForTesting
        var unexpectedTools = 0
        AgentToolExecutor.fakeForTesting = nil
        AgentToolExecutor.fireOverrideForTesting = { _, _ in
            unexpectedTools += 1
            throw FixtureError.invalidControl
        }
        defer {
            AgentToolExecutor.fakeForTesting = priorFake
            AgentToolExecutor.fireOverrideForTesting = priorFire
        }
        let directory = safe.appendingPathComponent("session-review-metadata", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let script = directory.appendingPathComponent("owned-peer.py")
        try peer.write(to: script, atomically: true, encoding: .utf8)
        let wireFile = directory.appendingPathComponent("wire.json")
        let taskID = "ABCDEFAB-CDEF-ABCD-ABCD-123456789012"
        let sessionID = "fixture-review-metadata"
        let objective = "Owned metadata review fixture: no tools"
        let marker = "Metadata fixture finished."
        let expectedOperation: [String: String] = ["toolCallId": "owned-metadata-review",
            "title": "Owned fixture review only", "kind": "other", "status": "pending"]
        let operationData = try JSONSerialization.data(withJSONObject: expectedOperation, options: [.sortedKeys])
        guard let detail = String(data: operationData, encoding: .utf8) else { throw FixtureError.invalidControl }
        let session = ACPSession()
        let events = Events()
        let token = await session.subscribe { events.append($0) }
        let result = Result()
        let askBefore = gate.askCount
        var prompt: Task<Void, Never>?
        var requestID: String?
        var caught: Error?
        do {
            // Existing standalone API: nil TaskJournalContext, no seeded Manager/task store.
            try await session.start(command: AgentStdioFixtures.python,
                arguments: [script.path, directory.path], directory: directory.path,
                taskID: taskID, approvePermissions: false)
            let initialized = await session.didInitialize
            let actualSessionID = await session.sessionID
            // S01
            check(initialized && actualSessionID == sessionID && UUID(uuidString: taskID) != nil,
                "ACP metadata: actual standalone handshake or known valid UUID failed")
            prompt = Task { @MainActor in
                do { result.reply = try await session.prompt(objective) }
                catch { result.error = error.localizedDescription }
                result.count += 1
                result.finished = true
            }
            guard await reached({ gate.pending?.taskID == taskID }) else { throw FixtureError.timeout }
            guard let request = gate.pending, let review = gate.pendingReview else { throw FixtureError.invalidControl }
            requestID = request.id
            let promptTrace = object(directory.appendingPathComponent("prompt.json"))
            // S02
            check(promptTrace["promptCount"] as? Int == 1 && promptTrace["sessionID"] as? String == sessionID,
                "ACP metadata: actual matched prompt did not precede the real Gate")
            // S03
            check(request.taskID == taskID && request.toolID == "mcp.acp_nested_tool" && request.risk == .privileged,
                "ACP metadata: typed task/header identity or operation risk changed")
            // S04
            check(request.arguments["toolCall"] == detail && request.detail == detail,
                "ACP metadata: exact operation JSON changed at the permission producer")
            // S05: intended original duplicate metadata failure.
            check(request.arguments["taskID"] == nil && !review.fields.contains { $0.name == "taskID" },
                "ACP metadata: internal task identity was exposed as an editable operation argument")
            // S06
            check(review.arguments == ["toolCall": detail] && review.fields.count == 1
                && review.fields.first?.name == "toolCall" && review.fields.first?.value == detail,
                "ACP metadata: actual review contains anything besides the exact requested operation")
            // S07: actual consumer, before any readiness confirmation.
            check(review.isReadyToRun && review.blockers.isEmpty,
                "ACP metadata: harmless operation needed confirmation of internal UUID digits")
            let firstAccepted = gate.respond(id: request.id, approved: true, duration: .once)
            // S08: original must fail on its actual first approval, not a helper verdict.
            check(firstAccepted && gate.pending == nil,
                "ACP metadata: actual first approval was refused by redundant internal task identity")
            SelfTest.diagnostic("ACP_REVIEW_METADATA_TRACE: fields=\(review.fields.count) problems=\(review.fields.filter { $0.problem != nil }.count) taskField=\(review.fields.contains { $0.name == "taskID" }) taskProblem=\(review.fields.first { $0.name == "taskID" }?.problem?.rawValue ?? "none") firstAccepted=\(firstAccepted)")
            // Retain old red inputs; only finish its harmless original protocol AFTER assertions.
            // No Manager ID selection, scrub, fake review or operation argument edit.
            if !firstAccepted {
                guard gate.pending == request, let retained = gate.pendingReview,
                      let taskField = retained.fields.first(where: { $0.name == "taskID" }),
                      taskField.value == taskID, taskField.problem == .notConfirmed,
                      retained.blockers.allSatisfy({ $0.name == "taskID" && $0.problem == .notConfirmed }) else {
                    throw FixtureError.invalidControl
                }
                ToolCallReviewStore.shared.confirm(id: request.id, field: "taskID")
                guard gate.respond(id: request.id, approved: true, duration: .once) else { throw FixtureError.invalidControl }
            }
            // S09
            check(request.taskID == taskID && request.arguments["toolCall"] == detail
                && PermissionGrantStore.shared.grants == grantsBefore,
                "ACP metadata: exact metadata/operation/grants changed while finishing original control")
            guard await reached({ FileManager.default.fileExists(atPath: wireFile.path) }) else { throw FixtureError.timeout }
            let wire = object(wireFile)
            let response = wire["result"] as? [String: Any] ?? [:]
            // S10
            check(response["outcome"] as? [String: String] == ["outcome": "selected", "optionId": "owned-allow-once"]
                && response["optionId"] == nil,
                "ACP metadata: actual owned peer did not receive the offered conforming approval")
            // S11
            check(wire["replyCount"] as? Int == 1 && wire["requestCount"] as? Int == 1
                && wire["cancelBeforeVerdict"] as? Bool == false && wire["externalEffectCount"] as? Int == 0,
                "ACP metadata: approval was substituted with cancellation/duplicate/effect")
            guard await reached({ result.finished }) else { throw FixtureError.timeout }
            // S12
            check(result.count == 1 && result.error.isEmpty && result.reply == marker,
                "ACP metadata: actual prompt consumer did not complete the same harmless reply once")
            let relayed = await session.permissionRelayed
            let observed = events.snapshot()
            // S13
            check(relayed && observed.filter { $0.kind == "permission" }.count == 1
                && observed.allSatisfy { $0.taskID == taskID },
                "ACP metadata: actual Session events lost typed task attribution")
            // S14
            check(gate.askCount == askBefore + 1,
                "ACP metadata: real permission reached Gate more or less than once")
            // S15
            check(gate.pending == nil && gate.queuedCount == 0 && unexpectedTools == 0
                && PermissionGrantStore.shared.grants == grantsBefore,
                "ACP metadata: pending/grants/no-backing completion controls failed")
            let calls = (try? JSONSerialization.jsonObject(with: Data(contentsOf:
                directory.appendingPathComponent("calls.json")))) as? [String]
            // S16
            check(calls == ["initialize", "session/new", "session/prompt"]
                && object(directory.appendingPathComponent("launch.json"))["count"] as? Int == 1,
                "ACP metadata: actual peer restarted or altered protocol controls")
        } catch { caught = error }
        gate.cancelPending(taskID: taskID)
        await session.unsubscribe(token)
        await session.close()
        let joined = await reached { result.finished || prompt == nil }
        // S17
        check(joined && (prompt == nil || result.count == 1),
            "ACP metadata: same owned prompt did not join exactly once")
        if joined { await prompt?.value }
        if let requestID { ToolCallReviewStore.shared.remove(id: requestID) }
        if let caught { throw caught }
        // O01
        check(SelfTestStoreGuard.diff(ownerBefore, SelfTestStoreGuard.take()).isEmpty
            && PermissionGrantStore.shared.grants == grantsBefore,
            "ACP metadata: standalone fixture changed owner stores/defaults/grants")
    }

    private static let peer = #"""
        import json, pathlib, sys, tempfile
        root = pathlib.Path(sys.argv[1]).resolve()
        temporary = pathlib.Path(tempfile.gettempdir()).resolve()
        assert root != temporary and temporary in root.parents and 'Application Support' not in root.parts
        session = 'fixture-review-metadata'
        calls = []
        prompt = None
        requests = 0
        replies = 0
        cancelled = False
        def write(name, value):
            stage = root / (name + '.tmp')
            stage.write_text(json.dumps(value, sort_keys=True))
            stage.replace(root / name)
        def send(value):
            sys.stdout.write(json.dumps(value) + '\n')
            sys.stdout.flush()
        assert not (root / 'launch.json').exists()
        write('launch.json', {'count': 1})
        for line in sys.stdin:
            message = json.loads(line)
            mid, method = message.get('id'), message.get('method')
            if method is not None:
                calls.append(method)
                write('calls.json', calls)
            if method == 'initialize':
                send({'jsonrpc': '2.0', 'id': mid, 'result': {'protocolVersion': 1, 'agentCapabilities': {}}})
            elif method == 'session/new':
                send({'jsonrpc': '2.0', 'id': mid, 'result': {'sessionId': session}})
            elif method == 'session/prompt':
                assert prompt is None and message['params']['sessionId'] == session
                assert message['params']['prompt'][0]['text'] == 'Owned metadata review fixture: no tools'
                prompt = mid
                write('prompt.json', {'promptCount': 1, 'sessionID': session})
                requests += 1
                send({'jsonrpc': '2.0', 'id': 900, 'method': 'session/request_permission', 'params': {
                    'sessionId': session, 'toolCall': {'toolCallId': 'owned-metadata-review',
                        'title': 'Owned fixture review only', 'kind': 'other', 'status': 'pending'},
                    'options': [{'optionId': 'owned-allow-once', 'name': 'Allow once', 'kind': 'allow_once'},
                        {'optionId': 'owned-reject-once', 'name': 'Reject', 'kind': 'reject_once'}]}})
            elif method is None and mid == 900:
                assert prompt is not None and replies == 0
                replies += 1
                write('wire.json', {'result': message.get('result', {}), 'replyCount': replies,
                    'requestCount': requests, 'cancelBeforeVerdict': cancelled, 'externalEffectCount': 0})
                send({'jsonrpc': '2.0', 'method': 'session/update', 'params': {'sessionId': session, 'update': {
                    'sessionUpdate': 'agent_message_chunk', 'content': {'type': 'text', 'text': 'Metadata fixture finished.'}}}})
                send({'jsonrpc': '2.0', 'id': prompt, 'result': {'stopReason': 'end_turn'}})
            elif method == 'session/cancel':
                if replies == 0:
                    cancelled = True
                send({'jsonrpc': '2.0', 'id': mid, 'result': {}})
            else:
                raise ValueError('unexpected owned metadata fixture message')
        """#
}

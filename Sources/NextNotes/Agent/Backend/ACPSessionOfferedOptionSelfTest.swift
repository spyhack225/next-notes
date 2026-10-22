import Foundation

/// Actual Session -> owned peer -> real Gate/Broker. No peer tool or external effect exists.
/// Preparation only; all original/fixed inputs and approval choices must remain identical.
@MainActor
enum ACPSessionOfferedOptionSelfTest {
    private enum FixtureError: Error { case unsafeRoot, busyGate }
    private final class PromptResult {
        var finished = false
        var count = 0
        var reply = ""
        var error = ""
        var reviewError = ""
        var standingGrantObserved = false
        var requestIDs: [String] = []
    }
    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var permissions = 0
        func append(_ value: AgentBackendEvent) {
            lock.lock(); defer { lock.unlock() }
            if value.kind == "permission" { permissions += 1 }
        }
        func count() -> Int {
            lock.lock(); defer { lock.unlock() }
            return permissions
        }
    }
    private struct Case {
        let mode: String
        let options: [[String: Any]]
        let approved: Bool
        let outcomes: [[String: String]]
        let relays: Int
        let asks: Int
    }
    private static func reached(_ predicate: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if predicate() { return true }
            await Task.yield()
        }
        return predicate()
    }
    private static func option(_ id: Any, _ kind: String, name: String = "Owned choice") -> [String: Any] {
        ["optionId": id, "name": name, "kind": kind]
    }
    private static func selected(_ id: String) -> [String: String] {
        ["outcome": "selected", "optionId": id]
    }
    private static let cancelled = ["outcome": "cancelled"]
    private static func encoded(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func originalCases(root: URL, check: (Bool, String) -> Void) async throws {
        let safe = root.resolvingSymlinksInPath().standardizedFileURL
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard SelfTest.isRunning, root.isFileURL,
              safe.path.hasPrefix(temporary.path + "/"),
              !safe.pathComponents.contains("Application Support") else { throw FixtureError.unsafeRoot }
        guard PermissionGate.shared.pending == nil, PermissionGate.shared.queuedCount == 0 else {
            throw FixtureError.busyGate
        }
        let ownerBefore = SelfTestStoreGuard.take()
        let grantsBefore = PermissionGrantStore.shared.grants
        let script = safe.appendingPathComponent("offered-option-peer.py")
        try peer.write(to: script, atomically: true, encoding: .utf8)
        let allowID = "owned-allow-\"\\-once"
        let rejectID = "owned-reject-\"\\-once"
        let normal = [option(allowID, "allow_once"), option(rejectID, "reject_once")]
        let lasting = [option("owned-allow-always", "allow_always"),
                       option("owned-reject-always", "reject_always")]
        let cases = [
            Case(mode: "valid-allow", options: [["options": normal]], approved: true,
                 outcomes: [selected(allowID)], relays: 1, asks: 1),
            Case(mode: "valid-decline", options: [["options": normal]], approved: false,
                 outcomes: [selected(rejectID)], relays: 1, asks: 1),
            Case(mode: "lasting-reject-first", options: [["options": [option("owned-lasting-reject", "reject_always")] + normal]],
                 approved: false, outcomes: [selected(rejectID)], relays: 1, asks: 1),
            Case(mode: "allow-only-decline", options: [["options": [option(allowID, "allow_once")]]],
                 approved: false, outcomes: [cancelled], relays: 1, asks: 1),
            Case(mode: "reject-only-approve", options: [["options": [option(rejectID, "reject_once")]]],
                 approved: true, outcomes: [selected(rejectID)], relays: 0, asks: 0),
            Case(mode: "lasting-only-approve", options: [["options": lasting]], approved: true,
                 outcomes: [cancelled], relays: 0, asks: 0),
            Case(mode: "missing-options", options: [[:]], approved: true,
                 outcomes: [cancelled], relays: 0, asks: 0),
            Case(mode: "empty-options", options: [["options": []]], approved: true,
                 outcomes: [cancelled], relays: 0, asks: 0),
            Case(mode: "nonarray-options", options: [["options": "owned malformed options"]], approved: true,
                 outcomes: [cancelled], relays: 0, asks: 0),
            Case(mode: "nonstring-allow-id", options: [["options": [option(42, "allow_once"), option(rejectID, "reject_once")]]],
                 approved: true, outcomes: [cancelled], relays: 0, asks: 0),
            Case(mode: "duplicate-id", options: [["options": [option("owned-duplicate", "allow_once"),
                                                                      option("owned-duplicate", "reject_once")]]],
                 approved: true, outcomes: [cancelled], relays: 0, asks: 0),
            Case(mode: "missing-option-name", options: [["options": [["optionId": allowID, "kind": "allow_once"],
                                                                             option(rejectID, "reject_once")]]],
                 approved: true, outcomes: [cancelled], relays: 0, asks: 0),
            Case(mode: "unknown-reject-first", options: [["options": [option("owned-unknown-reject", "reject_and_continue")] + normal]],
                 approved: false, outcomes: [selected(rejectID)], relays: 1, asks: 1),
            Case(mode: "legacy-once-alias", options: [["options": [option(allowID, "allow-once"), option(rejectID, "reject-once")]]],
                 approved: false, outcomes: [selected(rejectID)], relays: 1, asks: 1),
            // First actual approval creates the exact in-memory task grant. The second
            // request reaches the real Broker allow arm on ORIGINAL, not a fake policy.
            Case(mode: "standing-grant-lasting-only", options: [["options": normal], ["options": lasting]],
                 approved: true, outcomes: [selected(allowID), cancelled], relays: 1, asks: 1),
        ]

        for input in cases {
            let session = ACPSession()
            let taskID = "selftest-acp-offered-option-" + input.mode
            let specification = safe.appendingPathComponent(input.mode + "-input.json")
            let acknowledgement = safe.appendingPathComponent(input.mode + "-result.json")
            let operation: [String: Any] = ["toolCallId": "owned-option-tool", "title": "Owned review only",
                                          "kind": "other", "status": "pending"]
            let requests = input.options.map { options -> [String: Any] in
                var params = options
                params["sessionId"] = "fixture-offered-options"
                params["toolCall"] = operation
                return params
            }
            try encoded(requests).write(to: specification, options: .atomic)
            let askBefore = PermissionGate.shared.askCount
            let events = Events()
            let token = await session.subscribe { events.append($0) }
            let result = PromptResult()
            var prompt: Task<Void, Never>?
            var decision: Task<Void, Never>?
            var caught: Error?
            do {
                try await session.start(command: AgentStdioFixtures.python,
                    arguments: [script.path, specification.path, acknowledgement.path], directory: safe.path,
                    taskID: taskID, approvePermissions: false)
                let initialized = await session.didInitialize
                let sessionID = await session.sessionID
                check(initialized && sessionID == "fixture-offered-options", "ACP offers C01 handshake (\(input.mode))")
                decision = Task { @MainActor in
                    while !Task.isCancelled && !result.finished {
                        if let request = PermissionGate.shared.pending, request.taskID == taskID {
                            result.requestIDs.append(request.id)
                            guard let review = PermissionGate.shared.pendingReview, review.isReadyToRun else {
                                result.reviewError = "owned review was not ready"
                                PermissionGate.shared.cancelPending(taskID: taskID)
                                return
                            }
                            let duration: PermissionDuration = input.mode == "standing-grant-lasting-only" ? .thisTask : .once
                            let accepted = PermissionGate.shared.respond(id: request.id,
                                approved: input.approved, duration: duration)
                            if !accepted { result.reviewError = "owned decision was refused"; return }
                            if duration == .thisTask {
                                result.standingGrantObserved = PermissionGrantStore.shared.grants.contains {
                                    $0.toolID == request.toolID && $0.taskID == taskID && $0.duration == .thisTask
                                }
                            }
                        }
                        await Task.yield()
                    }
                }
                prompt = Task { @MainActor in
                    do { result.reply = try await session.prompt("Owned option fixture: no tools") }
                    catch { result.error = error.localizedDescription }
                    result.count += 1
                    result.finished = true
                }
                let finished = await reached { result.finished }
                check(finished && result.error.isEmpty && result.reply == "Owned options done.",
                      "ACP offers C02 actual prompt completion (\(input.mode))")
                if !finished { await session.close() }
                check(result.reviewError.isEmpty && (input.mode != "standing-grant-lasting-only" || result.standingGrantObserved),
                      "ACP offers C03 real review/grant control (\(input.mode))")
                let data = try Data(contentsOf: acknowledgement)
                let records = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
                let receivedRequests = records.map { $0["request"] as? [String: Any] ?? [:] }
                check(try encoded(receivedRequests) == encoded(requests),
                      "ACP offers C04 exact owned requests (\(input.mode))")
                let receivedResults = records.map { $0["result"] as? [String: Any] ?? [:] }
                let outcomes = receivedResults.map { $0["outcome"] as? [String: String] ?? [:] }
                check(outcomes == input.outcomes && receivedResults.allSatisfy { $0.count == 1 },
                      "ACP offers F01 truthful offered outcome (\(input.mode))")
                let selectionsAreOneTime = records.allSatisfy { record in
                    guard let wire = record["result"] as? [String: Any],
                          let outcome = wire["outcome"] as? [String: String] else { return false }
                    if outcome == cancelled { return wire.count == 1 }
                    guard outcome["outcome"] == "selected", outcome.count == 2,
                          let selectedID = outcome["optionId"],
                          let request = record["request"] as? [String: Any],
                          let offered = request["options"] as? [[String: Any]] else { return false }
                    let matches = offered.filter { ($0["optionId"] as? String) == selectedID }
                    guard matches.count == 1, let kind = matches[0]["kind"] as? String else { return false }
                    return ["allow_once", "reject_once", "allow-once", "reject-once"].contains(kind.lowercased())
                }
                check(selectionsAreOneTime, "ACP offers F02 unique one-time selection (\(input.mode))")
                check(PermissionGate.shared.askCount == askBefore + input.asks,
                      "ACP offers F03 actual Gate admission (\(input.mode))")
                check(events.count() == input.relays,
                      "ACP offers F04 actual permission relay (\(input.mode))")
                SelfTest.diagnostic("ACP_OFFER_TRACE: mode=\(input.mode) requests=\(records.count) asks=\(PermissionGate.shared.askCount - askBefore) relays=\(events.count()) outcomes=\(String(data: try encoded(outcomes), encoding: .utf8) ?? "unavailable") grant=\(result.standingGrantObserved)")
            } catch { caught = error }
            decision?.cancel()
            PermissionGate.shared.cancelPending(taskID: taskID)
            await session.unsubscribe(token)
            await session.close()
            let joined = await reached { result.finished || prompt == nil }
            check(joined && (prompt == nil || result.count == 1), "ACP offers C05 exact prompt join (\(input.mode))")
            if joined { await prompt?.value }
            _ = await decision?.value
            let created = PermissionGrantStore.shared.grants.filter { grant in
                !grantsBefore.contains { $0.id == grant.id } && grant.taskID == taskID
            }
            for grant in created { PermissionGrantStore.shared.revoke(id: grant.id) }
            for id in result.requestIDs { ToolCallReviewStore.shared.remove(id: id) }
            check(PermissionGate.shared.pending == nil && PermissionGate.shared.queuedCount == 0
                  && result.requestIDs.allSatisfy { ToolCallReviewStore.shared.review(id: $0) == nil }
                  && PermissionGrantStore.shared.grants == grantsBefore,
                  "ACP offers C06 exact Gate/grant cleanup (\(input.mode))")
            if let caught { throw caught }
        }
        check(SelfTestStoreGuard.diff(ownerBefore, SelfTestStoreGuard.take()).isEmpty,
              "ACP offers C07 owner guard unchanged")
    }

    private static let peer = """
        import json, pathlib, sys
        specification, acknowledgement = sys.argv[1:]
        requests = json.loads(pathlib.Path(specification).read_text())
        session = 'fixture-offered-options'
        waiting = None
        index = 0
        records = []
        def send(value):
            sys.stdout.write(json.dumps(value) + '\\n')
            sys.stdout.flush()
        def ask():
            send({'jsonrpc':'2.0','id':900 + index,'method':'session/request_permission','params':requests[index]})
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
                ask()
            elif method is None and mid == 900 + index:
                records.append({'request':requests[index], 'result':message.get('result', {})})
                index += 1
                if index < len(requests):
                    ask()
                else:
                    pathlib.Path(acknowledgement).write_text(json.dumps(records, sort_keys=True))
                    send({'jsonrpc':'2.0','method':'session/update','params':{'sessionId':session,
                        'update':{'sessionUpdate':'agent_message_chunk',
                            'content':{'type':'text','text':'Owned options done.'}}}})
                    send({'jsonrpc':'2.0','id':waiting,'result':{'stopReason':'end_turn'}})
                    waiting = None
            elif method == 'session/cancel':
                send({'jsonrpc':'2.0','id':mid,'result':{}})
        """
}

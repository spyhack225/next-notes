import Foundation

/// Real ACPSession -> shared stdio transport -> owned temporary no-tool peer.
/// Default ACP timeouts stay unchanged. No model/account/network/stale/retry proof.
@MainActor
enum ACPStdioTerminationSelfTest {
    private enum FixtureError: Error { case unsafeRoot, timeout }
    @MainActor
    private final class Result {
        var finished = false
        var completions = 0
        var reply: String?
        var error = ""
        var cancelled = false
        var cancelReturned = false
        var notifications = 0
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
        let safeRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard SelfTest.isRunning, safeRoot.path.hasPrefix(temporary.path + "/"),
              !safeRoot.pathComponents.contains("Application Support") else { throw FixtureError.unsafeRoot }
        let script = safeRoot.appendingPathComponent("stdio-terminal-peer.py")
        try peer.write(to: script, atomically: true, encoding: .utf8)
        let ownerBefore = SelfTestStoreGuard.take()
        for mode in ["final-exit", "pending-exit", "explicit-close", "cancel", "task-cancel"] {
            let marker = safeRoot.appendingPathComponent(mode + "-consumed.txt")
            let session = ACPSession()
            let result = Result()
            var prompt: Task<Void, Never>?
            var caught: Error?
            var requestedTaskCancellation = false
            do {
                try await session.start(command: AgentStdioFixtures.python,
                    arguments: [script.path, mode, marker.path], directory: safeRoot.path,
                    taskID: "selftest-acp-terminal-" + mode, approvePermissions: false)
                let initialized = await session.didInitialize
                let sessionID = await session.sessionID
                check(initialized && sessionID == "fixture-terminal",
                    "ACP terminal: actual isolated handshake failed (\(mode))")
                prompt = Task { @MainActor in
                    do {
                        let reply = try await withTaskCancellationHandler(operation: {
                            try await session.prompt("Owned fixture: no tools or external effects")
                        }, onCancel: { Task {
                            await session.cancel()
                            if mode == "task-cancel" { await MainActor.run { result.cancelReturned = true } }
                        } })
                        result.reply = reply
                    } catch {
                        result.error = error.localizedDescription
                        result.cancelled = error is CancellationError
                    }
                    result.completions += 1
                    result.finished = true
                }
                guard await reached({ FileManager.default.fileExists(atPath: marker.path) }) else {
                    throw FixtureError.timeout
                }
                if mode == "task-cancel" {
                    let beforeCancel = await session.currentRuntimeObservation()
                    check(beforeCancel?.pendingRequestCount == 1 && beforeCancel?.transportClosed == false
                        && beforeCancel?.outputEOF == false && (beforeCancel?.processID ?? 0) > 0,
                        "ACP task cancellation C01: actual consumed prompt was not pending on the owned peer")
                }
                if mode == "explicit-close" {
                    await session.close()
                } else if mode == "cancel" || mode == "task-cancel" {
                    requestedTaskCancellation = mode == "task-cancel"
                    prompt?.cancel() // Same cancellation-handler shape as actual backend.
                }
                if mode == "task-cancel" {
                    let acknowledgement = marker.appendingPathExtension("cancel-ack")
                    guard await reached({ FileManager.default.fileExists(atPath: acknowledgement.path) }) else {
                        throw FixtureError.timeout
                    }
                }
                let promptlyFinished = await reached { result.finished && (mode != "task-cancel" || result.cancelReturned) }
                if mode == "task-cancel" {
                    let afterCancel = await session.currentRuntimeObservation()
                    check(afterCancel?.pendingRequestCount == 0 && afterCancel?.transportClosed == false
                        && afterCancel?.outputEOF == false,
                        "ACP task cancellation F01: cancel acknowledgement left the original prompt pending")
                    SelfTest.diagnostic("ACP_TASK_CANCEL_TRACE: consumed=true ack=true promptFinished=\(promptlyFinished) completions=\(result.completions) cancelled=\(result.cancelled) pending=\(afterCancel?.pendingRequestCount ?? -1) closed=\(afterCancel?.transportClosed ?? true) eof=\(afterCancel?.outputEOF ?? true)")
                }
                if mode == "pending-exit" {
                    // Original transport waits its 90s prompt timeout. Cleanup below
                    // closes that SAME owned client; it never replaces this scenario.
                    check(promptlyFinished && result.reply == nil
                        && result.error == "The connection ended before a reply arrived." && !result.cancelled,
                        "ACP terminal: consumed prompt/peer EOF stayed pending until timeout or external close")
                } else if mode == "final-exit" {
                    check(promptlyFinished && result.reply == "Final fixture reply." && result.error.isEmpty,
                        "ACP terminal: final streamed response immediately before exit was lost")
                } else if mode == "explicit-close" {
                    check(promptlyFinished && result.reply == nil && result.error == "Session closed.",
                        "ACP terminal: explicit close failed to drain actual pending prompt")
                } else {
                    check(promptlyFinished && result.cancelled && result.reply == nil,
                        "ACP terminal: actual cancellation protocol did not end the pending prompt")
                }
            } catch { caught = error }
            await session.close()
            await session.close()
            if requestedTaskCancellation {
                // Closing settles the cancel request too. Drain the SAME existing
                // cancellation callback even when its acknowledgement guard threw.
                guard await reached({ result.cancelReturned }) else { throw FixtureError.timeout }
            }
            let joined = await reached { result.finished || prompt == nil }
            check(joined && (prompt == nil || result.completions == 1),
                "ACP terminal: same owned prompt did not join exactly once after cleanup (\(mode))")
            if joined { await prompt?.value }
            if let caught { throw caught }
            var rejectedAfterClose = false
            do { _ = try await session.prompt("Must not reopen a closed transport") }
            catch { rejectedAfterClose = error.localizedDescription == "ACP session never started." }
            check(rejectedAfterClose && result.completions == 1,
                "ACP terminal: closed session reused historical handshake as live authority (\(mode))")
        }

        // SAME shared client, two genuinely pending request IDs. Cancelling one must
        // not close the transport or settle its unrelated sibling.
        let siblingMarker = safeRoot.appendingPathComponent("rpc-sibling-consumed.txt")
        let siblingClient = try JSONRPCStdioClient(command: AgentStdioFixtures.python,
            arguments: [script.path, "rpc-sibling", siblingMarker.path], directory: safeRoot.path)
        let cancelledResult = Result(), siblingResult = Result(), preCancelledResult = Result()
        var siblingOperations: [Task<Void, Never>] = []
        siblingClient.onNotification { message in
            if message["method"] == "fixture/notice" {
                await MainActor.run { siblingResult.notifications += 1 }
            }
        }
        do {
            let cancelled = Task { @MainActor in
                do {
                    _ = try await siblingClient.request(method: "fixture/held")
                    cancelledResult.reply = "unexpected response"
                } catch { cancelledResult.cancelled = error is CancellationError; cancelledResult.error = error.localizedDescription }
                cancelledResult.completions += 1; cancelledResult.finished = true
            }
            siblingOperations.append(cancelled) // Before every qualification guard.
            guard await reached({ FileManager.default.fileExists(atPath: siblingMarker.path) }) else { throw FixtureError.timeout }
            let sibling = Task { @MainActor in
                do {
                    let data = try await siblingClient.request(method: "fixture/sibling")
                    let payload = try JSONSerialization.jsonObject(with: data) as? [String: Bool]
                    siblingResult.reply = payload?["ok"] == true ? "ok" : "wrong payload"
                } catch { siblingResult.error = error.localizedDescription }
                siblingResult.completions += 1; siblingResult.finished = true
            }
            siblingOperations.append(sibling)
            guard await reached({ FileManager.default.fileExists(atPath: siblingMarker.appendingPathExtension("sibling").path) }) else { throw FixtureError.timeout }
            let beforeCancel = siblingClient.currentRuntimeObservation()
            check(beforeCancel?.pendingRequestCount == 2 && beforeCancel?.transportClosed == false,
                "ACP task cancellation C02: SAME owned transport did not hold distinct prompt and sibling IDs")
            cancelled.cancel()
            let finishedAfterCancel = await reached { cancelledResult.finished }
            let afterCancel = siblingClient.currentRuntimeObservation()
            check(finishedAfterCancel && cancelledResult.cancelled && cancelledResult.reply == nil
                && cancelledResult.completions == 1 && afterCancel?.pendingRequestCount == 1,
                "ACP task cancellation F02: exact cancelled request remained pending")
            check(!siblingResult.finished && afterCancel?.processID == beforeCancel?.processID
                && afterCancel?.transportClosed == false && afterCancel?.outputEOF == false,
                "ACP task cancellation C03: cancelling one ID settled or closed its pending sibling")
            try siblingClient.notify(method: "fixture/release-sibling")
            guard await reached({ siblingResult.finished }) else { throw FixtureError.timeout }
            await sibling.value
            check(siblingResult.reply == "ok" && siblingResult.error.isEmpty
                && siblingResult.notifications == 1 && siblingResult.completions == 1,
                "ACP task cancellation C04: SAME sibling lost its preceding final notification or response")

            // Explicit actor scheduling cancels this SAME operation before its body starts.
            // The production lock guard separately handles cancellation after the early check.
            let preCancelled = Task { @MainActor in
                do {
                    _ = try await siblingClient.request(method: "fixture/pre-cancel")
                    preCancelledResult.reply = "unexpected response"
                } catch { preCancelledResult.cancelled = error is CancellationError }
                preCancelledResult.completions += 1; preCancelledResult.finished = true
            }
            siblingOperations.append(preCancelled); preCancelled.cancel()
            guard await reached({ preCancelledResult.finished }) else { throw FixtureError.timeout }
            await preCancelled.value
            check(preCancelledResult.cancelled && preCancelledResult.completions == 1
                && !FileManager.default.fileExists(atPath: siblingMarker.appendingPathExtension("pre-cancel").path),
                "ACP task cancellation F03: pre-cancelled operation registered or wrote a request")
            siblingClient.close(); siblingClient.close()
            for operation in siblingOperations { await operation.value }
            check(cancelledResult.completions == 1 && siblingResult.completions == 1
                && preCancelledResult.completions == 1 && siblingClient.currentRuntimeObservation()?.pendingRequestCount == 0,
                "ACP task cancellation C05: close/response/cancel settled an owned request twice")
            SelfTest.diagnostic("ACP_PENDING_CANCEL_TRACE: before=\(beforeCancel?.pendingRequestCount ?? -1) after=\(afterCancel?.pendingRequestCount ?? -1) cancelled=\(cancelledResult.cancelled) siblingCompletions=\(siblingResult.completions) notifications=\(siblingResult.notifications) preCancelled=\(preCancelledResult.cancelled)")
        } catch {
            // No returned tuple/root removal while a retained actual request remains unjoined.
            for operation in siblingOperations { operation.cancel() }
            siblingClient.close()
            for operation in siblingOperations { await operation.value }
            throw error
        }

        // Shared producer's final-response/EOF/explicit-close/short-timeout race.
        // The sleep is harness-only so the existing request timer actually expires;
        // no production timer/timeout is altered or introduced by this regression.
        let marker = safeRoot.appendingPathComponent("rpc-final-consumed.txt")
        let client = try JSONRPCStdioClient(command: AgentStdioFixtures.python,
            arguments: [script.path, "rpc-final", marker.path], directory: safeRoot.path)
        let result = Result()
        let request = Task { @MainActor in
            do {
                let data = try await client.request(method: "fixture/request", timeout: 0.2)
                let payload = try JSONSerialization.jsonObject(with: data) as? [String: Bool]
                result.reply = payload?["ok"] == true ? "ok" : "wrong payload"
            } catch { result.error = error.localizedDescription }
            result.completions += 1
            result.finished = true
        }
        func traceFinalRPC(_ stage: String) {
            let errorKind: String
            switch result.error {
            case "": errorKind = "none"
            case "JSON-RPC fixture/request timed out.": errorKind = "timeout"
            case "The connection ended before a reply arrived.": errorKind = "eof"
            case "Session closed.": errorKind = "closed"
            default: errorKind = "other"
            }
            SelfTest.diagnostic("ACP_FINAL_RPC_TRACE: stage=\(stage) finished=\(result.finished) completions=\(result.completions) replyPresent=\(result.reply != nil) replyOK=\(result.reply == "ok") errorKind=\(errorKind)")
        }
        let finished = await reached { result.finished }
        traceFinalRPC("before-check")
        check(finished && result.reply == "ok" && result.error.isEmpty,
            "ACP terminal: shared transport lost final response/EOF control")
        client.close()
        client.close()
        if await reached({ result.finished }) { await request.value }
        try await Task.sleep(for: .milliseconds(300))
        traceFinalRPC("after-cleanup")
        check(result.completions == 1 && result.reply == "ok",
            "ACP terminal: late timeout/EOF/close completed the same request twice")
        var closedRefused = false
        do { _ = try await client.request(method: "must-not-run", timeout: 0.2) }
        catch { closedRefused = true }
        check(closedRefused && result.completions == 1,
            "ACP terminal: closed shared transport admitted another request")
        check(SelfTestStoreGuard.diff(ownerBefore, SelfTestStoreGuard.take()).isEmpty,
            "ACP terminal: isolated subprocess fixture changed owner store/default")
    }

    private static let peer = """
        import json, pathlib, sys
        mode, marker = sys.argv[1:]
        waiting = None
        sibling = None
        def send(value):
            sys.stdout.write(json.dumps(value) + "\\n")
            sys.stdout.flush()
        for line in sys.stdin:
            msg = json.loads(line)
            mid, method = msg.get("id"), msg.get("method")
            if method == "initialize":
                send({"jsonrpc":"2.0","id":mid,"result":{"protocolVersion":1,"agentCapabilities":{}}})
            elif method == "session/new":
                send({"jsonrpc":"2.0","id":mid,"result":{"sessionId":"fixture-terminal"}})
            elif method == "session/prompt":
                pathlib.Path(marker).write_text("consumed prompt")
                if mode == "pending-exit":
                    break
                if mode == "final-exit":
                    for chunk in ["Final", " fixture", " reply."]:
                        send({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"fixture-terminal",
                              "update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":chunk}}}})
                    send({"jsonrpc":"2.0","id":mid,"result":{"stopReason":"end_turn"}})
                    break
                waiting = mid
            elif method == "session/cancel":
                send({"jsonrpc":"2.0","id":mid,"result":{}})
                if mode == "task-cancel":
                    pathlib.Path(marker + ".cancel-ack").write_text("cancel acknowledged")
                elif waiting is not None:
                    send({"jsonrpc":"2.0","id":waiting,"result":{"stopReason":"cancelled"}})
                    waiting = None
            elif method == "fixture/held":
                waiting = mid
                pathlib.Path(marker).write_text("consumed held request")
            elif method == "fixture/sibling":
                sibling = mid
                pathlib.Path(marker + ".sibling").write_text("consumed sibling request")
            elif method == "fixture/release-sibling":
                assert sibling is not None
                send({"jsonrpc":"2.0","method":"fixture/notice","params":{"text":"Owned sibling notice"}})
                send({"jsonrpc":"2.0","id":sibling,"result":{"ok":True}})
                sibling = None
            elif method == "fixture/pre-cancel":
                pathlib.Path(marker + ".pre-cancel").write_text("consumed pre-cancel request")
                send({"jsonrpc":"2.0","id":mid,"result":{}})
            elif method == "fixture/request":
                pathlib.Path(marker).write_text("consumed request")
                send({"jsonrpc":"2.0","id":mid,"result":{"ok":True}})
                break
        """
}

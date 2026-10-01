import Foundation

/// Extra legs of the existing real Chromium --selftest-cdp fixture. The target is the
/// harness's temporary HTML page/profile. Only setup/readback uses the fixture socket;
/// every measured action goes through the production BrowserCDPClient.run.
enum BrowserActionValiditySelfTest {
    @MainActor
    static func failures(host: String, port: Int, target: BrowserCDPTarget) async -> [String] {
        guard SelfTest.isRunning else { return ["CU fixture refused outside the self-test harness"] }
        var failures: [String] = []
        func check(_ name: String, _ pass: Bool) {
            print("CU_ACTION_CHECK: \(name) \(pass ? "PASS" : "FAIL")")
            if !pass { failures.append(name) }
        }
        guard let snapshot = AgentToolRegistry.shared.tool(named: "browser.snapshot"),
              let click = AgentToolRegistry.shared.tool(named: "browser.click"),
              let fill = AgentToolRegistry.shared.tool(named: "browser.fill") else {
            return ["CU fixture tools absent"]
        }
        func setup(_ body: String) async throws {
            HumanInputWatch.resetForNewTurn()
            BrowserCDPClient.removeSnapshotCache(for: target)
            _ = try await fixtureEvaluate("""
                (() => {
                  window.cuA = 0; window.cuB = 0;
                  document.body.innerHTML = \(BrowserCDPClient.jsonStringLiteral(body));
                  return 'ready';
                })()
                """, target: target)
        }
        func observe() async throws {
            _ = try await BrowserCDPClient.run(snapshot, arguments: ["targetId": target.id], host: host, port: port)
        }
        func action(_ requestedTool: AgentTool? = nil, extra: [String: String] = [:]) async throws -> AgentToolResult {
            let tool = requestedTool ?? click
            var args = ["targetId": target.id, "id": "1", "_authorizedPageURL": target.url]
            args.merge(extra) { _, supplied in supplied }
            return try await BrowserCDPClient.run(tool, arguments: args, host: host, port: port)
        }
        func counts() async throws -> String {
            try await fixtureEvaluate("JSON.stringify([window.cuA,window.cuB])", target: target)
        }
        defer { HumanInputWatch.stop(); BrowserCDPClient.removeSnapshotCache(for: target) }
        var axCalls = 0
        let axUnknown = try? VerifyRetry.run(
            risk: .modify, title: "Observed button", expected: "Completed", observed: { "Unchanged window" }, reinspect: {},
            act: {
                axCalls += 1
                return .init(summary: "Posted press", verification: axCalls >= 2 ? "Completed" : nil)
            }
        )
        print("CU_AX_UNVERIFIED_ATTEMPTS: \(axCalls)")
        check("the AX producer seam never replays an unverified press", axCalls == 1 && axUnknown?.attempts.count == 1)
        do {
            // ACK says the handler ran. A missing postcondition must not fire it again.
            try await setup("<button onclick='window.cuA++'>Toggle</button>")
            try await observe()
            let uncertain = try await action(extra: ["expectedText": "Never appears"])
            let uncertainCount = try await counts()
            print("CU_ACK_UNVERIFIED_COUNT: \(uncertainCount)")
            check("acknowledged unverified click fires exactly once", uncertainCount == "[1,0]")
            check("unverified click says the result could not be confirmed", uncertain.verification == nil
                  && uncertain.summary.localizedCaseInsensitiveContains("could not confirm"))

            try await setup("<button onclick='window.cuA++'>Same control</button>")
            try await observe()
            _ = try await action()
            let replay = try await action()
            let replayCount = try await counts()
            check("one observed decision cannot be delivered again without a fresh snapshot", replayCount == "[1,0]" && replay.summary.contains("No snapshot"))

            // Re-rendering after a delivered click must never hit the new occupant.
            try await setup("<button id='a' onclick='window.cuA++;this.parentNode.appendChild(this)'>First</button><button id='b' onclick='window.cuB++'>Second</button>")
            try await observe()
            _ = try await action(extra: ["expectedText": "Never appears"])
            let reorderedCount = try await counts()
            check("a click never repeats on a reordered control", reorderedCount == "[1,0]")

            // Two same-label controls expose why label/index equality is not identity.
            try await setup("<button id='a' onclick='window.cuA++'>Same</button><button id='b' onclick='window.cuB++'>Same</button>")
            try await observe()
            _ = try await fixtureEvaluate("document.body.appendChild(document.getElementById('a')); 'reordered'", target: target)
            let stale = try await action()
            let duplicateCount = try await counts()
            check("duplicate labels cannot retarget a cached control", duplicateCount == "[0,0]" && stale.verification == nil)

            try await setup("<button id='a' onclick='window.cuA++'>Same</button>")
            try await observe()
            _ = try await fixtureEvaluate("document.getElementById('a').outerHTML='<button onclick=\"window.cuB++\">Same</button>'; 'replaced'", target: target)
            _ = try await action()
            let replacedCount = try await counts()
            check("a same-label replacement never inherits a captured node's identity", replacedCount == "[0,0]")

            // The actual production backing must notice a person before posting.
            try await setup("<button onclick='window.cuA++'>Stable</button>")
            try await observe()
            HumanInputWatch.notePauseForTesting(at: Date())
            let yielded = try await action()
            let yieldedCount = try await counts()
            check("CDP yields before a posted action", yieldedCount == "[0,0]" && yielded.summary == HumanInputWatch.pausedSentence)

            try await setup("<button onclick='window.cuA++'>Stable</button>")
            try await observe()
            let touch = Task { @MainActor in
                await Task.yield()
                HumanInputWatch.notePauseForTesting(at: Date())
            }
            let interrupted = try await action()
            await touch.value
            let interruptedCount = try await counts()
            check("CDP rechecks human input after async inspection", interruptedCount == "[0,0]" && interrupted.summary == HumanInputWatch.pausedSentence)

            // A stable button still fires once and observes its stated postcondition.
            try await setup("<button onclick='window.cuA++;this.textContent=\"Completed\"'>Stable</button>")
            try await observe()
            let began = ContinuousClock.now
            let stable = try await action(extra: ["expectedText": "Completed"])
            print("CU_STABLE_CLICK_MS: \(Double(began.duration(to: .now).components.attoseconds) / 1e15 + Double(began.duration(to: .now).components.seconds) * 1000)")
            let stableCount = try await counts()
            check("stable bound control receives one verified action", stableCount == "[1,0]" && stable.verification != nil)

            var actionTimes: [Double] = []
            var observationTimes: [Double] = []
            for _ in 0..<10 {
                try await setup("<button onclick='window.cuA++;this.textContent=\"Completed\"'>Stable</button>")
                let observingAt = ContinuousClock.now
                try await observe()
                let actingAt = ContinuousClock.now
                let measured = try await action(extra: ["expectedText": "Completed"])
                let ended = ContinuousClock.now
                func ms(_ duration: Duration) -> Double {
                    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
                }
                actionTimes.append(ms(actingAt.duration(to: ended)))
                observationTimes.append(ms(observingAt.duration(to: ended)))
                if measured.verification == nil { failures.append("stable latency sample lacked a verified effect") }
            }
            for (name, values) in [("action", actionTimes), ("snapshot_to_action", observationTimes)] {
                let sorted = values.sorted()
                print("CU_LATENCY_MS: \(name) samples=\(sorted) p50=\(sorted[sorted.count / 2]) p95=\(sorted.last ?? 0)")
            }

            // Fill uses the same bound identity and does not type into a changed secret.
            try await setup("<input id='a' value='Name'><input id='b' value='Name'>")
            try await observe()
            _ = try await fixtureEvaluate("document.body.appendChild(document.getElementById('a')); 'reordered'", target: target)
            _ = try await action(fill, extra: ["text": "Changed"])
            let values = try await fixtureEvaluate("JSON.stringify([...document.querySelectorAll('input')].map(x=>x.value))", target: target)
            check("fill cannot retarget a duplicate-label input", values == "[\"Name\",\"Name\"]")
        } catch { failures.append("CU production-client fixture: \(error.localizedDescription)") }
        return failures
    }

    private static func fixtureEvaluate(_ expression: String, target: BrowserCDPTarget) async throws -> String {
        guard let url = URL(string: target.webSocketDebuggerURL) else { throw URLError(.badURL) }
        let session = URLSession(configuration: .ephemeral)
        let socket = session.webSocketTask(with: url)
        socket.resume()
        defer { socket.cancel(with: .goingAway, reason: nil); session.invalidateAndCancel() }
        let data = BrowserCDPClient.encode(method: "Runtime.evaluate", params: ["expression": expression, "returnByValue": true], id: 42)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
        let message = await withBoundedWait(.seconds(4)) { try? await socket.receive() }
        guard let message = message ?? nil else { throw URLError(.timedOut) }
        let raw: Data
        switch message {
        case .data(let value): raw = value
        case .string(let value): raw = Data(value.utf8)
        @unknown default: throw URLError(.cannotParseResponse)
        }
        guard let envelope = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let result = envelope["result"] as? [String: Any],
              let inner = result["result"] as? [String: Any], let value = inner["value"] else {
            throw URLError(.cannotParseResponse)
        }
        return String(describing: value)
    }
}

import Foundation

/// SAME Manager -> LocalBackend -> Executor -> real temporary read and actual recorder
/// wrapper, with a scripted provider inserted ONLY at the existing external-effect seam.
/// ACP separately exercises its production direct-row writer and an owned stdio peer.
/// This qualifies attribution/projection, not a normal knowledge-tool/model route.
@MainActor
enum TaskUsageProjectionSelfTest {
    private enum InputError: Error { case invalid, timeout }
    private struct ScriptedFailure: LocalizedError {
        var errorDescription: String? {
            #"Could not answer "usage-private-objective" at /fixture/usage-private-file.txt with "usage-private-argument""#
        }
    }
    private struct Provider: LLMProvider {
        let id = LLMProviderID.appLLM
        let displayModelName = "Task Usage Fixture"
        var contextTokens: Int { 4_096 }
        var unavailableReason: String? { get async { nil } }
        var fails = false
        var prompt = 11
        var completion = 7
        func countTokens(_ text: String) async throws -> Int { text.count / 4 }
        func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
            LLMCompletion(text: "Fixture answer", generatedTokens: completion, duration: 0)
        }
        func stream(system: String, user: String, maxTokens: Int) async -> AsyncThrowingStream<String, Error> {
            ModelPassRecorder.current?.report(promptTokens: prompt, cachedTokens: 3,
                completionTokens: completion, reasoningTokens: 2, finishReason: nil, estimated: false)
            return AsyncThrowingStream { continuation in
                if fails { continuation.finish(throwing: ScriptedFailure()) }
                else { continuation.yield("usage-private-reply"); continuation.finish() }
            }
        }
    }

    static func problems(root: URL) async -> [String] {
        guard SelfTest.isRunning else { return ["C00 harness required"] }
        var failures: [String] = []
        var checks = 0
        func check(_ condition: Bool, _ label: String) {
            checks += 1
            if !condition { failures.append(label) }
        }
        let oldFire = AgentToolExecutor.fireOverrideForTesting
        let oldFake = AgentToolExecutor.fakeForTesting
        let oldPolicy = AgentToolExecutor.policyOverrideForTesting
        defer {
            AgentToolExecutor.fireOverrideForTesting = oldFire
            AgentToolExecutor.fakeForTesting = oldFake
            AgentToolExecutor.policyOverrideForTesting = oldPolicy
        }
        let directory = root.appendingPathComponent("task-projection", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let input = directory.appendingPathComponent("usage-private-file.txt")
            let contents = "usage-private-file-content"
            try contents.write(to: input, atomically: true, encoding: .utf8)
            let log = UsageLog.shared // Existing harness-only store, never the owner's log.
            let beforeIDs = Set(log.load().map(\.id))
            let sql = TaskStore(root: directory)
            defer { sql.close() }
            let receipts = ActionReceiptStore(fileURL: directory.appendingPathComponent("action-receipts.json"))
            let store = AgentTaskStore(fileURL: directory.appendingPathComponent("agent-tasks.json"), mirror: sql)
            guard store.allowsHarnessPersistence else { throw InputError.invalid }
            let manager = AgentTaskManager(store: store, receiptStore: receipts)
            let turn = UUID()
            let schedule = UUID()
            var entered: [String] = []
            var exited = 0
            manager.backendEntryForTesting = { entered.append(TaskEventJournal.current?.taskID ?? "missing") }
            manager.backendExitForTesting = { exited += 1 }
            var effects = 0
            var calls = 0
            AgentToolExecutor.fakeForTesting = nil
            AgentToolExecutor.policyOverrideForTesting = .selfTest
            AgentToolExecutor.fireOverrideForTesting = { tool, arguments in
                guard tool.id == "filesystem.read", arguments == ["path": input.path],
                      TaskEventJournal.current?.taskID != nil else { throw InputError.invalid }
                effects += 1
                let passes = effects == 1 ? 2 : 1
                for number in 0..<passes {
                    calls += 1
                    let provider = Provider(fails: passes == 2 && number == 1,
                        prompt: passes == 2 ? 11 : 13, completion: passes == 2 ? 7 : 5)
                    let model = ProviderKnowledgeAnswerModel(provider: provider)
                    let stream = await model.stream(system: "usage-private-objective",
                        user: "usage-private-argument " + input.path, maxTokens: 64)
                    do { for try await _ in stream {} }
                    catch {
                        guard provider.fails, error is ScriptedFailure else { throw error }
                    }
                }
                return try FilesystemExecutor.run(tool, arguments: arguments)
            }
            let a = ModelPassRecorder.$correlation.withValue(UsageCorrelation(turnID: turn, scheduleID: schedule)) {
                manager.submit(objective: "usage-private-objective", tool: "filesystem.read",
                    arguments: ["path": input.path], source: "selftest")
            }
            guard await reached({ exited == 1 }) else { manager.cancel(a.id); throw InputError.timeout }
            let b = manager.submit(objective: "usage-private-argument", tool: "filesystem.read",
                arguments: ["path": input.path], source: "selftest")
            guard await reached({ exited == 2 }) else { manager.cancel(b.id); throw InputError.timeout }
            log.flush()
            let generated = log.load().filter { !beforeIDs.contains($0.id) }
            let modelRows = generated.filter { $0.modelID == "Task Usage Fixture" }
            check(effects == 2 && calls == 3 && entered == [a.id, b.id], "C01 real task/backing/model entry counts")
            check(manager.task(id: a.id)?.status == .completed && manager.task(id: b.id)?.status == .completed
                && manager.task(id: a.id)?.result?.contains(contents) == true
                && manager.task(id: b.id)?.result?.contains(contents) == true, "C02 real file result delivered to both tasks")
            check(modelRows.count == 3 && modelRows.filter { $0.finishReason == "error" }.count == 1
                && modelRows.filter { $0.errorClass != nil }.count == 1, "C03 actual wrapper wrote success and failure once")
            check(modelRows.filter { $0.turnID == turn && $0.scheduleID == schedule }.count == 2
                && modelRows.filter { $0.turnID == nil && $0.scheduleID == nil }.count == 1,
                "C04 worker scope preserves parent correlation without leaking to next task")
            check(modelRows.filter { $0.taskID == a.id }.count == 2
                && modelRows.filter { $0.taskID == b.id }.count == 1, "F01 actual model rows lack exact A/B task attribution")
            let summaryA = UsageSummary.task(rows: generated, taskID: a.id)
            let summaryB = UsageSummary.task(rows: generated, taskID: b.id)
            check(summaryA.passes == 2 && summaryA.promptTokens == 22 && summaryA.completionTokens == 14
                && summaryA.totalTokens == 36 && summaryA.cachedTokens == 6
                && summaryA.reasoningTokens == 4 && summaryA.countsEstimated == false,
                "F02 actual task A consumer lacks exact retained token projection")
            check(summaryB.passes == 1 && summaryB.totalTokens == 18,
                "F03 actual task B consumer includes another task or lacks rows")
            check(summaryA.cost == nil && summaryB.cost == nil
                && UsageSummary.task(rows: generated, taskID: UUID().uuidString).totalTokens == nil,
                "C05 no price invented and unknown task absent")
            let selected = generated.filter { UsageReport.matches($0, feature: "task.") }
            let report = UsageReport.lines(for: generated, files: 1, since: .distantPast, feature: "task.")
            check(selected.count == 3 && report.last?.contains("rows=3") == true
                && report.contains("USAGE_TASK_ROW task=\(a.id) passes=2 prompt_tokens=22 completion_tokens=14 total_tokens=36 cost=- coverage=retained")
                && report.contains("USAGE_TASK_ROW task=\(b.id) passes=1 prompt_tokens=13 completion_tokens=5 total_tokens=18 cost=- coverage=retained"), "F04 existing task. report filter misses actual worker rows")
            check(modelRows.allSatisfy { $0.feature == UsageFeature.knowledgeAsk.rawValue }
                && generated.filter { UsageReport.matches($0, feature: "knowledge.") }.count == 3,
                "C06 actual feature identity and existing report prefix preserved")
            let encoded = try JSONEncoder().encode(generated)
            let text = String(decoding: encoded, as: UTF8.self)
            check(["usage-private-objective", "usage-private-argument", "usage-private-file", contents,
                "usage-private-reply", input.path].allSatisfy { !text.contains($0) }, "C07 objective/arguments/file/reply leaked to log")
            check(modelRows.first { $0.errorClass != nil }?.errorMessage == UsageLog.sanitise(ScriptedFailure().localizedDescription),
                "C08 existing error sanitiser bypassed")
            check(try sql.load().map(\.id) == manager.tasks.map(\.id)
                && receipts.receipts.count == 2 && receipts.receipts.allSatisfy { $0.status == .completed },
                "C09 same primary and real receipt lifecycle preserved")

            // Rejected primary start must not invent a model pass or enter backing.
            try sql.withConnection { db in
                try TaskStore.exec(db, "CREATE TRIGGER refuse_usage_start BEFORE UPDATE ON task WHEN NEW.state='running' BEGIN SELECT RAISE(ABORT,'fixture refusal'); END")
            }
            let rejected = manager.submit(objective: "usage-private-objective rejected", tool: "filesystem.read",
                arguments: ["path": input.path], source: "selftest")
            guard await reached({ manager.task(id: rejected.id)?.status == .failed }) else { throw InputError.timeout }
            log.flush()
            check(effects == 2 && exited == 2 && manager.backendStartsForTesting == 2
                && log.load().filter { !beforeIDs.contains($0.id) }.count == 3,
                "C10 rejected primary start entered model/backing or fabricated usage")
            let absent = UsageSummary.task(rows: log.load(), taskID: rejected.id)
            check(absent.passes == 0 && absent.totalTokens == nil && absent.cost == nil,
                "C11 absent rows became zero cost/tokens or effect certainty")
            try sql.withConnection { try TaskStore.exec($0, "DROP TRIGGER refuse_usage_start") }
            AgentToolExecutor.fireOverrideForTesting = nil
            try await acp(root: directory, check: check)
            try codec(root: directory, row: modelRows.first, check: check)
            SelfTest.diagnostic("TASK_USAGE_TRACE: checks=\(checks) modelRows=\(modelRows.count) effects=\(effects) taskA=\(summaryA.passes) taskB=\(summaryB.passes) costUnavailable=true")
        } catch { failures.append("C99 fixture input/cleanup failed: \(error)") }
        return failures
    }

    private static func reached(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(8))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            await Task.yield()
        }
        return false
    }

    private static func acp(root: URL, check: (Bool, String) -> Void) async throws {
        for mode in ["accepted", "failed"] {
            let directory = root.appendingPathComponent(mode, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let sql = TaskStore(root: directory)
            defer { sql.close() }
            let receipts = ActionReceiptStore(fileURL: directory.appendingPathComponent("action-receipts.json"))
            let manager = AgentTaskManager(store: AgentTaskStore(fileURL: directory.appendingPathComponent("agent-tasks.json"), mirror: sql), receiptStore: receipts)
            let peerFile = directory.appendingPathComponent("peer.py")
            try peer.write(to: peerFile, atomically: true, encoding: .utf8)
            let log = UsageLog.shared
            let prior = Set(log.load().map(\.id))
            var exited = false
            manager.backendExitForTesting = { exited = true }
            manager.backendEntryForTesting = {
                guard let context = TaskEventJournal.current, context.attempt == 1 else { throw InputError.invalid }
                let config: [String: Any] = ["taskID": context.taskID, "mode": mode,
                    "attempt": context.attempt, "owner": context.leaseOwner ?? "missing"]
                try JSONSerialization.data(withJSONObject: config).write(to: directory.appendingPathComponent("config.json"))
            }
            let submitted = manager.submit(objective: "usage-private-objective", arguments: ["acpFixture": peerFile.path], backend: .acp, source: "selftest")
            guard await reached({ exited }) else {
                manager.cancel(submitted.id)
                _ = await reached { exited }
                SelfTest.diagnostic("TASK_USAGE_PEER_STDERR: " + ((try? String(contentsOf: directory.appendingPathComponent("stderr.txt"), encoding: .utf8)) ?? "missing"))
                throw InputError.timeout
            }
            log.flush()
            let rows = log.load().filter { !prior.contains($0.id) }
            let row = rows.first
            let calls = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("calls.json"))) as? [String]
            check(try calls == ["initialize", "session/new", "session/prompt"]
                && String(contentsOf: directory.appendingPathComponent("stderr.txt"), encoding: .utf8).isEmpty,
                "C12 \(mode) real owned ACP peer protocol or stderr")
            check(manager.task(id: submitted.id)?.status == (mode == "accepted" ? .completed : .failed)
                && manager.backendStartsForTesting == 1 && receipts.receipts.count == 1,
                "C13 \(mode) actual ACP task/receipt outcome")
            check(rows.count == 1 && row?.provider == UsageProvider.acp.rawValue
                && row?.feature == UsageFeature.agentHandoff.rawValue && row?.promptTokens == nil
                && row?.completionTokens == nil && row?.finishReason == (mode == "accepted" ? "stop" : "error"),
                "C14 \(mode) real ACP direct-row writer counts/provenance")
            check(row?.taskID == submitted.id, "F05 \(mode) production ACP handoff lacks exact task ID")
            let summary = UsageSummary.task(rows: rows, taskID: submitted.id)
            let report = UsageReport.lines(for: rows, files: 1, since: .distantPast, feature: "task.")
            check(summary.passes == 1 && summary.totalTokens == nil && summary.countsEstimated == nil
                && report.contains("USAGE_TASK_ROW task=\(submitted.id) passes=1 prompt_tokens=- completion_tokens=- total_tokens=- cost=- coverage=retained"),
                "F06 \(mode) tokenless ACP task projection fabricated zero or lost row")
            check(try summary.cost == nil
                && !String(decoding: JSONEncoder().encode(rows), as: UTF8.self).contains("usage-private"),
                "C15 \(mode) ACP private prompt or invented price")
            SelfTest.diagnostic("TASK_USAGE_ACP_TRACE: mode=\(mode) rows=\(rows.count) attributed=\(row?.taskID == submitted.id) peer=true costUnavailable=true")
        }
    }

    private static func codec(root: URL, row: UsageRecord?, check: (Bool, String) -> Void) throws {
        guard var row else { throw InputError.invalid }
        let directory = root.appendingPathComponent("codec", isDirectory: true)
        let log = UsageLog(directory: directory)
        row.taskID = "usage-private-objective /fixture/usage-private-file.txt"
        log.record(row)
        log.flush()
        let bytes = try Data(contentsOf: log.fileURL)
        check(log.load().first?.taskID == nil && !String(decoding: bytes, as: UTF8.self).contains("usage-private"),
            "C16 direct invalid ID writer leaked or manufactured attribution")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        var object = try JSONSerialization.jsonObject(with: encoder.encode(row)) as! [String: Any]
        object.removeValue(forKey: "taskID")
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        check(try decoder.decode(UsageRecord.self, from: legacy).taskID == nil, "C17 old usage row without taskID failed decode")
        object["taskID"] = "usage-private-objective"
        let invalid = try JSONSerialization.data(withJSONObject: object) + Data([0x0A])
        try invalid.write(to: log.fileURL)
        check(try log.load().first?.taskID == nil && Data(contentsOf: log.fileURL) == invalid,
            "C18 invalid persisted ID projected or read rewrote source")
        let identity = UUID().uuidString.lowercased()
        row.taskID = identity
        row.promptTokens = nil
        let unknown = UsageSummary.task(rows: [row], taskID: identity)
        check(unknown.passes == 1 && unknown.promptTokens == nil && unknown.totalTokens == nil
            && unknown.cost == nil, "C19 partial counts converted to zero or price")
        row.promptTokens = Int.max; row.completionTokens = 1
        let overflow = UsageSummary.task(rows: [row], taskID: identity)
        check(overflow.promptTokens == Int.max && overflow.totalTokens == nil,
            "C20 corrupt/overflow count trapped or fabricated total")
        row.promptTokens = -1
        check(UsageSummary.task(rows: [row], taskID: identity).promptTokens == nil,
            "C21 negative provider counts admitted to sum")
        row.promptTokens = 1; row.completionTokens = 2
        log.clear(); log.flush(); log.record(row); log.flush()
        check(log.load().first?.taskID == identity && UsageSummary.task(rows: log.load(), taskID: identity).totalTokens == 3,
            "C22 valid exact UUID spelling lost at writer/read consumer")
        check(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)) == [UsageLog.fileName],
            "C23 task usage created second ledger/file")
        check(UsageReport.lines(for: [], files: 0, since: .distantPast) == ["USAGE_REPORT_EMPTY"],
            "C24 empty report invented a pass")
    }

    private static let peer = #"""
    import json, pathlib, sys
    root = pathlib.Path(__file__).resolve().parent
    sys.stderr = (root / "stderr.txt").open("w", buffering=1)
    config = json.loads((root / "config.json").read_text())
    calls = []
    def send(value):
        print(json.dumps(value), flush=True)
    for line in sys.stdin:
        message = json.loads(line)
        method, mid = message.get("method"), message.get("id")
        calls.append(method)
        (root / "calls.json").write_text(json.dumps(calls))
        if method == "initialize":
            send({"jsonrpc":"2.0", "id":mid, "result":{"protocolVersion":1,"agentCapabilities":{}}})
        elif method == "session/new":
            send({"jsonrpc":"2.0", "id":mid, "result":{"sessionId":"usage-fixture"}})
        elif method == "session/prompt":
            assert message["params"]["prompt"] == [{"type":"text", "text":"usage-private-objective"}]
            receipts = json.loads((root / "action-receipts.json").read_text())
            assert len(receipts) == 1
            assert receipts[0]["taskID"] == config["taskID"]
            assert receipts[0]["taskAttempt"] == config["attempt"] == 1
            assert receipts[0]["taskLeaseOwner"] == config["owner"]
            assert receipts[0]["status"] == "fired"
            if config["mode"] == "failed":
                send({"jsonrpc":"2.0", "id":mid, "error":{"code":-32000,"message":"Failure with \"usage-private-objective\" at /fixture/usage-private-file.txt"}})
            else:
                send({"jsonrpc":"2.0", "method":"session/update", "params":{"sessionId":"usage-fixture","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Fixture finished"}}}})
                send({"jsonrpc":"2.0", "id":mid, "result":{"stopReason":"end_turn"}})
        elif mid is not None:
            send({"jsonrpc":"2.0", "id":mid, "result":{}})
    """#
}

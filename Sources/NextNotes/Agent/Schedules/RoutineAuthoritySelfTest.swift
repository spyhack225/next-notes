import Foundation

/// `--selftest-routine-authority`: what an unattended routine may do (Part 3, *Authority when
/// nobody is there*).
///
/// A real `ScheduledRunner` and the real `ActionOrchestrator`, driven by a scripted model and
/// a fake read executor. It checks that a scheduled run reads, drafts a write without
/// executing it, never waits on `PermissionGate`, stops at its time and tool-call budgets,
/// refuses tools outside its ceiling and any schedule tool, stays silent on
/// `NOTHING_TO_REPORT`, skips with a reason when no model can run, audits with the schedule
/// id, and that approving a draft is user authority while a scheduled ACP task is refused.
///
/// No model, network, microphone, notification center or account. Every store lives in a
/// temporary directory; the user's schedules, tasks, receipts and audit log are never read or
/// written.
@MainActor
enum RoutineAuthoritySelfTest {
    static func run() async -> Bool {
        var failures: [String] = []
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NextNotesSelfTest-routine-authority-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: ScheduleStore.shared.directory)
        }
        if ScheduleStore.shared.directory.path.hasPrefix(AppIdentity.applicationSupportDirectory.path) {
            failures.append("isolation: the shared schedule store is the user's")
        }

        failures += routerFailures()
        failures += await runFailures(root: root)
        failures += await budgetFailures(root: root)
        failures += await orchestratorFailures()
        failures += await approvalFailures(root: root)
        failures += await acpFailures()

        for failure in failures { print("ROUTINE_AUTHORITY_CHECK_FAILED: \(failure)") }
        print(failures.isEmpty ? "ROUTINE_AUTHORITY_OK" : "ROUTINE_AUTHORITY_FAILED")
        return failures.isEmpty
    }

    // MARK: - Fixtures

    static let scheduleID = UUID()

    static func routine(tools: [String], budget: AgentSchedule.Budget = .standard,
                        model: AgentSchedule.ModelChoice = .auto, id: UUID = scheduleID) -> AgentSchedule {
        AgentSchedule(
            id: id, kind: .routine, title: "Inbox check",
            plainEnglish: "Every weekday at 08:00, I'll check my inbox.",
            prompt: "Look for emails from Sam today. If one needs a reply, draft it.",
            when: ScheduleWhen(repeatRule: .weekdays, time: ScheduleLocalTime(hour: 8, minute: 0),
                               timeZone: "America/New_York"),
            allowedTools: tools, model: model, budget: budget,
            createdAt: Date(timeIntervalSince1970: 1_790_000_000))
    }

    nonisolated static func call(_ name: String, _ arguments: [String: String] = [:]) -> String {
        let data = try? JSONSerialization.data(withJSONObject: ["name": name, "arguments": arguments, "rationale": "step"],
                                               options: [.sortedKeys])
        return "<tool_call>\(String(data: data ?? Data(), encoding: .utf8) ?? "")</tool_call>"
    }

    static func makeRunner(store: ScheduleStore, environment: FakeRunEnvironment,
                           tools: FakeToolRunner, recorder: FakeRecorder) -> ScheduledRunner {
        ScheduledRunner(store: store, environment: environment, tools: tools, recorder: recorder,
                        timeZone: { TimeZone(identifier: "America/New_York")! })
    }

    // MARK: - Model routing

    private static func routerFailures() -> [String] {
        var failures: [String] = []
        func expect(_ name: String, _ route: RoutineModelRoute, _ wanted: RoutineModelRoute) {
            if route != wanted { failures.append("router: \(name) gave \(route), wanted \(wanted)") }
        }
        let route = RoutineModelRouter.route
        expect("auto, Qwen idle", route(.auto, false, .idle(seconds: 5), true), .local)
        expect("auto, Qwen loadable", route(.auto, false, .notLoaded, false), .local)
        expect("auto, Qwen busy, cloud", route(.auto, false, .busy, true), .cloud)
        expect("auto, Qwen busy, no cloud", route(.auto, false, .busy, false), .skip("local model busy"))
        expect("auto, no Qwen, no cloud", route(.auto, false, .unavailable, false), .skip("Qwen isn't downloaded"))
        expect("local, busy", route(.local, false, .busy, true), .skip("local model busy"))
        expect("cloud, not set up", route(.cloud, false, .idle(seconds: 99), false), .skip("OpenRouter isn't set up"))
        expect("cloud", route(.cloud, false, .busy, true), .cloud)
        if case .skip = route(.cloud, true, .idle(seconds: 99), true) {} else {
            failures.append("router: a routine ran while recording")
        }
        return failures
    }

    // MARK: - Reads run, writes draft, nothing waits

    private static func runFailures(root: URL) async -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append("run: \(name)") }
        }
        let store = ScheduleStore(directory: root.appendingPathComponent("run", isDirectory: true))
        let environment = FakeRunEnvironment()
        let tools = FakeToolRunner()
        let recorder = FakeRecorder()
        let runner = makeRunner(store: store, environment: environment, tools: tools, recorder: recorder)
        let gateAsks = PermissionGate.shared.askCount
        let schedule = routine(tools: ["search_email", "draft_email", "send_email"])
        store.save(schedule)

        // Read, then a send: the read runs under `.scheduled`, the send becomes a draft.
        var systemSeen = ""
        environment.model = ScriptedMemoryReviewModel { system, user in
            if user.contains("search_email returned") {
                return call("send_email", ["to": "sam@example.com", "subject": "Re: invoice", "body": "Paid today."])
            }
            return call("search_email", ["query": "from:sam newer_than:1d"])
        }
        environment.systemSink = { systemSeen = $0 }
        let outcome = await runner.run(schedule, now: Date())
        print("ROUTINE_AUTHORITY run -> \(outcome.status.rawValue): \(outcome.text)")
        check("the run did not report its draft", outcome.status == .reported && outcome.text.contains("approval"))
        check("the read did not run once under scheduled authority",
              tools.reads.map(\.0) == ["search_email"] && tools.reads.first?.1 == .scheduled(schedule.id))
        check("the send was executed or read", !tools.reads.contains { $0.0 == "send_email" } && tools.executedWrites == 0)
        check("no draft was saved", outcome.drafts.count == 1 && store.awaitingDrafts.count == 1
              && store.awaitingDrafts.first?.toolID == "send_email"
              && store.awaitingDrafts.first?.arguments["to"] == "sam@example.com")
        let receipt = outcome.drafts.first.flatMap { ActionReceiptStore.shared.receipt(for: $0.receiptID) }
        check("the draft's receipt is not waitingPermission under scheduled authority",
              receipt?.status == .waitingPermission && receipt?.authority == .scheduled(schedule.id)
                && receipt?.source == .scheduled && receipt?.preparedAction?.executionPlan.toolID == "send_email"
                && receipt?.events.contains { $0.stage == .fired } == false)
        check("the run waited on PermissionGate", PermissionGate.shared.askCount == gateAsks
              && PermissionGate.shared.pending == nil)
        check("the task is not a fresh scheduled task with the schedule id",
              recorder.begun.count == 1 && recorder.begun.first?.source == "scheduled"
                && recorder.begun.first?.scheduleID == schedule.id
                && recorder.finished.first?.1 == .completed)
        check("an audit entry lacks the schedule id",
              !recorder.audits.isEmpty && recorder.audits.allSatisfy { $0.scheduleID == schedule.id })
        check("the draft was not audited", recorder.audits.contains { $0.kind == .permission && $0.title.contains("Draft") })
        check("the prompt carries a conversation or lacks the silence token",
              systemSeen.contains(ScheduledRunner.silenceToken) && !systemSeen.contains("Earlier Agent conversation")
                && systemSeen.contains("search_email") && !systemSeen.contains("schedule.create"))
        check("the model was asked again after the draft", environment.completions == 2)

        // Outside the ceiling, and schedule tools even when listed: refused and recorded.
        let sneaky = routine(tools: ["search_email", "schedule.create"], id: UUID())
        store.save(sneaky)
        tools.reads = []
        environment.completions = 0
        environment.model = ScriptedMemoryReviewModel { _, user in
            if user.contains("schedule.create returned") { return "Done." }
            if user.contains("filesystem.write returned") {
                return call("schedule.create", ["kind": "routine", "title": "More", "text": "x", "repeat": "daily", "time": "9:00"])
            }
            return call("filesystem.write", ["path": "/tmp/x", "content": "y"])
        }
        let refused = await runner.run(sneaky, now: Date())
        print("ROUTINE_AUTHORITY refusals -> \(refused.refusals)")
        check("a tool outside the ceiling or a schedule tool was not refused with reasons",
              refused.refusals.count == 2
                && refused.refusals[0].contains("not one of this routine's allowed tools")
                && refused.refusals[1].contains("cannot create or change schedules"))
        check("a refused tool ran or drafted", tools.reads.isEmpty && refused.drafts.isEmpty)
        check("refusals were not audited", recorder.audits.filter { $0.kind == .permission && $0.title.hasPrefix("Refused") }.count == 2)

        // Silence.
        environment.model = ScriptedMemoryReviewModel { _, _ in ScheduledRunner.silenceToken }
        let silent = await runner.run(schedule, now: Date())
        check("NOTHING_TO_REPORT was not silent", silent.status == .nothingToReport && silent.text.isEmpty)

        // No model can run: skipped with a reason, nothing started.
        environment.recording = true
        let begunBefore = recorder.begun.count
        environment.completions = 0
        let skipped = await runner.run(schedule, now: Date())
        check("a run while recording was not skipped with a reason",
              skipped.status == .skipped && skipped.text.contains("recording")
                && recorder.begun.count == begunBefore && environment.completions == 0)
        environment.recording = false
        environment.local = .busy
        environment.cloud = false
        let busy = await runner.run(schedule, now: Date())
        check("busy local model with no cloud not skipped as local model busy",
              busy.status == .skipped && busy.text == "local model busy")
        environment.local = .idle(seconds: 120)
        return failures
    }

    // MARK: - Budgets: never hangs

    private static func budgetFailures(root: URL) async -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append("budget: \(name)") }
        }
        let store = ScheduleStore(directory: root.appendingPathComponent("budget", isDirectory: true))
        let environment = FakeRunEnvironment()
        let tools = FakeToolRunner()
        let recorder = FakeRecorder()
        let runner = makeRunner(store: store, environment: environment, tools: tools, recorder: recorder)

        // A model that never answers: the run ends at its time budget.
        environment.model = ScriptedMemoryReviewModel(delay: .seconds(30)) { _, _ in "too late" }
        let slow = routine(tools: ["search_email"], budget: .init(maxSeconds: 1, maxToolCalls: 8))
        let started = ContinuousClock.now
        let hung = await runner.run(slow, now: Date())
        let elapsed = started.duration(to: .now)
        print("ROUTINE_AUTHORITY time budget -> \(hung.status.rawValue) in \(elapsed): \(hung.text)")
        check("a hung model was not stopped at the time budget",
              hung.status == .failed && hung.text.contains("time limit") && elapsed < .seconds(5))
        check("a hung run left its task unfinished", recorder.finished.last?.1 == .failed)

        // A model that only ever calls tools: the run ends at its tool-call budget.
        let counter = Counter()
        environment.model = ScriptedMemoryReviewModel { _, _ in
            call("search_email", ["query": "page \(counter.next())"])
        }
        let greedy = routine(tools: ["search_email"], budget: .init(maxSeconds: 60, maxToolCalls: 3))
        let capped = await runner.run(greedy, now: Date())
        print("ROUTINE_AUTHORITY call budget -> \(capped.status.rawValue) after \(capped.calls) calls: \(capped.text)")
        check("the tool-call budget was not enforced",
              capped.calls == 3 && tools.reads.count == 3 && capped.status == .failed && capped.text.contains("3 tool calls"))
        check("standard budget is not 3 minutes and 8 calls",
              AgentSchedule.Budget.standard.maxSeconds == 180 && AgentSchedule.Budget.standard.maxToolCalls == 8)
        return failures
    }

    // MARK: - The orchestrator's rule stays

    private static func orchestratorFailures() async -> [String] {
        var failures: [String] = []
        let asks = PermissionGate.shared.askCount
        let write = AgentTool.native(namespace: .workspace, name: "selftest.routine_write", description: "test", risk: .write)
        let intent = ActionIntent(source: .scheduled, authority: .scheduled(scheduleID), verb: write.id,
                                  arguments: ["to": "sam@example.com"], risk: .write)
        var fired = false
        do {
            _ = try await ActionOrchestrator.shared.execute(
                intent: intent, tool: write, title: "Unattended write", routing: ActionRouting(taskID: "routine"),
                policy: .selfTest, promptIfNeeded: true, permissionAlreadyGranted: true,
                fire: { _ in
                    fired = true
                    return AgentToolResult(summary: "must not fire", reference: "x", verification: "x")
                })
            failures.append("orchestrator: a scheduled write executed")
        } catch let error as AgentError {
            if case .permissionDenied = error {} else {
                failures.append("orchestrator: a scheduled write was not denied (\(error.localizedDescription))")
            }
        } catch {
            failures.append("orchestrator: unexpected \(error.localizedDescription)")
        }
        if fired { failures.append("orchestrator: a scheduled write fired") }
        if PermissionGate.shared.askCount != asks { failures.append("orchestrator: a scheduled write asked PermissionGate") }
        if ActionReceiptStore.shared.receipt(forIntent: intent.id)?.status != .denied {
            failures.append("orchestrator: the refused write's receipt is not denied")
        }

        // Drafting refuses anything but an unattended write.
        let read = AgentTool.native(namespace: .meeting, name: "selftest.routine_read", description: "test", risk: .read)
        if (try? ActionOrchestrator.shared.draft(
            intent: ActionIntent(source: .scheduled, authority: .scheduled(scheduleID), verb: read.id, risk: .read),
            tool: read, title: "read", routing: ActionRouting())) != nil {
            failures.append("orchestrator: a read was drafted")
        }
        if (try? ActionOrchestrator.shared.draft(
            intent: ActionIntent(source: .agent, authority: .user, verb: write.id, risk: .write),
            tool: write, title: "user write", routing: ActionRouting())) != nil {
            failures.append("orchestrator: a user write was drafted instead of asked")
        }

        // Policy: no standing setting auto-runs a scheduled write.
        if let click = AgentToolRegistry.shared.tool(named: "computer.click") {
            let generous = PermissionPolicy(autoObserve: true, autoRead: true, autoSearchFiles: true, autoComputerControl: true)
            if generous.allowsAutomatically(click, authority: .scheduled(scheduleID)) {
                failures.append("policy: computer control auto-ran under scheduled authority")
            }
        }
        // The executor refuses schedule tools before anything runs.
        do {
            _ = try await AgentToolExecutor.run("schedule.list", arguments: [:], policy: .selfTest,
                                                taskID: "routine", autoApproveReads: true,
                                                authority: .scheduled(scheduleID))
            failures.append("executor: a scheduled run listed schedules")
        } catch {}

        // Authority round-trips as a string, and old receipts still decode.
        let encoded = try? JSONEncoder().encode([ActionAuthority.scheduled(scheduleID), .user])
        let text = encoded.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let decoded = encoded.flatMap { try? JSONDecoder().decode([ActionAuthority].self, from: $0) }
        if decoded != [.scheduled(scheduleID), .user] || !text.contains("scheduled:\(scheduleID.uuidString)") {
            failures.append("authority: did not round-trip (\(text))")
        }
        if (try? JSONDecoder().decode([ActionAuthority].self, from: Data(#"["memoryReview","systemDerived"]"#.utf8)))
            != [.memoryReview, .systemDerived] {
            failures.append("authority: an older receipt's authority no longer decodes")
        }
        return failures
    }

    // MARK: - Approval is user authority

    private static func approvalFailures(root: URL) async -> [String] {
        var failures: [String] = []
        let store = ScheduleStore(directory: root.appendingPathComponent("approval", isDirectory: true))
        func draft(_ tool: String) -> RoutineDraft {
            RoutineDraft(scheduleID: scheduleID, taskID: "routine-task", receiptID: UUID(), toolID: tool,
                         arguments: ["to": "sam@example.com"], title: "Reply to Sam", preview: "Paid today.",
                         risk: .send, createdAt: Date())
        }
        let first = draft("send_email")
        let second = draft("create_event")
        store.saveDraft(first)
        store.saveDraft(second)
        var executed: [(String, ActionAuthority)] = []
        let executor: RoutineDraftApproval.Executor = { draft, authority in
            executed.append((draft.toolID, authority))
            return AgentToolResult(summary: "Sent", reference: "msg-1", verification: "read back")
        }
        do {
            let approved = try await RoutineDraftApproval.approve(id: first.id, store: store, execute: executor)
            if approved.status != .approved || approved.result != "Sent" {
                failures.append("approval: the approved draft was not recorded")
            }
        } catch {
            failures.append("approval: approving threw \(error.localizedDescription)")
        }
        if executed.count != 1 || executed.first?.0 != "send_email" || executed.first?.1 != .user {
            failures.append("approval: approving did not execute once under user authority")
        }
        if (try? await RoutineDraftApproval.approve(id: first.id, store: store, execute: executor)) != nil || executed.count != 1 {
            failures.append("approval: a draft executed twice")
        }
        RoutineDraftApproval.dismiss(id: second.id, store: store)
        if store.draft(id: second.id)?.status != .dismissed || executed.count != 1 {
            failures.append("approval: dismissing ran or kept the draft")
        }
        let reopened = ScheduleStore(directory: store.directory)
        if reopened.drafts.count != 2 || !reopened.awaitingDrafts.isEmpty {
            failures.append("approval: drafts did not round-trip")
        }
        reopened.removeDrafts(for: scheduleID)
        if !reopened.drafts.isEmpty { failures.append("approval: a deleted routine's drafts stayed") }
        return failures
    }

    // MARK: - The ACP gap

    private static func acpFailures() async -> [String] {
        var failures: [String] = []
        if AgentTask(objective: "x", source: "meeting").isUserInitiated
            || AgentTask(objective: "x", source: "scheduled").isUserInitiated
            || AgentTask(objective: "x", source: "some-future-source").isUserInitiated
            || !AgentTask(objective: "x", source: "user").isUserInitiated
            || !AgentTask(objective: "x", source: "voice").isUserInitiated {
            failures.append("acp: task approval is still inferred from the source not being a meeting")
        }
        let missingFixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("NextNotesSelfTest-no-such-acp-fixture.py").path

        func refusal(_ task: AgentTask) async -> String? {
            do {
                _ = try await ACPAgentBackend().submit(task)
                return nil
            } catch let error as AgentError {
                if case .permissionDenied(let reason) = error { return reason }
                return "not denied: \(error.localizedDescription)"
            } catch {
                return "not denied: \(error.localizedDescription)"
            }
        }
        let scheduled = AgentTask(objective: "Refactor the parser", source: "scheduled",
                                  arguments: ["acpFixture": missingFixture], backend: "acp", scheduleID: scheduleID)
        let reason = await refusal(scheduled)
        print("ROUTINE_AUTHORITY acp -> \(reason ?? "ran")")
        if reason?.contains("cannot start a coding agent") != true {
            failures.append("acp: a scheduled ACP task was not refused (\(reason ?? "ran"))")
        }
        let orphan = AgentTask(objective: "Refactor", source: "scheduled",
                               arguments: ["acpFixture": missingFixture], backend: "acp")
        if await refusal(orphan) == nil { failures.append("acp: a scheduled task without its routine ran") }

        // Even a routine that allows the harness gets no auto-approval: the orchestrator
        // refuses the privileged session under scheduled authority, before any process starts.
        let allowing = routine(tools: ["acp"], id: UUID())
        ScheduleStore.shared.save(allowing)
        let allowed = AgentTask(objective: "Refactor", source: "scheduled",
                                arguments: ["acpFixture": missingFixture], backend: "acp", scheduleID: allowing.id)
        let allowedReason = await refusal(allowed)
        if allowedReason == nil || allowedReason?.hasPrefix("not denied") == true {
            failures.append("acp: a routine allowing ACP was auto-approved (\(allowedReason ?? "ran"))")
        }
        ScheduleStore.shared.remove(id: allowing.id)

        do {
            _ = try await ACPCompatibilityCLIBackend.submit(scheduled, explicitApproval: true)
            failures.append("acp: a scheduled task ran the compatibility CLI")
        } catch {}
        return failures
    }

    // MARK: - Fakes

    final class FakeRunEnvironment: ScheduledRunEnvironment {
        var recording = false
        var local: MemoryReviewLocalState = .idle(seconds: 120)
        var cloud = true
        var model: ScriptedMemoryReviewModel = ScriptedMemoryReviewModel { _, _ in "NOTHING_TO_REPORT" }
        var systemSink: ((String) -> Void)?
        var completions = 0

        var isRecording: Bool { recording }
        func localModelState() async -> MemoryReviewLocalState { local }
        func isCloudConfigured() async -> Bool { cloud }

        func model(for route: RoutineModelRoute) async -> (any MemoryReviewModel)? {
            if case .skip = route { return nil }
            return CountingModel(inner: model, owner: self)
        }

        func recordCompletion(system: String) {
            completions += 1
            systemSink?(system)
        }
    }

    struct CountingModel: MemoryReviewModel {
        let inner: ScriptedMemoryReviewModel
        let owner: FakeRunEnvironment
        var label: String { "scripted" }

        func complete(system: String, user: String) async throws -> String {
            await owner.recordCompletion(system: system)
            return try await inner.complete(system: system, user: user)
        }
    }

    /// Runs reads through the real orchestrator with `.scheduled` authority and a fixture
    /// result — the broker and receipts are exercised, no user data is touched.
    final class FakeToolRunner: ScheduledToolRunning {
        var reads: [(String, ActionAuthority)] = []
        var executedWrites = 0

        func read(_ tool: AgentTool, arguments: [String: String], authority: ActionAuthority,
                  taskID: String) async throws -> AgentToolResult {
            let intent = ActionIntent(source: .scheduled, authority: authority, verb: tool.id,
                                      arguments: arguments, risk: tool.risk)
            return try await ActionOrchestrator.shared.execute(
                intent: intent, tool: tool, title: tool.title(for: arguments),
                routing: ActionRouting(taskID: taskID),
                policy: PermissionPolicy(autoObserve: true, autoRead: true, autoSearchFiles: true,
                                         autoComputerControl: false, grants: []),
                promptIfNeeded: true,
                fire: { [self] _ in
                    reads.append((tool.id, authority))
                    if tool.risk > .read { executedWrites += 1 }
                    return AgentToolResult(summary: "1 email from Sam: invoice question.")
                })
        }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func next() -> Int {
            lock.withLock {
                value += 1
                return value
            }
        }
    }

    struct AuditLine {
        let kind: AgentAuditEntry.Kind
        let title: String
        let scheduleID: UUID
    }

    final class FakeRecorder: ScheduledRunRecording {
        var begun: [AgentTask] = []
        var finished: [(String, AgentTaskStatus)] = []
        var audits: [AuditLine] = []

        func begin(_ task: AgentTask) { begun.append(task) }

        func finish(taskID: String, status: AgentTaskStatus, result: String?, failure: String?) {
            finished.append((taskID, status))
        }

        func audit(kind: AgentAuditEntry.Kind, title: String, detail: String, toolID: String?,
                   taskID: String?, scheduleID: UUID) {
            audits.append(AuditLine(kind: kind, title: title, scheduleID: scheduleID))
        }
    }
}

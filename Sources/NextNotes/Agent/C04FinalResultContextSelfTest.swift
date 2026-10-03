import Darwin
import Foundation

/// Real account-read/final-answer production route; model/tokenizer are scripted.
@MainActor
enum C04FinalResultContextSelfTest {
    static func run() async -> String {
        guard SelfTest.isRunning else { return "C04_FINAL_RESULT_CONTEXT_FAILED_NOT_SELFTEST" }
        defer { fflush(nil) }
        let agent = RealtimeAgent.shared
        let expectedMemoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NextNotesSelfTest-memory-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
            .appendingPathComponent(NextMemory.fileName)
        let memoryIsTemporary = NextMemory.shared.fileURL?.standardizedFileURL == expectedMemoryURL.standardizedFileURL
        if memoryIsTemporary { NextMemory.shared.clearForTesting() }
        let oldHook = agent.beforeMemoryGroundingForTesting
        let oldProvider = agent.localModelProviderForTesting
        let oldBudget = agent.budgetForTesting
        let oldCold = agent.coldForTesting
        let oldCalls = agent.maxCallsForTesting
        let oldDepth = agent.answerDepthForTesting
        let oldDenial = agent.denyUnattendedApprovalsForTesting
        let oldRead = agent.readApprovalOverrideForTesting
        let oldFiles = agent.fileRetrievalForTesting
        let oldTrace = agent.plannerTraceForTesting
        let oldInputs = AgentCapabilityManifestBuilder.inputsOverrideForTesting
        let oldFake = AgentToolExecutor.fakeForTesting
        defer {
            agent.beforeMemoryGroundingForTesting = oldHook
            agent.localModelProviderForTesting = oldProvider
            agent.budgetForTesting = oldBudget
            agent.coldForTesting = oldCold
            agent.maxCallsForTesting = oldCalls
            agent.answerDepthForTesting = oldDepth
            agent.denyUnattendedApprovalsForTesting = oldDenial
            agent.readApprovalOverrideForTesting = oldRead
            agent.fileRetrievalForTesting = oldFiles
            agent.plannerTraceForTesting = oldTrace
            AgentCapabilityManifestBuilder.inputsOverrideForTesting = oldInputs
            AgentToolExecutor.fakeForTesting = oldFake
            agent.setTypedPendingForTesting(nil)
        }
        var failures: [String] = []
        var checked = 0
        func check(_ label: String, _ passed: Bool) {
            checked += 1
            if !passed { failures.append(label) }
            print("C04_FINAL_RESULT_CONTEXT_CHECK \(label) \(passed ? "PASS" : "FAIL")")
        }
        let request = "Summarize my last emails and list me my events for tomorrow"
        guard let rawClock = SelfTest.value(after: "--c04-fixture-now"),
              let now = ISO8601DateFormatter().date(from: rawClock) else {
            return "C04_FINAL_RESULT_CONTEXT_FAILED_FIXED_CLOCK_REQUIRED"
        }
        let fixtures = LiveEvalFixtures(now: now)
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        let tomorrow = formatter.string(from: Calendar.current.date(byAdding: .day, value: 1, to: now) ?? now)
        let mail = fixtures.mailSearch("", maxResults: 5)
        guard let agendaTool = AgentToolRegistry.shared.tool(named: "get_agenda") else {
            return "C04_FINAL_RESULT_CONTEXT_FAILED_MISSING_AGENDA_TOOL"
        }
        let agenda: String
        do { agenda = try await fixtures.run(agendaTool, ["date": tomorrow]).summary }
        catch { return "C04_FINAL_RESULT_CONTEXT_FAILED_FIXTURE_AGENDA" }
        let mailCall = #"<tool_call>{"name":"search_email","arguments":{"query":"","maxResults":"5"}}</tool_call>"#
        let refusal = "I can't access your calendar."
        let claim = "I ran the get_agenda tool. Your main calendar for tomorrow shows no booked events."
        // No tool call/denial/completed-tool claim: the actual account-read guard must run
        // tomorrow's read and call finalAnswerRound(reason:.accountRead) itself.
        let presentsCalendar = "Your calendar is busy tomorrow."
        let answer = "Cyril asked about dinner, Ana requested the deck, Marcus sent the pricing sheet, and Stripe has an invoice. Tomorrow: Dentist, Design sync, and Dinner with Cyril."
        print("C04_FINAL_RESULT_CONTEXT_INPUT mailCharacters=\(mail.count) agendaCharacters=\(agenda.count) claimNoteCharacters=\(ToolClaimGuard.replanNote.count)")
        var inputs = AgentCapabilityInputs.allEnabled(
            tools: AgentToolRegistry.shared.tools(upTo: .privileged), reader: .voiceFrontend)
        inputs.switches.skills = false
        AgentCapabilityManifestBuilder.inputsOverrideForTesting = inputs
        agent.denyUnattendedApprovalsForTesting = true
        agent.readApprovalOverrideForTesting = true
        agent.budgetForTesting = nil
        agent.coldForTesting = nil
        agent.maxCallsForTesting = nil
        agent.answerDepthForTesting = .balanced
        agent.fileRetrievalForTesting = fixtures.files
        AgentToolExecutor.fakeForTesting = { tool, arguments in
            guard tool.risk == .read, ["search_email", "get_agenda"].contains(tool.id) else {
                throw FixtureError.unexpectedTool(tool.id)
            }
            return try await fixtures.run(tool, arguments)
        }
        struct Outcome {
            let reply: String
            let calls: [C04FinalPromptLog.Call]
            let counts: [Int]
            let tools: [LiveEvalLoggedCall]
            let regularRounds: Int
            let rejected: Int
            let stopped: Int
            let controlledGrounding: Bool
            let noMemorySection: Bool
            let noApprovalAsk: Bool
            let rawResults: String
        }
        func runCase(script: [String], window: Int, pressure: C04FinalPromptProvider.Pressure,
                     cancelAtStream: Int? = nil, earlierUser: String? = nil) async -> Outcome {
            if memoryIsTemporary { NextMemory.shared.clearForTesting() }
            AgentSession.shared.startNewConversation()
            if let earlierUser { AgentSession.shared.recordUser(earlierUser, source: .text) }
            fixtures.beginCase()
            var clears = 0
            var emptyAtProducer = false
            agent.beforeMemoryGroundingForTesting = {
                guard memoryIsTemporary else { return }
                NextMemory.shared.clearForTesting()
                clears += 1
                emptyAtProducer = NextMemory.shared.grounding(for: request).isEmpty
            }
            let log = C04FinalPromptLog(script: script)
            agent.localModelProviderForTesting = C04FinalPromptProvider(
                window: window, pressure: pressure, cancelAtStream: cancelAtStream, log: log)
            var rounds = 0, rejected = 0, stopped = 0
            agent.plannerTraceForTesting = {
                switch $0 {
                case .round: rounds += 1
                case .rejectedCall: rejected += 1
                case .stopped: stopped += 1
                }
            }
            let asks = PermissionGate.shared.askCount
            let turn = await agent.handle(request, source: .text)
            let calls = log.calls
            return Outcome(reply: turn.reply, calls: calls, counts: log.counts, tools: fixtures.calls,
                regularRounds: rounds, rejected: rejected, stopped: stopped,
                controlledGrounding: memoryIsTemporary && clears == 1 && emptyAtProducer
                    && NextMemory.shared.grounding(for: request).isEmpty,
                noMemorySection: !calls.isEmpty && calls.allSatisfy {
                    !$0.user.contains("Relevant local memory for names and labels:")
                }, noApprovalAsk: PermissionGate.shared.askCount == asks,
                rawResults: AgentSession.shared.groundingHaystack())
        }
        struct Mode { let name: String; let window: Int; let correction: String?; let pressure: Bool }
        let modes = [
            Mode(name: "no-note-8192", window: 8_192, correction: nil, pressure: false),
            Mode(name: "refusal-8192", window: 8_192, correction: refusal, pressure: false),
            Mode(name: "claim-8192", window: 8_192, correction: claim, pressure: false),
            Mode(name: "refusal-32768", window: 32_768, correction: refusal, pressure: false),
            Mode(name: "claim-32768", window: 32_768, correction: claim, pressure: false),
            Mode(name: "pressure-8192", window: 8_192, correction: claim, pressure: true),
        ]
        for mode in modes {
            let script = [mailCall] + (mode.correction.map { [$0] } ?? []) + [presentsCalendar, answer]
            let result = await runCase(script: script, window: mode.window,
                pressure: mode.pressure ? .recoverable : .none)
            let finalCalls = result.calls.filter { $0.kind == "complete" }
            let final = finalCalls.last
            let prefix = mode.name + "/"
            let expectedMail = ToolResultBudget.cap(mail, readerContextTokens: mode.window, toolID: "search_email")
            let expectedAgenda = ToolResultBudget.cap(agenda, readerContextTokens: mode.window, toolID: "get_agenda")
            check(prefix + "C01-two-exact-reads", result.tools.map(\.toolID) == ["search_email", "get_agenda"])
            check(prefix + "C02-mail-query-and-count", result.tools.first?.arguments["maxResults"] == "5"
                && (result.tools.first?.arguments["query"] ?? "").isEmpty
                && Set(result.tools.first?.arguments.keys.map { $0 } ?? []).isSubset(of: ["query", "maxResults"]))
            check(prefix + "C03-real-default-agenda-arguments", result.tools.last?.arguments == ["date": tomorrow])
            check(prefix + "C04-actual-account-final-route", result.regularRounds == script.count - 1
                && result.calls.count == script.count && finalCalls.count == 1
                && result.calls.dropLast().allSatisfy { $0.kind == "stream" }
                && result.rejected == 0 && result.stopped == 0)
            check(prefix + "C05-current-grounded-request", result.calls.allSatisfy {
                $0.user.contains("Current user request:\n" + request)
            })
            check(prefix + "C06-raw-results-still-owned", result.rawResults.contains(mail) && result.rawResults.contains(agenda))
            check(prefix + "C07-final-mail-body-admission", mode.pressure
                ? final?.user.contains("search_email returned:") == true && final?.user.contains(expectedMail) == false
                : final?.user.contains(expectedMail) == true)
            check(prefix + "C08-final-agenda-body-admission", final?.user.contains(expectedAgenda) == true)
            let notePresent: Bool
            if mode.correction == refusal {
                notePresent = final?.user.contains("Correction from the application") == true
            } else if mode.correction == claim {
                notePresent = final?.user.contains(ToolClaimGuard.replanNote) == true
            } else {
                notePresent = final?.user.contains(ToolClaimGuard.replanNote) == false
                    && final?.user.contains("Correction from the application") == false
            }
            check(prefix + "C09-actual-guard-note", notePresent)
            check(prefix + "C10-no-invented-intermediate-prose", [claim, refusal, presentsCalendar,
                "Jane Doe", "Support Team", "Marketing Dept"].allSatisfy { final?.user.contains($0) == false })
            check(prefix + "C11-existing-visible-budget", result.calls.allSatisfy {
                $0.maxTokens == AgentAnswerBudget.tokens(
                    kind: $0.kind == "complete" ? .finalAnswer : .plannerRound(background: false),
                    contextTokens: mode.window, promptTokens: 2_000, depth: .balanced)
            })
            check(prefix + "C12-original-consumer-delivery", result.reply.hasSuffix(answer))
            check(prefix + "C13-actual-temporary-grounding-empty", result.controlledGrounding)
            check(prefix + "C14-all-provider-prompts-omit-local-memory", result.noMemorySection)
            check(prefix + "C15-no-extra-approval-or-tool-catalogue", result.noApprovalAsk
                && final?.system.contains("Available tools:") == false
                && final?.system.contains("For a tool step, emit exactly one Hermes call") == false
                && final?.user.hasSuffix("\n\nAnswer now from what you have; no tool calls.") == true)
            check(prefix + "C16-one-fit-counter-or-bounded-pressure", mode.pressure
                ? result.counts.allSatisfy { $0 == 2_000 || $0 == mode.window }
                    && (script.count...script.count + 1).contains(result.counts.count)
                : result.counts == Array(repeating: 2_000, count: script.count))
            print("C04_FINAL_RESULT_CONTEXT_TRACE mode=\(mode.name) regular=\(result.regularRounds) complete=\(finalCalls.count) tools=\(result.tools.count) counted=\(result.counts) userCharacters=\(final?.user.count ?? 0)")
            print("C04_FINAL_RESULT_CONTEXT_FINAL_BEGIN \(mode.name)")
            if result.controlledGrounding && result.noMemorySection {
                print(final?.user ?? "MISSING")
            } else { print("OMITTED_UNPROVEN_LOCAL_GROUNDING") }
            print("C04_FINAL_RESULT_CONTEXT_FINAL_END \(mode.name)")
        }
        // Nonempty actual history ends in CR. Joining the production separator creates
        // CRLF at the boundary, so removing count(history)+2 can delete the request's C.
        // Only the final envelope is pressured; ordinary rounds retain this exact history.
        do {
            let earlierUser = "Earlier fixture note\r"
            let script = [mailCall, presentsCalendar, answer]
            let result = await runCase(script: script, window: 8_192, pressure: .history,
                earlierUser: earlierUser)
            let finalCalls = result.calls.filter { $0.kind == "complete" }
            let final = finalCalls.last
            let streams = result.calls.filter { $0.kind == "stream" }
            check("history/H01-real-read-arguments", result.tools.map(\.toolID) == ["search_email", "get_agenda"]
                && result.tools.first?.arguments["maxResults"] == "5"
                && (result.tools.first?.arguments["query"] ?? "").isEmpty
                && result.tools.last?.arguments == ["date": tomorrow])
            check("history/H02-actual-account-final-route", streams.count == 2 && finalCalls.count == 1
                && result.regularRounds == 2 && result.rejected == 0 && result.stopped == 0)
            check("history/H03-measured-earlier-history-removal", final?.user.contains("Earlier fixture note") == false
                && final?.user.contains(RealtimeAgent.conversationSectionLabel) == false)
            check("history/H04-exact-current-request-survives", final?.user.contains("Current user request:\n" + request) == true)
            check("history/H05-real-crlf-history-origin", streams.count == 2 && streams.allSatisfy {
                $0.user.contains(RealtimeAgent.conversationSectionLabel + "\nUser [typed]: " + earlierUser
                    + "\n\nCurrent user request:\n" + request)
            } && result.rawResults.contains(earlierUser + "\n" + request))
            check("history/H06-both-result-bodies-survive", final?.user.contains(mail) == true
                && final?.user.contains(agenda) == true && result.rawResults.contains(mail)
                && result.rawResults.contains(agenda))
            check("history/H07-unchanged-final-envelope-and-delivery", result.reply.hasSuffix(answer)
                && final?.user.hasSuffix("\n\nAnswer now from what you have; no tool calls.") == true
                && [claim, refusal, presentsCalendar, "Jane Doe", "Support Team", "Marketing Dept"].allSatisfy {
                    final?.user.contains($0) == false
                })
            check("history/H08-current-budget-from-measured-envelope", streams.allSatisfy {
                $0.maxTokens == AgentAnswerBudget.tokens(kind: .plannerRound(background: false),
                    contextTokens: 8_192, promptTokens: 2_000, depth: .balanced)
            } && final?.maxTokens == AgentAnswerBudget.tokens(kind: .finalAnswer,
                contextTokens: 8_192, promptTokens: result.counts.last ?? -1, depth: .balanced))
            check("history/H09-controlled-grounding-and-permission", result.controlledGrounding
                && result.noMemorySection && result.noApprovalAsk)
            // The original final caller counts its unchanged envelope once at8192; the
            // candidate counts it again only after dropping history. Do not require the
            // fixed counter trace as an original control; H03 is the feature target.
            check("history/H10-exact-bounded-count-trace", result.counts == [2_000, 2_000, 8_192]
                || result.counts == [2_000, 2_000, 8_192, 2_000])
            print("C04_FINAL_RESULT_CONTEXT_TRACE mode=history regular=\(result.regularRounds) complete=\(finalCalls.count) tools=\(result.tools.count) counted=\(result.counts) userCharacters=\(final?.user.count ?? 0)")
            print("C04_FINAL_RESULT_CONTEXT_FINAL_BEGIN history")
            if result.controlledGrounding && result.noMemorySection {
                print(final?.user ?? "MISSING")
            } else { print("OMITTED_UNPROVEN_LOCAL_GROUNDING") }
            print("C04_FINAL_RESULT_CONTEXT_FINAL_END history")
        }
        // Irreducible final envelope: immutable rules/request do not fit even after all
        // existing reductions. No answer-only model invocation may be admitted.
        do {
            let script = [mailCall, claim, presentsCalendar, answer]
            let result = await runCase(script: script, window: 8_192, pressure: .irreducible)
            check("unfit/U01-actual-account-read", result.tools.map(\.toolID) == ["search_email", "get_agenda"])
            check("unfit/U02-real-agenda-arguments", result.tools.last?.arguments == ["date": tomorrow])
            check("unfit/U03-original-stream-route", result.regularRounds == 3
                && result.calls.filter { $0.kind == "stream" }.count == 3 && result.rejected == 0)
            check("unfit/U04-raw-results-retained", result.rawResults.contains(mail) && result.rawResults.contains(agenda))
            check("unfit/U05-refuse-final-model", result.calls.allSatisfy { $0.kind != "complete" })
            check("unfit/U06-render-existing-overflow-result", result.reply.hasSuffix(AgentReplyRenderer.render(
                    .contextOverflow(lastVerified: agenda), voice: false))
                && !result.reply.contains(answer))
            check("unfit/U07-grounding-domain", result.controlledGrounding && result.noMemorySection)
            check("unfit/U08-no-approval-unbounded-recount", result.noApprovalAsk
                && (4...6).contains(result.counts.count))
            print("C04_FINAL_RESULT_CONTEXT_TRACE mode=unfit regular=\(result.regularRounds) complete=\(result.calls.filter { $0.kind == "complete" }.count) tools=\(result.tools.count) counted=\(result.counts)")
        }
        // Real generation cancellation while the streamed account-presenting response is
        // in flight: no automatic calendar read or final completion may follow it.
        do {
            let script = [mailCall, claim, presentsCalendar, answer]
            let result = await runCase(script: script, window: 8_192, pressure: .none, cancelAtStream: 2)
            check("cancel/K01-only-first-read", result.tools.map(\.toolID) == ["search_email"])
            check("cancel/K02-exact-first-arguments", result.tools.first?.arguments["maxResults"] == "5")
            check("cancel/K03-streamed-cancel-boundary", result.calls.count == 3
                && result.calls.allSatisfy { $0.kind == "stream" })
            check("cancel/K04-no-final-completion", result.calls.allSatisfy { $0.kind != "complete" })
            check("cancel/K05-raw-mail-retained", result.rawResults.contains(mail))
            check("cancel/K06-no-calendar-result", !result.rawResults.contains(agenda))
            check("cancel/K07-grounding-domain", result.controlledGrounding && result.noMemorySection)
            check("cancel/K08-no-approval-extra-count", result.noApprovalAsk && result.counts == [2_000, 2_000, 2_000])
            print("C04_FINAL_RESULT_CONTEXT_TRACE mode=cancel streams=\(result.calls.count) tools=\(result.tools.count) counted=\(result.counts)")
        }
        for failure in failures { print("C04_FINAL_RESULT_CONTEXT_FAILURE \(failure)") }
        return failures.isEmpty ? "C04_FINAL_RESULT_CONTEXT_OK \(checked)"
            : "C04_FINAL_RESULT_CONTEXT_FAILED \(failures.count)/\(checked)"
    }
    private enum FixtureError: Error { case unexpectedTool(String) }
}

private final class C04FinalPromptLog: @unchecked Sendable {
    struct Call: Sendable { let kind: String; let system: String; let user: String; let maxTokens: Int }
    private let lock = NSLock()
    private let script: [String]
    private var storage: [Call] = []
    private var counted: [Int] = []
    init(script: [String]) { self.script = script }
    func next(kind: String, system: String, user: String, maxTokens: Int) -> (index: Int, text: String) {
        lock.lock(); defer { lock.unlock() }
        let index = storage.count
        storage.append(Call(kind: kind, system: system, user: user, maxTokens: maxTokens))
        return (index, index < script.count ? script[index] : "SCRIPT_EXHAUSTED")
    }
    func count(_ value: Int) { lock.lock(); defer { lock.unlock() }; counted.append(value) }
    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return storage }
    var counts: [Int] { lock.lock(); defer { lock.unlock() }; return counted }
}

private struct C04FinalPromptProvider: LLMProvider {
    enum Pressure: Sendable { case none, recoverable, history, irreducible }
    let id: LLMProviderID = .localServer
    let window: Int
    let pressure: Pressure
    let cancelAtStream: Int?
    let log: C04FinalPromptLog
    var contextTokens: Int { window }
    var unavailableReason: String? { get async { nil } }
    func countTokens(_ text: String) async throws -> Int {
        let finalEnvelope = text.hasSuffix("\n\nAnswer now from what you have; no tool calls.")
        let value: Int
        switch pressure {
        case .none: value = 2_000
        case .recoverable:
            value = finalEnvelope && text.contains("get_agenda returned:")
                && text.contains("Marcus Lee <marcus@productflo.example>") ? window : 2_000
        case .history:
            value = finalEnvelope && text.contains("Earlier fixture note\r\n\nCurrent user request:") ? window : 2_000
        case .irreducible: value = finalEnvelope ? window : 2_000
        }
        log.count(value)
        return value
    }
    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        try Task.checkCancellation()
        let next = log.next(kind: "complete", system: system, user: user, maxTokens: maxTokens)
        return LLMCompletion(text: next.text, generatedTokens: next.text.count, duration: 0)
    }
    func stream(system: String, user: String, maxTokens: Int) async -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try Task.checkCancellation()
                    let next = log.next(kind: "stream", system: system, user: user, maxTokens: maxTokens)
                    if next.index == cancelAtStream {
                        await MainActor.run { RealtimeAgent.shared.cancel() }
                    }
                    let midpoint = next.text.index(next.text.startIndex, offsetBy: next.text.count / 2)
                    continuation.yield(String(next.text[..<midpoint]))
                    continuation.yield(String(next.text[midpoint...]))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
    func streamConversation(system: String, messages: [LLMChatMessage], maxTokens: Int)
        async -> AsyncThrowingStream<String, Error> {
        await stream(system: system,
            user: messages.map { "\($0.role.rawValue.capitalized): \($0.content)" }.joined(separator: "\n\n"),
            maxTokens: maxTokens)
    }
}

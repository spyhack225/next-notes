import Darwin
import Foundation

/// Actual typed planner loop with the unchanged live-eval C04 tool backing. The model and
/// tokenizer are scripted; this proves prompt transport, not native model grounding quality.
@MainActor
enum C04ResultContextSelfTest {
    static func run() async -> String {
        guard SelfTest.isRunning else { return "C04_RESULT_CONTEXT_FAILED_NOT_SELFTEST" }
        defer { fflush(nil) }
        let agent = RealtimeAgent.shared
        let expectedMemoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NextNotesSelfTest-memory-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
            .appendingPathComponent(NextMemory.fileName)
        let memoryIsTemporary = NextMemory.shared.fileURL?.standardizedFileURL == expectedMemoryURL.standardizedFileURL
        if memoryIsTemporary { NextMemory.shared.clearForTesting() }
        let oldBeforeGrounding = agent.beforeMemoryGroundingForTesting
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
            agent.beforeMemoryGroundingForTesting = oldBeforeGrounding
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
        func check(_ label: String, _ accepted: Bool) {
            checked += 1
            if !accepted { failures.append(label) }
            print("C04_RESULT_CONTEXT_CHECK \(label) \(accepted ? "PASS" : "FAIL")")
        }
        let request = "Summarize my last emails and list me my events for tomorrow"
        guard let rawClock = SelfTest.value(after: "--c04-fixture-now"),
              let now = ISO8601DateFormatter().date(from: rawClock) else {
            return "C04_RESULT_CONTEXT_FAILED_FIXED_CLOCK_REQUIRED"
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
            return "C04_RESULT_CONTEXT_FAILED_MISSING_AGENDA_TOOL"
        }
        let agenda: String
        do { agenda = try await fixtures.run(agendaTool, ["date": tomorrow]).summary }
        catch { return "C04_RESULT_CONTEXT_FAILED_FIXTURE_AGENDA" }
        print("C04_RESULT_CONTEXT_INPUT mailCharacters=\(mail.count) agendaCharacters=\(agenda.count) claimNoteCharacters=\(ToolClaimGuard.replanNote.count)")
        let mailCall = #"<tool_call>{"name":"search_email","arguments":{"query":"","maxResults":"5"}}</tool_call>"#
        let agendaCall = "<tool_call>{\"name\":\"get_agenda\",\"arguments\":{\"date\":\"\(tomorrow)\"}}</tool_call>"
        let answer = "Cyril asked about dinner, Ana requested the deck, Marcus sent the pricing sheet, and Stripe has an invoice. Tomorrow: Dentist, Design sync, and Dinner with Cyril."
        let refusal = "I can't access your calendar."
        let claim = "I ran the get_agenda tool. Your main calendar for tomorrow shows no booked events."
        struct Mode {
            let name: String
            let window: Int
            let correction: String?
            let pressure: Bool
        }
        let modes = [
            Mode(name: "no-note-8192", window: 8_192, correction: nil, pressure: false),
            Mode(name: "refusal-8192", window: 8_192, correction: refusal, pressure: false),
            Mode(name: "claim-8192", window: 8_192, correction: claim, pressure: false),
            Mode(name: "refusal-32768", window: 32_768, correction: refusal, pressure: false),
            Mode(name: "claim-32768", window: 32_768, correction: claim, pressure: false),
            Mode(name: "pressure-8192", window: 8_192, correction: claim, pressure: true),
        ]
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
        for mode in modes {
            if memoryIsTemporary { NextMemory.shared.clearForTesting() }
            AgentSession.shared.startNewConversation()
            var groundingClears = 0
            var emptyGroundingAtProducer = false
            agent.beforeMemoryGroundingForTesting = {
                guard memoryIsTemporary else { return }
                NextMemory.shared.clearForTesting()
                groundingClears += 1
                emptyGroundingAtProducer = NextMemory.shared.grounding(for: request).isEmpty
            }
            fixtures.beginCase()
            let script = [mailCall] + (mode.correction.map { [$0] } ?? []) + [agendaCall, answer]
            let log = C04PromptLog(script: script)
            let provider = C04PromptProvider(window: mode.window, pressure: mode.pressure, log: log)
            agent.localModelProviderForTesting = provider
            var rounds = 0
            var rejected = 0
            var stopped = 0
            agent.plannerTraceForTesting = { event in
                switch event {
                case .round: rounds += 1
                case .rejectedCall: rejected += 1
                case .stopped: stopped += 1
                }
            }
            let turn = await agent.handle(request, source: .text)
            let calls = log.calls
            let toolCalls = fixtures.calls
            let final = calls.last
            let expectedMail = ToolResultBudget.cap(mail, readerContextTokens: mode.window, toolID: "search_email")
            let expectedAgenda = ToolResultBudget.cap(agenda, readerContextTokens: mode.window, toolID: "get_agenda")
            let prefix = mode.name + "/"
            check(prefix + "C01-two-exact-reads", toolCalls.map(\.toolID) == ["search_email", "get_agenda"])
            check(prefix + "C02-mail-query-and-count", toolCalls.first?.arguments["maxResults"] == "5"
                && (toolCalls.first?.arguments["query"] ?? "").isEmpty
                && Set(toolCalls.first?.arguments.keys.map { $0 } ?? []).isSubset(of: ["query", "maxResults"]))
            check(prefix + "C03-device-clock-agenda", toolCalls.last?.arguments["date"] == tomorrow)
            check(prefix + "C04-real-regular-rounds", calls.count == script.count && rounds == script.count
                && rejected == 0 && stopped == 0)
            check(prefix + "C05-request-carried", calls.allSatisfy { $0.user.contains(request) })
            check(prefix + "C06-raw-result-still-owned", AgentSession.shared.groundingHaystack().contains(mail))
            check(prefix + "C07-mail-body-admission", mode.pressure
                ? final?.user.contains("search_email returned:") == true && final?.user.contains(expectedMail) == false
                : final?.user.contains(expectedMail) == true)
            check(prefix + "C08-agenda-body-admission", final?.user.contains(expectedAgenda) == true)
            let notePresent: Bool
            if mode.correction == refusal {
                notePresent = final?.user.contains("Correction from the application") == true
            } else if mode.correction == claim {
                // Under real overflow, the older claim note may itself be folded. Its first
                // line is the whole note, so this remains the exact guard-produced string.
                notePresent = final?.user.contains(mode.pressure
                    ? ToolResultBudget.firstLine(ToolClaimGuard.replanNote) : ToolClaimGuard.replanNote) == true
            } else {
                notePresent = final?.user.contains(ToolClaimGuard.replanNote) == false
                    && final?.user.contains("Correction from the application") == false
            }
            check(prefix + "C09-actual-guard-note", notePresent)
            check(prefix + "C10-no-invented-intermediate-prose", final?.user.contains(claim) == false
                && final?.user.contains(refusal) == false
                && ["Jane Doe", "Support Team", "Marketing Dept"].allSatisfy { final?.user.contains($0) == false })
            check(prefix + "C11-existing-visible-budget", calls.allSatisfy {
                $0.maxTokens == AgentAnswerBudget.tokens(kind: .plannerRound(background: false),
                    contextTokens: mode.window, promptTokens: 2_000, depth: .balanced)
            })
            check(prefix + "C12-original-consumer-delivery", turn.reply.hasSuffix(answer))
            let controlledGrounding = memoryIsTemporary && groundingClears == 1
                && emptyGroundingAtProducer && NextMemory.shared.grounding(for: request).isEmpty
            let noMemorySection = !calls.isEmpty && calls.allSatisfy {
                !$0.user.contains("Relevant local memory for names and labels:")
            }
            check(prefix + "C13-actual-temporary-grounding-empty", controlledGrounding)
            check(prefix + "C14-all-provider-prompts-omit-local-memory", noMemorySection)
            print("C04_RESULT_CONTEXT_TRACE mode=\(mode.name) window=\(mode.window) rounds=\(rounds) tools=\(toolCalls.count) counted=\(log.counts) userCharacters=\(final?.user.count ?? 0)")
            // Emit a user prompt only after both local-grounding controls pass. Startup and
            // activity refresh still read existing owner labels; temporary storage alone
            // does not prove read isolation. Never print a failed-domain prompt's payload.
            print("C04_RESULT_CONTEXT_FINAL_BEGIN \(mode.name)")
            if controlledGrounding && noMemorySection {
                print(final?.user ?? "MISSING")
            } else {
                print("OMITTED_UNPROVEN_LOCAL_GROUNDING")
            }
            print("C04_RESULT_CONTEXT_FINAL_END \(mode.name)")
        }
        for failure in failures { print("C04_RESULT_CONTEXT_FAILURE \(failure)") }
        return failures.isEmpty ? "C04_RESULT_CONTEXT_OK \(checked)"
            : "C04_RESULT_CONTEXT_FAILED \(failures.count)/\(checked)"
    }

    private enum FixtureError: Error { case unexpectedTool(String) }
}

private final class C04PromptLog: @unchecked Sendable {
    struct Call: Sendable { let system: String; let user: String; let maxTokens: Int }
    private let lock = NSLock()
    private let script: [String]
    private var storage: [Call] = []
    private var counted: [Int] = []
    init(script: [String]) { self.script = script }
    func next(system: String, user: String, maxTokens: Int) -> String {
        lock.lock(); defer { lock.unlock() }
        let index = storage.count
        storage.append(Call(system: system, user: user, maxTokens: maxTokens))
        return index < script.count ? script[index] : "SCRIPT_EXHAUSTED"
    }
    func count(_ value: Int) { lock.lock(); defer { lock.unlock() }; counted.append(value) }
    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return storage }
    var counts: [Int] { lock.lock(); defer { lock.unlock() }; return counted }
}

private struct C04PromptProvider: LLMProvider {
    let id: LLMProviderID = .localServer
    let window: Int
    let pressure: Bool
    let log: C04PromptLog
    var contextTokens: Int { window }
    var unavailableReason: String? { get async { nil } }
    func countTokens(_ text: String) async throws -> Int {
        // Same real C04 text in both modes. The pressure control scripts tokenizer cost to
        // exceed room only when both bodies are carried. Native tokenizer fit is unproven.
        let value = pressure && text.contains("get_agenda returned:")
            && text.contains("Marcus Lee <marcus@productflo.example>") ? window : 2_000
        log.count(value)
        return value
    }
    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        let text = log.next(system: system, user: user, maxTokens: maxTokens)
        return LLMCompletion(text: text, generatedTokens: text.count, duration: 0)
    }
    func stream(system: String, user: String, maxTokens: Int) async -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try Task.checkCancellation()
                    let result = try await complete(system: system, user: user, maxTokens: maxTokens)
                    continuation.yield(result.text)
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

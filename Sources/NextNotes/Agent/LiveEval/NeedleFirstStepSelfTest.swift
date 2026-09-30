import Foundation

/// P1-31: canned Needle responses cross the actual first-step branch and the sole
/// ToolStepRunner. These are execution-policy regressions, not live-eval score cases.
@MainActor
enum NeedleFirstStepSelfTest {
    static func run() async -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append("Needle first: " + name) }
        }
        func response(_ name: String?, _ arguments: [String: String] = [:],
                      negated: Bool = false, ungrounded: [String] = [], success: Bool = true)
            -> NeedleResponse {
            let json: [String: Any] = [
                "success": success,
                "function_calls": name.map { [["name": $0, "arguments": arguments]] } ?? [],
                "confidence": 0.99,
                "validation": ["negation": negated, "ungrounded": ungrounded],
            ]
            return try! JSONDecoder().decode(NeedleResponse.self,
                                            from: JSONSerialization.data(withJSONObject: json))
        }
        let inputs = AgentCapabilityInputs.allEnabled(
            tools: AgentToolRegistry.shared.tools(upTo: .privileged), reader: .voiceFrontend)
        func manifest(_ request: String) -> AgentCapabilityManifest {
            AgentCapabilityManifestBuilder.build(inputs, request: request)
        }
        func accepted(_ response: NeedleResponse, _ request: String) -> AgentToolCall? {
            let m = manifest(request)
            return ToolLoopLiveEval.validatedNeedleCall(response, request: request, shortlist: m.allowed)
        }

        let calendar = manifest("What's on my calendar today?")
        let tools = ToolLoopLiveEval.needleTools(calendar.selected)
        let abstention = tools.first { $0.id == FunctionCallRelevance.abstentionToolID }
        check("Agent abstention still excludes questions or searches",
              abstention != nil && abstention?.description.contains("for questions") == false
                  && abstention?.description.contains("searching or playing") == false)
        check("calendar question accepted an unsolicited calendar write",
              accepted(response("create_event", ["title": "What's on my calendar today"]),
                       "What's on my calendar today?") == nil)
        check("invented recipient accepted at high confidence",
              accepted(response("send_email", ["to": "invented@acme.com", "subject": "Deck",
                                                  "body": "Here is the deck"]),
                       "Email Marcus the deck") == nil)
        check("missing recipient accepted",
              accepted(response("send_email", ["subject": "Deck", "body": "Here is the deck"]),
                       "Email Marcus the deck") == nil)
        check("invented document accepted",
              accepted(response("append_doc", ["document_id": "inventedDocument123",
                                                 "text": "bring passports"]),
                       "Append bring passports to the trip document") == nil)
        check("negated send accepted",
              accepted(response("send_email", ["to": "ana@example.com", "subject": "Deck",
                                                  "body": "Here is the deck"], negated: true),
                       "Don't email ana@example.com the deck") == nil)
        check("backend-flagged recipient accepted",
              accepted(response("send_email", ["to": "ana@example.com", "subject": "Deck",
                                                  "body": "Here is the deck"],
                                ungrounded: ["send_email.to"]),
                       "Email ana@example.com the deck") == nil)
        check("valid fully grounded send refused",
              accepted(response("send_email", ["to": "ana@acme.com", "subject": "deck",
                                                  "body": "Here is the deck"]),
                       "Email ana@acme.com the deck") != nil)
        check("failed engine response accepted",
              accepted(response("schedule.list", success: false), "List my reminders") == nil)
        check("valid read refused", accepted(response("schedule.list"), "List my reminders") != nil)
        check("valid recall refused", accepted(response("memory.recall", ["query": "brother"]),
                                               "What's my brother's name?") != nil)
        check("unknown tool accepted", accepted(response("not_registered"), "List my reminders") == nil)
        check("abstention accepted as an executable call",
              accepted(response("no_action"), "List my reminders") == nil)

        let agent = RealtimeAgent.shared
        let oldProvider = agent.localModelProviderForTesting
        let oldInputs = AgentCapabilityManifestBuilder.inputsOverrideForTesting
        let oldFake = AgentToolExecutor.fakeForTesting
        let oldNeedle = ToolLoopLiveEval.needleFirstForTesting
        let oldResponse = ToolLoopLiveEval.needleResponseForTesting
        let oldTurns = ToolLoopLiveEval.needleTurnsForTesting
        let oldCalls = ToolLoopLiveEval.needleCallsForTesting
        let oldErrors = ToolLoopLiveEval.needleErrorsForTesting
        let oldAttempts = ToolLoopLiveEval.needleAttemptsForTesting
        defer {
            agent.localModelProviderForTesting = oldProvider
            AgentCapabilityManifestBuilder.inputsOverrideForTesting = oldInputs
            AgentToolExecutor.fakeForTesting = oldFake
            ToolLoopLiveEval.needleFirstForTesting = oldNeedle
            ToolLoopLiveEval.needleResponseForTesting = oldResponse
            ToolLoopLiveEval.needleTurnsForTesting = oldTurns
            ToolLoopLiveEval.needleCallsForTesting = oldCalls
            ToolLoopLiveEval.needleErrorsForTesting = oldErrors
            ToolLoopLiveEval.needleAttemptsForTesting = oldAttempts
        }
        AgentCapabilityManifestBuilder.inputsOverrideForTesting = inputs
        ToolLoopLiveEval.needleFirstForTesting = true
        let fixtures = LiveEvalFixtures()
        AgentToolExecutor.fakeForTesting = fixtures.run
        AgentSession.shared.startNewConversation()
        agent.localModelProviderForTesting = NeedleScriptProvider(state: NeedleScriptState(script: ["<tool_call>{\"name\":\"memory.remember\",\"arguments\":{\"kind\":\"profile\",\"text\":\"The user prefers short answers.\"}}</tool_call>",
                     "Saved your preference for short answers."]))
        ToolLoopLiveEval.needleResponseForTesting = { _, _ in
            response("memory.recall", ["query": "short answers"])
        }
        _ = await agent.handle("Remember that I prefer short answers", source: .text)
        check("recall ended a save objective without its write",
              fixtures.calls.map(\.toolID) == ["memory.recall", "memory.remember"])

        AgentSession.shared.startNewConversation()
        fixtures.beginCase()
        let before = ToolLoopLiveEval.needleErrorsForTesting
        ToolLoopLiveEval.needleResponseForTesting = { _, _ in
            throw FunctionCallError.timedOut(8)
        }
        agent.localModelProviderForTesting = NeedleScriptProvider(state: NeedleScriptState(script: ["<tool_call>{\"name\":\"schedule.list\",\"arguments\":{}}</tool_call>",
                     "You have a reminder to put the book out."]))
        _ = await agent.handle("List my reminders", source: .text)
        check("engine timeout did not fall back exactly once",
              fixtures.calls.map(\.toolID) == ["schedule.list"]
                  && ToolLoopLiveEval.needleErrorsForTesting == before + 1)
        // This catalogue cannot fit as a whole: no truncated shortlist and no engine call.
        let compound = manifest("Search my email and calendar and files and browser")
        var invoked = false
        ToolLoopLiveEval.needleResponseForTesting = { _, _ in
            invoked = true
            return response("schedule.list")
        }
        let overCap = await ToolLoopLiveEval.needleFirstCall(
            request: "Search my email and calendar and files and browser", manifest: compound)
        check("an oversized intent class reached Needle",
              compound.selected.filter { compound.selectedIntents.contains($0.intent) }.count
                  > FunctionCallCatalogue.maxTools && overCap == nil && !invoked)
        let noTool = await ToolLoopLiveEval.needleFirstCall(
            request: "Hello", manifest: manifest("Hello"))
        check("answer-only request reached Needle", noTool == nil && !invoked)

        // A first read is not evidence that a send happened. The answer-only round
        // must cross the same existing claim guard as an ordinary planner answer.
        AgentSession.shared.startNewConversation()
        fixtures.beginCase()
        ToolLoopLiveEval.needleResponseForTesting = { _, _ in response("schedule.list") }
        agent.localModelProviderForTesting = NeedleScriptProvider(state: NeedleScriptState(
            script: ["I sent the email."]))
        let unsupported = await agent.handle("List my reminders", source: .text)
        check("answer-only round claimed an unexecuted send",
              !unsupported.reply.lowercased().contains("i sent"))

        // The first call and the base planner share one duplicate-call ledger.
        AgentSession.shared.startNewConversation()
        fixtures.beginCase()
        ToolLoopLiveEval.needleResponseForTesting = { _, _ in
            response("memory.recall", ["query": "short answers"])
        }
        agent.localModelProviderForTesting = NeedleScriptProvider(state: NeedleScriptState(script: [
            "<tool_call>{\"name\":\"memory.recall\",\"arguments\":{\"query\":\"short answers\"}}</tool_call>",
            "<tool_call>{\"name\":\"memory.remember\",\"arguments\":{\"kind\":\"profile\",\"text\":\"The user prefers short answers.\"}}</tool_call>",
            "Saved your preference for short answers."]))
        _ = await agent.handle("Remember that I prefer short answers", source: .text)
        check("the base planner repeated an executed first call",
              fixtures.calls.map(\.toolID) == ["memory.recall", "memory.remember"])
        UsageLog.shared.flush()
        let rows = UsageLog.shared.load().filter {
            $0.turnID == agent.currentTurnID && $0.pass == "needle-first"
        }
        check("Needle's attempted first call was not logged once", rows.count == 1)

        AgentSession.shared.startNewConversation()
        fixtures.beginCase()
        // Pin this policy check to one real send schema: unrelated tools added by
        // another feature must not turn a denial test into an oversized-class skip.
        AgentCapabilityManifestBuilder.inputsOverrideForTesting = .allEnabled(
            tools: AgentToolRegistry.shared.tools(upTo: .privileged).filter { $0.id == "send_email" },
            reader: .voiceFrontend)
        let actualReader = AgentCapabilityManifest.Reader(
            provider: .localServer, displayName: "fixture", contextTokens: 32_768)
        let liveInputs = AgentCapabilityInputs.live(reader: actualReader)
        check("production planner ignored its fixture roster or reader",
              liveInputs.tools.map(\.id) == ["send_email"] && liveInputs.reader == actualReader)
        var deniedCalls = 0
        AgentToolExecutor.fakeForTesting = { _, _ in
            deniedCalls += 1
            throw AgentError.permissionDenied("You said no.")
        }
        ToolLoopLiveEval.needleResponseForTesting = { _, _ in
            response("send_email", ["to": "ana@acme.com", "subject": "hello", "body": "hello"])
        }
        agent.localModelProviderForTesting = NeedleScriptProvider(state: NeedleScriptState(script: []))
        let denied = await agent.handle("Email ana@acme.com hello", source: .text)
        let deniedClaims = ToolClaimGuard.claims(
            in: denied.reply, roster: ToolClaimGuard.registryNames)
        check("denied first write was retried or claimed as sent",
              deniedCalls == 1 && ToolClaimGuard.unsupported(deniedClaims, completed: []).isEmpty)
        print("  TOOLLOOP_PRODUCTION_NEEDLE: \(failures.count) problem(s)")
        return failures
    }
}

private actor NeedleScriptState {
    private let script: [String]
    private var index = 0
    init(script: [String]) { self.script = script }
    func next() -> String {
        defer { index += 1 }
        return index < script.count ? script[index] : "There is nothing more to add."
    }
}

private struct NeedleScriptProvider: LLMProvider {
    let state: NeedleScriptState
    var id: LLMProviderID { .localServer }
    var contextTokens: Int { 32_768 }
    var unavailableReason: String? { get async { nil } }
    func countTokens(_ text: String) async throws -> Int { 1_000 }
    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        let text = await state.next()
        return LLMCompletion(text: text, generatedTokens: text.count / 4, duration: 0)
    }
}

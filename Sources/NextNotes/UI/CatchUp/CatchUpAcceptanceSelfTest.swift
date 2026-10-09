import Foundation

@MainActor
enum CatchUpAcceptanceSelfTest {
    static func run() async -> [String] {
        var failures: [String] = []
        let facts = "Recipient: dana@fixture.invalid. Subject: Launch confirmation. Remind Dana to confirm the launch checklist by noon tomorrow."
        // Ordinary opening paragraphs put every action referent beyond the small row cap.
        let long = String(repeating: "The project update is ready for your review. ", count: 90)
            + "\n\n" + facts + "\n\nWant me to send the reminders?"
        let entry = CatchUpText.entry(id: "budget-offer", title: "Catch-up", madeAt: Date(), text: long,
                                     audioURL: nil, duration: nil)!
        for crossing in [false, true] {
            let offered = crossing ? CatchUpText.entry(id: "compaction-offer", title: "Catch-up", madeAt: Date(),
                text: facts + " Want me to send the reminders?", audioURL: nil, duration: nil)! : entry
            let session = AgentSession(fileURL: nil)
            if crossing {
                // The background row is still BELOW 24,000; only the accepting
                // user append crosses it and folds the preceding background turn.
                let seed = AgentSessionBoundary.workingBudget - offered.text.count - offered.offer!.yesText.count / 2
                session.recordUser(String(repeating: "u", count: seed / 2), source: .text)
                session.recordAssistant(String(repeating: "a", count: seed - seed / 2))
            }
            // Real acceptance producer and both real bounded history consumers.
            LiveCatchUpOfferActing(session: session, open: {}, submitAccepted: { words, context in
                if crossing && (session.compactionCount != 0 || session.messages.reduce(0, { $0 + $1.text.count }) > AgentSessionBoundary.workingBudget) {
                    failures.append("acceptance: fixture crossed working budget before acceptance")
                }
                session.recordUser(words, source: .text, catchUpAcceptance: context)
            }).say(offered.offer!.yesText, for: offered)
            let budget = AgentHistoryBudget.characters(contextTokens: 4_096)
            let cap = AgentHistoryBudget.perMessageCap(budget: budget)
            let string = session.contextForCurrentTurn(maxCharacters: budget, scrubToolClaims: true, perMessageCharacters: cap)
            let chat = session.chatHistoryForCurrentTurn(maxCharacters: budget, scrubToolClaims: true, perMessageCharacters: cap)
            for (name, prompt) in [("planner", string), ("chat", chat.map(\.content).joined())] {
                for fact in ["dana@fixture.invalid", "Launch confirmation", "noon tomorrow", "Want me to send the reminders?"] {
                    if !prompt.contains(fact) { failures.append("acceptance: \(name) crossing=\(crossing) lost \(fact)") }
                }
                if prompt.count > budget { failures.append("acceptance: \(name) exceeded reader budget") }
            }
            if crossing && session.compactionCount == 0 { failures.append("acceptance: did not cross real compaction") }
            let stored = (try? JSONEncoder().encode(session.messages.last)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            if !stored.contains("catchUpAcceptance") { failures.append("acceptance: accepting row did not retain bound Codable context") }
            if session.messages.last?.text != offered.offer!.yesText { failures.append("acceptance: changed literal accepting words") }
        }
        // Unsupported oversized offers must not consume the omission notice.
        // Real handoff and both real small-reader prompt consumers, not a helper mirror.
        let oversized = CatchUpText.entry(id: "oversized-offer", title: "Catch-up", madeAt: Date(),
            text: facts + "\n\nWant me to send " + String(repeating: "the reminders to Dana ", count: 80) + "?",
            audioURL: nil, duration: nil)!
        let bounded = AgentSession(fileURL: nil)
        LiveCatchUpOfferActing(session: bounded, open: {}, submitAccepted: { words, context in
            bounded.recordUser(words, source: .text, catchUpAcceptance: context)
        }).say(oversized.offer!.yesText, for: oversized)
        let budget = AgentHistoryBudget.characters(contextTokens: 4_096)
        let cap = AgentHistoryBudget.perMessageCap(budget: budget)
        let boundedPrompts = [bounded.contextForCurrentTurn(maxCharacters: budget, scrubToolClaims: true, perMessageCharacters: cap),
            bounded.chatHistoryForCurrentTurn(maxCharacters: budget, scrubToolClaims: true, perMessageCharacters: cap).map(\.content).joined()]
        for prompt in boundedPrompts {
            if !prompt.contains("Ask for any missing action details.") {
                failures.append("acceptance: oversized offer silently lost omission notice")
            }
            if prompt.count > budget { failures.append("acceptance: oversized offer exceeded reader budget") }
        }
        // Real asynchronous typed entry, with the handoff value captured before Task
        // scheduling. The shared typed entry and captured typed worker use real
        // recordUser/planner producers; only the provider response is substituted.
        // Manager admission is outside this focused prompt-context contract.
        let liveSession = AgentSession.shared
        for route in ["handleLive", "typedWorker", "localOnce"] {
            let typedWorker = route == "typedWorker"
            liveSession.startNewConversation()
            if typedWorker {
                liveSession.recordUser(String(repeating: "u", count: 11_950), source: .text)
                liveSession.recordAssistant(String(repeating: "a", count: 11_950))
            }
            let agent = RealtimeAgent.shared
            let previousProvider = agent.localModelProviderForTesting
            defer { agent.localModelProviderForTesting = previousProvider }
            let log = CatchUpPromptLog()
            agent.localModelProviderForTesting = CatchUpPromptProvider(log: log)
            var job: Task<AgentTurn, Never>?
            var interposed = false
            LiveCatchUpOfferActing(session: liveSession, open: {}, submitAccepted: { words, context in
                job = Task {
                    if typedWorker {
                        let work = VoiceConversationWork(words, userWords: words, catchUpAcceptance: context)
                        let worker = agent.makeTypedWorker(work)
                        worker.beforeMemoryGroundingForTesting = {
                            interposed = true
                            liveSession.recordUser("An unrelated status question.", source: .text)
                        }
                        return await worker.runTypedWorkerTurn(work, recordInput: true)
                    }
                    if route == "localOnce" {
                        return await agent.runWithLocalToolsOnce(words, source: .text, catchUpAcceptance: context)
                    }
                    return await agent.handleLive(words, source: .text, catchUpAcceptance: context)
                }
            }).say(entry.offer!.yesText, for: entry)
            _ = await job?.value
            let prompts = await log.prompts
            if !prompts.contains(where: { $0.contains("dana@fixture.invalid") && $0.contains("Launch confirmation") && $0.contains("noon tomorrow") }) {
                failures.append("acceptance: asynchronous production planner route=\(route) lost action details")
            }
            let acceptedRow = liveSession.messages.last(where: { $0.role == "user" && $0.text == entry.offer!.yesText })
            let encoded = (try? JSONEncoder().encode(acceptedRow)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            if !encoded.contains("catchUpAcceptance") { failures.append("acceptance: route=\(route) did not bind context on its actual accepting row") }
            if typedWorker && !interposed { failures.append("acceptance: did not interpose actual pre-history user row") }
            liveSession.startNewConversation()
        }
        for failure in failures { print("CATCH_UP_ACCEPTANCE_CHECK_FAILED: \(failure)") }
        print(failures.isEmpty ? "CATCH_UP_ACCEPTANCE_OK" : "CATCH_UP_ACCEPTANCE_FAILED")
        return failures
    }
}

actor CatchUpPromptLog {
    var prompts: [String] = []
    var systems: [String] = []
    func append(system: String, user: String) { systems.append(system); prompts.append(user) }
}
struct CatchUpPromptProvider: LLMProvider {
    let id: LLMProviderID = .localServer
    let contextTokens = 65_536
    var unavailableReason: String? { get async { nil } }
    let log: CatchUpPromptLog
    func countTokens(_ text: String) async throws -> Int { text.count / 4 }
    func complete(system: String, user: String, maxTokens: Int) async throws -> LLMCompletion {
        await log.append(system: system, user: user)
        // Scripted compliance is deliberately not a real-model security verdict.
        return LLMCompletion(text: "Please confirm the reminder details.", generatedTokens: 7, duration: 0)
    }
}

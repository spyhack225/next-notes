import Foundation

/// The session half of `--selftest-memory`: idle boundaries, *Clear conversation*, the frozen
/// memory snapshot re-read at session start and after compaction, the labelled summary, turns
/// that are never split, and the full history kept on disk. A fake clock and a temporary
/// `agent-conversation.json`; the user's conversation is never read.
@MainActor
enum AgentSessionSelfTest {
    static func failures(root: URL) -> [String] {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append("sessions: \(name)") }
        }
        final class Clock {
            var current = Date(timeIntervalSince1970: 1_800_000_000)
            func now() -> Date { current }
            func advance(minutes: Double) { current += minutes * 60 }
        }
        let clock = Clock()
        let file = root.appendingPathComponent(AgentSession.fileName)
        var refreshes = 0
        var requests: [AgentSession.ReviewRequest] = []
        // P1-18: an explicit `workingBudget`, because the product's fold point moved from
        // 10,000 to 24,000 and every existing case here measures compaction, not the product
        // default. Without it the old numbers would keep passing by accident and the fixture
        // would stop meaning what it says.
        // `name` defaults to the fixture's own file, so every existing case keeps its rows
        // where it expects them. The P1-18 cases pass their own: a 40-turn session written to
        // the shared file is not a bug in the budget, it is the fixture arguing with a check
        // that counts what is on disk.
        func makeSession(workingBudget: Int = 10_000, name: String = "agent-conversation.json")
            -> AgentSession {
            let session = AgentSession(fileURL: root.appendingPathComponent(name),
                                       now: clock.now, idleMinutes: { 30 },
                                       beginMemorySession: { refreshes += 1 },
                                       workingBudget: workingBudget)
            session.onReviewRequest = { requests.append($0) }
            return session
        }
        // `shared` has no file under a self-test, so nothing it records can reach the user's
        // agent-conversation.json.
        check("the shared session is not isolated", AgentSession.shared.fileURL == nil)

        // MARK: Idle boundary
        let session = makeSession()
        session.recordUser("My first question about the roadmap.", source: .text)
        session.recordAssistant("Here is the roadmap answer.")
        let first = session.sessionID
        clock.advance(minutes: 29)
        session.recordUser("A follow-up inside the window.", source: .voice)
        check("29 minutes of silence started a session", session.sessionID == first && refreshes == 0 && requests.isEmpty)
        session.recordAssistant("Follow-up answer.")
        clock.advance(minutes: 31)
        session.recordUser("A new topic entirely.", source: .text)
        check("31 minutes of silence did not start a session", session.sessionID != first)
        check("the snapshot was not re-read at session start", refreshes == 1)
        check("the ended session was not handed to the review",
              requests.count == 1 && requests[0].reason == .idle && requests[0].sessionID == first
                && requests[0].messages.count == 4)
        check("the new session's prompt carries the old session",
              !session.contextForCurrentTurn().contains("roadmap") && !session.hasPriorAssistantTurn
                && session.chatHistoryForCurrentTurn(maxCharacters: 5_000).isEmpty)
        check("rows lost their session", session.messages.filter { $0.sessionID == first }.count == 4
              && session.currentSessionMessages.count == 1)

        // A relaunch inside the window continues the session; after it, a new one starts and
        // the old sessions are there to catch up on.
        let relaunched = makeSession()
        check("a relaunch inside the idle window started a new session",
              relaunched.sessionID == session.sessionID && relaunched.messages.count == 5)
        clock.advance(minutes: 45)
        let later = makeSession()
        check("a relaunch after the idle window continued the session",
              later.sessionID != session.sessionID && later.currentSessionMessages.isEmpty
                && later.endedSessions().map(\.messages.count) == [4, 1])
        check("the loop's idle check ended an idle session", session.endSessionIfIdle() && requests.count == 2)

        // MARK: Clear conversation
        session.recordUser("Something to clear.", source: .text)
        let beforeClear = refreshes
        let cleared = session.sessionID
        session.forgetAllConversations()
        check("Clear conversation did not start a session", session.sessionID != cleared && refreshes == beforeClear + 1)
        check("Clear conversation did not hand the session to the review first",
              requests.last?.reason == .cleared && requests.last?.messages.first?.text == "Something to clear.")
        check("Clear conversation left rows or the file",
              session.messages.isEmpty && !FileManager.default.fileExists(atPath: file.path))

        // MARK: Legacy rows are split on the same rule
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let legacy = AgentSessionBoundary.assignSessions([
            AgentSession.Message(role: "user", text: "a", at: base),
            AgentSession.Message(role: "assistant", text: "b", at: base + 600),
            AgentSession.Message(role: "user", text: "c", at: base + 2 * 3_600),
        ], idleMinutes: 30)
        check("legacy rows were not split into sessions",
              legacy[0].sessionID != nil && legacy[0].sessionID == legacy[1].sessionID
                && legacy[2].sessionID != legacy[1].sessionID)

        // MARK: Compaction never splits a turn
        func row(_ role: String, _ size: Int, kind: String? = nil) -> AgentSession.Message {
            AgentSession.Message(role: role, text: String(repeating: "x", count: size), contextKind: kind)
        }
        var synthetic: [AgentSession.Message] = []
        for _ in 0..<8 {
            synthetic += [row("user", 400), row("assistant", 300, kind: "files"), row("tool", 900), row("assistant", 200)]
        }
        let slice = synthetic[...]
        let boundary = AgentSessionBoundary.compactionStart(slice, current: 0, budget: 4_000)
        check("compaction did not fold anything", boundary > 0)
        check("compaction split a tool call from its result", synthetic[boundary].role == "user")
        check("compaction folded the last turn", boundary <= synthetic.count - 4)
        check("the kept tail is over budget",
              AgentSessionBoundary.characters(synthetic[boundary...]) <= 4_000)
        check("under budget compacted anyway", AgentSessionBoundary.compactionStart(slice, current: 0, budget: 100_000) == 0)
        let oneTurn = [row("user", 9_000), row("tool", 9_000)][...]
        check("a single turn was split", AgentSessionBoundary.compactionStart(oneTurn, current: 0, budget: 1_000) == 0)

        // MARK: Compaction in a live session
        refreshes = 0
        let long = makeSession()
        for index in 1...14 {
            long.recordUser("Request \(index): " + String(repeating: "please look into the quarterly numbers ", count: 12),
                            source: .text)
            long.recordAssistant("Result \(index): " + String(repeating: "the numbers are fine ", count: 20),
                                 contextKind: index.isMultiple(of: 2) ? "files" : nil)
            clock.advance(minutes: 1)
        }
        long.recordUser("And the final question?", source: .text)
        check("a long session never compacted", long.compactionCount >= 1)
        check("the snapshot was not re-read after compaction", refreshes == long.compactionCount)
        let summary = long.compactionSummary()
        print("MEMORY_SESSION compactions=\(long.compactionCount) summary=\(summary.count) rows=\(long.messages.count)")
        check("the summary is not headed reference-only", summary.hasPrefix(AgentSessionBoundary.summaryHeader))
        check("the summary does not mark tool results", summary.contains("Agent returned a files result"))
        check("the summary repeats tool-result content",
              !summary.split(separator: "\n").contains { $0.hasPrefix("- Agent returned") && $0.contains("Result ") })
        let context = long.contextForCurrentTurn()
        check("the prompt context does not lead with the summary", context.hasPrefix(AgentSessionBoundary.summaryHeader))
        check("the prompt context lost the newest turn", context.contains("Result 14"))
        check("the prompt context carries the active request", !context.contains("And the final question?"))
        check("the prompt context is over its budget", context.count <= 10_000)
        let history = long.chatHistoryForCurrentTurn(maxCharacters: 2_500)
        check("chat history does not lead with the labelled summary",
              history.first?.content.hasPrefix(AgentSessionBoundary.summaryHeader) == true
                && history.first?.role == .user)
        check("chat history is over its budget", history.reduce(0) { $0 + $1.content.count } <= 2_500)

        // MARK: P1-18 — a history budget that scales with the reader
        //
        // The finding (H1 #9) is that every one of these budgets was a literal: 2,500 on the
        // first pass, 6,000 in the planner, 1,800 per message, and a hard 10,000 ceiling on the
        // session context. A reader with a 262,144-token window was given less than one email
        // listing, and the 10,000 ceiling clipped silently, so raising the caller's budget
        // changed nothing at all. Red today on both counts.

        // The table, pure. Four readers, and the two numbers each one decides.
        for (tokens, characters, perMessage) in [
            (4_096, 2_500, 1_000), (8_192, 6_000, 2_400), (32_768, 12_000, 4_800),
            (262_144, 24_000, 6_000),
        ] {
            check("a \(tokens)-token reader is given \(characters) characters of history, "
                + "expected \(characters)",
                  AgentHistoryBudget.characters(contextTokens: tokens) == characters)
            check("a \(characters)-character budget clips one message at \(perMessage), "
                + "expected \(perMessage)",
                  AgentHistoryBudget.perMessageCap(budget: characters) == perMessage)
        }
        check("the largest budget is reachable rather than silently clipped",
              AgentHistoryBudget.characters(contextTokens: 262_144)
                  == AgentHistoryBudget.maximumCharacters)

        // A long session on the product's own budget. **Red today:** clipped to 10,000 by the
        // `min(Self.contextCharacters, …)` at the top of `contextForCurrentTurn`.
        let roomy = makeSession(workingBudget: AgentHistoryBudget.maximumCharacters,
                              name: "p118-roomy.json")
        for turn in 0..<40 {
            roomy.recordUser("Turn \(turn) asks about the pricing sheet and the deck. "
                + String(repeating: "detail ", count: 90), source: .text)
            roomy.recordAssistant("Turn \(turn) answer. " + String(repeating: "detail ", count: 90))
        }
        roomy.recordUser("And the final question?", source: .text)
        let roomyContext = roomy.contextForCurrentTurn(
            maxCharacters: AgentHistoryBudget.maximumCharacters)
        check("a 262,144-token reader was given \(roomyContext.count) characters of history, "
            + "expected more than 10,000",
              roomyContext.count > 10_000)
        check("a 262,144-token reader was given \(roomyContext.count) characters, "
            + "over the \(AgentHistoryBudget.maximumCharacters) ceiling",
              roomyContext.count <= AgentHistoryBudget.maximumCharacters)

        // One very long message, and the per-message cap that scales with the budget. **Red
        // today:** there is no `perMessageCharacters` to pass, so the first assertion fails at
        // 1,800 and there is no marker at the end.
        let longMessage = makeSession(workingBudget: AgentHistoryBudget.maximumCharacters,
                                    name: "p118-long-message.json")
        longMessage.recordUser("A short question about one very long document.")
        longMessage.recordAssistant(String(repeating: "word ", count: 1_800))
        longMessage.recordUser("And now?")
        let big = longMessage.chatHistoryForCurrentTurn(
            maxCharacters: AgentHistoryBudget.maximumCharacters,
            perMessageCharacters: AgentHistoryBudget.perMessageCap(
                budget: AgentHistoryBudget.maximumCharacters))
        // The long assistant row on its own. The join would count the short user message and
        // the compaction summary too, and 6,046 characters of "≤ 6,000" is a measurement of
        // the wrong thing rather than a failure of the right one.
        let bigBody = big.first { $0.role == .assistant }?.content ?? ""
        check("one message inside a 24,000-character budget is \(bigBody.count) characters, "
            + "expected at most 6,000",
              bigBody.count <= 6_000)
        check("one message inside a 24,000-character budget is \(bigBody.count) characters, "
            + "so the 1,800 cap is still what is being applied",
              bigBody.count > 1_800)
        check("a clipped message says so instead of ending mid-word",
              bigBody.contains(AgentHistoryBudget.clippedSuffix))

        // The same message on a small reader's budget, which is the per-message cap doing its
        // job rather than one constant for everybody.
        let smallBudget = makeSession(workingBudget: 2_500, name: "p118-small.json")
        smallBudget.recordUser("A short question about one very long document.")
        smallBudget.recordAssistant(String(repeating: "word ", count: 1_800))
        smallBudget.recordUser("And now?")
        let small = smallBudget.chatHistoryForCurrentTurn(
            maxCharacters: 2_500,
            perMessageCharacters: AgentHistoryBudget.perMessageCap(budget: 2_500))
        let smallBody = small.first { $0.role == .assistant }?.content ?? ""
        check("one message inside a 2,500-character budget is \(smallBody.count) characters, "
            + "expected at most 1,000",
              smallBody.count <= 1_000)

        // And the voice frontend's call, which P4-08 owns: 1,400 total and **no**
        // `perMessageCharacters`, so it keeps today's 1,800 per message. Asserted because
        // `perMessageCap(budget: 1_400)` is 560, and passing it there would silently halve
        // voice history to make a table look tidy.
        let voice = makeSession(workingBudget: AgentHistoryBudget.maximumCharacters,
                               name: "p118-voice.json")
        voice.recordUser("A short question about one very long document.")
        voice.recordAssistant(String(repeating: "word ", count: 1_800))
        voice.recordUser("And now?")
        let voiceBody = voice.chatHistoryForCurrentTurn(maxCharacters: 1_400)
            .first { $0.role == .assistant }?.content ?? ""
        check("the voice frontend's history is \(voiceBody.count) characters, over the 560 "
            + "over the 560 that perMessageCap would have given it",
              voiceBody.count > 560)
        check("the voice frontend's history is \(voiceBody.count) characters, over its 1,400",
              voiceBody.count <= 1_400)
        if let tailID = long.compactedTailStartID, let tail = long.messages.firstIndex(where: { $0.id == tailID }) {
            check("the live boundary is not a turn start", long.messages[tail].role == "user")
        } else {
            failures.append("sessions: no compaction boundary")
        }
        let reopened = AgentSession(fileURL: file, now: clock.now, idleMinutes: { 30 })
        check("compaction removed rows from disk", reopened.messages.count == long.messages.count
              && reopened.messages.first?.text.hasPrefix("Request 1:") == true)
        let voiceContext = long.contextForCurrentTurn(maxCharacters: 2_500)
        check("a small prompt budget was exceeded", voiceContext.count <= 2_500)
        long.forgetAllConversations()
        return failures
    }
}

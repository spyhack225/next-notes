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
        func makeSession() -> AgentSession {
            let session = AgentSession(fileURL: file, now: clock.now, idleMinutes: { 30 },
                                       beginMemorySession: { refreshes += 1 })
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
        session.clear()
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
        long.clear()
        return failures
    }
}

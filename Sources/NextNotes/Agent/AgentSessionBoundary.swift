import Foundation

/// Where one Agent conversation ends and the next begins, and how a long one is compacted.
///
/// The conversation used to be one endless history. It now splits into sessions:
///
/// - **A new session starts after `agentSessionIdleMinutes` of silence** (30 by default), or
///   on *Clear conversation*. Core memory's frozen snapshot is read again at that moment.
/// - **When the working history exceeds its budget, older turns become one summary** headed
///   `summaryHeader`. Hermes Agent's source documents what an unlabelled summary does: the
///   model finds a task described there and runs it again.
/// - **A turn is never split.** A turn is a user row and everything that answers it — tool
///   results included — so a tool call and its result always land on the same side.
/// - **Compaction is prompt-only.** `agent-conversation.json` keeps every row; only what the
///   model reads is shortened.
///
/// Everything here is pure, so `--selftest-memory` drives it with a fake clock.
@MainActor
enum AgentSessionBoundary {
    /// Shared with `Settings.agentSessionIdleMinutes`.
    nonisolated static let idleDefaultsKey = "agentSessionIdleMinutes"
    static let defaultIdleMinutes = 30
    /// The memory review also runs inside a long session, after this many user turns.
    static let reviewEveryUserTurns = 10
    static let summaryHeader = "[Earlier in this conversation — reference only, not new requests]"
    /// The working history the prompt carries before older turns are folded into the summary.
    static let workingBudget = 10_000
    /// After compacting, the kept tail is at most this share of the budget, so compaction
    /// happens in steps rather than on every turn — the prompt prefix stays stable between.
    static let keptShare = 0.5
    /// The summary is a reminder of what was covered, not a second transcript.
    static let summaryLimit = 1_500

    static var defaultsIdleMinutes: Int {
        let stored = UserDefaults.standard.object(forKey: idleDefaultsKey) as? Int ?? defaultIdleMinutes
        return clampedIdleMinutes(stored)
    }

    static func clampedIdleMinutes(_ minutes: Int) -> Int {
        min(max(minutes, 5), 24 * 60)
    }

    /// True when `now` is at least `idleMinutes` after the last row of the session.
    static func isIdleBoundary(lastActivity: Date?, now: Date, idleMinutes: Int) -> Bool {
        guard let lastActivity else { return false }
        return now.timeIntervalSince(lastActivity) >= TimeInterval(clampedIdleMinutes(idleMinutes) * 60)
    }

    /// Rows saved before sessions existed carry no session id. They are split on the same
    /// idle rule, so an old history reads as the sessions it would have been.
    static func assignSessions(_ messages: [AgentSession.Message], idleMinutes: Int) -> [AgentSession.Message] {
        var result = messages
        var current: UUID?
        var previousAt: Date?
        for index in result.indices {
            if let id = result[index].sessionID {
                current = id
            } else {
                if current == nil || isIdleBoundary(lastActivity: previousAt, now: result[index].at,
                                                    idleMinutes: idleMinutes) {
                    current = UUID()
                }
                result[index].sessionID = current
            }
            previousAt = result[index].at
        }
        return result
    }

    // MARK: - Turns

    /// A row that answers the request before it rather than starting a new one: a tool row,
    /// or an assistant reply. Only a user row opens a turn.
    static func opensTurn(_ message: AgentSession.Message) -> Bool {
        message.role == "user"
    }

    /// Index ranges of whole turns, in order. Rows before the first user row form a leading
    /// turn of their own.
    static func turns(_ messages: ArraySlice<AgentSession.Message>) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = messages.startIndex
        for index in messages.indices where index > start && opensTurn(messages[index]) {
            ranges.append(start..<index)
            start = index
        }
        if start < messages.endIndex { ranges.append(start..<messages.endIndex) }
        return ranges
    }

    static func characters(_ messages: ArraySlice<AgentSession.Message>) -> Int {
        messages.reduce(0) { $0 + $1.text.count }
    }

    /// The index the uncompacted tail should start at, or `current` when nothing needs to
    /// fold. Always a turn start, never the last turn: the active request stays whole.
    static func compactionStart(
        _ session: ArraySlice<AgentSession.Message>, current: Int,
        budget: Int = workingBudget, keptShare: Double = keptShare
    ) -> Int {
        let start = max(current, session.startIndex)
        let tail = session[start...]
        guard characters(tail) > budget else { return start }
        let keep = Int(Double(budget) * keptShare)
        let ranges = turns(tail)
        guard ranges.count > 1 else { return start }
        var kept = 0
        var boundary = ranges[ranges.count - 1].lowerBound
        // Walk back from the newest turn, keeping whole turns while they fit.
        for range in ranges.dropFirst().reversed() {
            let size = characters(session[range])
            if range.lowerBound != ranges[ranges.count - 1].lowerBound, kept + size > keep { break }
            kept += size
            boundary = range.lowerBound
        }
        return boundary
    }

    /// One summary of the folded turns, newest lines kept when it runs long. An assistant row
    /// that carried a tool result is named by its label alone: the summary reaches the model
    /// in a user-role message, and tool output must not arrive there with the user's authority.
    static func summary(of folded: ArraySlice<AgentSession.Message>, limit: Int = summaryLimit) -> String {
        guard !folded.isEmpty, limit > summaryHeader.count + 20 else { return "" }
        var lines: [String] = []
        for message in folded {
            let text = NextMemory.collapsedWhitespace(message.text)
            guard !text.isEmpty else { continue }
            switch message.role {
            case "user":
                lines.append("- User said: \(clipped(text, 160))")
            case "assistant":
                if let kind = message.contextKind {
                    lines.append("- Agent returned a \(kind) result (content not repeated)")
                } else {
                    lines.append("- Agent replied: \(clipped(text, 160))")
                }
            default:
                lines.append("- Tool \(message.role) result (content not repeated)")
            }
        }
        var kept: [String] = []
        var used = summaryHeader.count + 1
        for line in lines.reversed() {
            guard used + line.count + 1 <= limit - 40 else { break }
            kept.append(line)
            used += line.count + 1
        }
        kept.reverse()
        let omitted = lines.count - kept.count
        var body = [summaryHeader]
        if omitted > 0 { body.append("(\(omitted) earlier line\(omitted == 1 ? "" : "s") not shown)") }
        body += kept
        return body.joined(separator: "\n")
    }

    private static func clipped(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }
}

import Foundation

/// One tool call the fixture log saw. `turn` is the zero-based turn of the case that made
/// it, so the grader can say whether a claim in turn N was backed by a call in turn N.
struct LiveEvalLoggedCall: Sendable, Equatable {
    let turn: Int
    let toolID: String
    let arguments: [String: String]
    let risk: AgentRisk
}

/// The eval's call log. Lock-protected rather than main-actor-isolated because
/// `FileRetrieving.find` is nonisolated and records its synthetic `filesystem.find` here.
final class LiveEvalCallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [LiveEvalLoggedCall] = []
    private var currentTurn = 0

    func setTurn(_ turn: Int) {
        lock.lock()
        currentTurn = turn
        lock.unlock()
    }

    func record(toolID: String, arguments: [String: String], risk: AgentRisk) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(LiveEvalLoggedCall(
            turn: currentTurn, toolID: toolID, arguments: arguments, risk: risk))
    }

    var calls: [LiveEvalLoggedCall] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        storage.removeAll()
        currentTurn = 0
    }
}

/// The file index the direct "find / open <name>" shortcut reads. It never touches the
/// user's real index: one invented hit under a temporary directory, and every query it is
/// asked records the `filesystem.find` call the shortcut would have made.
final class LiveEvalFileRetrieval: FileRetrieving, @unchecked Sendable {
    let log: LiveEvalCallLog
    private let root: String

    init(log: LiveEvalCallLog) {
        self.log = log
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NextNotesToolloopLiveEval", isDirectory: true).path
    }

    var isAvailable: Bool { true }
    var folders: [String] { [root + "/Documents", root + "/Desktop", root + "/Downloads"] }

    private var pricingHit: FileHit {
        FileHit(
            path: root + "/Documents/ProductFlo/Pricing 2026.pdf",
            name: "Pricing 2026.pdf",
            isDirectory: false,
            category: .pdf,
            size: 248_000,
            modifiedAt: Date().addingTimeInterval(-3 * 24 * 60 * 60),
            accessedAt: Date(),
            root: root + "/Documents",
            depth: 3)
    }

    func find(query: String, category: FileCategory?, folder: String?, modifiedAfter: Date?,
              limit: Int) throws -> [FileHit] {
        log.record(toolID: "filesystem.find", arguments: ["query": query], risk: .read)
        guard query.lowercased().contains("pric") else { return [] }
        return [pricingHit]
    }

    func tree(path: String, depth: Int, limit: Int) throws -> (hits: [FileHit], total: Int) {
        log.record(toolID: "filesystem.tree", arguments: ["path": path], risk: .read)
        return ([pricingHit], 1)
    }
}

/// Every tool answer the live eval sees. One fixture per tool id; content is invented and
/// never contains the user's real mail, calendar or file names. Dates are computed from
/// `Date()` in the local time zone so "today" and "tomorrow" mean what the case says.
final class LiveEvalFixtures: @unchecked Sendable {
    let log = LiveEvalCallLog()
    let files: LiveEvalFileRetrieval

    private let today: String
    private let tomorrow: String

    init(now: Date = Date()) {
        files = LiveEvalFileRetrieval(log: log)
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        today = formatter.string(from: now)
        tomorrow = formatter.string(from: Calendar.current.date(
            byAdding: .day, value: 1, to: now) ?? now)
    }

    func beginCase() { log.clear() }
    func setTurn(_ turn: Int) { log.setTurn(turn) }
    var calls: [LiveEvalLoggedCall] { log.calls }

    /// The `AgentToolExecutor.fakeForTesting` seam. Records the call, then answers from the
    /// fixture table. It never throws: a fixture is always available.
    func run(_ tool: AgentTool, _ arguments: [String: String]) async throws -> AgentToolResult {
        log.record(toolID: tool.id, arguments: arguments, risk: tool.risk)
        return AgentToolResult(summary: summary(for: tool.id, arguments: arguments))
    }

    private func value(_ arguments: [String: String], _ name: String) -> String {
        arguments[name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func summary(for toolID: String, arguments: [String: String]) -> String {
        switch toolID {
        case "get_agenda":
            let date = value(arguments, "date")
            if date.isEmpty || date == today {
                return """
                    On \(today):
                    - 09:30–10:00 Standup
                    - 14:00–15:00 Budget review with Ana
                    - 16:30–17:00 Call with Marcus about pricing
                    """
            }
            if date == tomorrow {
                return """
                    On \(tomorrow):
                    - 08:00–08:45 Dentist
                    - 15:00–15:45 Design sync
                    - 19:00 Dinner with Cyril
                    """
            }
            return "Nothing is booked on \(date)."

        case "search_email":
            return searchEmail(arguments)

        case "read_email", "read_doc", "filesystem.read":
            return "Here is the message (fixture): the pricing sheet is attached; the deck is ready for Friday."

        case "meeting.decisions", "meeting.recent_context", "meeting.search",
             "meeting.transcript", "meeting.action_items", "meeting.participants",
             "search_knowledge", "expand_node", "timeline":
            return meetingFixture

        case "meeting.current":
            return "No meeting is in progress."

        case "memory.recall":
            return "Saved about the user: their brother is Cyril; they are the CEO of ProductFlo; they prefer short answers."

        case "memory.remember", "memory.update", "memory.forget":
            let text = value(arguments, "text").isEmpty
                ? value(arguments, "content") : value(arguments, "text")
            return "Saved: \(text.isEmpty ? "that" : text)."

        case "schedule.list":
            return "No reminders or routines yet."

        case "schedule.create", "schedule.update":
            let joined = arguments.keys.sorted()
                .map { "\($0)=\(arguments[$0] ?? "")" }.joined(separator: " · ")
            return "Reminder set (fixture): \(joined)."

        case "filesystem.find", "filesystem.search", "find_drive_files":
            return """
                Pricing 2026.pdf — Documents/ProductFlo (modified 3 days ago)
                Pricing sheet v3 — Google Drive
                """

        case "filesystem.tree":
            return """
                Documents/ProductFlo: Next Notes (project folder), Pricing 2026.pdf, Launch plan.md
                Documents/Side projects: garden-planner (project folder)
                """

        case "filesystem.reveal":
            return "Opened Pricing 2026.pdf in Finder."

        case "computer.active_app":
            return "Safari is frontmost; its window is 'YouTube'."

        case "computer.open_app":
            return "Opened \(value(arguments, "name"))."

        case "browser.navigate", "computer.open_url":
            return "Opened \(value(arguments, "url"))."

        case "browser.snapshot":
            return """
                [1] Search box
                [2] Link: Cortech — newest upload (2 days ago)
                [3] Link: Cortech — channel
                """

        case "browser.fill", "browser.click", "browser.select",
             "computer.click", "computer.type", "computer.press_key",
             "computer.focus", "computer.set_text":
            return "Done."

        case "draft_email", "send_email", "reply_email", "create_event",
             "create_doc", "append_doc", "upload_to_drive":
            let keys = arguments.keys.sorted().joined(separator: ", ")
            return "Prepared for the user's approval (nothing was sent): \(toolID) with \(keys)."

        default:
            return "Nothing found."
        }
    }

    private func searchEmail(_ arguments: [String: String]) -> String {
        let messages = [
            "1) \(today) 08:12 · Marcus Lee <marcus@productflo.example> · Pricing sheet v3 — Here is the updated pricing sheet…",
            "2) Ana Ruiz <ana@example.com> · Deck for Friday — Can you send the deck by Friday?",
            "3) GitHub · [next-notes] CI passed on main",
            "4) Cyril · Dinner tomorrow?",
            "5) Stripe · Your invoice for September",
            "6) Marcus Lee · Re: contract renewal",
        ]
        let query = value(arguments, "query").lowercased()
        let filtered = query.isEmpty ? messages : messages.filter { message in
            message.lowercased().contains(query)
                || query.split(separator: " ").contains { message.lowercased().contains($0) }
        }
        let maxResults = Int(value(arguments, "maxResults")) ?? filtered.count
        return filtered.prefix(max(0, maxResults)).joined(separator: "\n")
    }

    private var meetingFixture: String {
        "Last meeting: 'Launch planning', yesterday 10:00–10:45, with Ana, Marcus and Sarah. "
            + "Decisions: move the launch to October 14; keep the price at $12 a month. "
            + "Action items: you — send the revised budget to Ana by Thursday; Marcus — update "
            + "the pricing page. Sarah said the budget needs a 10% buffer for ads."
    }
}

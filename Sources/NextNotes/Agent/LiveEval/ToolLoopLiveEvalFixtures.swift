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

/// One message in the eval's mailbox, in the fields the real tool answers from.
///
/// P1-09 measured the shapes: `gmail users messages get --format metadata` puts the sender,
/// the subject and the date in `payload.headers[]` with `internalDate` as a string of epoch
/// milliseconds, and `WorkspaceToolRunner` reads them into a `WorkspaceMailSummary`. A query
/// can only be answered against the field it names, so the row carries the fields rather
/// than a printed line for a matcher to scan.
struct LiveEvalMessage: Sendable, Equatable {
    let stamp: Date
    let fromName: String
    let fromAddress: String
    let to: String
    let subject: String
    let snippet: String
    let unread: Bool

    /// What the real tool prints for a sender, and what `from:` is matched against.
    var from: String { "\(fromName) <\(fromAddress)>" }
    /// Everything a free-text term is matched against. Gmail searches the whole message.
    var text: String { "\(from) \(to) \(subject) \(snippet)" }
}

/// The eval's mailbox, and Gmail's query language over it.
///
/// This exists because the eval's mail answer used to be a substring scan over six
/// pre-rendered lines, which could answer **none** of the four forms `search_email`'s own
/// parameter description advertises — `from:`, `subject:`, `newer_than:`, `is:unread` — nor
/// `in:inbox`, which is what an empty query means and what the eval's own grader fixtures
/// send. Three cases were unwinnable for that reason alone (C04, M03, M05: their `mustMention`
/// asks for a subject word no answer could carry), and a query that matched nothing came
/// back as an empty string, which is indistinguishable from a tool that returned nothing —
/// C04 answered "no new email summaries were found" about a mailbox holding six messages.
///
/// Two rules, both of them about answering like the tool rather than like a lookup table:
///
/// 1. **The query is ours, the corpus is not.** `GmailQuery.normalize` and `GmailQuery.tokens`
///    are the one implementation of the grammar; a miss is `WorkspaceToolRunner`'s own
///    sentence. Nothing here re-decides what a query means.
/// 2. **A miss says so.** `No message matches <query>.` is what the tool answers, and it is
///    the difference between a model that knows its filter was wrong and one that concludes
///    the mailbox is empty.
///
/// An operator this corpus has no column for — `has:attachment`, `larger:1M` — matches
/// **nothing** rather than being ignored. Ignoring it would answer with messages that do not
/// have the attachment, which is a lie in the direction that matters.
struct LiveEvalMailbox: Sendable {
    let messages: [LiveEvalMessage]
    let now: Date

    /// The answer a model reads, or the reason it was refused.
    func search(_ rawQuery: String, maxResults: Int? = nil) -> String {
        let written = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let query: String
        let hits: [LiveEvalMessage]
        do {
            query = try WorkspaceToolRunner.GmailQuery.normalize(
                written.isEmpty ? WorkspaceToolRunner.GmailQuery.inbox : written)
            hits = matching(query)
        } catch {
            // The sentence the real tool refuses with, from the function that writes it: an
            // executor surfaces `localizedDescription`, so this is what a model reads.
            return error.localizedDescription
        }
        guard hits.isEmpty == false else { return "No message matches \(query)." }
        // Newest first, one numbered line per message. The number is load-bearing — the model
        // is told to read one in full by its number — so it is rendered here, not invented by
        // the reader.
        let ordered = hits.sorted { $0.stamp > $1.stamp }
        let shown = maxResults.map { min(max($0, 1), 25) } ?? ordered.count
        var lines: [String] = []
        for (index, mail) in ordered.prefix(shown).enumerated() {
            lines.append("\(index + 1)) \(label(for: mail.stamp)) · \(mail.from) · "
                + "\(mail.subject) — \(mail.snippet)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Matching

    private func matching(_ query: String) -> [LiveEvalMessage] {
        var required: [String: [String]] = [:]
        var excluded: [String: [String]] = [:]
        var terms: [String] = []
        var unsupported = false
        for token in WorkspaceToolRunner.GmailQuery.tokens(of: query) {
            guard let colon = token.firstIndex(of: ":"), token.hasPrefix("\"") == false else {
                terms.append(unquoted(token).lowercased())
                continue
            }
            let negated = token.hasPrefix("-")
            let name = String(token[(negated ? token.index(after: token.startIndex)
                                            : token.startIndex)..<colon]).lowercased()
            let value = unquoted(String(token[token.index(after: colon)...])).lowercased()
            guard value.isEmpty == false else { continue }
            if negated {
                excluded[name, default: []].append(value)
            } else {
                required[name, default: []].append(value)
            }
            if supported(name) == false { unsupported = true }
        }
        guard unsupported == false else { return [] }
        return messages.filter { mail in
            for (name, values) in required {
                for value in values where matches(mail, name: name, value: value) == false {
                    return false
                }
            }
            for (name, values) in excluded {
                for value in values where matches(mail, name: name, value: value) {
                    return false
                }
            }
            return terms.allSatisfy { term in
                mail.text.range(of: term, options: .caseInsensitive) != nil
            }
        }
    }

    /// The operators this corpus can answer. Everything else is refused rather than ignored.
    private func supported(_ name: String) -> Bool {
        [
            "from", "to", "cc", "bcc", "subject", "in", "label", "is",
            "newer_than", "older_than", "after", "before",
        ].contains(name)
    }

    private func matches(_ mail: LiveEvalMessage, name: String, value: String) -> Bool {
        switch name {
        case "from":
            return contains(mail.from, value) || contains(mail.fromName, value)
        case "to", "cc", "bcc":
            return contains(mail.to, value)
        case "subject":
            return contains(mail.subject, value)
        // Every message in here is in the inbox and in no other folder, so `in:` and
        // `label:` answer that question and nothing more.
        case "in", "label":
            return value == "inbox"
        case "is":
            switch value {
            case "unread": return mail.unread
            case "read": return mail.unread == false
            default: return false
            }
        case "newer_than": return days(value).map { mail.stamp > now.addingTimeInterval(-$0) } ?? false
        case "older_than": return days(value).map { mail.stamp < now.addingTimeInterval(-$0) } ?? false
        case "after": return day(value).map { mail.stamp > $0 } ?? false
        case "before": return day(value).map { mail.stamp < $0 } ?? false
        default: return false
        }
    }

    private func contains(_ haystack: String, _ needle: String) -> Bool {
        haystack.range(of: needle, options: .caseInsensitive) != nil
    }

    /// `2d`, `1m`, `6y` — Gmail's own units for the relative operators.
    private func days(_ value: String) -> TimeInterval? {
        guard value.count >= 2 else { return nil }
        let count = Double(value.dropLast()) ?? 0
        guard count > 0 else { return nil }
        switch value.last! {
        case "d": return count * 86_400
        case "w": return count * 7 * 86_400
        case "m": return count * 30 * 86_400
        case "y": return count * 365 * 86_400
        default: return nil
        }
    }

    /// `YYYY/MM/DD` at the start of that day, which is what `GmailQuery.normalize` rewrites a
    /// written `YYYY-MM-DD` into.
    private func day(_ value: String) -> Date? {
        let parts = value.split(separator: "/")
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
        else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return Calendar.current.date(from: components)
    }

    private func unquoted(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    /// The same label the real tool prints, from the same formatter settings: the date in
    /// this machine's zone, so "today" in a case means what it means in the fixture's own
    /// calendar answers.
    private func label(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "EEE d MMM HH:mm"
        return formatter.string(from: date)
    }
}

/// Every tool answer the live eval sees. One fixture per tool id; content is invented and
/// never contains the user's real mail, calendar or file names. Dates are computed from
/// `Date()` in the local time zone so "today" and "tomorrow" mean what the case says.
final class LiveEvalFixtures: @unchecked Sendable {
    let log = LiveEvalCallLog()
    let files: LiveEvalFileRetrieval
    let mailbox: LiveEvalMailbox

    private let today: String
    private let tomorrow: String

    init(now: Date = Date()) {
        files = LiveEvalFileRetrieval(log: log)
        mailbox = LiveEvalMailbox(messages: Self.mail(now: now), now: now)
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        today = formatter.string(from: now)
        tomorrow = formatter.string(from: Calendar.current.date(
            byAdding: .day, value: 1, to: now) ?? now)
    }

    /// The six messages this eval has always answered with, as fields rather than as printed
    /// lines. **No message was added, removed or renamed**: the fix is that a query is read
    /// against the field it names, and that a miss says so. Ages are relative to `now`, which
    /// is what makes `newer_than:2d` mean something on any day the eval is run.
    private static func mail(now: Date) -> [LiveEvalMessage] {
        // Keep the same mailbox and ordering at every hour. Calendar-clock stamps made
        // today's 18:20 message appear in the future during morning eval runs.
        func stamp(hoursAgo: Double) -> Date {
            now.addingTimeInterval(-hoursAgo * 3_600)
        }
        let to = "sam@productflo.example"
        return [
            LiveEvalMessage(
                stamp: stamp(hoursAgo: 3),
                fromName: "Marcus Lee", fromAddress: "marcus@productflo.example", to: to,
                subject: "Pricing sheet v3", snippet: "Here is the updated pricing sheet…",
                unread: false),
            LiveEvalMessage(
                stamp: stamp(hoursAgo: 2),
                fromName: "Ana Ruiz", fromAddress: "ana@example.com", to: to,
                subject: "Deck for Friday", snippet: "Can you send the deck by Friday?",
                unread: true),
            LiveEvalMessage(
                stamp: stamp(hoursAgo: 4),
                fromName: "GitHub", fromAddress: "no-reply@github.example", to: to,
                subject: "[next-notes] CI passed on main", snippet: "All 214 checks passed.",
                unread: false),
            LiveEvalMessage(
                stamp: stamp(hoursAgo: 1),
                fromName: "Cyril", fromAddress: "cyril@example.com", to: to,
                subject: "Dinner tomorrow?", snippet: "Are you free tomorrow evening?",
                unread: true),
            LiveEvalMessage(
                stamp: stamp(hoursAgo: 3 * 24),
                fromName: "Stripe", fromAddress: "noreply@stripe.example", to: to,
                subject: "Your invoice for September",
                snippet: "Your September invoice is ready.", unread: false),
            LiveEvalMessage(
                stamp: stamp(hoursAgo: 9 * 24),
                fromName: "Marcus Lee", fromAddress: "marcus@productflo.example", to: to,
                subject: "Re: contract renewal", snippet: "The renewal terms are attached.",
                unread: true),
        ]
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
            return mailSearch(value(arguments, "query"),
                              maxResults: Int(value(arguments, "maxResults")))

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

    /// The mailbox the `search_email` answer comes from, and the seam
    /// `--selftest-toolloop-live-grader` reads to pin it. One path: the case log and the
    /// self-test are the same query matcher.
    func mailSearch(_ query: String, maxResults: Int? = nil) -> String {
        mailbox.search(query, maxResults: maxResults)
    }

    private var meetingFixture: String {
        "Last meeting: 'Launch planning', yesterday 10:00–10:45, with Ana, Marcus and Sarah. "
            + "Decisions: move the launch to October 14; keep the price at $12 a month. "
            + "Action items: you — send the revised budget to Ana by Thursday; Marcus — update "
            + "the pricing page. Sarah said the budget needs a 10% buffer for ads."
    }
}

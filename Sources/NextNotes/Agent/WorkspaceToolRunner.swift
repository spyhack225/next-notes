import Foundation

/// Turns one tool call into `gws` invocations and their answer into something short.
///
/// Written as a switch rather than as data hung off each catalogue entry because three of
/// these are two commands rather than one — creating a Doc is `documents create` followed by
/// `+write`, searching mail is a list followed by a read of each hit — and a declarative
/// invocation format able to express "use the id from the previous step" is a small
/// interpreter nobody would be able to read afterwards.
///
/// Every command here was checked against `gws --help` for that helper; the flag names are
/// not guesses.
enum WorkspaceToolRunner {

    /// How much of a tool's answer is fed back to the model, in characters. A Drive listing
    /// or a long thread would otherwise eat the context the transcript needs.
    ///
    /// P1-10: the cap is the reader's, not a constant. Inside a planned turn the planner
    /// binds `ToolResultBudget.$readerContextTokens`, so a 262,144-token reader is allowed
    /// twelve thousand characters and a 4,096-token one seven hundred; outside one — the
    /// meeting agent, a scheduled routine, any caller with no bound reader — this is the
    /// historical 2,000, which is what those callers measured against.
    static func maxResultCharacters(toolID: String) -> Int {
        // 2,000 is the no-reader fallback: the meeting agent and a scheduled routine
        // answer on a model whose window this function cannot know, and 2,000 is what they
        // have measured against.
        guard let reader = ToolResultBudget.readerContextTokens else { return 2_000 }
        return ToolResultBudget.characterCap(readerContextTokens: reader, toolID: toolID)
    }
    /// How many messages a search lists, and how many it reads metadata for. The search's own
    /// `maxResults` argument can ask for fewer; it is clamped to `maxSearchResults`.
    static let maxSearchResults = 25
    static let defaultSearchResults = 10
    /// `gws` spawns a process per call, so a search that fetched ten messages one at a time
    /// paid ten process launches. Five at a time is where the launch cost stops being the
    /// thing being measured, and it is the number the task pins rather than a preference.
    private static let metadataConcurrency = 5

    static func run(
        _ proposal: AgentProposal,
        cli: any WorkspaceCLIRunning = GoogleWorkspaceCLI.shared
    ) async throws -> WorkspaceToolResult {
        // P1-10: the reader of the plan in flight. The planner binds it around
        // `AgentToolExecutor.run`, so every answer this runner shapes below is capped for
        // the model that will read it. Rebinding it to whatever is already in scope is a
        // no-op inside a planned turn and leaves `nil` — today's 2,000 — everywhere else.
        try await ToolResultBudget.$readerContextTokens.withValue(
            ToolResultBudget.readerContextTokens
        ) {
            try await runBounded(proposal, cli: cli)
        }
    }

    private static func runBounded(
        _ proposal: AgentProposal,
        cli: any WorkspaceCLIRunning
    ) async throws -> WorkspaceToolResult {
        guard let tool = proposal.definition else {
            throw AgentError.unknownTool(proposal.tool)
        }
        for parameter in tool.parameters where parameter.isRequired {
            let value = proposal.arguments[parameter.name]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !value.isEmpty else {
                throw AgentError.missingArgument(name: parameter.name, tool: tool.name)
            }
        }

        let arguments = proposal.arguments
        switch tool.name {
        case "search_email": return try await searchEmail(arguments, cli: cli)
        case "read_email": return try await readEmail(arguments, cli: cli)
        case "get_agenda": return try await agenda(arguments, cli: cli)
        case "find_drive_files": return try await findDriveFiles(arguments, cli: cli)
        case "read_doc": return try await readDoc(arguments, cli: cli)
        case "create_doc": return try await createDoc(arguments, cli: cli)
        case "append_doc": return try await appendDoc(arguments, cli: cli)
        case "upload_to_drive": return try await uploadToDrive(arguments, cli: cli)
        case "create_event": return try await createEvent(arguments, cli: cli)
        case "draft_email": return try await sendEmail(arguments, cli: cli, asDraft: true)
        case "send_email": return try await sendEmail(arguments, cli: cli, asDraft: false)
        case "reply_email": return try await replyEmail(arguments, cli: cli)
        default: throw AgentError.unknownTool(tool.name)
        }
    }

    // MARK: - Read

    /// The latest mail, or a filter over it — sender, date and subject, newest first.
    ///
    /// Three things were wrong with the version this replaces, and each was measured rather
    /// than argued about (09-26, against this Mac's own `gws`):
    ///
    /// 1. **It read bodies.** `+read` with `--headers` still returns the whole message, so a
    ///    five-message search fetched five bodies — and `header()` then failed to find the
    ///    sender in *any* of them, because `+read` prints `from` as `{"name","email"}` and
    ///    the old reader only looked for a top-level string or a `headers` object. That is
    ///    where "from unknown sender" on 5 of 5 audit rows came from. `messages get
    ///    --format metadata` answers the same question in 601 bytes instead of 71,698, and
    ///    puts the headers where the API documents them, in `payload.headers[]`.
    /// 2. **A query was required.** "Summarize my last 5 emails" is the most ordinary
    ///    sentence in the catalogue and the tool could not answer it, so a model that had
    ///    nothing to filter by either failed or invented a filter. An empty query is
    ///    `in:inbox`, and the count is 10 unless the caller says otherwise.
    /// 3. **It cost one process launch per message, serially.** `gws` spawns a child per
    ///    call, so ten messages was ten sequential launches. Five at a time, and the cap is
    ///    a measured number rather than a preference.
    ///
    /// **No Gmail id reaches this text.** The numbering is what the model is told to use, and
    /// `MailReferenceCache` is the only thing that maps it back — a 16-character id in a
    /// summary is both noise in the context window and something a person can read aloud.
    private static func searchEmail(
        _ arguments: [String: String],
        cli: any WorkspaceCLIRunning
    ) async throws -> WorkspaceToolResult {
        let written = (arguments["query"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let query = try GmailQuery.normalize(written.isEmpty ? GmailQuery.inbox : written)
        let count = searchCount(arguments["maxResults"])
        let listing = try await cli.run([
            "gmail", "users", "messages", "list",
            "--params", json(["userId": "me", "q": query, "maxResults": count]),
        ])
        let ids = (dictionary(from: listing)?["messages"] as? [[String: Any]] ?? [])
            .compactMap { $0["id"] as? String }
            .filter { !$0.isEmpty }
            .prefix(count)
        guard !ids.isEmpty else {
            // A success, not a failure, and the *normalised* query: a model that wrote
            // `older:1d` needs to see that `older_than:1d` is what was actually run, or the
            // next attempt repeats the same word.
            return WorkspaceToolResult(summary: "No message matches \(query).")
        }

        let summaries = await mailSummaries(for: Array(ids), cli: cli)
        guard !summaries.isEmpty else {
            return WorkspaceToolResult(summary: "No message matches \(query).")
        }
        // Newest first, whatever order the list came back in. Gmail's list order is
        // "most relevant", and a summary that puts an eight-day-old message above today's
        // reads as wrong to both the model and the person reading its answer.
        let ordered = summaries.sorted { $0.stamp > $1.stamp }
        let references = await MailReferenceCache.shared.store(ordered.map(\.id))
        var lines: [String] = []
        for (index, mail) in ordered.enumerated() {
            var line = "\(references[index]))"
            if let stamp = mailLabel(mail) { line += " \(stamp)" }
            line += " · \(mail.from)"
            line += " · \(mail.subject)"
            if !mail.snippet.isEmpty { line += " — \(mail.snippet)" }
            lines.append(line)
        }
        lines.append("To read one in full, call read_email with its number.")
        return WorkspaceToolResult(summary: truncated(lines.joined(separator: "\n"),
                                                    toolID: "search_email"))
    }

    /// Metadata for each id, at most `metadataConcurrency` at a time, in whatever order they
    /// come back — the caller sorts. A message whose metadata cannot be read is dropped
    /// rather than failed: nine answers and one gap beats ten rounds of repair.
    private static func mailSummaries(
        for ids: [String], cli: any WorkspaceCLIRunning
    ) async -> [WorkspaceMailSummary] {
        var collected: [WorkspaceMailSummary] = []
        var next = 0
        await withTaskGroup(of: WorkspaceMailSummary?.self) { group in
            func addNext() {
                guard next < ids.count else { return }
                let id = ids[next]
                next += 1
                group.addTask { await Self.mailSummary(id: id, cli: cli) }
            }
            for _ in 0..<min(metadataConcurrency, ids.count) { addNext() }
            while let summary = await group.next() {
                if let summary { collected.append(summary) }
                addNext()
            }
        }
        return collected
    }

    private static func mailSummary(
        id: String, cli: any WorkspaceCLIRunning
    ) async -> WorkspaceMailSummary? {
        guard let output = try? await cli.run([
            "gmail", "users", "messages", "get",
            "--params", json([
                "userId": "me", "id": id, "format": "metadata",
                "metadataHeaders": ["From", "Subject", "Date"],
            ]),
        ]) else { return nil }
        let fields = dictionary(from: output) ?? [:]
        return WorkspaceMailSummary(
            id: id,
            stamp: int(fields, "internalDate") ?? 0,
            from: header(fields, "from") ?? "unknown sender",
            subject: header(fields, "subject") ?? "(no subject)",
            // Gmail returns a snippet only for `format: full`, and that answer carries the
            // whole base64 body — 71,698 bytes against metadata's 601 for the same message.
            // Read when one is there, never at that price.
            snippet: snippet(from: string(fields, "snippet")))
    }

    /// One message in full, by the number the last search printed.
    ///
    /// `AgentError.notFound` would read better here, but this is a Workspace-path refusal and
    /// `WorkspaceCLIError.invalidRequest` is the one the tool loop's classifier already maps
    /// to a repair — a number nobody printed is a bad argument, and the model can correct it
    /// in the same turn rather than ending on it.
    private static func readEmail(
        _ arguments: [String: String],
        cli: any WorkspaceCLIRunning
    ) async throws -> WorkspaceToolResult {
        let reference = (arguments["message"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = await MailReferenceCache.shared.resolve(reference) else {
            throw WorkspaceCLIError.invalidRequest(
                "There is no message \(reference.isEmpty ? "here" : reference) in the last "
                + "search. Search again, then use one of the numbers it prints.")
        }
        let output = try await cli.run(["gmail", "+read", "--id", id, "--headers", "--format", "json"])
        let fields = dictionary(from: output) ?? [:]
        let body = body(of: fields)
        var lines: [String] = []
        lines.append("From: \(header(fields, "from") ?? "unknown sender")")
        if let date = header(fields, "date") { lines.append("Date: \(date)") }
        lines.append("Subject: \(header(fields, "subject") ?? "(no subject)")")
        if !body.isEmpty {
            lines.append("")
            lines.append(body)
        } else {
            lines.append("")
            lines.append("The message has no text body.")
        }
        // No `reference:` — nothing consumes one for a read, and an id carried further is an
        // id that can reach a surface somebody reads.
        return WorkspaceToolResult(summary: truncated(lines.joined(separator: "\n"),
                                                    toolID: "read_email"))
    }

    /// `+read` prefers plain text; an HTML-only message comes back with `body_text` empty and
    /// the markup under `body_html`, and an empty body read as "there is nothing here" when
    /// there is a page. The other field is the fallback rather than the first choice.
    private static func body(of fields: [String: Any]) -> String {
        if let text = fields["body_text"] as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let html = fields["body_html"] as? String,
           !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return html.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    /// A snippet as a sentence fragment: entities resolved, runs of whitespace collapsed, and
    /// a hard stop mid-word so the model never reads a half word as a fact.
    private static func snippet(from raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        var text = raw
        for entity in ["&amp;", "&lt;", "&gt;", "&quot;", "&#39;", "&apos;", "&nbsp;"] {
            text = text.replacingOccurrences(of: entity, with: " ")
        }
        text = text.replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
        text = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        while text.contains("  ") { text = text.replacingOccurrences(of: "  ", with: " ") }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > snippetCharacters else { return text }
        return String(text.prefix(snippetCharacters)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static let snippetCharacters = 140

    /// `Tue 23 Sep 08:12` — enough to order by eye, short enough to fit ten on a line.
    ///
    /// `internalDate` is epoch milliseconds **as a string** in the metadata response, which
    /// is why this is a number first and a date second. The user's locale and zone, because
    /// "08:12" means nothing without knowing whose morning it is.
    private static func mailLabel(_ mail: WorkspaceMailSummary) -> String? {
        guard mail.stamp > 0 else { return nil }
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.dateFormat = "EEE d MMM HH:mm"
        return formatter.string(from: Date(timeIntervalSince1970: Double(mail.stamp) / 1000))
    }

    /// How many messages to ask for. Unparseable is the default rather than a failure: a model
    /// that wrote "all" wanted mail, and refusing the call teaches it nothing.
    private static func searchCount(_ raw: String?) -> Int {
        guard let raw else { return defaultSearchResults }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed) else { return defaultSearchResults }
        return min(max(value, 1), maxSearchResults)
    }

    /// Gmail's own search language, as a small model writes it.
    ///
    /// Gmail answers an operator it does not have with a 400, which reaches a person as a
    /// refusal and a model as an error and is the dead end this type removes. The rewrites
    /// below are the spellings measured in this app's own turns, and a `word:` whose word is
    /// not an operator is refused here — with the operators that work named — so the tool
    /// loop can hand it back as a repair and the next call can be right.
    ///
    /// Two rules it deliberately does **not** apply, because each would be a guess:
    /// - The *value* of a known operator is passed through (`has:nothing` is `has:nothing`).
    ///   Gmail's own 400 is the answer, and the classifier treats a 400 as recoverable.
    /// - Free text is never rewritten. `"pricing sheet v3"` reaches Gmail as written.
    enum GmailQuery {
        /// What an empty search means. Not a guess: "the latest mail" with no filter is the
        /// inbox, and a model that has nothing to filter by can be told so.
        static let inbox = "in:inbox"

        /// Everything Gmail accepts after a colon. Adding a row is a widening; removing one
        /// turns a real query into a dead end, so this table only grows.
        static let operators: Set<String> = [
            "from", "to", "cc", "bcc", "subject", "label", "in", "is", "has", "filename",
            "after", "before", "older", "newer", "older_than", "newer_than", "category",
            "larger", "smaller", "list", "deliveredto", "rfc822msgid",
        ]

        /// The invented spellings and what Gmail calls them. `older`/`newer` are real search
        /// words in Gmail's own help text and are not operators, which is why they are the
        /// two models reach for most.
        static let rewrites: [String: String] = ["older": "older_than", "newer": "newer_than"]

        /// `in:` takes a folder. A model writing a date range as `in:after 2026-09-04` is
        /// naming two operators, and Gmail would read the second as a folder that does not
        /// exist — so the pair becomes the date it was reaching for.
        static let folderOperators: Set<String> = ["in", "label"]

        static func normalize(_ raw: String) throws -> String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return trimmed }
            var out: [String] = []
            // `in:after` hands its value to the *next* token, so the loop carries it.
            var awaitingValue: (name: String, negated: Bool)?
            for token in tokens(of: trimmed) {
                if let pending = awaitingValue {
                    awaitingValue = nil
                    out.append(apply(pending.name, to: token, negated: pending.negated))
                    continue
                }
                guard let colon = token.firstIndex(of: ":"), !token.hasPrefix("\"") else {
                    // Free text, or a quoted phrase. Gmail wants both exactly as written.
                    out.append(token)
                    continue
                }
                let negated = token.hasPrefix("-")
                let name = String(token[(negated ? token.index(after: token.startIndex)
                                               : token.startIndex)..<colon]).lowercased()
                let value = String(token[token.index(after: colon)...])
                guard !value.isEmpty else {
                    throw WorkspaceCLIError.invalidRequest(
                        "Gmail search \u{201c}\(name):\u{201d} has nothing after the colon. "
                        + "Useful ones: from:, subject:, newer_than:2d, is:unread, after:YYYY/MM/DD.")
                }
                guard operators.contains(name) else {
                    throw WorkspaceCLIError.invalidRequest(noSuchOperator(name))
                }
                if folderOperators.contains(name),
                   ["after", "before", "older", "newer"].contains(value.lowercased()) {
                    awaitingValue = (rewrites[value.lowercased()] ?? value.lowercased(), negated)
                    continue
                }
                out.append(apply(name, to: value, negated: negated))
            }
            if awaitingValue != nil {
                throw WorkspaceCLIError.invalidRequest(
                    "Gmail search \u{201c}in:\u{201d} needs the date after it, as after:YYYY/MM/DD.")
            }
            return out.joined(separator: " ")
        }

        /// One rewritten `name:value` token, or the same token when there is nothing to do.
        private static func apply(_ name: String, to value: String, negated: Bool) -> String {
            let prefix = negated ? "-" : ""
            let written = rewrites[name] ?? name
            if written == "after" || written == "before" {
                // Gmail's date operators want `YYYY/MM/DD`; a model writes `YYYY-MM-DD`,
                // which is the one date format it has seen most.
                return prefix + written + ":" + slashes(in: value)
            }
            return prefix + written + ":" + value
        }

        /// Gmail's date operators want `YYYY/MM/DD`; a model writes `YYYY-MM-DD`, which is
        /// the one date format it has seen most. A quoted value is unquoted on the way —
        /// `after:"2026-09-04"` and `after:2026/09/04` mean the same to Gmail, and leaving the
        /// quote in would make the rewrite silently not apply.
        private static func slashes(in value: String) -> String {
            let bare = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let parts = bare.split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
                  parts[0].count == 4, parts[1].count == 2, parts[2].count == 2
            else { return value }
            return "\(parts[0])/\(parts[1])/\(parts[2])"
        }

        /// The sentence the model gets back. It names the operators that work rather than
        /// insisting on the one that did not, because what comes next is a corrected call.
        static func noSuchOperator(_ name: String) -> String {
            "Gmail has no \u{201c}\(name):\u{201d} search. Useful ones: from:, subject:, "
            + "newer_than:2d, is:unread, after:YYYY/MM/DD."
        }

        /// Whitespace-separated tokens, with a quoted phrase kept whole.
        ///
        /// A search is not `split(separator:)`-safe: `"pricing sheet v3"` is one term to
        /// Gmail and three to a naive split, and the second reading silently changes what is
        /// being asked for. A phrase that *starts* its own token is what needs merging here;
        /// a phrase inside a value (`subject:"quarterly report"`) survives on its own,
        /// because the tokens are rejoined with the same single space and the colon belongs
        /// to the operator in front of it.
        ///
        /// Internal rather than private because the live eval's mailbox is a second reader of
        /// Gmail's grammar: it has to take a query apart to answer it, and one tokenizer is
        /// the whole point of this type.
        static func tokens(of text: String) -> [String] {
            var out: [String] = []
            var pending: [String] = []
            for word in text.split(separator: " ", omittingEmptySubsequences: true) {
                if pending.isEmpty, !word.hasPrefix("\"") {
                    out.append(String(word))
                    continue
                }
                pending.append(String(word))
                if word.hasSuffix("\"") {
                    out.append(pending.joined(separator: " "))
                    pending = []
                }
            }
            // An unterminated quote is still one term to Gmail, so it is passed on whole.
            if !pending.isEmpty { out.append(pending.joined(separator: " ")) }
            return out
        }
    }

    /// The numbers a search printed, and the message ids behind them.
    ///
    /// In memory only, and replaced rather than appended: a second search's "1)" is a
    /// different message, so a list that accumulated would let the model read a stale number
    /// and get somebody else's mail. Nothing here reaches disk — the map exists to stop a
    /// Gmail id appearing in text a person or a model reads.
    @MainActor
    final class MailReferenceCache {
        static let shared = MailReferenceCache()

        private var ids: [String] = []

        /// Stores this search's ids and returns the references to print beside them.
        func store(_ newIDs: [String]) -> [String] {
            ids = newIDs
            return newIDs.enumerated().map { "\($0.offset + 1)" }
        }

        /// A number from the last search, or a raw id the caller already had.
        func resolve(_ reference: String) -> String? {
            let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
            if let index = Int(trimmed), index >= 1, index <= ids.count { return ids[index - 1] }
            // A Gmail message id is at least 12 hex characters; a short one is a typo, and
            // passing a typo to the API is how "no such message" becomes the answer.
            guard trimmed.count >= 12, trimmed.allSatisfy(\.isHexDigit) else { return nil }
            return trimmed
        }
    }

    /// What is booked on one day.
    ///
    /// Asked for as that day's own bounds rather than as a horizon. `+agenda --days N`
    /// counts forward from today, so "what does next Thursday look like" came back as six
    /// days of events in chronological order — and `truncated` then cut off the end, which
    /// is exactly the day that was asked about. A model reading that answer concludes the
    /// day is free and proposes a meeting on top of an existing one, which is the mistake
    /// this tool exists to prevent. The generated `events list` takes `timeMin`/`timeMax`,
    /// so the API does the filtering and a day's worth of events cannot overflow the cap.
    ///
    /// The cost of leaving the helper behind is that this reads the user's main calendar
    /// rather than every calendar they subscribe to; the catalogue entry says so.
    private static func agenda(
        _ arguments: [String: String],
        cli: any WorkspaceCLIRunning
    ) async throws -> WorkspaceToolResult {
        let calendar = Calendar.current
        let start = day(from: arguments["date"])
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        let output = try await cli.run([
            "calendar", "events", "list",
            "--params", json([
                "calendarId": "primary",
                "timeMin": timestamp(start),
                "timeMax": timestamp(end),
                "singleEvents": true,
                "orderBy": "startTime",
            ]),
        ])
        let events = dictionary(from: output)?["items"] as? [[String: Any]] ?? []
        guard !events.isEmpty else {
            return WorkspaceToolResult(summary: "Nothing is booked on \(dayLabel(start)).")
        }
        let lines = events.map { event in
            "- \(when(event)) \(string(event, "summary") ?? "(no title)")"
        }
        return WorkspaceToolResult(
            summary: truncated("On \(dayLabel(start)):\n" + lines.joined(separator: "\n"),
                             toolID: "get_agenda")
        )
    }

    private static func findDriveFiles(
        _ arguments: [String: String],
        cli: any WorkspaceCLIRunning
    ) async throws -> WorkspaceToolResult {
        let query = (arguments["query"] ?? "").replacingOccurrences(of: "'", with: "\\'")
        let output = try await cli.run([
            "drive", "files", "list",
            "--params", json([
                "q": "name contains '\(query)' and trashed = false",
                "pageSize": 10,
            ]),
        ])
        let files = (dictionary(from: output)?["files"] as? [[String: Any]] ?? [])
        guard !files.isEmpty else {
            return WorkspaceToolResult(summary: "No file in Drive matches \(arguments["query"] ?? "").")
        }
        let lines = files.map { file in
            let id = file["id"] as? String ?? ""
            return "- \(file["name"] as? String ?? "(unnamed)") — id \(id)"
        }
        return WorkspaceToolResult(summary: truncated(lines.joined(separator: "\n"),
                                                    toolID: "find_drive_files"))
    }

    private static func readDoc(
        _ arguments: [String: String],
        cli: any WorkspaceCLIRunning
    ) async throws -> WorkspaceToolResult {
        let id = arguments["document_id"] ?? ""
        let output = try await cli.run([
            "docs", "documents", "get", "--params", json(["documentId": id]),
        ])
        // A Docs document is a tree of structural elements, and the raw JSON is mostly
        // styling — several hundred kilobytes for a page of text. Only the runs of text are
        // any use to a model.
        let text = documentText(in: try? output.json())
        return WorkspaceToolResult(
            summary: truncated(text.isEmpty ? "The document is empty." : text, toolID: "read_doc"),
            reference: id,
            link: documentURL(id)
        )
    }

    // MARK: - Write

    private static func createDoc(
        _ arguments: [String: String],
        cli: any WorkspaceCLIRunning
    ) async throws -> WorkspaceToolResult {
        let title = arguments["title"] ?? ""
        let created = try await cli.run([
            "docs", "documents", "create", "--json", json(["title": title]),
        ])
        guard let id = string(dictionary(from: created) ?? [:], "documentId") else {
            throw WorkspaceCLIError.badOutput
        }
        // `+write` appends plain text, so the Markdown lands as Markdown rather than as
        // headings and bullets. The alternative — a `documents.batchUpdate` carrying
        // paragraph styles — is a Markdown-to-Docs converter, and one written against a 4B
        // model's output would be wrong about more documents than it was right about.
        _ = try await cli.run([
            "docs", "+write", "--document", id, "--text", arguments["markdown"] ?? "",
        ])
        let readback = try? await cli.run([
            "docs", "documents", "get", "--params", json(["documentId": id]),
        ])
        let saved = readback.flatMap(dictionary(from:)) ?? [:]
        let verified = string(saved, "documentId") == id
            && string(saved, "title") == title
            && documentText(in: try? readback?.json()).contains(arguments["markdown"] ?? "")
        return WorkspaceToolResult(
            summary: "Created the Doc \u{201c}\(title)\u{201d}.",
            reference: id,
            link: documentURL(id),
            verification: verified ? "Read back the created document's title and content" : nil
        )
    }

    private static func appendDoc(
        _ arguments: [String: String],
        cli: any WorkspaceCLIRunning
    ) async throws -> WorkspaceToolResult {
        let id = arguments["document_id"] ?? ""
        let before = try? await cli.run([
            "docs", "documents", "get", "--params", json(["documentId": id]),
        ])
        let beforeText = documentText(in: try? before?.json())
        _ = try await cli.run([
            "docs", "+write", "--document", id, "--text", arguments["text"] ?? "",
        ])
        let readback = try? await cli.run([
            "docs", "documents", "get", "--params", json(["documentId": id]),
        ])
        let afterText = documentText(in: try? readback?.json())
        let appended = arguments["text"] ?? ""
        let verified = before != nil
            && string(readback.flatMap(dictionary(from:)) ?? [:], "documentId") == id
            && !appended.isEmpty
            && afterText.count > beforeText.count
            && afterText.contains(appended)
        return WorkspaceToolResult(
            summary: "Added to the Doc.",
            reference: id,
            link: documentURL(id),
            verification: verified ? "Read back the appended document text" : nil
        )
    }

    private static func uploadToDrive(
        _ arguments: [String: String],
        cli: any WorkspaceCLIRunning
    ) async throws -> WorkspaceToolResult {
        let path = ((arguments["path"] ?? "") as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else {
            throw WorkspaceCLIError.invalidRequest("there is no file at \(path)")
        }
        var command = ["drive", "+upload", path]
        if let name = arguments["name"], !name.isEmpty {
            command.append(contentsOf: ["--name", name])
        }
        let output = try await cli.run(command)
        let fields = dictionary(from: output) ?? [:]
        let id = string(fields, "id")
        guard let id else { throw WorkspaceCLIError.badOutput }
        let readback = try? await cli.run([
            "drive", "files", "get", "--params", json(["fileId": id]),
            "--fields", "id,name,trashed",
        ])
        let saved = readback.flatMap(dictionary(from:)) ?? [:]
        let expectedName = arguments["name"] ?? URL(fileURLWithPath: path).lastPathComponent
        let verified = string(saved, "id") == id
            && string(saved, "name") == expectedName
            && saved["trashed"] as? Bool != true
        return WorkspaceToolResult(
            summary: "Uploaded \(string(fields, "name") ?? URL(fileURLWithPath: path).lastPathComponent).",
            reference: id,
            link: URL(string: "https://drive.google.com/file/d/\(id)/view"),
            verification: verified ? "Read back the uploaded Drive file and name" : nil
        )
    }

    /// Coerces whatever the model wrote for a time into RFC 3339 with an offset.
    ///
    /// Asking clearly in the tool schema is the first half; this is the second. Google
    /// rejects anything else, and `gws --dry-run` does not catch it because it validates
    /// locally — so a wrong format survives every check the app can make and fails only
    /// once the user has already approved the action.
    ///
    /// An input that already parses as RFC 3339 is passed through untouched. One that
    /// doesn't is read in the local time zone, which is the one the meeting happened in.
    /// Anything unrecognisable is passed through as written, so the API's own complaint
    /// reaches the user rather than a date this function invented.
    static func rfc3339(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }

        let strict = ISO8601DateFormatter()
        strict.formatOptions = [.withInternetDateTime]
        if strict.date(from: trimmed) != nil { return trimmed }

        let fallbacks = [
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm",
        ]
        for format in fallbacks {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                let output = ISO8601DateFormatter()
                output.formatOptions = [.withInternetDateTime]
                output.timeZone = .current
                return output.string(from: date)
            }
        }
        return trimmed
    }

    private static func createEvent(
        _ arguments: [String: String],
        cli: any WorkspaceCLIRunning
    ) async throws -> WorkspaceToolResult {
        var command = [
            "calendar", "+insert",
            "--summary", arguments["title"] ?? "",
            "--start", rfc3339(arguments["start"] ?? ""),
            "--end", rfc3339(arguments["end"] ?? ""),
        ]
        if let description = arguments["description"], !description.isEmpty {
            command.append(contentsOf: ["--description", description])
        }
        for attendee in WorkspaceTools.list(arguments["attendees"]) {
            command.append(contentsOf: ["--attendee", attendee])
        }
        let output = try await cli.run(command)
        let fields = dictionary(from: output) ?? [:]
        guard let id = string(fields, "id") else { throw WorkspaceCLIError.badOutput }
        let readback = try? await cli.run([
            "calendar", "events", "get", "--params", json([
                "calendarId": "primary", "eventId": id,
            ]),
        ])
        let saved = readback.flatMap(dictionary(from:)) ?? [:]
        let verified = string(saved, "id") == id
            && string(saved, "summary") == arguments["title"]
            && Self.sameInstant(saved["start"], rfc3339(arguments["start"] ?? ""))
            && Self.sameInstant(saved["end"], rfc3339(arguments["end"] ?? ""))
        return WorkspaceToolResult(
            summary: "Created the event \u{201c}\(arguments["title"] ?? "")\u{201d}.",
            reference: id,
            link: string(fields, "htmlLink").flatMap(URL.init(string:)),
            verification: verified ? "Read back the event title and scheduled time" : nil
        )
    }

    // MARK: - Send

    private static func sendEmail(
        _ arguments: [String: String],
        cli: any WorkspaceCLIRunning,
        asDraft: Bool
    ) async throws -> WorkspaceToolResult {
        var command = [
            "gmail", "+send",
            "--to", WorkspaceTools.list(arguments["to"]).joined(separator: ","),
            "--subject", arguments["subject"] ?? "",
            "--body", arguments["body"] ?? "",
        ]
        if asDraft { command.append("--draft") }
        let output = try await cli.run(command)
        let fields = dictionary(from: output) ?? [:]
        // A draft's response wraps the message; a send's is the message itself.
        let message = fields["message"] as? [String: Any] ?? fields
        let threadID = string(message, "threadId")
        guard let id = string(fields, "id") ?? string(message, "id") else {
            throw WorkspaceCLIError.badOutput
        }
        let readback = try? await cli.run(asDraft
            ? ["gmail", "users", "drafts", "get", "--params", json(["userId": "me", "id": id])]
            : ["gmail", "users", "messages", "get", "--params", json(["userId": "me", "id": id])]
        )
        let saved = readback.flatMap(dictionary(from:)) ?? [:]
        let savedMessage = asDraft ? (saved["message"] as? [String: Any] ?? [:]) : saved
        let recipients = WorkspaceTools.list(arguments["to"])
        let savedTo = gmailHeader(savedMessage, "To") ?? ""
        let verified = string(saved, "id") == id
            && (asDraft || (saved["labelIds"] as? [String] ?? []).contains("SENT"))
            && gmailHeader(savedMessage, "Subject") == arguments["subject"]
            && !recipients.isEmpty
            && recipients.allSatisfy { savedTo.localizedCaseInsensitiveContains($0) }
        return WorkspaceToolResult(
            summary: asDraft ? "Saved the draft." : "Sent the email.",
            reference: id,
            link: threadID.flatMap { URL(string: "https://mail.google.com/mail/u/0/#all/\($0)") },
            verification: verified
                ? (asDraft ? "Read back the saved Gmail draft" : "Read back the message with its SENT label")
                : nil
        )
    }

    private static func replyEmail(
        _ arguments: [String: String],
        cli: any WorkspaceCLIRunning
    ) async throws -> WorkspaceToolResult {
        let output = try await cli.run([
            "gmail", "+reply",
            "--message-id", arguments["message_id"] ?? "",
            "--body", arguments["body"] ?? "",
        ])
        let fields = dictionary(from: output) ?? [:]
        let threadID = string(fields, "threadId")
        guard let id = string(fields, "id") else { throw WorkspaceCLIError.badOutput }
        let readback = try? await cli.run([
            "gmail", "users", "messages", "get", "--params", json(["userId": "me", "id": id]),
        ])
        let saved = readback.flatMap(dictionary(from:)) ?? [:]
        let verified = string(saved, "id") == id
            && (saved["labelIds"] as? [String] ?? []).contains("SENT")
            && string(saved, "threadId") == threadID
        return WorkspaceToolResult(
            summary: "Sent the reply.",
            reference: id,
            link: threadID.flatMap { URL(string: "https://mail.google.com/mail/u/0/#all/\($0)") },
            verification: verified ? "Read back the sent reply in its thread" : nil
        )
    }

    private static func sameInstant(_ calendarField: Any?, _ expected: String) -> Bool {
        guard let field = calendarField as? [String: Any],
              let actual = field["dateTime"] as? String else { return false }
        func parse(_ value: String) -> Date? {
            let parser = ISO8601DateFormatter()
            parser.formatOptions = [.withInternetDateTime]
            if let date = parser.date(from: value) { return date }
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return parser.date(from: value)
        }
        guard let actualDate = parse(actual),
              let expectedDate = parse(expected) else { return false }
        return abs(actualDate.timeIntervalSince(expectedDate)) < 1
    }

    // MARK: - JSON

    /// The `--params` / `--json` payload. `gws` takes JSON on the command line, and a
    /// hand-built string breaks on the first apostrophe in a search query.
    private static func json(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func dictionary(from output: WorkspaceCLIOutput) -> [String: Any]? {
        (try? output.json()) as? [String: Any]
    }

    /// One RFC 5322 header, wherever the build that produced this JSON put it.
    ///
    /// Five shapes, and every one of them was measured on 2026-09-26 against this Mac's own
    /// `gws` before the reader was written:
    ///
    /// 1. a top-level string — what the old reader found, and the only shape it looked for;
    /// 2. an **address object**, `{"name": …, "email": …}` — what `gmail +read --headers`
    ///    actually prints, and the reason every sender read as "unknown sender";
    /// 3. a `headers` object, `{"from": "…"}` — the helper's other layout;
    /// 4. `payload.headers[]` — what `messages get --format metadata` returns;
    /// 5. a wrapped `message` object — a draft's answer wraps the message it created.
    ///
    /// Tolerant on purpose: a missing sender should cost the model one word, not the search.
    private static func header(_ fields: [String: Any], _ name: String) -> String? {
        for candidate in [name, name.capitalized] {
            if let value = string(fields, candidate) { return value }
            if let address = fields[candidate] as? [String: Any],
               let value = addressLine(address) {
                return value
            }
            let nested = fields["headers"] as? [String: Any] ?? [:]
            if let value = string(nested, candidate) { return value }
        }
        if let value = gmailHeader(fields, name) { return value }
        if let message = fields["message"] as? [String: Any],
           let value = header(message, name) {
            return value
        }
        return nil
    }

    /// `Marcus Lee <marcus@productflo.example>`, or whichever half exists. Both halves are
    /// optional because senders really are sometimes one or the other, and a name with no
    /// address is still the answer to "who sent this".
    private static func addressLine(_ address: [String: Any]) -> String? {
        let name = string(address, "name")
        let email = string(address, "email")
        switch (name, email) {
        case let (name?, email?): return "\(name) <\(email)>"
        case let (nil, email?): return email
        case let (name?, nil): return name
        case (nil, nil): return nil
        }
    }

    private static func gmailHeader(_ message: [String: Any], _ name: String) -> String? {
        let payload = message["payload"] as? [String: Any] ?? [:]
        let headers = payload["headers"] as? [[String: Any]] ?? []
        return headers.first {
            ($0["name"] as? String)?.localizedCaseInsensitiveCompare(name) == .orderedSame
        }?["value"] as? String
    }

    private static func string(_ object: [String: Any], _ key: String) -> String? {
        guard let value = object[key] as? String, !value.isEmpty else { return nil }
        return value
    }

    /// A number that arrived as a number or as a string. `internalDate` is the second: the
    /// Gmail API returns epoch milliseconds as a JSON **string**, so a reader written for
    /// numbers alone gets `0` and every message sorts as undated.
    private static func int(_ object: [String: Any], _ key: String) -> Int? {
        if let value = object[key] as? Int { return value }
        if let value = (object[key] as? NSNumber)?.intValue { return value }
        if let text = object[key] as? String, let value = Int(text) { return value }
        return nil
    }

    private static func documentURL(_ id: String) -> URL? {
        URL(string: "https://docs.google.com/document/d/\(id)/edit")
    }

    /// Every run of text in a Docs document, in order.
    ///
    /// A recursive walk rather than a decode: the document tree is a dozen element types
    /// deep and only one of them — `textRun.content` — carries anything a summary needs.
    private static func documentText(in json: Any?) -> String {
        var pieces: [String] = []
        func walk(_ value: Any) {
            if let dictionary = value as? [String: Any] {
                if let run = dictionary["textRun"] as? [String: Any],
                   let content = run["content"] as? String {
                    pieces.append(content)
                }
                for (key, child) in dictionary where key != "textRun" { walk(child) }
            } else if let array = value as? [Any] {
                for child in array { walk(child) }
            }
        }
        if let json { walk(json) }
        return pieces.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The cap, cut the way `ToolResultBudget` cuts: at a line boundary, and saying how
    /// much was not shown. The old constant cut mid-word and appended a bare "…", which a
    /// small model reads as the end of the answer rather than as a cut.
    private static func truncated(_ text: String, toolID: String) -> String {
        ToolResultBudget.cap(text, to: maxResultCharacters(toolID: toolID))
    }

    /// The midnight the model meant. An unparseable date means today, which answers something
    /// rather than failing the whole proposal; a date in the past is honoured rather than
    /// clamped, since "was anything booked last Tuesday" has an answer.
    private static func day(from value: String?) -> Date {
        let calendar = Calendar.current
        guard let value, !value.isEmpty else { return calendar.startOfDay(for: Date()) }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        let date = formatter.date(from: String(value.prefix(10)))
            ?? ISO8601DateFormatter().date(from: value)
        return calendar.startOfDay(for: date ?? Date())
    }

    /// RFC 3339 in the user's own zone, which is what `timeMin`/`timeMax` want: sent as UTC,
    /// a day boundary lands hours into the previous or next day for most of the world.
    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    private static func dayLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    /// When one event starts, as short as it can be said. An all-day event has `date` rather
    /// than `dateTime`, and saying "00:00" for one would read as a midnight meeting.
    private static func when(_ event: [String: Any]) -> String {
        let start = event["start"] as? [String: Any] ?? [:]
        guard let value = string(start, "dateTime"),
              let date = ISO8601DateFormatter().date(from: value)
        else { return "all day —" }
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date) + " —"
    }
}

/// One message's metadata, as the search needs it: enough to rank, print and re-find, and
/// nothing else. A value rather than a dictionary because the three consumers — the sort, the
/// numbered line and the cache — each want one field, and a dictionary would let a fourth
/// consumer reach for the body.
struct WorkspaceMailSummary: Sendable {
    let id: String
    /// Epoch milliseconds, `0` when the message carried no `internalDate`.
    let stamp: Int
    let from: String
    let subject: String
    let snippet: String
}

// MARK: - The fixture half of `--selftest-gws`
//
// Every shape below is **synthetic**: invented names, subjects and addresses, written as
// string constants so the file is readable and no real mail can ever reach the repository.
// What they copy is the *shape*, which was measured against this Mac's own `gws` on
// 2026-09-26 by printing key paths only (`jq 'paths(scalars)'`) and reading the types:
//
// - `gmail users messages list` → `{"messages":[{"id","threadId"}],"resultSizeEstimate"}`.
// - `gmail users messages get --format metadata` → `payload.headers[].name/.value`,
//   `internalDate` as a **string** of epoch milliseconds. No `snippet`: Gmail only returns
//   one for `format: full`, and that answer measured 71,698 bytes against metadata's 601
//   for the same message because it carries the whole base64 body. The "do not read bodies
//   in a search" rule and the snippet are the same trade, and the body is the expensive half.
// - `gmail +read --headers --format json` → `from: {name, email}`, `to: [ {name, email} ]`,
//   `subject`, `date` (RFC 2822), `body_text`, `body_html`. **No** `payload.headers[]` and no
//   top-level string `from`, which is why the sender read as "unknown sender" on 5 of 5 rows.
//
// The whole half needs no binary, no keyring, no account and no model, which is the point:
// the rules being pinned are about the arguments the runner builds and the JSON it reads
// back, and both are reachable without asking Google anything.
extension WorkspaceToolRunner {

    /// Runs the cases and returns one line per failure. Empty means green.
    ///
    /// `MainActor` because `MailReferenceCache` is: the number→id map is app state, and a
    /// fixture that resolved a number through some other copy of it would be testing a
    /// different map than the one a turn reads.
    @MainActor
    static func selfTestFailures() async -> [String] {
        var failures: [String] = []
        func wrong(_ message: String) { failures.append(message) }

        // MARK: 1 — an empty query means the inbox, and ten is the answer
        let defaults = FakeWorkspaceCLI()
        do {
            _ = try await run(AgentProposal(
                meetingID: UUID(), tool: "search_email", arguments: [:], rationale: ""),
                cli: defaults)
            if defaults.listQuery != "in:inbox" {
                wrong("an empty query asked Gmail for \(defaults.listQuery ?? "nothing") "
                    + "rather than the inbox")
            }
            if defaults.listMaxResults != defaultSearchResults {
                wrong("a search with no count asked for \(defaults.listMaxResults.map(String.init) ?? "nothing") "
                    + "rather than \(defaultSearchResults)")
            }
        } catch {
            wrong("a search with no query failed instead of listing the latest mail: "
                + "\(error.localizedDescription)")
        }

        // MARK: 2 — three messages, three real senders, no ids in the text
        let three = FakeWorkspaceCLI(messages: SelfTestFixtures.threeMessages)
        do {
            let result = try await run(AgentProposal(
                meetingID: UUID(), tool: "search_email", arguments: [:], rationale: ""),
                cli: three)
            let text = result.summary
            for expected in ["Marcus Lee", "Ana Ruiz", "GitHub"] where !text.contains(expected) {
                wrong("a search over three fixtures did not name the sender \(expected): \(bounded(text))")
            }
            if text.contains("unknown sender") {
                wrong("a search still reads senders as unknown: \(bounded(text))")
            }
            for id in SelfTestFixtures.ids where text.contains(id) {
                wrong("a Gmail id reached text the model reads: \(id)")
            }
            // Newest first, and one numbered line per message. The order is the assertion
            // rather than the rendered date, which is locale-shaped and would be a test of
            // the machine's region settings.
            let numbers = text.split(separator: "\n").compactMap { line -> Int? in
                let head = line.split(separator: ")").first.map(String.init) ?? ""
                return Int(head.trimmingCharacters(in: .whitespaces))
            }
            if numbers != [1, 2, 3] {
                wrong("a search's lines are not numbered 1, 2, 3: \(numbers)")
            }
            let subjectsInOrder = ["Pricing sheet v3", "Deck for Friday", "CI passed on main"]
            var cursor = text.startIndex
            for subject in subjectsInOrder {
                guard let range = text.range(of: subject, range: cursor..<text.endIndex) else {
                    wrong("a search did not list \(subject) in newest-first order: \(bounded(text))")
                    break
                }
                cursor = range.upperBound
            }
            for expected in ["Marcus", "marcus@", "Pricing"] where !text.contains(expected) {
                wrong("a search dropped \(expected): \(bounded(text))")
            }
        } catch {
            wrong("a search over three fixtures failed: \(error.localizedDescription)")
        }

        // MARK: 3 — `read_email` reads the number the last search printed
        do {
            _ = try await run(AgentProposal(
                meetingID: UUID(), tool: "search_email", arguments: [:], rationale: ""),
                cli: three)
            let reader = FakeWorkspaceCLI(messages: SelfTestFixtures.threeMessages)
            let result = try await run(AgentProposal(
                meetingID: UUID(), tool: "read_email", arguments: ["message": "2"], rationale: ""),
                cli: reader)
            if reader.readID != SelfTestFixtures.ids[1] {
                wrong("read_email(\"2\") asked for \(reader.readID ?? "nothing") "
                    + "rather than the second id of the last search")
            }
            if !result.summary.contains("Ana Ruiz") {
                wrong("read_email lost the sender: \(bounded(result.summary))")
            }
            if !result.summary.contains("Can you send the deck by Friday") {
                wrong("read_email lost the body: \(bounded(result.summary))")
            }
            if result.summary.count > maxResultCharacters(toolID: "read_email") + 40 {
                wrong("read_email returned \(result.summary.count) characters, over the cap")
            }
        } catch {
            wrong("read_email over a fixture failed: \(error.localizedDescription)")
        }
        // A number nobody printed is a bad argument, not a message that does not exist.
        do {
            _ = try await run(AgentProposal(
                meetingID: UUID(), tool: "read_email", arguments: ["message": "9"], rationale: ""),
                cli: FakeWorkspaceCLI(messages: SelfTestFixtures.threeMessages))
            wrong("read_email accepted a number the last search never printed")
        } catch WorkspaceCLIError.invalidRequest(let detail) {
            if detail.contains("9") == false {
                wrong("an unknown reference is refused without saying which: \(detail)")
            }
        } catch {
            wrong("an unknown reference failed as \(type(of: error)) rather than a request "
                + "the model can correct")
        }

        // MARK: 4 — the invented operators, both directions
        for (raw, expected) in [
            ("older:1d", "older_than:1d"),
            ("newer:2d", "newer_than:2d"),
            ("after:2026-09-04", "after:2026/09/04"),
            ("in:after 2026-09-04", "after:2026/09/04"),
            ("from:ana@x.com deck", "from:ana@x.com deck"),
            ("is:unread", "is:unread"),
            ("in:inbox", "in:inbox"),
            ("newer_than:2d -is:read", "newer_than:2d -is:read"),
            ("subject:\"quarterly report\"", "subject:\"quarterly report\""),
            ("after:\"2026-09-04\"", "after:2026/09/04"),
            ("\"pricing sheet v3\"", "\"pricing sheet v3\""),
        ] {
            do {
                let normalized = try GmailQuery.normalize(raw)
                if normalized != expected {
                    wrong("normalize(\(raw)) is \(normalized), not \(expected)")
                }
            } catch {
                wrong("normalize(\(raw)) was refused: \(error.localizedDescription)")
            }
        }
        for raw in ["foo:bar", "older_than:"] {
            do {
                let normalized = try GmailQuery.normalize(raw)
                wrong("normalize(\(raw)) accepted it as \(normalized)")
            } catch WorkspaceCLIError.invalidRequest(let detail) {
                // The message is the whole point: it is what the tool loop hands back to the
                // model as a repair, and a bare "invalid" would be the dead end this removes.
                if detail.contains("newer_than:2d") == false {
                    wrong("an unknown operator's message names no usable operator: \(detail)")
                }
            } catch {
                wrong("normalize(\(raw)) threw \(type(of: error)) rather than invalidRequest")
            }
        }
        // A known operator with an odd *value* is passed through, not second-guessed here:
        // Gmail's own 400 is the answer, and the tool loop classifies a 400 as recoverable.
        // Inventing a value table here would be a guess about a list that changes.
        if let passthrough = try? GmailQuery.normalize("has:nothing"), passthrough != "has:nothing" {
            wrong("normalize(\"has:nothing\") rewrote a known operator's value to \(passthrough)")
        }

        // MARK: 5 — the count is clamped, and a bad one is not a failure
        let wide = FakeWorkspaceCLI()
        do {
            _ = try await run(AgentProposal(
                meetingID: UUID(), tool: "search_email",
                arguments: ["maxResults": "40"], rationale: ""), cli: wide)
            if wide.listMaxResults != maxSearchResults {
                wrong("maxResults \"40\" asked Gmail for \(wide.listMaxResults.map(String.init) ?? "nothing") "
                    + "rather than the \(maxSearchResults)-message ceiling")
            }
            let narrow = FakeWorkspaceCLI()
            _ = try await run(AgentProposal(
                meetingID: UUID(), tool: "search_email",
                arguments: ["maxResults": "0"], rationale: ""), cli: narrow)
            if narrow.listMaxResults != 1 {
                wrong("maxResults \"0\" asked for \(narrow.listMaxResults.map(String.init) ?? "nothing") "
                    + "rather than one message")
            }
            let nonsense = FakeWorkspaceCLI()
            _ = try await run(AgentProposal(
                meetingID: UUID(), tool: "search_email",
                arguments: ["maxResults": "all"], rationale: ""), cli: nonsense)
            if nonsense.listMaxResults != defaultSearchResults {
                wrong("maxResults \"all\" asked for \(nonsense.listMaxResults.map(String.init) ?? "nothing") "
                    + "rather than the default \(defaultSearchResults)")
            }
        } catch {
            wrong("search_email refused a maxResults it should have clamped: \(error.localizedDescription)")
        }

        // MARK: 6 — a filter that matches nothing is an answer, and says what it searched
        do {
            let empty = FakeWorkspaceCLI(messages: [])
            let result = try await run(AgentProposal(
                meetingID: UUID(), tool: "search_email",
                arguments: ["query": "older:1d"], rationale: ""), cli: empty)
            if result.summary.contains("older_than:1d") == false {
                wrong("an empty result does not show the query that was actually run: "
                    + result.summary)
            }
            if empty.readIDs.isEmpty == false {
                wrong("a search that matched nothing still fetched \(empty.readIDs.count) messages")
            }
        } catch {
            wrong("a search that matched nothing failed: \(error.localizedDescription)")
        }

        // MARK: 7 — five at a time, never more
        let many = FakeWorkspaceCLI(messages: SelfTestFixtures.tenMessages)
        do {
            _ = try await run(AgentProposal(
                meetingID: UUID(), tool: "search_email", arguments: [:], rationale: ""), cli: many)
            if many.peakConcurrency > metadataConcurrency {
                wrong("a search ran \(many.peakConcurrency) metadata reads at once, over the "
                    + "cap of \(metadataConcurrency)")
            }
            if many.readIDs.count != SelfTestFixtures.tenMessages.count {
                wrong("a search of ten messages fetched \(many.readIDs.count)")
            }
        } catch {
            wrong("a ten-message search failed: \(error.localizedDescription)")
        }

        // MARK: 8 — the registry and the roster
        if WorkspaceTools.tool(named: "read_email") == nil {
            wrong("read_email is not in the Workspace catalogue, so nothing can be routed to it")
        } else {
            let registered = AgentToolRegistry.shared.tool(named: "read_email")
            if registered == nil {
                wrong("read_email is not registered in the tool registry")
            } else if registered?.risk != .read {
                wrong("read_email is \(registered?.risk.rawValue ?? "?") rather than a read, so "
                    + "reading somebody's mail would ask for approval it does not need")
            }
            if AgentToolRegistry.shared.tool(named: "workspace.read_email") == nil {
                wrong("read_email has no workspace alias")
            }
        }
        if AgentCapabilityManifestBuilder.intent(
            for: AgentToolRegistry.shared.tool(named: "read_email")
                ?? AgentTool.workspace(WorkspaceTool(
                    name: "read_email", summary: "", risk: .read, parameters: [],
                    titleBuilder: { $0["message"] ?? "" }, previewBuilder: nil))
        ) != .mail {
            wrong("read_email is not in the mail class, so a question about email does not reach it")
        }
        let mailCapability = AgentRefusalGuard.capabilities.first {
            $0.toolIDs.contains("search_email")
        }
        if mailCapability?.toolIDs.contains("read_email") == false {
            wrong("the refusal guard's email capability does not name read_email, so denying "
                + "it is not corrected")
        }

        // MARK: 9 — the write half is unreachable from a fixture run
        //
        defer { try? FileManager.default.removeItem(at: SelfTestFixtures.fixtureFile) }
        //
        // Not a formality: this half runs under a `--selftest-*` flag on a Mac whose `gws` is
        // signed in, so anything that reached a write tool here would send on a real account.
        // The fixtures answer reads and nothing else, and this case is what says so.
        for tool in WorkspaceTools.all where tool.risk > .read {
            let arguments = SelfTestFixtures.writeArguments(for: tool.name)
            do {
                let result = try await run(AgentProposal(
                    meetingID: UUID(), tool: tool.name, arguments: arguments, rationale: ""),
                    cli: FakeWorkspaceCLI(messages: SelfTestFixtures.threeMessages))
                wrong("\(tool.name) is a \(tool.risk.rawValue) tool and a read-shaped fake "
                    + "answered it: \(bounded(result.summary))")
            } catch WorkspaceCLIError.notInstalled, WorkspaceCLIError.notAuthenticated {
                // Right: the fake is not a Workspace account, and a write is refused before
                // any command is built.
            } catch {
                // Any other refusal is a refusal. Nothing above `.read` may succeed here.
            }
        }

        return failures
    }

    private static func bounded(_ text: String) -> String {
        let oneLine = text.replacingOccurrences(of: "\n", with: " | ")
        return String(oneLine.prefix(220))
    }
}

/// A `gws` that answers from a dictionary instead of from Google.
///
/// Keyed by the argument list, because that is the thing worth asserting: the shape of the
/// command the runner builds. Records the list query, the count, every id it was asked to
/// read, and the high-water mark of concurrent reads, so "five at a time" is measured rather
/// than asserted in a comment. Every write tool raises `notInstalled` instead of answering,
/// which is what keeps this half from performing one even if the catalogue is edited.
private final class FakeWorkspaceCLI: WorkspaceCLIRunning, @unchecked Sendable {
    private static let writeCommands: Set<String> = [
        "+send", "+reply", "+insert", "+write", "+upload", "create", "trash", "delete", "batchUpdate",
    ]

    private let messages: [WorkspaceSelfTestMail]
    private let lock = NSLock()
    private var listQueryValue: String?
    private var listMaxResultsValue: Int?
    private var readIDsValue: [String] = []
    private var readIDValue: String?
    private var inFlight = 0
    private var peakInFlight = 0

    init(messages: [WorkspaceSelfTestMail] = []) {
        self.messages = messages
    }

    var listQuery: String? { lock.withLock { listQueryValue } }
    var listMaxResults: Int? { lock.withLock { listMaxResultsValue } }
    var readIDs: [String] { lock.withLock { readIDsValue } }
    var readID: String? { lock.withLock { readIDValue } }
    var peakConcurrency: Int { lock.withLock { peakInFlight } }

    func run(_ arguments: [String], timeout: TimeInterval) async throws -> WorkspaceCLIOutput {
        // Every command that creates or sends is refused here, by verb, before anything is
        // parsed: this fake has no account and must never be the reason one is used. The verbs
        // are the `gws` helper names and the one generated `create` that mutates.
        let verbs: [String] = arguments.dropFirst()
            .filter { !$0.hasPrefix("-") }
            .prefix(3)
            .map { String($0) }
        if verbs.contains(where: Self.writeCommands.contains) {
            throw WorkspaceCLIError.notInstalled
        }
        if arguments.contains("+read") {
            let id = Self.value(after: "--id", in: arguments) ?? ""
            lock.withLock { readIDValue = id }
            guard let mail = messages.first(where: { $0.id == id }) else {
                throw WorkspaceCLIError.apiFailed("404 not found")
            }
            return json(mail.readFixture)
        }
        if arguments.contains("list") {
            let params = Self.value(after: "--params", in: arguments) ?? ""
            lock.withLock {
                listQueryValue = Self.string(in: params, key: "q")
                listMaxResultsValue = Self.int(in: params, key: "maxResults")
            }
            return json(["messages": messages.map { ["id": $0.id, "threadId": "t-\($0.id)"] },
                         "resultSizeEstimate": messages.count])
        }
        if arguments.contains("get") {
            let params = Self.value(after: "--params", in: arguments) ?? ""
            let id = Self.string(in: params, key: "id") ?? ""
            lock.withLock {
                readIDsValue.append(id)
                inFlight += 1
                peakInFlight = max(peakInFlight, inFlight)
            }
            defer { lock.withLock { inFlight -= 1 } }
            guard let mail = messages.first(where: { $0.id == id }) else {
                throw WorkspaceCLIError.apiFailed("404 not found")
            }
            return json(mail.metadataFixture)
        }
        throw WorkspaceCLIError.badOutput
    }

    private func json(_ object: Any) -> WorkspaceCLIOutput {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data("{}".utf8)
        return WorkspaceCLIOutput(standardOutput: data, standardError: "", exitCode: 0)
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func parsed(_ params: String) -> [String: Any] {
        guard let data = params.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    private static func string(in params: String, key: String) -> String? {
        parsed(params)[key] as? String
    }

    private static func int(in params: String, key: String) -> Int? {
        (parsed(params)[key] as? NSNumber)?.intValue
    }
}

/// One synthetic message, in the two shapes `gws` actually returned on 2026-09-26.
struct WorkspaceSelfTestMail {
    let id: String
    let internalDate: String
    let fromName: String
    let fromAddress: String
    let subject: String
    let body: String

    /// `gmail users messages get --format metadata`, measured.
    var metadataFixture: [String: Any] {
        [
            "id": id, "threadId": "t-\(id)", "internalDate": internalDate,
            "labelIds": ["INBOX", "UNREAD"],
            "sizeEstimate": 2_048,
            "payload": [
                "partId": "", "mimeType": "text/plain",
                "headers": [
                    ["name": "From", "value": "\(fromName) <\(fromAddress)>"],
                    ["name": "Subject", "value": subject],
                    ["name": "Date", "value": "Tue, 23 Sep 2026 08:12:00 -0400"],
                ],
            ] as [String: Any],
        ]
    }

    /// `gmail +read --headers --format json`, measured. `from` is an object, not a string,
    /// and there is no `payload.headers[]` anywhere in it.
    var readFixture: [String: Any] {
        [
            "message_id": "\(id)@mail.example",
            "thread_id": "t-\(id)",
            "from": ["name": fromName, "email": fromAddress],
            "to": [["name": nil, "email": "reader@mail.example"]],
            "cc": NSNull(),
            "subject": subject,
            "date": "Tue, 23 Sep 2026 08:12:00 -0400",
            "references": [String](),
            "body_text": body,
            "body_html": "",
        ]
    }
}

/// The fixtures themselves. Invented people, invented companies, invented mail — the shapes
/// are measured, the content is not anybody's.
enum SelfTestFixtures {
    static let ids = ["aaa111bbb222ccc", "ddd333eee444fff", "ggg555hhh666iii"]

    /// Newest first is the order the search must produce, so `internalDate` descends with
    /// the list: 23 Sep 08:12, 22 Sep 17:40, 21 Sep 09:05.
    static let threeMessages: [WorkspaceSelfTestMail] = [
        WorkspaceSelfTestMail(
            id: ids[0], internalDate: "1790165520000",
            fromName: "Marcus Lee", fromAddress: "marcus@productflo.example",
            subject: "Pricing sheet v3",
            body: "Here is the updated pricing sheet. The deck goes out on Friday."),
        WorkspaceSelfTestMail(
            id: ids[1], internalDate: "1790079600000",
            fromName: "Ana Ruiz", fromAddress: "ana@productflo.example",
            subject: "Deck for Friday",
            body: "Can you send the deck by Friday? I need it for the review."),
        WorkspaceSelfTestMail(
            id: ids[2], internalDate: "1789991100000",
            fromName: "GitHub", fromAddress: "no-reply@github.example",
            subject: "CI passed on main",
            body: "The build finished. One warning about an unused import."),
    ]

    /// Ten, for the concurrency ceiling. Same three people, ten messages, invented subjects.
    static let tenMessages: [WorkspaceSelfTestMail] = (0..<10).map { index in
        let people = [
            ("Marcus Lee", "marcus@productflo.example"),
            ("Ana Ruiz", "ana@productflo.example"),
            ("GitHub", "no-reply@github.example"),
        ][index % 3]
        return WorkspaceSelfTestMail(
            id: String(format: "%012x", 0xA0000 + index),
            internalDate: String(1_790_000_000_000 - index * 3_600_000),
            fromName: people.0, fromAddress: people.1,
            subject: "Message \(index + 1)",
            body: "Body \(index + 1).")
    }

    /// A complete, harmless argument set per write tool, so the case in
    /// `selfTestFailures()` can offer one without ever inventing a recipient.
    static func writeArguments(for tool: String) -> [String: String] {
        switch tool {
        case "create_event":
            ["title": "Fixture event", "start": "2026-09-23T08:12:00-04:00",
             "end": "2026-09-23T08:42:00-04:00"]
        case "upload_to_drive":
            ["path": SelfTestFixtures.fixtureFile.path, "name": "fixture.txt"]
        case "reply_email":
            ["message_id": ids[0], "body": "Nothing was sent; this is a fixture."]
        case "send_email", "draft_email":
            ["to": "nobody@productflo.example", "subject": "Fixture",
             "body": "Nothing was sent; this is a fixture."]
        default:
            ["document_id": "fixture-doc", "title": "Fixture",
             "markdown": "Fixture.", "text": "Fixture."]
        }
    }

    /// A file that exists so `upload_to_drive`'s own pre-flight passes and the refusal comes
    /// from the fake, not from a missing path. In the temporary directory, and removed.
    static let fixtureFile: URL = {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nextnotes-gws-fixture-\(ProcessInfo.processInfo.processIdentifier).txt")
        try? "fixture".write(to: url, atomically: true, encoding: .utf8)
        return url
    }()
}

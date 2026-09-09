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
    static let maxResultCharacters = 2_000
    /// How many messages a search reads in full. Each is its own `gws` call.
    private static let searchResultLimit = 5

    static func run(
        _ proposal: AgentProposal,
        cli: GoogleWorkspaceCLI = .shared
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

    private static func searchEmail(
        _ arguments: [String: String],
        cli: GoogleWorkspaceCLI
    ) async throws -> WorkspaceToolResult {
        let query = arguments["query"] ?? ""
        let listing = try await cli.run([
            "gmail", "users", "messages", "list",
            "--params", json(["userId": "me", "q": query, "maxResults": searchResultLimit]),
        ])
        let ids = (dictionary(from: listing)?["messages"] as? [[String: Any]] ?? [])
            .compactMap { $0["id"] as? String }
        guard !ids.isEmpty else {
            return WorkspaceToolResult(summary: "No message matches \(query).")
        }

        var lines: [String] = []
        for id in ids.prefix(searchResultLimit) {
            // Headers only would be ideal, but `+read` returns the body with them and the
            // first line of a message is usually what says whether it is the right one.
            guard let message = try? await cli.run(
                ["gmail", "+read", "--id", id, "--headers", "--format", "json"]
            ) else { continue }
            let fields = dictionary(from: message) ?? [:]
            let from = header(fields, "from") ?? "unknown sender"
            let subject = header(fields, "subject") ?? "(no subject)"
            lines.append("- id \(id) — from \(from) — \(subject)")
        }
        return WorkspaceToolResult(summary: truncated(lines.joined(separator: "\n")))
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
        cli: GoogleWorkspaceCLI
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
            summary: truncated("On \(dayLabel(start)):\n" + lines.joined(separator: "\n"))
        )
    }

    private static func findDriveFiles(
        _ arguments: [String: String],
        cli: GoogleWorkspaceCLI
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
        return WorkspaceToolResult(summary: truncated(lines.joined(separator: "\n")))
    }

    private static func readDoc(
        _ arguments: [String: String],
        cli: GoogleWorkspaceCLI
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
            summary: truncated(text.isEmpty ? "The document is empty." : text),
            reference: id,
            link: documentURL(id)
        )
    }

    // MARK: - Write

    private static func createDoc(
        _ arguments: [String: String],
        cli: GoogleWorkspaceCLI
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
        return WorkspaceToolResult(
            summary: "Created the Doc \u{201c}\(title)\u{201d}.",
            reference: id,
            link: documentURL(id)
        )
    }

    private static func appendDoc(
        _ arguments: [String: String],
        cli: GoogleWorkspaceCLI
    ) async throws -> WorkspaceToolResult {
        let id = arguments["document_id"] ?? ""
        _ = try await cli.run([
            "docs", "+write", "--document", id, "--text", arguments["text"] ?? "",
        ])
        return WorkspaceToolResult(
            summary: "Added to the Doc.",
            reference: id,
            link: documentURL(id)
        )
    }

    private static func uploadToDrive(
        _ arguments: [String: String],
        cli: GoogleWorkspaceCLI
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
        return WorkspaceToolResult(
            summary: "Uploaded \(string(fields, "name") ?? URL(fileURLWithPath: path).lastPathComponent).",
            reference: id,
            link: id.flatMap { URL(string: "https://drive.google.com/file/d/\($0)/view") }
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
        cli: GoogleWorkspaceCLI
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
        return WorkspaceToolResult(
            summary: "Created the event \u{201c}\(arguments["title"] ?? "")\u{201d}.",
            reference: string(fields, "id"),
            link: string(fields, "htmlLink").flatMap(URL.init(string:))
        )
    }

    // MARK: - Send

    private static func sendEmail(
        _ arguments: [String: String],
        cli: GoogleWorkspaceCLI,
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
        return WorkspaceToolResult(
            summary: asDraft ? "Saved the draft." : "Sent the email.",
            reference: string(fields, "id") ?? string(message, "id"),
            link: threadID.flatMap { URL(string: "https://mail.google.com/mail/u/0/#all/\($0)") }
        )
    }

    private static func replyEmail(
        _ arguments: [String: String],
        cli: GoogleWorkspaceCLI
    ) async throws -> WorkspaceToolResult {
        let output = try await cli.run([
            "gmail", "+reply",
            "--message-id", arguments["message_id"] ?? "",
            "--body", arguments["body"] ?? "",
        ])
        let fields = dictionary(from: output) ?? [:]
        let threadID = string(fields, "threadId")
        return WorkspaceToolResult(
            summary: "Sent the reply.",
            reference: string(fields, "id"),
            link: threadID.flatMap { URL(string: "https://mail.google.com/mail/u/0/#all/\($0)") }
        )
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

    /// One RFC 5322 header out of `+read --headers`, wherever that build puts them.
    ///
    /// Tolerant on purpose: the helper is free to print `from` at the top level or under a
    /// `headers` object, and header names keep their original capitalisation. A missing
    /// sender should cost the model one line of context, not the whole search.
    private static func header(_ fields: [String: Any], _ name: String) -> String? {
        let nested = fields["headers"] as? [String: Any] ?? [:]
        for candidate in [name, name.capitalized] {
            if let value = string(fields, candidate) ?? string(nested, candidate) { return value }
        }
        return nil
    }

    private static func string(_ object: [String: Any], _ key: String) -> String? {
        guard let value = object[key] as? String, !value.isEmpty else { return nil }
        return value
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

    private static func truncated(_ text: String) -> String {
        guard text.count > maxResultCharacters else { return text }
        return String(text.prefix(maxResultCharacters)) + "\n…"
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

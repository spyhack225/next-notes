import Foundation

/// One thing the agent can offer to do, described once for three audiences.
///
/// The model sees `name`, `summary` and the JSON schema built from `parameters`; the user
/// sees `title(for:)` and, for anything that speaks in their name, `preview(for:)`; the
/// runner sees the name and switches on it. Keeping all three in one entry is what stops a
/// tool being offered to the model that the runner can't perform, which is the failure this
/// catalogue exists to prevent.
struct WorkspaceTool: Sendable, Identifiable {
    let name: String
    let summary: String
    let risk: AgentRisk
    let parameters: [Parameter]
    /// One line for the card. Takes the arguments because "Create a Doc" is not as useful
    /// as the title of the document being created.
    let titleBuilder: @Sendable ([String: String]) -> String
    /// The full text of what would be said, for the tools that say things.
    let previewBuilder: (@Sendable ([String: String]) -> String?)?

    var id: String { name }

    func title(for arguments: [String: String]) -> String { titleBuilder(arguments) }
    func preview(for arguments: [String: String]) -> String? { previewBuilder?(arguments) }

    /// A named argument, in the shape both the JSON schema and the editor need.
    struct Parameter: Sendable, Identifiable {
        let name: String
        let description: String
        var isRequired = true
        var kind = Kind.text

        var id: String { name }

        /// What the editor should show, and how the runner reads the value back. Everything
        /// crosses the boundary as a string — these say what kind of string.
        enum Kind: Sendable {
            /// One line.
            case text
            /// Several lines: an email body, a document.
            case multiline
            /// Comma-separated, split by the runner. `gws` takes comma-separated recipients
            /// and repeated `--attendee` flags, and both come from one field here.
            case list
            /// ISO 8601, or a plain `YYYY-MM-DD`.
            case date
        }

        /// The JSON-schema type. Everything is a string: the model writes command-line
        /// arguments, and a schema that promises an array produces one that then has to be
        /// flattened back into a flag anyway.
        var schema: [String: Any] {
            var schema: [String: Any] = ["type": "string", "description": description]
            switch kind {
            case .list: schema["description"] = "\(description) Comma-separated."
            case .date: schema["description"] = "\(description) ISO 8601."
            case .text, .multiline: break
            }
            return schema
        }
    }
}

/// Everything the agent is allowed to propose.
///
/// Deliberately small. `gws` exposes every Workspace API there is, and handing a 4B model a
/// hundred generated endpoints produces confident calls to the wrong one; these eleven are
/// the actions a meeting actually ends in, and each maps to a `gws` invocation that has been
/// read rather than guessed.
enum WorkspaceTools {

    static let all: [WorkspaceTool] = [
        // MARK: Read

        WorkspaceTool(
            name: "search_email",
            summary: "Search the user's Gmail and return the matching messages' senders, "
                + "subjects and ids. Use Gmail's own search syntax.",
            risk: .read,
            parameters: [
                .init(name: "query", description: "A Gmail search query, e.g. from:ana@x.com deck.")
            ],
            titleBuilder: { "Search email for \u{201c}\($0["query"] ?? "")\u{201d}" },
            previewBuilder: nil
        ),
        WorkspaceTool(
            name: "get_agenda",
            summary: "List what is on the user's main calendar for one day, to check what "
                + "is already booked before proposing a new meeting.",
            risk: .read,
            parameters: [
                .init(
                    name: "date",
                    description: "The day to list, as YYYY-MM-DD.",
                    kind: .date
                )
            ],
            titleBuilder: { "Check the agenda for \($0["date"] ?? "today")" },
            previewBuilder: nil
        ),
        WorkspaceTool(
            name: "find_drive_files",
            summary: "Find files in the user's Google Drive by name, and return their names, "
                + "ids and links.",
            risk: .read,
            parameters: [
                .init(name: "query", description: "Words from the file's name.")
            ],
            titleBuilder: { "Find \u{201c}\($0["query"] ?? "")\u{201d} in Drive" },
            previewBuilder: nil
        ),
        WorkspaceTool(
            name: "read_doc",
            summary: "Read the text of a Google Doc the user can open, by its document id.",
            risk: .read,
            parameters: [
                .init(name: "document_id", description: "The Google Docs document id.")
            ],
            titleBuilder: { "Read the Doc \($0["document_id"] ?? "")" },
            previewBuilder: nil
        ),

        // MARK: Write

        WorkspaceTool(
            name: "create_doc",
            summary: "Create a new Google Doc with a title and a body of Markdown. Use this "
                + "to put the meeting notes somewhere the other participants can read them.",
            risk: .write,
            parameters: [
                .init(name: "title", description: "The document's title."),
                .init(
                    name: "markdown",
                    description: "The document's body, in Markdown.",
                    kind: .multiline
                ),
            ],
            titleBuilder: { "Create the Doc \u{201c}\($0["title"] ?? "")\u{201d}" },
            previewBuilder: { $0["markdown"] }
        ),
        WorkspaceTool(
            name: "append_doc",
            summary: "Append text to the end of an existing Google Doc.",
            risk: .write,
            parameters: [
                .init(name: "document_id", description: "The document to append to."),
                .init(name: "text", description: "The text to append.", kind: .multiline),
            ],
            titleBuilder: { "Add to the Doc \($0["document_id"] ?? "")" },
            previewBuilder: { $0["text"] }
        ),
        WorkspaceTool(
            name: "upload_to_drive",
            summary: "Upload a local file to the user's Google Drive.",
            risk: .write,
            parameters: [
                .init(name: "path", description: "The absolute path of the local file."),
                .init(
                    name: "name",
                    description: "The name the file should have in Drive.",
                    isRequired: false
                ),
            ],
            titleBuilder: { arguments in
                let name = arguments["name"]
                    ?? (arguments["path"].map { URL(fileURLWithPath: $0).lastPathComponent } ?? "")
                return "Upload \(name) to Drive"
            },
            previewBuilder: nil
        ),
        WorkspaceTool(
            name: "create_event",
            summary: "Create a calendar event, for a follow-up that was given a date.",
            risk: .write,
            parameters: [
                .init(name: "title", description: "The event's title."),
                // Spelled out because "When it starts." is not a specification, and a 4B
                // model answering it produces "1:40 PM" or "today at 2" — which Google
                // refuses at the API, long after any local validation has passed.
                // `WorkspaceToolRunner` normalises what still arrives in another shape.
                .init(
                    name: "start",
                    description: "When it starts, RFC 3339 with an offset, "
                        + "e.g. 2026-09-09T13:40:00-04:00.",
                    kind: .date
                ),
                .init(
                    name: "end",
                    description: "When it ends, same format as start, "
                        + "e.g. 2026-09-09T14:10:00-04:00.",
                    kind: .date
                ),
                .init(
                    name: "attendees",
                    description: "Email addresses to invite.",
                    isRequired: false,
                    kind: .list
                ),
                .init(
                    name: "description",
                    description: "What the event is about.",
                    isRequired: false,
                    kind: .multiline
                ),
            ],
            titleBuilder: { "Schedule \u{201c}\($0["title"] ?? "")\u{201d}" },
            previewBuilder: nil
        ),
        WorkspaceTool(
            name: "draft_email",
            summary: "Save an email as a draft in the user's Gmail, without sending it. "
                + "Prefer this when you are unsure whether the message should go out.",
            risk: .write,
            parameters: [
                .init(name: "to", description: "Recipient addresses.", kind: .list),
                .init(name: "subject", description: "The subject line."),
                .init(name: "body", description: "The message, in plain text.", kind: .multiline),
            ],
            titleBuilder: { "Draft an email to \($0["to"] ?? "")" },
            previewBuilder: Self.messagePreview
        ),

        // MARK: Send

        WorkspaceTool(
            name: "send_email",
            summary: "Send an email as the user. Only for a message the meeting explicitly "
                + "asked for, addressed to people who were on the invite.",
            risk: .send,
            parameters: [
                .init(name: "to", description: "Recipient addresses.", kind: .list),
                .init(name: "subject", description: "The subject line."),
                .init(name: "body", description: "The message, in plain text.", kind: .multiline),
            ],
            titleBuilder: { "Email \($0["to"] ?? "")" },
            previewBuilder: Self.messagePreview
        ),
        WorkspaceTool(
            name: "reply_email",
            summary: "Reply to a Gmail message the user has received, in its own thread.",
            risk: .send,
            parameters: [
                .init(name: "message_id", description: "The Gmail message id to reply to."),
                .init(name: "body", description: "The reply, in plain text.", kind: .multiline),
            ],
            titleBuilder: { "Reply to \($0["message_id"] ?? "")" },
            previewBuilder: { $0["body"] }
        ),
    ]

    static func tool(named name: String) -> WorkspaceTool? {
        all.first { $0.name == name }
    }

    /// The tools of at most one risk class, for the prompt: a meeting that may not send
    /// anything is not told that sending exists.
    static func tools(upTo risk: AgentRisk) -> [WorkspaceTool] {
        all.filter { $0.risk <= risk }
    }

    /// The `<tools>` block's contents: one JSON object per line, in the Hermes shape Qwen
    /// was tuned on. Built through `JSONSerialization` rather than string interpolation
    /// because a description with a quote in it would otherwise produce a block the model
    /// reads as truncated.
    static func schemaJSON(for tools: [WorkspaceTool]) -> String {
        tools.compactMap { tool in
            var properties: [String: Any] = [:]
            for parameter in tool.parameters { properties[parameter.name] = parameter.schema }
            let function: [String: Any] = [
                "name": tool.name,
                "description": tool.summary,
                "parameters": [
                    "type": "object",
                    "properties": properties,
                    "required": tool.parameters.filter(\.isRequired).map(\.name),
                ] as [String: Any],
            ]
            let envelope: [String: Any] = ["type": "function", "function": function]
            guard let data = try? JSONSerialization.data(
                withJSONObject: envelope,
                options: [.sortedKeys]
            ) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
        .joined(separator: "\n")
    }

    /// Splits a comma-separated argument into the values `gws` wants as separate flags.
    static func list(_ value: String?) -> [String] {
        (value ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static let messagePreview: @Sendable ([String: String]) -> String? = { arguments in
        """
        To: \(arguments["to"] ?? "")
        Subject: \(arguments["subject"] ?? "")

        \(arguments["body"] ?? "")
        """
    }
}

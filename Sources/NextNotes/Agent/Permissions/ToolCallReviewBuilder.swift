import Foundation

/// Turns one proposed tool call into the card the user reads.
///
/// The card is built from the tool's own schema rather than from the arguments the model
/// happened to emit, which is the whole point: a parameter the model left out has to appear
/// on the card as a question, and it cannot do that if the card is a rendering of the JSON.
/// Every required parameter therefore becomes a field whether or not it has a value.
///
/// Nothing here fills anything in. `ToolCallReviewBuilder` will not copy the only attendee
/// into an empty `to`, will not default a date to today, and will not shorten a missing
/// subject into "Follow-up" — all three are the app inventing on the model's behalf, which
/// is the behaviour this workstream exists to remove.
enum ToolCallReviewBuilder {

    static func review(
        id: String,
        tool: AgentTool,
        arguments: [String: String],
        trigger: ToolCallTrigger = .unattributed,
        context: ToolCallContext = .empty
    ) -> ToolCallReview {
        var fields: [ToolCallField] = []
        for parameter in tool.parameters {
            fields.append(field(for: parameter, tool: tool, arguments: arguments, context: context))
        }
        // Arguments the catalogue does not name still get a row: an argument nobody can see
        // is an argument nobody approved. Internal keys (`_browserBackend`) are machinery
        // and stay out.
        let known = Set(tool.parameters.map(\.name))
        for (name, value) in arguments.sorted(by: { $0.key < $1.key })
        where !known.contains(name) && !name.hasPrefix("_") {
            fields.append(extraField(name: name, value: value, risk: tool.risk, context: context))
        }

        return ToolCallReview(
            id: id,
            toolID: tool.id,
            title: title(for: tool, arguments: arguments, context: context),
            trigger: trigger,
            fields: fields,
            risk: tool.risk,
            previewField: fields.first(where: { $0.kind == .longText })?.name
        )
    }

    // MARK: - One field

    private static func field(
        for parameter: WorkspaceTool.Parameter,
        tool: AgentTool,
        arguments: [String: String],
        context: ToolCallContext
    ) -> ToolCallField {
        let raw = arguments[parameter.name] ?? ""
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind = kind(of: parameter, toolID: tool.id)
        let label = label(for: parameter.name, toolID: tool.id)

        let unverified = value.isEmpty
            ? []
            : ToolCallInspector.unverifiedTokens(in: value, kind: kind, context: context)
        let provenance = value.isEmpty
            ? ToolCallProvenance.missing
            : ToolCallInspector.provenance(for: value, kind: kind, unverified: unverified, context: context)
        let problem = ToolCallInspector.problem(
            value: value, isRequired: parameter.isRequired, kind: kind,
            provenance: provenance, unverified: unverified,
            risk: tool.risk, name: parameter.name
        )
        return ToolCallField(
            name: parameter.name,
            label: label,
            value: value,
            isRequired: parameter.isRequired,
            kind: kind,
            provenance: provenance,
            prompt: prompt(for: parameter.name, label: label, kind: kind),
            origin: origin(for: provenance, kind: kind, context: context, value: value),
            unverified: unverified,
            problem: problem,
            suggestions: problem == nil ? [] : suggestions(for: kind, value: value, context: context)
        )
    }

    /// People the app can already point at, for a recipient it cannot confirm.
    ///
    /// This is the "resolve before asking" step: the invite and the resolved people in the
    /// knowledge store usually already contain the person the model was reaching for, and
    /// offering them is faster than typing an address. They are offered as choices and
    /// never applied — the app filling a blank recipient in with the only other attendee
    /// would be the same fabrication in a different coat.
    private static func suggestions(
        for kind: ToolCallFieldKind, value: String, context: ToolCallContext
    ) -> [String] {
        guard kind == .email || kind == .person else { return [] }
        let known = (context.attendees + context.knownEmails + context.people)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        // A bare name in the field narrows the list to the people it could mean.
        let hint = ToolCallContext.fold(ToolCallInspector.listItems(value).first ?? "")
            .split(whereSeparator: { !$0.isLetter })
            .filter { $0.count >= 3 }
            .map(String.init)
        var matched = known
        if !hint.isEmpty {
            let narrowed = known.filter { candidate in
                let folded = ToolCallContext.fold(candidate)
                return hint.contains { folded.contains($0) }
            }
            if !narrowed.isEmpty { matched = narrowed }
        }
        if kind == .email { matched = matched.filter { $0.contains("@") } }
        var seen = Set<String>()
        return matched.filter { seen.insert(ToolCallContext.fold($0)).inserted }.prefix(4).map { $0 }
    }

    private static func extraField(
        name: String,
        value: String,
        risk: AgentRisk,
        context: ToolCallContext
    ) -> ToolCallField {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind: ToolCallFieldKind = trimmed.contains("\n") ? .longText : .text
        let unverified = ToolCallInspector.unverifiedTokens(in: trimmed, kind: kind, context: context)
        let provenance = ToolCallInspector.provenance(
            for: trimmed, kind: kind, unverified: unverified, context: context)
        let label = prettify(name)
        return ToolCallField(
            name: name,
            label: label,
            value: trimmed,
            isRequired: false,
            kind: kind,
            provenance: provenance,
            prompt: "What should \u{201c}\(label)\u{201d} be?",
            origin: origin(for: provenance, kind: kind, context: context, value: trimmed),
            unverified: unverified,
            problem: ToolCallInspector.problem(
                value: trimmed, isRequired: false, kind: kind,
                provenance: provenance, unverified: unverified,
                risk: risk, name: name)
        )
    }

    // MARK: - Kinds

    private static func kind(of parameter: WorkspaceTool.Parameter, toolID: String) -> ToolCallFieldKind {
        let name = parameter.name.lowercased()
        switch parameter.kind {
        case .multiline: return .longText
        case .date: return .dateTime
        case .list, .text: break
        }
        if name == "to" || name == "cc" || name == "bcc" || name.contains("email")
            || name.contains("recipient") || name.contains("attendee") {
            return .email
        }
        if name == "owner" || name == "person" || name == "who" || name.contains("speaker") {
            return .person
        }
        if name == "path" || name.contains("file") || name.contains("folder") {
            return .file
        }
        if name.contains("date") || name == "start" || name == "end" || name == "when" {
            return .dateTime
        }
        return .text
    }

    // MARK: - Words

    /// Plain-language labels. The user does not know what `document_id` is, and a card that
    /// prints it has asked them to approve something they cannot read.
    private static let labels: [String: String] = [
        "to": "Who it goes to",
        "cc": "Copied in",
        "bcc": "Blind copied",
        "subject": "Subject",
        "body": "Message",
        "markdown": "What it says",
        "text": "What to add",
        "title": "Title",
        "query": "What to look for",
        "date": "Which day",
        "start": "Starts",
        "end": "Ends",
        "attendees": "People invited",
        "description": "Details",
        "document_id": "Which document",
        "message_id": "Which email",
        "path": "Which file",
        "name": "Name",
    ]

    static func label(for name: String, toolID: String) -> String {
        if toolID == "upload_to_drive", name == "name" { return "Name in Google Drive" }
        return labels[name.lowercased()] ?? prettify(name)
    }

    /// The short question the card asks for a field nobody filled in.
    private static let prompts: [String: String] = [
        "to": "Who should this go to?",
        "cc": "Who else should be copied in?",
        "subject": "What should the subject say?",
        "body": "What should the message say?",
        "markdown": "What should the document say?",
        "text": "What should be added?",
        "title": "What should it be called?",
        "query": "What should I look for?",
        "date": "Which day?",
        "start": "When does it start?",
        "end": "When does it end?",
        "attendees": "Who should be invited?",
        "document_id": "Which document?",
        "message_id": "Which email should I reply to?",
        "path": "Which file?",
    ]

    static func prompt(for name: String, label: String, kind: ToolCallFieldKind) -> String {
        if let prompt = prompts[name.lowercased()] { return prompt }
        switch kind {
        case .email: return "Which address should I use?"
        case .person: return "Who?"
        case .dateTime: return "When?"
        case .file: return "Which file?"
        default: return "What should \u{201c}\(label)\u{201d} be?"
        }
    }

    private static func prettify(_ name: String) -> String {
        let spaced = name.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: #"([a-z])([A-Z])"#, with: "$1 $2", options: .regularExpression)
            .lowercased()
        guard let first = spaced.first else { return name }
        return first.uppercased() + spaced.dropFirst()
    }

    /// The phrase under a field that is fine, saying where the value came from. Silence
    /// would be a small lie of omission — the user cannot tell a quoted address from an
    /// invented one by looking at it.
    private static func origin(
        for provenance: ToolCallProvenance,
        kind: ToolCallFieldKind,
        context: ToolCallContext,
        value: String
    ) -> String? {
        switch provenance {
        case .userSaid: return "You said this."
        case .fromContext:
            if context.attendees.contains(where: {
                ToolCallContext.fold($0).contains(ToolCallContext.fold(value))
            }) {
                return "They were on the invite."
            }
            return "This came from the meeting."
        case .inferred:
            return kind.isFactual ? nil : "The assistant wrote this. Read it before you approve."
        case .missing, .edited:
            return nil
        }
    }

    // MARK: - Title

    /// "Send an email to Marie" rather than "send_email". Falls back to the catalogue's own
    /// title, which is already written for a person, and never to the raw tool id.
    static func title(for tool: AgentTool, arguments: [String: String], context: ToolCallContext) -> String {
        let who = personName(arguments["to"] ?? arguments["attendees"] ?? "", context: context)
        let what = (arguments["title"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        switch tool.id {
        case "send_email", "workspace.send_email":
            return who.isEmpty ? "Send an email" : "Send an email to \(who)"
        case "draft_email", "workspace.draft_email":
            return who.isEmpty ? "Save an email as a draft" : "Save a draft email to \(who)"
        case "reply_email", "workspace.reply_email":
            return "Reply to an email"
        case "create_doc", "workspace.create_doc":
            return what.isEmpty ? "Create a document" : "Create the document \u{201c}\(what)\u{201d}"
        case "append_doc", "workspace.append_doc":
            return "Add to a document"
        case "upload_to_drive", "workspace.upload_to_drive":
            let file = (arguments["name"] ?? arguments["path"]).map {
                URL(fileURLWithPath: $0).lastPathComponent
            } ?? ""
            return file.isEmpty ? "Put a file in Google Drive" : "Put \(file) in Google Drive"
        case "create_event", "workspace.create_event":
            return what.isEmpty ? "Put something in your calendar" : "Put \u{201c}\(what)\u{201d} in your calendar"
        case "search_email", "workspace.search_email":
            return "Look through your email"
        case "get_agenda", "workspace.get_agenda":
            return "Check what is on your calendar"
        case "find_drive_files", "workspace.find_drive_files":
            return "Look for a file in Google Drive"
        case "read_doc", "workspace.read_doc":
            return "Read a document"
        default:
            let built = tool.title(for: arguments).trimmingCharacters(in: .whitespacesAndNewlines)
            return built.isEmpty || built == tool.id ? prettify(tool.name) : built
        }
    }

    /// The readable name for a recipient. An address whose owner the app knows is shown as
    /// that person; otherwise the address's own local part, capitalised, because
    /// "Send an email to marie.dupont@acme.com" is a sentence nobody reads.
    static func personName(_ value: String, context: ToolCallContext) -> String {
        let items = ToolCallInspector.listItems(value)
        guard let first = items.first else { return "" }
        if ToolCallInspector.isPlaceholder(first, kind: .email) { return "" }
        guard first.contains("@") else { return first }
        let local = String(first.split(separator: "@").first ?? "")
        let folded = ToolCallContext.fold(first)
        if let known = context.people.first(where: { ToolCallContext.fold($0).contains(folded) }) {
            return known
        }
        let parts = local.split(whereSeparator: { $0 == "." || $0 == "_" || $0 == "-" })
        let name = parts.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        let suffix = items.count > 1 ? " and \(items.count - 1) other\(items.count > 2 ? "s" : "")" : ""
        return name.isEmpty ? first : name + suffix
    }
}

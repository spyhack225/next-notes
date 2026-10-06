import Foundation

/// The seven mail and calendar tools, answered by the Mac's own accounts (PL-09).
///
/// The tool ids, their arguments, the numbered search lines and every sentence the model reads
/// are the ones the `gws` path prints, so a prompt, a card and a receipt cannot tell which source
/// answered. What differs is honest and small: an event with guests is refused (Calendar on the
/// Mac cannot invite anyone), and a search is limited to what Mail's local index holds.
extension WorkspaceToolRunner {

    static func runOnMac(
        tool: String, arguments: [String: String], mac: any MacWorkspace, accountTag: String? = nil
    ) async throws -> WorkspaceToolResult {
        switch tool {
        case "search_email": return try await searchEmailOnMac(arguments, mac: mac)
        case "read_email": return try await readEmailOnMac(arguments, mac: mac)
        case "get_agenda": return try await agendaOnMac(arguments, mac: mac)
        case "create_event": return try await createEventOnMac(arguments, mac: mac)
        case "draft_email": return try await composeOnMac(arguments, mac: mac, kind: .draft, accountTag: accountTag)
        case "send_email": return try await composeOnMac(arguments, mac: mac, kind: .send, accountTag: accountTag)
        case "reply_email":
            let reference = try await macReference(arguments["message_id"] ?? "")
            return try await composeOnMac(arguments, mac: mac, kind: .reply(ref: reference), accountTag: accountTag)
        default: throw AgentError.unknownTool(tool)
        }
    }

    // MARK: - Mail

    private static func searchEmailOnMac(
        _ arguments: [String: String], mac: any MacWorkspace
    ) async throws -> WorkspaceToolResult {
        let written = (arguments["query"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let query = try GmailQuery.normalize(written.isEmpty ? GmailQuery.inbox : written)
        let count = searchCount(arguments["maxResults"])
        let found = try await mac.searchMail(try MacMailQuery(gmail: query, limit: count))
        guard !found.isEmpty else { return WorkspaceToolResult(summary: "No message matches \(query).") }
        let references = await MailReferenceCache.shared.store(found.map(\.ref))
        var lines: [String] = []
        var evidence: [ActionContextReference] = []
        for (index, mail) in found.enumerated() {
            let stamp = macMailStamp(mail.date)
            let summary = WorkspaceMailSummary(id: mail.ref, stamp: stamp, from: mail.from,
                                               subject: mail.subject, snippet: snippet(from: mail.snippet))
            var line = "\(references[index]))"
            if let label = mailLabel(summary) { line += " \(label)" }
            line += " \u{00B7} \(mail.from) \u{00B7} \(mail.subject)"
            if !summary.snippet.isEmpty { line += " \u{2014} \(summary.snippet)" }
            lines.append(line)
            if let reference = mailContextReference(id: mail.ref,
                sender: mail.from == "unknown sender" ? nil : mail.from, stamp: stamp) {
                evidence.append(reference)
            }
        }
        lines.append("To read one in full, call read_email with its number.")
        return WorkspaceToolResult(summary: truncated(lines.joined(separator: "\n"), toolID: "search_email"),
                                   contextReferences: evidence)
    }

    private static func readEmailOnMac(
        _ arguments: [String: String], mac: any MacWorkspace
    ) async throws -> WorkspaceToolResult {
        let ref = try await macReference(arguments["message"] ?? "")
        let message = try await mac.readMail(ref: ref)
        var lines = ["From: \(message.from)"]
        if let date = message.date {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            lines.append("Date: \(formatter.string(from: date))")
        }
        lines.append("Subject: \(message.subject)")
        lines.append("")
        lines.append(message.bodyIsAvailable
            ? message.body
            : "Mail hasn\u{2019}t downloaded this message\u{2019}s text yet. Open it in Mail once, then ask again.")
        return WorkspaceToolResult(summary: truncated(lines.joined(separator: "\n"), toolID: "read_email"),
            contextReferences: mailContextReference(id: ref,
                sender: message.from == "unknown sender" ? nil : message.from,
                stamp: macMailStamp(message.date)).map { [$0] } ?? [])
    }

    private static func macMailStamp(_ date: Date?) -> Int {
        guard let value = date?.timeIntervalSince1970, value.isFinite,
              value > 0, value * 1_000 < Double(Int.max) else { return 0 }
        return Int(value * 1_000)
    }

    /// A number the last search printed, or a reference it already carries. Anything else is a
    /// bad argument the model can correct in the same turn.
    private static func macReference(_ raw: String) async throws -> String {
        let reference = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if reference.hasPrefix("mac-") { return reference }
        if let id = await MailReferenceCache.shared.resolve(reference), id.hasPrefix("mac-") { return id }
        throw WorkspaceCLIError.invalidRequest(
            "There is no message \(reference.isEmpty ? "here" : reference) in the last search. "
            + "Search again, then use one of the numbers it prints.")
    }

    private static func composeOnMac(
        _ arguments: [String: String], mac: any MacWorkspace, kind: MacComposeRequest.Kind, accountTag: String?
    ) async throws -> WorkspaceToolResult {
        let request = MacComposeRequest(
            kind: kind, to: WorkspaceTools.list(arguments["to"]),
            subject: arguments["subject"] ?? "", body: arguments["body"] ?? "", expectedAccountTag: accountTag)
        let result = try await mac.compose(request)
        switch kind {
        case .draft:
            return WorkspaceToolResult(
                summary: "Saved the draft.",
                verification: result.confirmedInMail ? "Found the draft in Mail\u{2019}s Drafts" : nil)
        case .send:
            return WorkspaceToolResult(
                summary: "Sent the email.",
                verification: result.confirmedInMail ? "Found the message in Mail\u{2019}s Sent folder" : nil)
        case .reply:
            return WorkspaceToolResult(
                summary: "Sent the reply.",
                verification: result.confirmedInMail ? "Found the reply in Mail\u{2019}s Sent folder" : nil)
        }
    }

    // MARK: - Calendar

    private static func agendaOnMac(
        _ arguments: [String: String], mac: any MacWorkspace
    ) async throws -> WorkspaceToolResult {
        let start = day(from: arguments["date"])
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start
        let items = try await mac.agenda(from: start, to: end)
        guard !items.isEmpty else { return WorkspaceToolResult(summary: "Nothing is booked on \(dayLabel(start)).") }
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        let lines = items.map { item in
            "- \(item.isAllDay ? "all day" : formatter.string(from: item.start)) \u{2014} \(item.title)"
        }
        return WorkspaceToolResult(
            summary: truncated("On \(dayLabel(start)):\n" + lines.joined(separator: "\n"), toolID: "get_agenda"))
    }

    private static func createEventOnMac(
        _ arguments: [String: String], mac: any MacWorkspace
    ) async throws -> WorkspaceToolResult {
        // Refused before anything is created: Calendar on the Mac cannot invite anyone, and an
        // event that quietly left the guests out would be a different event from the reviewed one.
        guard WorkspaceTools.list(arguments["attendees"]).isEmpty else { throw MacWorkspaceError.cannotInvite }
        guard let start = date(fromArgument: arguments["start"] ?? ""),
              let end = date(fromArgument: arguments["end"] ?? ""), end > start else {
            throw WorkspaceCLIError.invalidRequest(
                "The event needs a start and a later end, like 2026-09-30T15:00:00+02:00.")
        }
        let title = arguments["title"] ?? ""
        let result = try await mac.createEvent(MacEventDraft(
            title: title, start: start, end: end, notes: arguments["description"] ?? ""))
        if result.alreadyThere {
            return WorkspaceToolResult(
                summary: result.verified ? "It was already on your calendar."
                    : "I couldn\u{2019}t confirm the reviewed event. Check your calendar before trying again.",
                reference: result.reference,
                verification: result.verified ? "Read back the reviewed event details" : nil)
        }
        return WorkspaceToolResult(
            summary: "Created the event \u{201c}\(title)\u{201d}.",
            reference: result.reference,
            verification: result.verified ? "Read back the reviewed event details" : nil)
    }

    // MARK: - A write that never answered

    /// The same four questions `resolveUnknown` asks Google, asked of Mail and Calendar. Loose
    /// by design: a find is "looks like it went out", never certain.
    static func resolveUnknownOnMac(
        tool: String, arguments: [String: String], firedAt: Date, mac: any MacWorkspace
    ) async -> UnknownOutcome {
        do {
            switch tool {
            case "send_email", "reply_email", "draft_email":
                let kind: MacComposeRequest.Kind = tool == "draft_email" ? .draft
                    : tool == "send_email" ? .send : .reply(ref: "")
                let request = MacComposeRequest(kind: kind, to: WorkspaceTools.list(arguments["to"]),
                                                subject: arguments["subject"] ?? "", body: arguments["body"] ?? "")
                let found = try await mac.findComposed(request, since: firedAt)
                return found ? .found(looksLike: true) : .notFound
            case "create_event":
                // EventKit assigns its identifier on save. A timed-out write has no retained
                // identifier here, so a title/time match cannot prove the approved event.
                return .noReliableRead
            default:
                return .noReliableRead
            }
        } catch {
            return .noReliableRead
        }
    }
}

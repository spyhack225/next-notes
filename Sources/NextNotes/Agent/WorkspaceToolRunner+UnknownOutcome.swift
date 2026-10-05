import Foundation

/// P1-21: did a write that never came back actually go out?
///
/// A Google write runs through `gws` with a 60-second timeout and is terminated when it expires.
/// When a send takes longer than that — or exits after the request left with something unreadable
/// on stdout — the receipt said `failed`, the card said it failed, and the person pressed it
/// again. **That is how the app sends the same email twice**, and it is live today rather than a
/// recovery-after-restart problem.
///
/// OpenMuse (`packages/integrations/src/google.ts:19-26`, `:576-605`) marks a write
/// `outcome_unknown` on a network error, a 5xx or 408, or an unreadable reply, and never retries
/// it silently. This takes that rule and adds what OpenMuse does not do: **ask Google before
/// asking the person.**
extension WorkspaceToolRunner {

    /// What a read can say about a write that never answered.
    enum UnknownOutcome: Equatable, Sendable {
        /// A read found it. `looksLike` is false only when the match was exact; a fuzzy match
        /// is described as "looks like it went out" and never as certain, because the sent
        /// message's own id is not recorded yet (P1-22) and a loose match cannot honestly be
        /// called an exact one.
        case found(looksLike: Bool)
        /// A read ran and found nothing. The app is out of answers and the person has the call.
        case notFound
        /// No reliable read exists for this tool, or the read itself failed. Neither is evidence
        /// that the write failed, and neither is passed off as evidence that it succeeded.
        case noReliableRead
    }

    /// The sentence, and whether a **Check again** button is worth offering.
    ///
    /// **Send again** is deliberately not produced here. It is a *new approval of the same
    /// prepared content*, and a function that says "not sure" has no business deciding that a
    /// write should happen twice.
    static func unknownOutcomeSentence(
        tool: String, arguments: [String: String], outcome: UnknownOutcome
    ) -> (sentence: String, offersCheckAgain: Bool) {
        // The `let` first: a switch *expression* branch may not hold a statement, which is a
        // compile error rather than a subtle mistake.
        let who = (arguments["to"] ?? "them")
            .replacingOccurrences(of: "@.*", with: "", options: .regularExpression)
        let target: String = switch tool {
        case "send_email", "reply_email": "the email to \(who)"
        case "draft_email": "the draft"
        case "create_event": "the event"
        case "create_doc": "the document"
        default: "that"
        }
        switch outcome {
        // Bound as `looksLike`, which is what the case carries. Binding it as `exact` and
        // testing it reads a *loose* match as a certain one — the inverse of the whole point of
        // the flag, and a case that caught it.
        case .found(let looksLike):
            return (looksLike ? "It looks like it went out." : "It went out.", false)
        case .notFound:
            return ("I\u{2019}m not sure \(target) went out. It isn\u{2019}t there yet.", true)
        case .noReliableRead:
            return ("I\u{2019}m not sure \(target) went out. Check it before trying again.", true)
        }
    }

    /// The sentence as a tool result, for the write whose answer never came back.
    ///
    /// One read, one sentence, no second write. The `verification` is set only on an exact match,
    /// so the receipt says what was actually established.
    static func unknownOutcomeResult(
        _ proposal: AgentProposal, preparedAction: PreparedAction? = nil,
        calendarEventID: String? = nil, firedAt: Date = Date(),
        cli: any WorkspaceCLIRunning = GoogleWorkspaceCLI.shared
    ) async -> AgentToolResult {
        let arguments = preparedAction?.executionPlan.arguments ?? proposal.arguments
        let exactCalendarID = preparedAction?.executionPlan.toolID == "create_event" ? calendarEventID : nil
        let outcome = await resolveUnknown(
            tool: proposal.tool, arguments: arguments, firedAt: firedAt,
            calendarEventID: exactCalendarID, cli: cli)
        let said = unknownOutcomeSentence(
            tool: proposal.tool, arguments: arguments, outcome: outcome)
        return AgentToolResult(
            summary: said.sentence,
            reference: proposal.tool == "create_event" ? exactCalendarID : nil,
            verification: outcome == .found(looksLike: false)
                ? "Found by a read after the fact" : nil,
            outcomeUnknown: proposal.tool != "create_event" || outcome != .found(looksLike: false))
    }

    /// One read per write tool, and only for the four that have a reliable one.
    ///
    /// `append_doc` and `upload_to_drive` have none — a document's body is not a queryable name —
    /// so they go straight to the person, which is the honest answer rather than a read that
    /// would match something unrelated.
    ///
    /// The mail and event matches are deliberately loose, because the exact identifier the write
    /// used is not recorded (P1-22's job) and a strict match would report "not found" for a send
    /// that went out. Loose is exactly why the answer is "looks like it went out" and never
    /// certain.
    static func resolveUnknown(
        tool: String, arguments: [String: String], firedAt: Date,
        calendarEventID: String? = nil, cli: any WorkspaceCLIRunning
    ) async -> UnknownOutcome {
        if let mac = await GoogleSource.macWorkspace(forTool: tool, cli: cli) {
            return await resolveUnknownOnMac(tool: tool, arguments: arguments, firedAt: firedAt, mac: mac)
        }
        do {
            switch tool {
            case "send_email", "reply_email", "draft_email":
                let subject = (arguments["subject"] ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let folder = tool == "draft_email" ? "in:drafts" : "in:sent"
                let query = subject.isEmpty ? folder : "\(folder) subject:\(subject)"
                let listing = try await cli.run([
                    "gmail", "users", "messages", "list",
                    "--params", json(["userId": "me", "q": query, "maxResults": 10]),
                ])
                let messages = (dictionary(from: listing)?["messages"] as? [[String: Any]]) ?? []
                guard messages.contains(where: {
                    !((($0["id"] as? String) ?? "").isEmpty)
                }) else { return .notFound }
                // Exact only when the send wrote a subject, which is the strongest thing
                // available without the sent message's own id.
                return .found(looksLike: subject.isEmpty)
            case "create_event":
                guard let id = calendarEventID, !id.isEmpty,
                      arguments["start"].flatMap({ date(fromArgument: $0) }) != nil,
                      arguments["end"].flatMap({ date(fromArgument: $0) }) != nil,
                      let title = arguments["title"], !title.isEmpty else { return .noReliableRead }
                let readback = try await cli.run([
                    "calendar", "events", "get", "--params",
                    json(["calendarId": "primary", "eventId": id]),
                ])
                guard let saved = dictionary(from: readback),
                      reviewedEventMatches(saved, id: id, arguments: arguments) else { return .noReliableRead }
                return .found(looksLike: false)
            case "create_doc":
                let name = arguments["name"] ?? arguments["title"] ?? ""
                guard !name.isEmpty else { return .noReliableRead }
                let listing = try await cli.run([
                    "drive", "files", "list",
                    "--params", json(["q": "name = '\(name)'", "pageSize": 10]),
                ])
                let files = (dictionary(from: listing)?["files"] as? [[String: Any]]) ?? []
                return files.isEmpty ? .notFound : .found(looksLike: true)
            default:
                return .noReliableRead
            }
        } catch {
            // The read failed too. That is not evidence either way, and it is certainly not
            // evidence that the write failed.
            return .noReliableRead
        }
    }
}

import Foundation

/// `--selftest-tool-review`: the approval card cannot present an invented value as fact,
/// and cannot offer Approve while something required is missing.
///
/// Four fixture calls — complete, missing recipient, placeholder email, invented attendee —
/// walked end to end: the review that is built from each, the state of every field, whether
/// Approve is live, what the gate does when it is pressed anyway, and what the executor's
/// own validation says about the same arguments arriving from somewhere that never drew a
/// card.
///
/// It fails, rather than passing quietly, when an invented value comes back confirmed or a
/// half-filled call comes back ready — which is the failure this whole workstream is about,
/// and the one a probe that only checked "did a review get built" would sail past.
enum ToolCallReviewSelfTest {

    @MainActor
    @discardableResult
    static func run() async -> Bool {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        guard let sendEmail = WorkspaceTools.tool(named: "send_email").map(AgentTool.workspace),
              let createEvent = WorkspaceTools.tool(named: "create_event").map(AgentTool.workspace)
        else {
            print("TOOL_REVIEW_WRONG: the Workspace catalogue no longer has send_email/create_event")
            print("TOOL_REVIEW_FAILED")
            return false
        }

        // The meeting everything below is judged against: Marie was really there, with a
        // real address, and the deck was really asked for.
        var context = ToolCallContext.empty
        context.userWords = "Send the deck to marie.dupont@acme.com before Friday."
        context.transcript = """
            Marie: can you send me the deck when you get a chance?
            You: yes, I will send the deck to marie.dupont@acme.com before Friday.
            """
        context.attendees = ["marie.dupont@acme.com", "sam@acme.com"]
        context.people = ["Marie Dupont", "Sam Okonjo"]
        context.knownEmails = ["marie.dupont@acme.com", "sam@acme.com"]

        // MARK: 1 — complete

        let complete = ToolCallReviewBuilder.review(
            id: "fixture-complete", tool: sendEmail,
            arguments: [
                "to": "marie.dupont@acme.com",
                "subject": "The deck",
                "body": "Hi Marie, here is the deck we talked about. Thanks!",
            ],
            trigger: .youSaid("send the deck to marie.dupont@acme.com"),
            context: context
        )
        check("a complete call was not ready to run", complete.isReadyToRun)
        check("a complete call still reported something needed", complete.needsSummary == nil)
        check("a complete call reported a blocker", complete.blockers.isEmpty)
        check(
            "a confirmed recipient was not marked as confirmed",
            complete.field("to")?.provenance.isConfirmed == true
        )
        check(
            "the title did not name the recipient in plain language",
            complete.title == "Send an email to Marie Dupont"
        )
        check(
            "the why line did not quote what the user actually said",
            complete.why.contains("You said") && complete.why.contains("send the deck")
        )
        check(
            "a complete call did not pass its arguments through",
            complete.arguments["to"] == "marie.dupont@acme.com"
        )
        check(
            "a body was not offered as the previewable field",
            complete.previewField == "body"
        )

        // MARK: 2 — missing recipient

        let missing = ToolCallReviewBuilder.review(
            id: "fixture-missing", tool: sendEmail,
            arguments: ["subject": "The deck", "body": "Here is the deck."],
            trigger: .youSaid("send the deck"),
            context: context
        )
        check("a call with no recipient was ready to run", !missing.isReadyToRun)
        check(
            "a missing recipient did not appear as a field at all",
            missing.field("to") != nil
        )
        check(
            "a missing recipient was not reported as missing",
            missing.field("to")?.problem == .missing
        )
        check(
            "a missing recipient was reported as confirmed",
            missing.field("to")?.provenance.isConfirmed == false
        )
        check(
            "the card did not ask who it should go to",
            missing.field("to")?.statusLine == "Who should this go to?"
        )
        check("the collapsed line did not count what was needed", missing.needsSummary == "1 thing needed")
        check(
            "a missing recipient was silently filled in from the attendees",
            missing.arguments["to"] == nil
        )

        // The island card built from that state must not offer Approve.
        let islandCard = IslandProposal(
            id: missing.id, title: missing.title, detail: missing.why, meetingID: nil,
            needsReview: true, canExecute: false, needsCount: missing.blockers.count)
        check("the island offered Approve for a half-filled call",
              islandCard.leadAction == .review)
        check("the island card did not say how many answers were owed",
              islandCard.needsSummary == "1 thing needed")

        // MARK: 3 — placeholder email

        let placeholder = ToolCallReviewBuilder.review(
            id: "fixture-placeholder", tool: sendEmail,
            arguments: [
                "to": "john.doe@example.com",
                "subject": "The deck",
                "body": "Hi [Name], here is the deck.",
            ],
            trigger: .unattributed,
            context: context
        )
        check("a placeholder recipient was ready to run", !placeholder.isReadyToRun)
        check(
            "john.doe@example.com was not recognised as a stand-in",
            placeholder.field("to")?.problem == .placeholder
        )
        check(
            "a body addressed to [Name] was treated as ready to send",
            placeholder.field("body")?.problem == .placeholder
        )
        check(
            "a placeholder was reported as confirmed",
            placeholder.field("to")?.provenance.isConfirmed == false
        )
        check(
            "an unattributed call still claimed the user had asked for it",
            !placeholder.why.contains("You said")
        )
        for value in ["[Name]", "TBD", "unknown", "N/A", "<insert date>", "{{name}}",
                      "jane.doe@example.org", "(555) 555-0134", "___"] {
            check("\u{201c}\(value)\u{201d} was not recognised as a stand-in",
                  ToolCallInspector.isPlaceholder(value, kind: .text))
        }
        for value in ["Marie Dupont", "marie.dupont@acme.com", "The Q3 deck", "+33 6 12 34 56 78",
                      // A real person on a documentation domain. Refusing every
                      // example.com address outright rejects invites that genuinely use
                      // one and still misses an invented address at a real domain, so this
                      // one goes to grounding rather than to the string check.
                      "sam@example.com"] {
            check("\u{201c}\(value)\u{201d} was wrongly called a stand-in",
                  !ToolCallInspector.isPlaceholder(value, kind: .text))
        }
        var withSam = context
        withSam.attendees.append("sam@example.com")
        withSam.knownEmails.append("sam@example.com")
        check("an address that is really on the invite was called unconfirmed",
              ToolCallInspector.unverifiedTokens(
                in: "sam@example.com", kind: .email, context: withSam).isEmpty)
        check("an address nothing confirms was passed off as fact",
              ToolCallInspector.unverifiedTokens(
                in: "sam@example.com", kind: .email, context: context) == ["sam@example.com"])

        // MARK: 4 — invented attendee

        let invented = ToolCallReviewBuilder.review(
            id: "fixture-invented", tool: createEvent,
            arguments: [
                "title": "Deck review",
                "start": "2026-09-09T13:40:00-04:00",
                "end": "2026-09-09T14:10:00-04:00",
                "attendees": "priya.raman@northwind.example",
            ],
            trigger: .saidInMeeting("let's review the deck", speaker: "Marie", at: 462),
            context: context
        )
        check("an invented attendee was ready to run", !invented.isReadyToRun)
        check(
            "an invented attendee was not flagged as unconfirmed",
            invented.field("attendees")?.problem == .notConfirmed
        )
        check(
            "an invented attendee was reported as confirmed",
            invented.field("attendees")?.provenance.isConfirmed == false
        )
        check(
            "the card did not name the value it could not confirm",
            invented.field("attendees")?.statusLine.contains("priya.raman@northwind.example") == true
        )
        check(
            "an invented date was not flagged",
            invented.field("start")?.problem == .notConfirmed
        )
        check(
            "the why line dropped who said it and when",
            invented.why.contains("Marie") && invented.why.contains("07:42")
        )
        check(
            "unconfirmed values were not listed for the card to highlight",
            invented.unconfirmed.contains { $0.name == "attendees" }
        )

        check(
            "the people the app already knows were not offered for a missing recipient",
            missing.field("to")?.suggestions.contains("marie.dupont@acme.com") == true
        )
        check(
            "a missing recipient was quietly filled in from a suggestion",
            missing.field("to")?.value.isEmpty == true
        )

        // A read may show "not confirmed" and must still be runnable: the harm is in
        // acting on an invented address, not in looking one up.
        if let searchEmail = WorkspaceTools.tool(named: "search_email").map(AgentTool.workspace) {
            let lookup = ToolCallReviewBuilder.review(
                id: "fixture-read", tool: searchEmail,
                arguments: ["query": "from:priya.raman@northwind.example deck"],
                trigger: .youSaid("find the deck email"), context: context)
            check("an unconfirmed value blocked a read", lookup.isReadyToRun)
            check("an unconfirmed value in a read was not labelled",
                  lookup.field("query")?.problem == .notConfirmed)
        } else {
            failures.append("the Workspace catalogue no longer has search_email")
        }

        // A date that *was* said is not flagged, or the label means nothing.
        var spoken = context
        spoken.userWords += " Let's meet at 1:40 on Wednesday."
        let groundedDate = ToolCallReviewBuilder.review(
            id: "fixture-date", tool: createEvent,
            arguments: [
                "title": "Deck review",
                "start": "2026-09-09T13:40:00-04:00",
                "end": "2026-09-09T14:10:00-04:00",
            ],
            trigger: .youSaid("let's meet at 1:40"), context: spoken)
        check("""
            a time the user actually said was called invented \
            (problem \(String(describing: groundedDate.field("start")?.problem)), \
            unverified \(groundedDate.field("start")?.unverified ?? []))
            """,
              groundedDate.field("start")?.problem == nil)

        // MARK: 5 — the user fills it in, and that is what runs

        var edited = missing
        edited.update("to", to: "marie.dupont@acme.com")
        check("filling in the recipient did not make the call runnable", edited.isReadyToRun)
        check("an edited value did not reach the arguments",
              edited.arguments["to"] == "marie.dupont@acme.com")
        check("an edit was not recorded for the audit log", edited.wasEdited)
        check("the audit note did not name the edited field",
              edited.auditNote.contains("to"))

        var typedPlaceholder = missing
        typedPlaceholder.update("to", to: "[Name]")
        check("a placeholder typed by the user was accepted", !typedPlaceholder.isReadyToRun)

        var confirmedInvention = invented
        confirmedInvention.confirm("attendees")
        check("confirming an unconfirmed value did not clear it",
              confirmedInvention.field("attendees")?.problem == nil)
        check("a user-confirmed value was not recorded as theirs",
              confirmedInvention.field("attendees")?.provenance == .edited)
        check("confirming a value did not count as an edit", confirmedInvention.wasEdited)

        // MARK: 6 — nothing fabricated can reach the executor

        check("the executor accepted a missing required argument",
              ToolCallValidation.problem(tool: sendEmail, arguments: [
                "subject": "The deck", "body": "Here.",
              ]) != nil)
        check("the executor accepted a placeholder recipient",
              ToolCallValidation.problem(tool: sendEmail, arguments: [
                "to": "john.doe@example.com", "subject": "The deck", "body": "Here.",
              ]) != nil)
        check("the executor accepted a body with a blank to fill in",
              ToolCallValidation.problem(tool: sendEmail, arguments: [
                "to": "marie.dupont@acme.com", "subject": "The deck", "body": "Hi [Name],",
              ]) != nil)
        check("the executor refused a complete call",
              ToolCallValidation.isRunnable(tool: sendEmail, arguments: [
                "to": "marie.dupont@acme.com", "subject": "The deck", "body": "Here it is.",
              ]))
        // The same refusal has to hold for a proposal decoded off disk, which reaches the
        // Workspace runner without passing the generic executor at all.
        let stale = AgentProposal(
            meetingID: UUID(), tool: "send_email",
            arguments: ["to": "[Name]", "subject": "The deck", "body": "Here."],
            rationale: "asked for")
        check("a stored proposal carrying a placeholder was runnable",
              stale.definition.map {
                  !ToolCallValidation.isRunnable(tool: AgentTool.workspace($0),
                                                 arguments: stale.arguments)
              } == true)

        // MARK: 7 — the model's own output never carries a stand-in forward

        let parsed = AgentToolCallParser.parse(#"""
            {"name":"send_email","arguments":{"to":"[Recipient]","subject":"TBD",
            "body":"Hi Marie, here is the deck."},"rationale":"asked for"}
            """#)
        check("the parser kept a placeholder recipient", parsed?.arguments["to"] == nil)
        check("the parser dropped a real body", parsed?.arguments["body"] != nil)
        // The parser has read a name, not looked a tool up, so the whole-value stand-in
        // list is not its to apply: "TBD" is furniture as an email subject and a perfectly
        // ordinary thing to search a folder for. It survives here and is judged one step
        // later, where the tool's risk is known.
        check("the parser applied a judgement it had no tool to make",
              parsed?.arguments["subject"] == "TBD")

        let stripped = AgentToolLoop.grounded(AgentToolCall(
            name: "send_email",
            arguments: ["to": "john.doe@example.com", "subject": "TBD", "body": "Here."],
            rationale: "asked for", evidence: nil))
        check("the tool loop passed an invented recipient to the executor",
              stripped.arguments["to"] == nil)
        check("the tool loop kept a stand-in subject on a send",
              stripped.arguments["subject"] == nil)
        let keptSubject = AgentToolLoop.grounded(AgentToolCall(
            name: "send_email",
            arguments: ["to": "marie.dupont@acme.com", "subject": "The deck", "body": "Here."],
            rationale: "asked for", evidence: nil))
        check("the tool loop dropped an argument that was fine",
              keptSubject.arguments["subject"] == "The deck")

        // …and the same list must not be applied to a lookup's own search box. "Find files
        // with todo in them" is the user's question, not the model failing to know one.
        for (toolID, name, value, others) in [
            ("filesystem.search", "query", "todo", [String: String]()),
            ("filesystem.search", "query", "pending", [:]),
            ("browser.fill", "text", "N/A", ["id": "12"]),
            ("browser.select", "value", "None", ["id": "12"]),
        ] {
            guard let definition = AgentToolRegistry.shared.tool(named: toolID) else {
                failures.append("the catalogue no longer has \(toolID)")
                continue
            }
            var arguments = others
            arguments[name] = value
            let kept = AgentToolLoop.grounded(AgentToolCall(
                name: toolID, arguments: arguments, rationale: "asked for", evidence: nil))
            check("the tool loop dropped \u{201c}\(value)\u{201d} from \(toolID) \(name)",
                  kept.arguments[name] == value)
            check("\(toolID) was refused for having \u{201c}\(value)\u{201d} in \(name)",
                  ToolCallValidation.problem(tool: definition, arguments: kept.arguments) == nil)
        }

        // MARK: 8 — the gate refuses the press, not only the button

        let request = PermissionRequest(
            id: "fixture-gate", toolID: "send_email",
            title: "Send an email", detail: "",
            risk: .send,
            arguments: ["subject": "The deck", "body": "Here."],
            trigger: .youSaid("send the deck"))
        ToolCallReviewStore.shared.remove(id: request.id)
        _ = ToolCallReviewStore.shared.begin(request)
        check("the store built a runnable review for a call with no recipient",
              !ToolCallReviewStore.shared.isReadyToRun(id: request.id))

        let waiting = Task { await PermissionGate.shared.ask(request) }
        for _ in 0..<100 where PermissionGate.shared.pending?.id != request.id {
            try? await Task.sleep(for: .milliseconds(10))
        }
        if PermissionGate.shared.pending?.id == request.id {
            let accepted = PermissionGate.shared.respond(id: request.id, approved: true)
            check("the gate approved a call that was still missing a required field", !accepted)
            ToolCallReviewStore.shared.update(id: request.id, field: "to",
                                              to: "marie.dupont@acme.com")
            let acceptedAfterFill = PermissionGate.shared.respond(id: request.id, approved: true)
            check("the gate refused a call the user had completed", acceptedAfterFill)
        } else {
            failures.append("the gate never presented the fixture request")
        }
        PermissionGate.shared.cancelPending(id: request.id)
        _ = await withBoundedWait(.seconds(1)) { await waiting.value }
        ToolCallReviewStore.shared.remove(id: request.id)

        // MARK: 9 — the card is *reachable* from the executor, not only from a watcher

        // A missing required argument used to be thrown out at the top of
        // `AgentToolExecutor.run`, before anything could raise a card: the model got
        // `send_email needs "to", and it is empty.` back and the user got nothing. Where
        // somebody can be asked, the gap has to become a question.
        let raised = Task { @MainActor in
            try await AgentToolExecutor.run(
                "send_email",
                arguments: ["subject": "The deck", "body": "Here is the deck."],
                policy: .selfTest,
                promptIfNeeded: true
            )
        }
        var presented: PermissionRequest?
        for _ in 0..<200 {
            if let pending = PermissionGate.shared.pending, pending.toolID == "send_email" {
                presented = pending
                break
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        check("an incomplete call was refused before anybody could be asked about it",
              presented != nil)
        if let presented {
            let card = ToolCallReviewStore.shared.review(for: presented)
            check("the card raised for an incomplete call did not ask for the missing value",
                  card.field("to")?.problem == .missing)
            check("the card raised for an incomplete call offered to run it",
                  !card.isReadyToRun)
            check("approving the card ran a call that was still incomplete",
                  !PermissionGate.shared.respond(id: presented.id, approved: true))
            PermissionGate.shared.cancelPending(id: presented.id)
        }
        raised.cancel()
        _ = await withBoundedWait(.seconds(2)) { try? await raised.value }
        PermissionGate.shared.cancelPending()

        // MARK: 10 — an edit keeps the authorization the card never showed

        var browserEdit = ToolCallReviewBuilder.review(
            id: "fixture-browser",
            tool: AgentTool.native(
                namespace: .browser, name: "fill", description: "Type into an element.",
                risk: .modify,
                parameters: [
                    .init(name: "id", description: "The element id."),
                    .init(name: "text", description: "The text to type."),
                ]),
            arguments: [
                "id": "12", "text": "N/A",
                "_browserBackend": "cdp",
                "_authorizedPageURL": "https://example.org/form",
            ],
            context: context)
        check("an internal authorization key was put on the card",
              browserEdit.field("_browserBackend") == nil)
        check("\u{201c}N/A\u{201d} typed into a web form was called a stand-in",
              browserEdit.field("text")?.problem == nil)
        browserEdit.update("text", to: "None")
        let merged = browserEdit.executionArguments(mergedOver: [
            "id": "12", "text": "N/A",
            "_browserBackend": "cdp",
            "_authorizedPageURL": "https://example.org/form",
        ])
        check("an edit dropped the browser backend the executor had pinned",
              merged["_browserBackend"] == "cdp")
        check("an edit dropped the page the user was shown",
              merged["_authorizedPageURL"] == "https://example.org/form")
        check("an edited value did not reach execution", merged["text"] == "None")

        // MARK: 11 — grounding matches words, not letters inside other words

        var noisy = ToolCallContext.empty
        noisy.userWords = "Put the deck review in the calendar."
        noisy.transcript = """
            You: the analysis is nearly done and I was half asleep writing it.
            Marie: send it round when you can.
            """
        let smeared = ToolCallReviewBuilder.review(
            id: "fixture-smeared", tool: createEvent,
            arguments: [
                "title": "Deck review",
                "start": "2026-09-09T13:40:00-04:00",
                "end": "2026-09-09T14:10:00-04:00",
                "attendees": "Ana Lee",
            ],
            trigger: .youSaid("put the deck review in the calendar"),
            context: noisy)
        check("""
            an invented attendee was confirmed by letters inside other words \
            (\u{201c}ana\u{201d} in analysis, \u{201c}lee\u{201d} in asleep)
            """,
              smeared.field("attendees")?.problem == .notConfirmed)
        check("a name nobody said was presented as something somebody said",
              smeared.field("attendees")?.provenance.isConfirmed == false)
        check("a name that really was said stopped being recognised",
              ToolCallInspector.unverifiedTokens(
                in: "Marie Dupont", kind: .person, context: context).isEmpty)
        check("a name written the other way round stopped being recognised",
              ToolCallInspector.unverifiedTokens(
                in: "Dupont Marie", kind: .person, context: context).isEmpty)

        // MARK: 12 — the meeting card is not a trap

        // Typing the right address into the proposal sheet has to make the card runnable.
        // It did not: the card rebuilt its review from the saved arguments on every redraw,
        // so a correct address nobody had said out loud came back "not confirmed" forever
        // and Approve stayed off however many times it was filled in.
        let proposalID = "fixture-proposal"
        ToolCallReviewStore.shared.remove(id: proposalID)
        let meetingCard = ToolCallReviewStore.shared.beginProposal(
            id: proposalID, toolID: "send_email",
            arguments: ["subject": "The deck", "body": "Here is the deck."],
            meetingID: nil, evidence: "send me the deck", risk: .send,
            title: "Send an email")
        check("a proposal with no recipient was ready to run", !meetingCard.isReadyToRun)
        ToolCallReviewStore.shared.applyEdits(id: proposalID, arguments: [
            "to": "priya.raman@northwind.example",
            "subject": "The deck",
            "body": "Here is the deck.",
        ])
        let filled = ToolCallReviewStore.shared.review(id: proposalID)
        check("an address the user typed into the sheet came back unconfirmed",
              filled?.field("to")?.provenance == .edited)
        check("a proposal the user had completed still could not be approved",
              filled?.isReadyToRun == true)
        check("the edit was not recorded for the audit log",
              filled?.auditNote.contains("to") == true)
        // Building it again must not throw the user's answer away.
        let again = ToolCallReviewStore.shared.beginProposal(
            id: proposalID, toolID: "send_email",
            arguments: [
                "to": "priya.raman@northwind.example",
                "subject": "The deck",
                "body": "Here is the deck.",
            ],
            meetingID: nil, evidence: "send me the deck", risk: .send,
            title: "Send an email")
        check("a redraw threw the user's answer away", again.isReadyToRun)

        // The other way out: a value the app cannot confirm, vouched for on the row.
        ToolCallReviewStore.shared.remove(id: proposalID)
        ToolCallReviewStore.shared.beginProposal(
            id: proposalID, toolID: "send_email",
            arguments: [
                "to": "priya.raman@northwind.example",
                "subject": "The deck",
                "body": "Here is the deck.",
            ],
            meetingID: nil, evidence: "send me the deck", risk: .send,
            title: "Send an email")
        check("an address nothing confirms was offered as ready to send",
              ToolCallReviewStore.shared.isReadyToRun(id: proposalID) == false)
        ToolCallReviewStore.shared.confirm(id: proposalID, field: "to")
        check("saying \u{201c}that's right\u{201d} did not unblock the proposal",
              ToolCallReviewStore.shared.isReadyToRun(id: proposalID))
        ToolCallReviewStore.shared.remove(id: proposalID)

        for failure in failures { print("TOOL_REVIEW_WRONG: \(failure)") }
        print(failures.isEmpty ? "TOOL_REVIEW_OK" : "TOOL_REVIEW_FAILED")
        return failures.isEmpty
    }
}

import Foundation

/// End-of-meeting merge of live cards and the review pass.
///
/// The live extractor already raised asks as they were spoken. The review pass then reads
/// the notes and the transcript and may propose the same work again — "send the deck" as a
/// Workspace email next to the card Sarah already triggered. This is the one place those
/// two lists become one, and the place a summary Doc nobody asked for is dropped. That
/// invention was the old two-minute poll: a model given a generic excerpt proposed
/// `create_doc` every tick.
///
/// Pure, so `--selftest` (and the Actions tab) share one definition. Nothing here runs a
/// tool, talks to `gws`, or writes a meeting file.
enum MeetingActionReconciler {

    /// One live ask, with a review proposal attached when they name the same work.
    struct BoundCandidate: Identifiable, Equatable, Sendable {
        var candidate: MeetingCandidateAction
        var proposal: AgentProposal?

        var id: String { candidate.id }

        /// A bound proposal can be approved from the Actions tab after its preview is shown.
        /// System audio never becomes authority: the candidate source remains `.system`, and
        /// this is true only because a person is explicitly approving the proposal. A live
        /// candidate without a proposal can only be prepared for review.
        var canExecute: Bool {
            proposal != nil
        }
    }

    /// The independent action list: live candidates first (never dropped), then review
    /// proposals that are not a duplicate and not an invented summary Doc.
    struct Outcome: Equatable, Sendable {
        var candidates: [BoundCandidate]
        var proposals: [AgentProposal]

        var isEmpty: Bool { candidates.isEmpty && proposals.isEmpty }

        /// Visible rows across both sections. A merged pair counts as one.
        var rowCount: Int { candidates.count + proposals.count }
    }

    /// Live candidates stay; matching review proposals fold into them; discussion-only
    /// mentions and a generic notes Doc do not become rows.
    static func reconcile(
        candidates: [MeetingCandidateAction],
        proposals: [AgentProposal],
        mentioned: [MeetingContextItem] = [],
        actionItems: [MeetingContextItem] = []
    ) -> Outcome {
        _ = mentioned
        let surviving = acceptedProposals(
            from: proposals,
            candidates: candidates,
            actionItems: actionItems
        )

        let rankedCandidates = candidates.enumerated().sorted {
            if MeetingIntentDetector.mayAuthorizeExecute($0.element) != MeetingIntentDetector.mayAuthorizeExecute($1.element) {
                return MeetingIntentDetector.mayAuthorizeExecute($0.element)
            }
            return $0.offset < $1.offset
        }

        var claimed: Set<String> = []
        var attachedForCandidate: [String: AgentProposal?] = [:]
        for indexedCandidate in rankedCandidates {
            let candidate = indexedCandidate.element
            let unclaimed = surviving.filter { !claimed.contains($0.id) }
            let matched = unclaimed.filter { Self.matches(candidate, $0) }
            if matched.count == 1 {
                attachedForCandidate[candidate.id] = matched.first
                claimed.insert(matched[0].id)
            }
        }

        let bound: [BoundCandidate] = candidates.map {
            BoundCandidate(candidate: $0, proposal: attachedForCandidate[$0.id] ?? nil)
        }

        let leftover = surviving.filter { !claimed.contains($0.id) }
        return Outcome(candidates: bound, proposals: leftover)
    }

    /// What `AgentService.review` may file. Invented summary Docs are dropped here, before
    /// they reach `proposals.json`. A proposal that matches a live card is kept: Approve on
    /// that card is the only path that runs the tool, and hiding it from disk would leave
    /// the card with nothing to run.
    static func acceptedProposals(
        from proposals: [AgentProposal],
        candidates: [MeetingCandidateAction],
        mentioned: [MeetingContextItem] = [],
        actionItems: [MeetingContextItem] = []
    ) -> [AgentProposal] {
        _ = mentioned
        return proposals.filter {
            !isInventedSummaryDoc($0, candidates: candidates, actionItems: actionItems)
        }
    }

    /// Match the action's tool, its object, and (when the live ask names one) the proposal's
    /// explicit target. Rationale text is useful for a card, but it is not a recipient field:
    /// using it as one can bind Sarah's ask to a proposal addressed to Jordan.
    static func matches(_ candidate: MeetingCandidateAction, _ proposal: AgentProposal) -> Bool {
        guard actionMatches(candidate.action, proposal.tool) else { return false }

        let object = normalize(candidate.object ?? "")
        if !object.isEmpty, !containsPhrase(object, in: haystack(for: proposal)) { return false }

        let recipient = candidate.recipient.map(normalize) ?? ""
        guard !object.isEmpty || !recipient.isEmpty else { return false }
        guard !recipient.isEmpty else { return true }

        let targets = proposalTargets(for: proposal)
        guard !targets.isEmpty else { return false }
        return recipientAliases(recipient).contains { candidateAlias in
            targets.contains(candidateAlias)
        }
    }

    // MARK: - Inventions

    /// A generic notes Doc without transcript evidence is an invention. The model pass
    /// now requires an exact quote, so this no longer depends on a list of English ask
    /// phrases that would miss other wording or languages.
    static func isInventedSummaryDoc(
        _ proposal: AgentProposal,
        candidates: [MeetingCandidateAction],
        actionItems: [MeetingContextItem]
    ) -> Bool {
        _ = candidates
        _ = actionItems
        return proposal.tool == "create_doc" && proposal.evidence == nil
    }

    // MARK: - Marks

    private static func haystack(for proposal: AgentProposal) -> String {
        (
            proposal.title + " " + proposal.rationale + " "
                + proposal.arguments.values.joined(separator: " ")
        ).lowercased()
    }

    /// Keep the small detector vocabulary tied to the tool that can perform it. Matching a
    /// `send` candidate to a `create_doc` proposal just because both mention "deck" would
    /// make the folded card approve the wrong kind of work.
    private static func actionMatches(_ action: String, _ tool: String) -> Bool {
        switch normalize(action) {
        case "send", "email":
            return tool == "send_email"
        case "share":
            return tool == "send_email" || tool == "upload_to_drive"
        case "create", "write":
            return tool == "create_doc"
        case "append", "update":
            return tool == "append_doc"
        case "upload":
            return tool == "upload_to_drive"
        case "schedule":
            return tool == "create_event"
        case "search", "find":
            return tool == "search_email" || tool == "find_drive_files"
        case "read":
            return tool == "read_doc"
        default:
            return false
        }
    }

    private static func containsPhrase(_ phrase: String, in text: String) -> Bool {
        let needle = normalize(phrase)
        guard !needle.isEmpty else { return false }
        return (" " + normalize(text) + " ").contains(" " + needle + " ")
    }

    /// Candidate intent and proposal matching are both phrase-driven, so the same normalization
    /// keeps punctuation and spacing stable before containment checks.
    private static func normalize(_ text: String) -> String {
        text
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"[^\p{L}\p{N}\s]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    /// Pull likely recipients out of proposal arguments to avoid cross-speaker cross-target
    /// merges when two asks say “send the deck”.
    private static func proposalTargets(for proposal: AgentProposal) -> Set<String> {
        let fields = ["to", "to_email", "attendees", "attendee", "cc", "bcc", "recipient", "recipients", "owner", "owners"]
        let values = proposal.arguments
            .filter { fields.contains($0.key.lowercased()) }
            .flatMap { splitTargets($0.value) }

        return Set(values.flatMap(recipientAliases))
    }

    /// Produce both display-name and email aliases without first normalizing away `@`.
    private static func recipientAliases(_ value: String) -> Set<String> {
        let lowered = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cleaned = normalize(lowered)
        guard !cleaned.isEmpty else { return [] }

        var aliases: Set<String> = [cleaned]
        if let at = lowered.firstIndex(of: "@") {
            let local = lowered[..<at]
                .split(whereSeparator: { $0.isWhitespace || $0 == "<" || $0 == ">" })
                .last
                .map(String.init) ?? String(lowered[..<at])
            let normalizedLocal = normalize(local)
            if !normalizedLocal.isEmpty { aliases.insert(normalizedLocal) }
            aliases.insert(String(lowered[...]))
        }
        return aliases
    }

    private static func splitTargets(_ value: String) -> [String] {
        value
            .components(separatedBy: CharacterSet(charactersIn: ",;|"))
            .flatMap { $0.replacingOccurrences(of: " and ", with: ",").components(separatedBy: ",") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Self-test

    /// Duplicate live card + review proposal collapse to one row; a discussion does not
    /// become an action; system audio cannot execute. Prints `MEETING_RECONCILE_OK` /
    /// `MEETING_RECONCILE_FAILED` last. Not wired to `NextNotesApp`. Never calls
    /// `RunLog.record`.
    @discardableResult
    static func runSelfTest() -> Bool {
        var failures: [String] = []
        func check(_ name: String, _ condition: Bool) {
            if !condition { failures.append(name) }
        }

        let meetingID = UUID()
        let deck = MeetingCandidateAction(
            recipient: "Sarah",
            action: "send",
            object: "deck",
            speaker: "Sarah",
            source: .system,
            confidence: "high"
        )
        let email = AgentProposal(
            meetingID: meetingID,
            tool: "send_email",
            arguments: [
                "to": "sarah@example.com",
                "subject": "the deck",
                "body": "Here is the deck.",
            ],
            rationale: "Sarah asked you to send the deck.",
            source: .review
        )
        let teamDeck = AgentProposal(
            meetingID: meetingID,
            tool: "send_email",
            arguments: [
                "to": "jordan@example.com",
                "subject": "the deck",
                "body": "Here is the deck too.",
            ],
            rationale: "Jordan asked you to send the deck.",
            source: .review
        )
        let wrongRecipient = AgentProposal(
            meetingID: meetingID,
            tool: "send_email",
            arguments: [
                "to": "jordan@example.com",
                "subject": "the deck",
                "body": "Here is the deck.",
            ],
            rationale: "Sarah asked you to send the deck.",
            source: .review
        )
        let wrongTool = AgentProposal(
            meetingID: meetingID,
            tool: "create_doc",
            arguments: [
                "title": "the deck",
                "markdown": "Deck notes for Sarah.",
            ],
            rationale: "Create a copy of the deck for Sarah.",
            source: .review
        )
        let calendarWrite = AgentProposal(
            meetingID: meetingID,
            tool: "create_event",
            arguments: [
                "title": "Review the deck",
                "start": "2026-09-15T10:00:00-04:00",
                "end": "2026-09-15T10:30:00-04:00",
                "attendees": "sarah@example.com",
            ],
            rationale: "Schedule the follow-up.",
            source: .review
        )
        check(
            "calendar approval omitted concrete times or attendees",
            calendarWrite.reviewPreview?.contains("2026-09-15T10:00:00-04:00") == true
                && calendarWrite.reviewPreview?.contains("sarah@example.com") == true
        )
        let sarahSystem = MeetingCandidateAction(
            recipient: "Sarah",
            action: "send",
            object: "deck",
            speaker: "Sarah",
            source: .system,
            confidence: "high"
        )
        let jordanSystem = MeetingCandidateAction(
            recipient: "Jordan",
            action: "send",
            object: "deck",
            speaker: "Jordan",
            source: .system,
            confidence: "high"
        )
        let micDeck = MeetingCandidateAction(action: "send", object: "deck", source: .mic)
        let ungrounded = MeetingCandidateAction(action: "send", source: .mic)

        let recipientsMatched = reconcile(
            candidates: [sarahSystem, jordanSystem],
            proposals: [email, teamDeck]
        )
        check(
            "same-object asks for different recipients were matched to Sarah",
            recipientsMatched.candidates.first(where: { $0.candidate.id == sarahSystem.id })?.proposal?.id == email.id
        )
        check(
            "same-object asks for different recipients were matched to Jordan",
            recipientsMatched.candidates.first(where: { $0.candidate.id == jordanSystem.id })?.proposal?.id == teamDeck.id
        )
        let ambiguousMic = reconcile(
            candidates: [micDeck],
            proposals: [email, teamDeck]
        )
        check(
            "a mic ask without a recipient stayed ambiguous",
            ambiguousMic.candidates.first?.proposal == nil && ambiguousMic.proposals.count == 2
        )
        check(
            "a rationale could not override the proposal recipient",
            !matches(sarahSystem, wrongRecipient)
        )
        check(
            "an object-only match could not cross tools",
            !matches(sarahSystem, wrongTool)
        )
        check(
            "an ungrounded candidate did not bind by tool alone",
            !matches(ungrounded, email)
        )
        let confirmation = reconcile(
            candidates: [sarahSystem, micDeck],
            proposals: [email]
        )
        check(
            "a mic confirmation kept the live execution path over system-only",
            confirmation.candidates.first(where: { $0.candidate.id == micDeck.id })?.proposal?.id == email.id
                && confirmation.candidates.first(where: { $0.candidate.id == sarahSystem.id })?.proposal == nil
        )
        check(
            "a folded system proposal kept explicit approval with preview",
            confirmation.candidates.first(where: { $0.candidate.id == sarahSystem.id })?.candidate.source == .system
                && reconcile(candidates: [sarahSystem], proposals: [email])
                    .candidates.first(where: { $0.candidate.id == sarahSystem.id })?.canExecute == true
        )
        check(
            "explicit approval did not turn system speech into authority",
            confirmation.candidates.first(where: { $0.candidate.id == sarahSystem.id })
                .map { !MeetingIntentDetector.mayAuthorizeExecute($0.candidate) } ?? false
        )

        let merged = reconcile(candidates: [deck], proposals: [email])
        check("duplicate live candidate + review proposal became one row", merged.rowCount == 1)
        check("the live candidate stayed visible", merged.candidates.map(\.id) == [deck.id])
        check("the matching proposal folded into the live card", merged.proposals.isEmpty)
        check(
            "a system-audio candidate remained preview-approvable",
            merged.candidates.count == 1 && merged.candidates[0].canExecute
        )

        let discussion = MeetingContextItem(
            text: "We should write this up in a doc later.",
            source: .mic
        )
        let summaryDoc = AgentProposal(
            meetingID: meetingID,
            tool: "create_doc",
            arguments: [
                "title": "Standup notes",
                "markdown": "Notes from standup.",
            ],
            rationale: "Put the notes in a Doc so the room can read them.",
            source: .review
        )
        let discussed = reconcile(
            candidates: [],
            proposals: [summaryDoc],
            mentioned: [discussion],
            actionItems: [discussion]
        )
        check("a discussion became an action", discussed.isEmpty)
        check("an invented summary Doc survived", discussed.proposals.isEmpty)
        check(
            "a paraphrased model citation was accepted as transcript evidence",
            !MeetingAgent.isTranscriptEvidence(
                "Please distribute the revised plan", in: "Sam: Share the final deck with Alex."
            )
        )
        check(
            "an exact model citation was rejected",
            MeetingAgent.isTranscriptEvidence(
                "Share the final deck with Alex.",
                in: "Sam: Share the final deck with Alex."
            )
        )
        let parsedEvidence = AgentToolCallParser.calls(in: """
            <tool_call>{"name":"create_doc","arguments":{"title":"Plan"},"rationale":"Requested","evidence":"Share the final deck with Alex."}</tool_call>
            """)
        check("tool parser lost the transcript quote", parsedEvidence.first?.evidence == "Share the final deck with Alex.")
        check(
            "acceptedProposals kept an invented Doc",
            acceptedProposals(
                from: [summaryDoc],
                candidates: [],
                actionItems: [discussion]
            ).isEmpty
        )

        let systemOnly = reconcile(candidates: [deck], proposals: [])
        check("a live system candidate stayed visible", systemOnly.rowCount == 1)
        check(
            "a system-audio candidate reported as executable",
            systemOnly.candidates.count == 1 && !systemOnly.candidates[0].canExecute
        )

        let mic = MeetingCandidateAction(action: "send", object: "deck", source: .mic)
        let fromMic = reconcile(candidates: [mic], proposals: [])
        check(
            "a mic candidate without a proposal stayed in Prepare",
            fromMic.candidates.count == 1 && !fromMic.candidates[0].canExecute
        )

        writeLine(failures)
        return failures.isEmpty
    }

    private static func writeLine(_ failures: [String]) {
        for failure in failures {
            emit("  MEETING_RECONCILE_WRONG: \(failure)")
        }
        emit(failures.isEmpty
             ? "MEETING_RECONCILE_OK: merge, discussion filter and the authority split hold"
             : "MEETING_RECONCILE_FAILED: \(failures.count) rule(s) wrong")
    }

    private static func emit(_ line: String) {
        let text = "\(line)\n"
        FileHandle.standardOutput.write(Data(text.utf8))
        Log.app.info("selftest · \(line, privacy: .public)")
        guard let path = SelfTest.outputPath else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}

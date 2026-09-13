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

        /// Microphone speech may authorise execute. System audio never does — a matching
        /// Workspace proposal is a person clicking Approve, not Sarah's ask becoming
        /// authority.
        var canExecute: Bool {
            MeetingIntentDetector.mayAuthorizeExecute(candidate)
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

        var claimed: Set<String> = []
        let bound: [BoundCandidate] = candidates.map { candidate in
            let paired = surviving.filter { Self.matches(candidate, $0) }
            let attached = paired.count == 1 ? paired[0] : nil
            if let attached { claimed.insert(attached.id) }
            return BoundCandidate(candidate: candidate, proposal: attached)
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

    /// Same object in the proposal's title, rationale or arguments. No object, no guess —
    /// the same conservative rule `AgentService.matchingProposal` uses at Approve time.
    static func matches(_ candidate: MeetingCandidateAction, _ proposal: AgentProposal) -> Bool {
        guard let object = candidate.object?.lowercased(), !object.isEmpty else { return false }
        return haystack(for: proposal).contains(object)
    }

    // MARK: - Inventions

    /// `create_doc` with no explicit ask behind it. "We should write this up later" is a
    /// mention, not a request, and the review prompt's "put the notes in a Doc" habit is
    /// how the two-minute poll used to invent one every tick.
    static func isInventedSummaryDoc(
        _ proposal: AgentProposal,
        candidates: [MeetingCandidateAction],
        actionItems: [MeetingContextItem]
    ) -> Bool {
        guard proposal.tool == "create_doc" else { return false }
        if candidates.contains(where: { matches($0, proposal) && isDocumentAction($0) }) {
            return false
        }
        if actionItems.contains(where: { isExplicitAsk($0.text) && mentionsDocument($0.text) }) {
            return false
        }
        return true
    }

    // MARK: - Marks

    private static func haystack(for proposal: AgentProposal) -> String {
        (
            proposal.title + " " + proposal.rationale + " "
                + proposal.arguments.values.joined(separator: " ")
        ).lowercased()
    }

    private static func isDocumentAction(_ candidate: MeetingCandidateAction) -> Bool {
        mentionsDocument([candidate.action, candidate.object ?? ""].joined(separator: " "))
    }

    private static func mentionsDocument(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return ["doc", "notes", "summary", "write-up", "writeup"].contains { lowered.contains($0) }
    }

    /// The same ask shapes the live detector uses, plus "put that in a doc" — an explicit
    /// request the review pass is allowed to keep a Doc for.
    private static func isExplicitAsk(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let asks = [
            "can you", "could you", "would you",
            "please send", "please share", "please email", "please put", "please write",
            "send me", "share the", "send her", "send him", "send them",
            "put that in", "put this in",
        ]
        guard asks.contains(where: lowered.contains) else { return false }
        return !isDiscussionOnly(lowered)
    }

    private static func isDiscussionOnly(_ lowered: String) -> Bool {
        let hedges = ["we should", "maybe we", "at some point", "sometime"]
        return hedges.contains(where: lowered.contains) || lowered.contains(" later")
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

        let merged = reconcile(candidates: [deck], proposals: [email])
        check("duplicate live candidate + review proposal became two rows", merged.rowCount == 1)
        check("the live candidate was dropped", merged.candidates.map(\.id) == [deck.id])
        check("the matching proposal stayed visible as its own card", merged.proposals.isEmpty)
        check(
            "a system-audio candidate reported as executable",
            merged.candidates.count == 1 && !merged.candidates[0].canExecute
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
            "acceptedProposals kept an invented Doc",
            acceptedProposals(
                from: [summaryDoc],
                candidates: [],
                actionItems: [discussion]
            ).isEmpty
        )

        let systemOnly = reconcile(candidates: [deck], proposals: [])
        check("a live system candidate was removed", systemOnly.rowCount == 1)
        check(
            "a system-audio candidate reported as executable",
            systemOnly.candidates.count == 1 && !systemOnly.candidates[0].canExecute
        )

        let mic = MeetingCandidateAction(action: "send", object: "deck", source: .mic)
        let fromMic = reconcile(candidates: [mic], proposals: [])
        check(
            "mic speech was refused authority",
            fromMic.candidates.count == 1 && fromMic.candidates[0].canExecute
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

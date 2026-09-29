import SwiftUI

/// The meeting panel's Actions section: what the meeting asked for, heard while it is
/// happening rather than read off the notes afterwards.
///
/// Almost none of this is new, and that is the point. `AgentService` already owns one list
/// of candidates, one of proposals and one of performed actions, live and after the fact,
/// and `MeetingActionsView` already draws all three for a finished meeting. This is that
/// same information in a panel, at a smaller size, with the meeting still running — the
/// permission model, the review builder and the only path to a tool are the service's, and
/// nothing here reaches a Workspace write by any other route.
///
/// Three things are different because the meeting is not over, and each is load-bearing
/// rather than cosmetic: there is no transcript to review, so no "Review this meeting" and
/// no speaker identification; a pass may be *running*, which is a state between empty and
/// populated; and every ask carries the moment in the meeting it came from, because
/// "what did we agree" mid-meeting is a question about a position in the recording rather
/// than a question about a list.
struct MeetingConsoleActionsSection: View {
    let session: MeetingSession

    @State private var agent = AgentService.shared
    @State private var settings = Settings.shared
    @State private var contextStore = MeetingContextStore.shared
    @State private var editing: AgentProposal?

    // MARK: - What the sheet draws around us

    /// `.findingActions` while a pass over *this* meeting is running, and `.idle` otherwise.
    ///
    /// Read from the service rather than from a timer, because a status row is a claim and
    /// the whole orb vocabulary rests on not claiming work that is not happening. Not
    /// `.transcribing`: that is the Notes section's work, and two sections claiming the
    /// same work is a claim the app cannot back up.
    var activity: MeetingConsoleActivity {
        isWorking(meetingID, reconciled) ? .findingActions : .idle
    }

    /// Nothing, on purpose. An approval belongs on the row that approves, beside the
    /// message it approves; a panel-wide "Approve all" would put a bulk path in front of
    /// irreversible actions, which is the one thing the permission model exists to prevent.

    // MARK: - Body

    var body: some View {
        // The meeting id read once, so every card in the panel agrees with every other
        // about which meeting it is about. Read per-card it is one `UUID` copy, but the
        // reason to bind it is the row that closes over it: an approve built against a
        // different id than the row it sits on is a write to the wrong meeting.
        let id = meetingID
        let outcome = reconciled
        let done = performed
        let busy = isWorking(id, outcome)
        return VStack(alignment: .leading, spacing: DS.Space.l) {
            MeetingConsoleSectionHeader(section: .actions, subtitle: subtitle(outcome))

            if let problem = agent.problem(for: id) {
                // The service's own sentence, whatever the failure was: no model resolved,
                // a tool that is switched on but not connected, a refused address. A second
                // summary written here would be a second thing that can be wrong, and this
                // one already reaches the user through the island and the Actions tab.
                ProblemBanner(
                    message: problem,
                    dismiss: { agent.clearProblem(for: id) }
                )
            }

            if agent.isThinking(id) {
                note(thinkingLine)
            } else if busy {
                note(runningLine)
            }

            if !outcome.isEmpty || !done.isEmpty {
                rows(outcome, done, id)
            } else if !busy {
                empty
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Two things change under a live meeting without the panel's shape changing at
        // all: a card arrives, and a pass starts or stops. Both are the service's own
        // counters, so both animate from the same signal the list is drawn from.
        .animation(DS.Motion.fluid, value: agent.revision)
        .animation(DS.Motion.fluid, value: busy)
        .sheet(item: $editing) { proposal in
            ProposalArgumentsSheet(proposal: proposal) { arguments in
                agent.update(proposal, arguments: arguments)
                // What was typed here is the person's own, and the card has to hear about
                // it. Rebuilding the review from the saved arguments instead would run them
                // back through the inspector, which cannot tell a correct address the
                // person knows from one the model invented — and the card would go on
                // refusing a value it had just asked for.
                ToolCallReviewStore.shared.applyEdits(id: proposal.id, arguments: arguments)
            }
        }
    }

    // MARK: - Reading the meeting

    private var meetingID: UUID { session.meeting.id }

    /// Live cards and review proposals after the merge, and the two signals that make this
    /// list live: the service's `revision` and the live meeting context. Both are read in
    /// the body on purpose — that is the subscription. A panel that showed a stale list
    /// while a meeting filled it in would be worse than no panel, because it would look
    /// like the meeting had asked for nothing.
    private var reconciled: MeetingActionReconciler.Outcome {
        _ = contextStore.current
        _ = agent.revision
        return agent.reconciled(for: meetingID)
    }

    /// Read back off the store rather than off `session.meeting`, because approving
    /// something rewrites the meeting file and the session's copy predates it.
    private var performed: [AgentActionRecord] {
        _ = agent.revision
        return (MeetingStore.shared.meeting(id: meetingID) ?? session.meeting).agentActions
    }

    /// A pass is running: either one over this meeting, or one of its tools. Both are
    /// named below, because "working out what this meeting needs" and "finishing what you
    /// approved" are different sentences and one status row cannot say both.
    private func isWorking(
        _ id: UUID,
        _ outcome: MeetingActionReconciler.Outcome
    ) -> Bool {
        if agent.isThinking(id) { return true }
        return outcome.proposals.contains { agent.isRunning($0) }
            || outcome.candidates.contains { $0.proposal.map(agent.isRunning) ?? false }
    }

    /// Not the status row's own sentence, which the sheet already pins above this and
    /// which says the same thing more briefly. What this line adds is the panel's promise:
    /// the list is still being filled from what has been said so far.
    private var thinkingLine: String {
        "Going through what has been said so far. Anything the meeting agrees to do "
            + "appears here as it is said."
    }

    /// Not the same claim: a tool is running because a person pressed Approve, and the
    /// panel is waiting on that rather than looking for anything.
    private var runningLine: String {
        "Finishing what you approved. The row it belongs to says which."
    }

    private func note(_ line: String) -> some View {
        // Centred rather than baseline-aligned: a circular progress indicator has no text
        // baseline to line a sentence up with.
        HStack(spacing: DS.Space.s) {
            // Not an orb: the panel's one turning shape is the status row the sheet draws
            // above this, and two would be a scattering of marks on a 300pt pane.
            ProgressView()
                .controlSize(.small)
            Text(line)
                .font(DS.Font.callout)
                .foregroundStyle(DS.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// How many are on the list, with "so far" because the meeting is still going. A bare
    /// number over a growing list reads as a total, and a total is a claim about a meeting
    /// that has not ended.
    private func subtitle(_ outcome: MeetingActionReconciler.Outcome) -> String? {
        outcome.rowCount > 0 ? "\(outcome.rowCount) so far" : nil
    }

    // MARK: - The list

    /// Three groups, in the order `MeetingActionsView` uses for a finished meeting —
    /// asked, waiting, done — because the merge that produced this order is the
    /// reconciler's and a second ordering would have to re-derive it. A hairline between
    /// the groups rather than a heading style change, so the eye finds the seams without
    /// the panel looking like three documents.
    private func rows(
        _ outcome: MeetingActionReconciler.Outcome,
        _ done: [AgentActionRecord],
        _ id: UUID
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            if !outcome.candidates.isEmpty {
                group("Asked in the meeting") {
                    ForEach(outcome.candidates) { bound in
                        card(bound, meetingID: id)
                    }
                }
            }

            if !outcome.proposals.isEmpty {
                if !outcome.candidates.isEmpty { Divider() }
                group("Waiting for you") {
                    ForEach(outcome.proposals) { proposal in
                        card(proposal)
                    }
                }
            }

            if !done.isEmpty {
                if !outcome.candidates.isEmpty || !outcome.proposals.isEmpty { Divider() }
                // "Done" is last and is not the last word: the meeting is still running, and
                // the growing list above is the point of the panel.
                group("Done") {
                    ForEach(done) { record in
                        ConsolePerformedRow(record: record)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// No orb on a group heading. The panel's one turning shape is the status row above,
    /// and a mark per heading is exactly the scattering of small orbs the vocabulary rules
    /// out — these headings are also names rather than statuses: they say what a group
    /// *is*.
    private func group(
        _ title: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionHeading(title: title)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func card(
        _ bound: MeetingActionReconciler.BoundCandidate,
        meetingID: UUID
    ) -> some View {
        ConsoleActionCard(
            ask: ConsoleAsk(bound.candidate, isReviewed: bound.proposal != nil),
            proposal: bound.proposal,
            isRunning: bound.proposal.map { agent.isRunning($0) } ?? false,
            approve: {
                if let proposal = bound.proposal {
                    agent.approve(proposal)
                } else {
                    agent.approveCandidate(bound.candidate, meetingID: meetingID)
                }
            },
            prepare: { agent.prepareCandidate(bound.candidate, meetingID: meetingID) },
            edit: { editing = bound.proposal },
            dismiss: { agent.dismissCandidate(bound.candidate) }
        )
    }

    /// `prepare` is never called from this one: a row without a proposal is the only row
    /// that offers Prepare, so the closure is a requirement of the shared card rather than
    /// a path to anything.
    private func card(_ proposal: AgentProposal) -> some View {
        ConsoleActionCard(
            ask: nil,
            proposal: proposal,
            isRunning: agent.isRunning(proposal),
            approve: { agent.approve(proposal) },
            prepare: {},
            edit: { editing = proposal },
            dismiss: { agent.dismiss(proposal) }
        )
    }

    // MARK: - Nothing yet

    /// Why there is nothing here. Three different answers because the three fixes are in
    /// three different places, and one "nothing yet" would hide which one applies.
    /// `MeetingActionsView` draws the same split for a finished meeting and its first two
    /// sentences are used here unchanged; the third is not, because a meeting in progress
    /// has no transcript to read and no "review it again" to offer.
    private var emptyReason: EmptyReason {
        if !settings.agentEnabled { return .turnedOff }
        if !agent.authState.isSignedIn { return .notConnected }
        return .nothingYet
    }

    private enum EmptyReason {
        case turnedOff
        case notConnected
        case nothingYet
    }

    @ViewBuilder
    private var empty: some View {
        switch emptyReason {
        case .turnedOff:
            // `breathing`, not `connecting`: nothing is being wired together, the feature
            // is simply at rest until a person asks for it.
            OrbUnavailableView(
                .breathing,
                title: "Follow-up actions are off",
                message: "Turn them on in Settings, then connect your Google account.",
                hasField: false
            ) {
                SettingsLink { Text("Open Settings\u{2026}") }
            }
        case .notConnected:
            // The same shape the Workspace tab shows while a connection is being made,
            // because that is what is missing. The message is the CLI's own account state,
            // which is what distinguishes "not installed" from "no account" from "the probe
            // itself failed" — three different fixes in three different places.
            OrbUnavailableView(
                .connecting,
                title: "Not connected",
                message: agent.authState.detail,
                hasField: false
            ) {
                SettingsLink { Text("Open Settings\u{2026}") }
            }
        case .nothingYet:
            OrbUnavailableView(
                .breathing,
                title: "Nothing to do yet",
                message: liveListening
                    ? "What the meeting agrees on turns up here as it is said."
                    : "Nothing is listening for requests while the meeting runs. Turn on "
                        + "“Listen for requests during a meeting” in the Workspace tab "
                        + "in Settings.",
                hasField: false
            ) {
                if liveListening {
                    EmptyView()
                } else {
                    SettingsLink { Text("Open Settings\u{2026}") }
                }
            }
        }
    }

    /// Off by default, and it is the switch that decides whether this panel can ever fill
    /// up during a meeting — so a live panel that said "nothing yet" while nothing was
    /// listening would be answering a question nobody asked.
    private var liveListening: Bool { settings.agentLiveDuringMeeting }
}

/// The meeting's own ask, before any review has answered it: what was said, by whom, and
/// where in the meeting it was said.
///
/// The position is the one thing a finished meeting does not need. Once the notes are
/// written, a row's usefulness is whether you agree with it; mid-meeting, "what did we
/// agree" is a question about a moment, and a quote you can find again is the difference
/// between a row you trust and a row you go and check.
private struct ConsoleAsk {
    var title: String
    var source: AudioSource
    var quote: String?
    var position: TimeInterval?
    /// `MeetingLiveAgent`'s own sentence for an ask nobody has reviewed — which quotes the
    /// words the card came from and says that nothing runs before the details have been
    /// checked. Nil once a proposal answers the ask, because then the proposal's own
    /// sentence is the one to read.
    var detail: String?

    init(_ candidate: MeetingCandidateAction, isReviewed: Bool) {
        title = MeetingLiveAgent.title(for: candidate)
        source = candidate.source
        quote = candidate.evidence.flatMap { trimmed in
            trimmed.isEmpty ? nil : trimmed
        }
        position = candidate.evidenceStart
        detail = isReviewed ? nil : MeetingLiveAgent.detail(for: candidate)
    }

    /// Which side of the room said it, and not decoration: system audio may propose a
    /// follow-up and may never authorise one.
    var chipText: String {
        source == .system ? "Others asked" : "You said"
    }
}

/// One row of the panel: an ask the meeting made, a proposal waiting for an answer, or an
/// ask a proposal has been folded into.
///
/// All three are the same card because the only thing that differs is which halves are
/// present — and which halves are present *is* the permission model. A row with no
/// proposal can only be prepared; a row with one can be approved, and only through
/// `AgentService`, which routes to the executor and the broker like every other surface.
private struct ConsoleActionCard: View {
    /// Nil for a proposal a pass raised on its own, which has no moment in the meeting to
    /// point back to.
    let ask: ConsoleAsk?
    /// Nil for an ask nobody has reviewed yet. That absence is the whole gate: without it
    /// there is nothing to approve, only something to look at.
    let proposal: AgentProposal?
    let isRunning: Bool
    let approve: () -> Void
    let prepare: () -> Void
    let edit: () -> Void
    let dismiss: () -> Void

    /// Where the review lives. The fallback below covers the frame before `.task` has run
    /// and nothing else.
    @State private var store = ToolCallReviewStore.shared

    /// Built from the tool's own schema rather than from the proposal's prose, so a
    /// parameter the model left out or invented shows up as a question rather than as
    /// nothing at all. Read out of the store, because the person's own edits and
    /// confirmations live in the stored copy.
    private var review: ToolCallReview? {
        guard let proposal else { return nil }
        return store.review(id: proposal.id) ?? ToolCallReviewStore.review(
            proposalID: proposal.id, toolID: proposal.tool, arguments: proposal.arguments,
            meetingID: proposal.meetingID, evidence: proposal.evidence,
            risk: proposal.risk, title: proposal.title
        )
    }

    /// A proposal still short an address, a start time or a value nobody could confirm
    /// cannot be approved from here. Nothing on the card arrives pre-checked: a value the
    /// model made up is not a fact until a person recognises it, and it blocks everything
    /// above a read, because nothing sends itself. The row's own "That's right" is how a
    /// person says so without leaving the panel.
    private var isReadyToRun: Bool { review?.isReadyToRun ?? true }

    /// Blockers the editing sheet can actually answer. A value that is merely unconfirmed
    /// is answered on the row itself, and sending somebody to a sheet where everything is
    /// already filled in is how the old card trapped them.
    private var fillable: [ToolCallField] {
        review?.blockers.filter { $0.problem != .notConfirmed } ?? []
    }

    private var fillInLabel: String {
        fillable.count == 1 ? "Fill in 1 thing\u{2026}" : "Fill in \(fillable.count) things\u{2026}"
    }

    private var signature: String {
        guard let proposal else { return "" }
        return proposal.id + "\u{1}"
            + proposal.arguments.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }.joined(separator: "\u{2}")
    }

    var body: some View {
        surface
            // Keyed on the arguments as well as the id: a proposal the agent has rewritten
            // gets a fresh review, and one the person has just edited keeps theirs.
            .task(id: signature) {
                guard let proposal else { return }
                store.beginProposal(
                    id: proposal.id, toolID: proposal.tool, arguments: proposal.arguments,
                    meetingID: proposal.meetingID, evidence: proposal.evidence,
                    risk: proposal.risk, title: proposal.title
                )
            }
    }

    /// Waiting is a different *kind* of row, not a different tint. A proposal is drawn on
    /// glass over the pane's dotted field; an ask nobody has reviewed is not. The chip
    /// above names which of the two it is, so the two are never told apart by colour
    /// alone — and never by red, which means recording.
    @ViewBuilder
    private var surface: some View {
        if proposal != nil {
            GlassCard(cornerRadius: DS.Radius.glassSmall, padding: DS.Space.cardTight) {
                contents
            }
        } else {
            contents
                .padding(.vertical, DS.Space.xs)
        }
    }

    private var contents: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            head
            if let position = ask?.position { positionLine(position) }
            proposalBody
            buttons
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var head: some View {
        if let ask {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                Text(ask.title)
                    .font(DS.Font.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: DS.Space.s)
                StatusChip(text: ask.chipText, color: DS.Color.info)
            }
        }
        if let proposal {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                // What the review proposes, as a second line when it is answering the
                // meeting's own ask, and as the row's title when there was no ask to answer.
                Text(proposal.title)
                    .font(ask == nil ? DS.Font.headline : DS.Font.callout)
                    .foregroundStyle(ask == nil ? DS.Color.text : DS.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: DS.Space.s)
                StatusChip(text: proposal.risk.displayName, color: riskColor(proposal.risk))
            }
        }
    }

    /// The position in the meeting, stamped the way the transcript rows are stamped, so it
    /// reads as a place rather than as a duration.
    private func positionLine(_ position: TimeInterval) -> some View {
        Label(position.counterText, systemImage: "clock")
            .font(DS.Font.caption)
            .foregroundStyle(DS.Color.textTertiary)
            .help("Where in the meeting this was said")
    }

    @ViewBuilder
    private var proposalBody: some View {
        if let proposal {
            Text(proposal.rationale)
                .font(DS.Font.callout)
                .foregroundStyle(DS.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let evidence = proposal.evidence ?? ask?.quote {
                Text("Transcript: “\(evidence)”")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if let review {
                ToolReviewSummary(review: review) { field in
                    store.confirm(id: proposal.id, field: field)
                }
            }

            if let preview = proposal.reviewPreview, !preview.isEmpty {
                ScrollView {
                    Text(preview)
                        .font(DS.Font.transcript)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: DS.Size.messagePreviewHeight)
                .padding(DS.Space.s)
                // Stays an opaque fill rather than becoming a second glass surface: this is
                // a well *inside* a card, and glass in glass refracts glass.
                .background(DS.Color.groupedFill, in: RoundedRectangle(cornerRadius: DS.Radius.control))
            }
        } else if let detail = ask?.detail {
            Text(detail)
                .font(DS.Font.callout)
                .foregroundStyle(DS.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var buttons: some View {
        HStack(spacing: DS.Space.s) {
            if proposal != nil {
                Button("Approve", action: approve)
                    .buttonStyle(.borderedProminent)
                    // Nothing here is pre-checked: a value the model invented is not a fact
                    // until a person recognises it, and a card that could be approved over
                    // an unreviewed value would be the whole permission model with a
                    // sentence removed. Edit, or the row's own "That's right", is the way
                    // forward — and the help says which.
                    .disabled(!isReadyToRun)
                    .help(isReadyToRun
                          ? "Runs exactly what is on this card."
                          : (review?.needsSummary ?? "Something is still needed."))
            } else {
                // Never Approve. Without a proposal there is nothing approved, nothing to
                // check and no arguments to see — Prepare opens the meeting where the whole
                // card is. A row from others' voices cannot be run from this panel at all
                // until a person has looked at what a review proposes for it.
                Button("Prepare", action: prepare)
                    .buttonStyle(.borderedProminent)
                    .help("Opens this meeting so you can check the details before anything runs.")
            }
            overflow
            if isRunning {
                ProgressView()
                    .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        // `gws` is a network round trip and the card looks untouched for the second or two
        // it takes, which is how a send gets pressed twice.
        .disabled(isRunning)
    }

    /// The two secondary answers, in the shape the rest of the app's overflows use rather
    /// than a second row of buttons: this pane is about 300 points wide, and three buttons
    /// on every row is a wall of chrome around a list of things somebody has to read.
    private var overflow: some View {
        Menu {
            if proposal != nil {
                // Labelled for what it does rather than always "Edit…": with nothing to
                // fill in, editing is an option rather than the next step, and the row
                // above already says which of the two this is.
                Button(fillable.isEmpty ? "Edit\u{2026}" : fillInLabel, action: edit)
            }
            Button("Dismiss", role: .cancel, action: dismiss)
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help(proposal == nil
              ? "Take this off the list"
              : "Change the details, or take it off the list")
    }

    /// Warning for anything that cannot run without a person, plain otherwise. Never red:
    /// red is recording, and a proposal is not a recording.
    private func riskColor(_ risk: AgentRisk) -> Color {
        risk.mayAutoRun ? DS.Color.info : DS.Color.warning
    }
}

/// One thing that already happened, with the way back to it.
///
/// The record the finished meeting's row draws, at the size that fits under a list that is
/// still growing: a lookup's answer clipped, and the link back to whatever was created.
private struct ConsolePerformedRow: View {
    let record: AgentActionRecord

    /// A lookup's answer, clipped: it is context for the row above it, not a document.
    private static let detailLines = 2

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            Image(systemName: record.succeeded
                ? "checkmark.circle.fill"
                : "exclamationmark.triangle.fill")
                .foregroundStyle(record.succeeded ? DS.Color.success : DS.Color.warning)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(record.title)
                    .font(DS.Font.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if let failure = record.failure {
                    Text(failure)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.warning)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(record.performedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textTertiary)
                }
                if let detail = record.detail, !detail.isEmpty {
                    Text(detail)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                        .lineLimit(Self.detailLines)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: DS.Space.s)
            if let link = record.link {
                Link(destination: link) {
                    Label("Open", systemImage: "arrow.up.right.square")
                        .font(DS.Font.caption)
                }
            }
        }
        .padding(.vertical, DS.Space.xs)
    }
}

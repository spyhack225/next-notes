import AppKit
import SwiftUI

/// What the meeting asked for, what the Workspace agent has offered, and what has already
/// been done.
///
/// Live candidates stay above leftover Workspace proposals. After a review pass,
/// `AgentService.reconciled` folds a matching proposal into its live card so "send the
/// deck" is one row rather than two — and drops an invented summary Doc that nobody
/// asked for. Performed actions stay last.
struct MeetingActionsView: View {
    let meeting: Meeting

    @State private var agent = AgentService.shared
    @State private var settings = Settings.shared
    @State private var contextStore = MeetingContextStore.shared
    @State private var editing: AgentProposal?

    /// Live cards + review proposals after dedupe. Observes the live store so a card
    /// raised mid-meeting appears here without a reopen.
    private var reconciled: MeetingActionReconciler.Outcome {
        _ = contextStore.current
        _ = agent.revision
        return agent.reconciled(for: meeting.id)
    }

    /// Read back off the store rather than from the captured `meeting`: approving something
    /// rewrites `meeting.json`, and the copy this view was handed is from before that.
    private var performed: [AgentActionRecord] {
        _ = agent.revision
        return (MeetingStore.shared.meeting(id: meeting.id) ?? meeting).agentActions
    }

    var body: some View {
        Group {
            if agent.isThinking(meeting.id) {
                working
            } else if reconciled.isEmpty, performed.isEmpty {
                empty
            } else {
                list
            }
        }
        .animation(DS.Motion.fluid, value: agent.revision)
        .animation(DS.Motion.fluid, value: agent.isThinking(meeting.id))
        .animation(DS.Motion.fluid, value: reconciled.rowCount)
        .sheet(item: $editing) { proposal in
            ProposalArgumentsSheet(proposal: proposal) { arguments in
                agent.update(proposal, arguments: arguments)
            }
        }
    }

    // MARK: - States

    /// The same orb the notes use, for the same reason: this wait is a local model reading a
    /// transcript, which is a minute or two rather than a frame or two.
    private var working: some View {
        VStack(spacing: DS.Space.m) {
            ThinkingOrb(state: .searching, isInline: false)
            Text("Working out what this meeting needs\u{2026}")
                .font(DS.Font.callout)
                .foregroundStyle(DS.Color.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dottedField(opacity: DS.Opacity.fieldFaint)
    }

    private var empty: some View {
        OrbUnavailableView(
            emptyOrb,
            title: "No actions",
            message: emptyDescription
        ) {
            if agent.isReady {
                Button("Review this meeting") { agent.review(meeting, force: true) }
            } else {
                SettingsLink { Text("Open Settings\u{2026}") }
            }
        }
    }

    /// The orb takes the empty state's *cause*, which here is one of two different things.
    ///
    /// An agent that is switched off or signed out is a connection that has not been made,
    /// and `connecting` is the same shape the Workspace tab shows while it is being made —
    /// so the orb and the button under it are telling the same story. A meeting that simply
    /// asked for nothing is a screen at rest, which is `breathing`.
    private var emptyOrb: OrbGeometry.State {
        settings.agentEnabled && agent.authState.isSignedIn ? .breathing : .connecting
    }

    /// Says which of the three reasons there is nothing here — off, not signed in, or
    /// nothing to do. They need different answers and a single "nothing yet" hides that.
    private var emptyDescription: String {
        if !settings.agentEnabled {
            return "Follow-up actions are turned off. The Workspace tab in Settings turns "
                + "them on, once the Google Workspace CLI is signed in."
        }
        if !agent.authState.isSignedIn {
            return agent.authState.detail
        }
        return "Nothing in this meeting asked for a follow-up. Reviewing it again reads the "
            + "notes and the transcript from scratch."
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.l) {
                if !reconciled.candidates.isEmpty {
                    // No orb: these are notices the extractor already raised, not a job
                    // that is running. The Meetings live pane keeps the one `weaving` orb.
                    section("Asked in the meeting") {
                        ForEach(reconciled.candidates) { bound in
                            CandidateActionCard(
                                bound: bound,
                                isRunning: bound.proposal.map(agent.isRunning) ?? false,
                                approve: {
                                    if let proposal = bound.proposal {
                                        agent.approve(proposal)
                                    } else {
                                        agent.approveCandidate(
                                            bound.candidate,
                                            meetingID: meeting.id
                                        )
                                    }
                                },
                                prepare: {
                                    agent.prepareCandidate(
                                        bound.candidate,
                                        meetingID: meeting.id
                                    )
                                },
                                edit: { editing = bound.proposal },
                                dismiss: { agent.dismissCandidate(bound.candidate) }
                            )
                        }
                    }
                }

                if !reconciled.proposals.isEmpty {
                    // `searching` on the heading and nowhere else. Every card under it came
                    // out of the same pass over the notes and the transcript, so the mark
                    // belongs to the section rather than repeated down a column of cards —
                    // which would be the "scattering of small orbs" the design rules out.
                    // Matching live cards are already folded above; this list is leftovers.
                    section("Waiting for you", orb: .searching) {
                        ForEach(reconciled.proposals) { proposal in
                            ProposalCard(
                                proposal: proposal,
                                isRunning: agent.isRunning(proposal),
                                approve: { agent.approve(proposal) },
                                edit: { editing = proposal },
                                dismiss: { agent.dismiss(proposal) }
                            )
                        }
                    }
                }

                if !performed.isEmpty {
                    section("Done") {
                        ForEach(performed) { record in
                            PerformedActionRow(record: record)
                        }
                    }
                }

                if agent.isReady {
                    Button("Review again") { agent.review(meeting, force: true) }
                        .buttonStyle(.link)
                }
            }
            .padding(DS.Space.l)
            .frame(maxWidth: DS.Size.readingWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Something for the glass to be glass over. A pane with nothing behind it has
        // nothing to refract, which is how a card ends up reading as a flat grey box.
        .dottedField(opacity: DS.Opacity.fieldFaint)
    }

    /// "Done" gets no orb, and the absence is the point: the section above it is work the
    /// agent went looking for, and this one is a record of what already happened.
    private func section(
        _ title: String,
        orb: OrbGeometry.State? = nil,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionHeading(title: title, orb: orb)
            content()
        }
    }
}

/// One extracted live ask, optionally folded with a matching Workspace proposal after
/// review. System-audio cards still require an explicit click, but a matched proposal keeps
/// the full preview visible so the user can approve it with confidence.
private struct CandidateActionCard: View {
    let bound: MeetingActionReconciler.BoundCandidate
    let isRunning: Bool
    let approve: () -> Void
    let prepare: () -> Void
    let edit: () -> Void
    let dismiss: () -> Void

    private var candidate: MeetingCandidateAction { bound.candidate }
    private var canExecute: Bool { bound.canExecute }
    private var proposal: AgentProposal? { bound.proposal }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                    Text(MeetingLiveAgent.title(for: candidate))
                        .font(DS.Font.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: DS.Space.s)
                    StatusChip(text: chipText, color: DS.Color.info)
                }

                if let proposal {
                    // Keep the proposed tool and its resolved target visible on a folded
                    // candidate, just as they are on a standalone proposal card.
                    Text(proposal.title)
                        .font(DS.Font.callout)
                        .foregroundStyle(DS.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(detailText)
                    .font(DS.Font.callout)
                    .foregroundStyle(DS.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let preview = proposal?.reviewPreview, !preview.isEmpty {
                    ScrollView {
                        Text(preview)
                            .font(DS.Font.transcript)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: DS.Size.messagePreviewHeight)
                    .padding(DS.Space.s)
                    .background(DS.Color.groupedFill, in: RoundedRectangle(cornerRadius: DS.Radius.control))
                }

                HStack(spacing: DS.Space.s) {
                    if canExecute {
                        Button("Approve", action: approve)
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Prepare", action: prepare)
                            .buttonStyle(.borderedProminent)
                    }
                    if proposal != nil {
                        Button("Edit\u{2026}", action: edit)
                    }
                    Button("Dismiss", role: .cancel, action: dismiss)
                    if isRunning {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Spacer()
                }
                .disabled(isRunning)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var chipText: String {
        if proposal != nil {
            return candidate.source == .system ? "Others asked · review" : "You said · review"
        }
        return candidate.source == .system ? "Others asked" : "You said"
    }

    private var detailText: String {
        if let proposal {
            return proposal.rationale
        }
        return MeetingLiveAgent.detail(for: candidate)
    }
}

/// One unanswered proposal.
///
/// Everything the action would do is on the card before either button: the tool's own words,
/// the model's reason, and — for anything that speaks in the user's name — the full message.
/// A proposal that has to be opened to be understood is one that gets approved unread.
private struct ProposalCard: View {
    let proposal: AgentProposal
    /// Whether this proposal's tool is running right now. Nothing is written until it
    /// returns, so without this the card looks untouched for the second or two `gws` takes
    /// and gets pressed again — which the service refuses, but silently.
    let isRunning: Bool
    let approve: () -> Void
    let edit: () -> Void
    let dismiss: () -> Void

    var body: some View {
        GlassCard {
            card
        }
    }

    /// The landing page's hero card, in a window: a pane with nothing but a corner radius
    /// and its own refraction saying where it ends. The border and the opaque fill it
    /// replaces were both standing in for that.
    private var card: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                Text(proposal.title)
                    .font(DS.Font.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: DS.Space.s)
                StatusChip(text: proposal.risk.displayName, color: riskColor)
            }

            Text(proposal.rationale)
                .font(DS.Font.callout)
                .foregroundStyle(DS.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

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
                // a well *inside* a pane, and glass in glass refracts glass.
                .background(DS.Color.groupedFill, in: RoundedRectangle(cornerRadius: DS.Radius.control))
            }

            HStack(spacing: DS.Space.s) {
                Button("Approve", action: approve)
                    .buttonStyle(.borderedProminent)
                Button("Edit\u{2026}", action: edit)
                Button("Dismiss", role: .cancel, action: dismiss)
                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
            }
            .disabled(isRunning)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Warning for anything that speaks as the user, plain otherwise. Never red: red is
    /// recording, and a proposal is not a recording.
    private var riskColor: Color {
        proposal.risk == .send ? DS.Color.warning : DS.Color.info
    }
}

/// One thing that actually happened, with the way back to it.
private struct PerformedActionRow: View {
    let record: AgentActionRecord

    /// A lookup's answer, clipped: it is context for the row above it, not a document.
    private static let detailLines = 4

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
            Image(systemName: record.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
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

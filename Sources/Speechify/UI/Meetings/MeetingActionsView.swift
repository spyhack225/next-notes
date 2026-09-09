import AppKit
import SwiftUI

/// What the agent has offered to do about this meeting, and what has already been done.
///
/// Two lists, and the order is the point: the unanswered proposals first, because they are
/// the only thing on this screen that needs a person, and the record of what was performed
/// under them, because that is what answers "did I already send this?" a week later.
struct MeetingActionsView: View {
    let meeting: Meeting

    @State private var agent = AgentService.shared
    @State private var settings = Settings.shared
    @State private var editing: AgentProposal?

    private var proposals: [AgentProposal] { agent.proposals(for: meeting.id) }

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
            } else if proposals.isEmpty, performed.isEmpty {
                empty
            } else {
                list
            }
        }
        .animation(DS.Motion.fluid, value: agent.revision)
        .animation(DS.Motion.fluid, value: agent.isThinking(meeting.id))
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
    }

    private var empty: some View {
        ContentUnavailableView {
            Label("No actions", systemImage: "sparkles")
        } description: {
            Text(emptyDescription)
        } actions: {
            if agent.isReady {
                Button("Review this meeting") { agent.review(meeting, force: true) }
            } else {
                SettingsLink { Text("Open Settings\u{2026}") }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                if !proposals.isEmpty {
                    section("Waiting for you") {
                        ForEach(proposals) { proposal in
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
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func section(
        _ title: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text(title)
                .font(DS.Font.sectionLabel)
                .foregroundStyle(DS.Color.textSecondary)
            content()
        }
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

            if let preview = proposal.messagePreview, !preview.isEmpty {
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
        .padding(DS.Space.m)
        .background(DS.Color.content, in: RoundedRectangle(cornerRadius: DS.Radius.card))
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.card)
                .strokeBorder(DS.Color.separator, lineWidth: DS.Border.hairline)
        }
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

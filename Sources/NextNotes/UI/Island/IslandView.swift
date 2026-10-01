import SwiftUI

/// What the island draws.
///
/// Two layouts of the same thing. Collapsed, it is a badge on each side of the notch — the
/// strip of menu bar next to the camera is the only screen real estate on a MacBook that
/// nothing else wants. Expanded, the card grows down out of that strip and the badge slides
/// into it, which is why the badge is one view with a matched geometry rather than two.
///
/// The view knows nothing about windows. `IslandPanel` gives it the screen's measurements
/// and its own size; everything here is laid out inside that.
struct IslandView: View {
    @Bindable var state: IslandState
    let metrics: IslandGeometry.Metrics

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var namespace

    var body: some View {
        card
            .frame(width: size.width, height: size.height)
            // Top-anchored inside the panel, which is always the expanded bounds: the
            // island hangs from the top edge of the screen and grows downwards.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(reduceMotion ? nil : expansion, value: state.isExpanded)
            // A question arrives with a little bounce and a readout simply changes: the
            // island is at the top of the screen either way, and only one of the two is
            // asking to be looked at.
            .animation(
                reduceMotion ? nil : state.kind.demandsAttention ? DS.Motion.bouncy : DS.Motion.fluid,
                value: state.kind.identity
            )
            .opacity(state.kind.isHidden ? 0 : 1)
            // The panel is the notch's own safe area. Without this, SwiftUI pads the
            // collapsed card by that inset and the badges land below the notch — or
            // disappear, when the card is only as tall as the inset it was padded by.
            .ignoresSafeArea()
    }

    private var size: CGSize {
        state.isExpanded ? metrics.expandedSize : metrics.collapsedSize
    }

    private var expansion: Animation {
        state.isExpanded ? DS.Motion.islandExpand : DS.Motion.islandCollapse
    }

    // MARK: - The card

    @ViewBuilder
    private var card: some View {
        if reduceMotion {
            cardContent
        } else {
            // The keyed arrival is only decorative. When motion is reduced, the same
            // content appears at its final size without running a second animation.
            cardContent
                .keyframeAnimator(
                    initialValue: CGFloat(1),
                    trigger: state.isExpanded
                ) { view, scale in
                    view.scaleEffect(x: 1, y: scale, anchor: .top)
                } keyframes: { _ in
                    KeyframeTrack {
                        CubicKeyframe(DS.Scale.islandArrive, duration: DS.Motion.islandExpandDuration / 4)
                        SpringKeyframe(DS.Scale.islandOvershoot, duration: DS.Motion.islandExpandDuration / 2)
                        SpringKeyframe(1, duration: DS.Motion.islandExpandDuration / 4)
                    }
                }
        }
    }

    private var cardContent: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background { substrate }
            .clipShape(shape)
    }

    /// Black and opaque against the bezel, glass when it is floating over a window.
    ///
    /// `GlassEffectContainer` so that the card and the controls inside it are resolved as
    /// one piece of glass while the shape is changing size, instead of each sampling what is
    /// behind it separately and shearing apart mid-animation.
    @ViewBuilder
    private var substrate: some View {
        if metrics.hugsNotch {
            shape.fill(DS.Color.island)
        } else {
            GlassEffectContainer {
                shape
                    .fill(.clear)
                    .glassSurface(in: shape, glass: DS.Material.hudGlass)
            }
        }
    }

    private var shape: UnevenRoundedRectangle {
        // Hugging the notch, the top edge *is* the top of the screen, so it has no corners
        // to round — only the two the notch itself ends on.
        let top: CGFloat = metrics.hugsNotch ? 0 : DS.Radius.islandFloating
        let bottom: CGFloat = metrics.hugsNotch ? DS.Radius.island : DS.Radius.islandFloating
        return UnevenRoundedRectangle(
            topLeadingRadius: top,
            bottomLeadingRadius: bottom,
            bottomTrailingRadius: bottom,
            topTrailingRadius: top,
            style: .continuous
        )
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if state.isExpanded {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                // The strip level with the menu bar. Empty on a notched Mac because the
                // camera is in the middle of it; on a floating island there is no strip.
                if metrics.hugsNotch {
                    Spacer().frame(height: metrics.collapsedSize.height)
                }
                expanded
                    .padding(.horizontal, DS.Space.l)
                    .padding(.bottom, DS.Space.m)
                    .padding(.top, metrics.hugsNotch ? 0 : DS.Space.m)
            }
        } else {
            collapsed
        }
    }

    /// The two badges, with the notch as a hole between them.
    private var collapsed: some View {
        HStack(spacing: metrics.hugsNotch ? 0 : DS.Space.m) {
            badge
                .frame(maxWidth: flankWidth)
            if metrics.hugsNotch {
                Spacer().frame(width: metrics.notchWidth)
            }
            trailing
                .frame(maxWidth: flankWidth)
        }
        .padding(.horizontal, DS.Space.s)
        .frame(height: metrics.collapsedSize.height)
    }

    private var flankWidth: CGFloat {
        metrics.hugsNotch ? DS.Size.islandFlank : .infinity
    }

    @ViewBuilder
    private var expanded: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            badge
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(state.cardTitle)
                    .font(DS.Font.headline)
                    .tracking(0)
                    .foregroundStyle(ink)
                    .lineLimit(1)
                detail
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actions
        }
    }

    // MARK: - Badge

    /// The one element that exists in both layouts, so it can travel between them.
    ///
    /// A recording wears both marks. They answer two different questions — the dot says
    /// this is being recorded, the orb says what *kind* of work is running — so the orb
    /// is drawn *beside* the red dot rather than in place of it, the same way `HUDView`
    /// sets the orb beside the dot and the level bar. Red is still only ever recording.
    private var badge: some View {
        HStack(spacing: DS.Space.xs) {
            mark
            if isCapturing {
                RecordingIndicator(compact: true, label: nil)
            }
        }
        .matchedGeometryEffect(id: Self.badgeID, in: namespace)
    }

    /// Microphone open: a held dictation, or a meeting being recorded. Not the wait after
    /// the key comes up — that is work, not recording, and the red dot would lie.
    private var isCapturing: Bool {
        switch state.kind {
        case .dictating(_, _, let capturing): capturing
        case .meetingRecording: true
        case .agentListening: true
        default: false
        }
    }

    /// The orb for whatever work is running, or the glyph that stands in where none does.
    @ViewBuilder
    private var mark: some View {
        if let avatar = state.avatarState {
            // The agent's own states wear the character rather than the orb. Its clock is a
            // `TimelineView` too, so `IslandAvatarMark` exists for the reason
            // `IslandWorkMark` does: a microphone-level tick must not tear it down.
            IslandAvatarMark(
                config: state.avatarConfig,
                state: avatar,
                ink: ink
            )
            .equatable()
        } else if let orb = state.kind.orb {
            // Identity is the orb's mode, not the microphone level sitting on `kind`.
            // Without `Equatable`, a VU tick would rebuild this wrapper and tear down
            // the `TimelineView` inside `ThinkingOrb` — a blank badge, several times a
            // second, which is the "animation is missing" half of the island report.
            IslandWorkMark(
                orb: orb,
                ink: ink,
                isAnimated: !isPendingApproval
            )
                .equatable()
                // The collapsed waiting count already says what needs attention.
                // Reading the still breathing orb as "idle" would contradict it.
                .accessibilityHidden(isPendingApproval)
        } else {
            switch state.kind {
            case .meetingArmed, .callQuestion:
                glyph("calendar.badge.clock")
            case .notesReady:
                glyph("doc.text")
            case .problem:
                glyph("exclamationmark.triangle")
            default:
                EmptyView()
            }
        }
    }

    private func glyph(_ name: String) -> some View {
        Image(systemName: name)
            .font(DS.Font.title3)
            .foregroundStyle(ink)
            .frame(width: DS.Size.orbInline, height: DS.Size.orbInline)
    }

    /// An unanswered approval is waiting on the person, not doing work. The notice may
    /// expire, but the persistent badge must stay still until somebody answers it.
    private var isPendingApproval: Bool {
        if case .pendingApproval = state.kind { return true }
        return false
    }

    private static let badgeID = "island.badge"

    // MARK: - Collapsed trailing

    /// The right-hand flank: the one number or meter worth the space, or nothing.
    @ViewBuilder
    private var trailing: some View {
        switch state.kind {
        case .dictating(_, let level, let capturing):
            // The meter answers "is it hearing me?", so it is shown only while something
            // is actually being heard. A bar pinned at zero after the key came up reads as
            // a dead microphone rather than as work in progress.
            if capturing {
                LevelBar(level: level)
                    .frame(width: DS.Size.islandBarWidth)
            }
        case .meetingRecording(let elapsed, _, _):
            counter(elapsed)
        case .agentListening(_, let level):
            LevelBar(level: level)
                .frame(width: DS.Size.islandBarWidth)
        case .summarizing(let progress), .diarizing(let progress):
            if let progress {
                Text(progress.formatted(.percent.precision(.fractionLength(0))))
                    .font(DS.Font.caption)
                    .monospacedDigit()
                    .foregroundStyle(secondaryInk)
                    .contentTransition(.numericText())
            }
        case .agentProposal(let proposal):
            // Collapsed, the flank has room for one number. How many answers are owed is
            // the only number this card has.
            if proposal.needsCount > 0 {
                Text("\(proposal.needsCount)")
                    .font(DS.Font.counterSmall)
                    .monospacedDigit()
                    .foregroundStyle(ink)
                    .accessibilityLabel(proposal.needsSummary ?? "")
            }
        case .pendingApproval(_, let waiting):
            // P1-16: the badge's one number. "1 waiting" is what the card says when it is
            // hovered, and the collapsed flank shows the same figure so the count is legible
            // before anybody points at it.
            Text("\(waiting) waiting")
                .font(DS.Font.counterSmall)
                .monospacedDigit()
                .foregroundStyle(ink)
                .accessibilityLabel(proposalAccessibilityLabel(waiting))
        case .agentWorking(_, let current, let total):
            // Collapsed: the counter and the one control worth the flank (P1-1).
            HStack(spacing: DS.Space.xs) {
                Text("\(current)/\(total)")
                    .font(DS.Font.counterSmall)
                    .monospacedDigit()
                    .foregroundStyle(ink)
                    .contentTransition(.numericText())
                    .accessibilityLabel("Step \(current) of \(total)")
                Button("Stop") { state.cancelAgentWork() }
                    .controlSize(.mini)
            }
        default:
            EmptyView()
        }
    }

    private func counter(_ elapsed: TimeInterval) -> some View {
        Text(elapsed.counterText)
            .font(DS.Font.counterSmall)
            .foregroundStyle(ink)
            // Counters roll their digits rather than cutting to the next value: the island
            // sits still for minutes at a time, so the one thing that moves should move.
            .contentTransition(.numericText())
    }

    /// The proposal card's body, shared by the notice and by P1-16's live badge.
    ///
    /// Extracted rather than copied because these are the **same card**: a person who hovers
    /// the badge eight seconds after the card opened it must be looking at exactly the thing
    /// they missed. Two copies of seven lines of view is two cards, and they would drift.
    @ViewBuilder
    private func proposalBody(_ proposal: IslandProposal) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            // The count first, because it changes what the buttons mean. A card that
            // leads with "Send an email to Marie" and buries "no address yet" in the
            // second line is the card that gets approved without being read.
            if let needed = proposal.needsSummary {
                Label(needed, systemImage: "exclamationmark.circle")
                    .font(DS.Font.chip)
                    .foregroundStyle(ink)
                    .labelStyle(.titleAndIcon)
            }
            Text(proposal.detail)
                .font(DS.Font.callout)
                .foregroundStyle(secondaryInk)
                .lineLimit(2)
        }
    }

    /// Plain words, and the singular is its own string: VoiceOver reading "1 waiting" is
    /// fine and "2 waiting" is not a sentence anybody would say.
    private func proposalAccessibilityLabel(_ waiting: Int) -> String {
        waiting == 1 ? "1 request waiting for your answer"
                     : "\(waiting) requests waiting for your answer"
    }

    /// The proposal card's buttons, shared for the same reason the body is: the badge and the
    /// notice are one card, and an Approve in one place and a Review in the other would be a
    /// difference nobody would notice until it mattered.
    @ViewBuilder
    private func proposalActions(_ proposal: IslandProposal) -> some View {
        HStack(spacing: DS.Space.s) {
            Button("Dismiss") { state.decide(proposal, approved: false) }
            // System-audio candidates never get Approve-to-execute. A send that
            // speaks in the user's name still cannot be approved from two lines.
            switch proposal.leadAction {
            case .prepare:
                Button("Prepare") { state.prepare(proposal) }
                    .buttonStyle(.borderedProminent)
            case .review:
                // Two different waits, two different words: something the user has to
                // type is not the same request as something they only have to read.
                Button(proposal.needsCount > 0 ? "Fill in\u{2026}" : "Review\u{2026}") {
                    state.review(proposal)
                }
                .buttonStyle(.borderedProminent)
            case .approve:
                Button("Approve") { state.decide(proposal, approved: true) }
                    .buttonStyle(.borderedProminent)
            }
        }
        .controlSize(.small)
    }

    // MARK: - Expanded detail and actions

    @ViewBuilder
    private var detail: some View {
        switch state.kind {
        case .dictating(let transcript, let level, let capturing):
            HStack(spacing: DS.Space.s) {
                if capturing {
                    LevelBar(level: level)
                        .frame(width: DS.Size.islandBarWidth)
                }
                Text(transcript.isEmpty ? (capturing ? "Listening\u{2026}" : "Transcribing\u{2026}") : transcript)
                    .font(DS.Font.callout)
                    .foregroundStyle(secondaryInk)
                    .lineLimit(2)
                    .truncationMode(.head)
            }

        case .meetingRecording(let elapsed, let micLevel, let systemLevel):
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                counter(elapsed)
                track("You", level: micLevel)
                track("Others", level: systemLevel)
                if let session = MeetingController.shared.session {
                    if session.liveTranscriptPaused {
                        Text("Some live transcription may pause")
                            .foregroundStyle(DS.Color.warning)
                    }
                    if let issue = session.healthWarnings.last {
                        Text(issue.message)
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .meetingArmed(let event), .callQuestion(let event):
            Text(armedDetail(event))
                .font(DS.Font.callout)
                .foregroundStyle(secondaryInk)

        case .notesReady:
            Text("Notes are ready.")
                .font(DS.Font.callout)
                .foregroundStyle(secondaryInk)

        case .pendingApproval(let proposal, let waiting):
            // Exactly what `.agentProposal` draws for the same proposal, not a copy of it:
            // one card, two routes onto it. The one line above it says the card is still
            // waiting, because the *only* reason a person is looking at it is that they
            // never saw it before.
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(waiting == 1 ? "Waiting for your answer."
                                  : "Waiting for your answer \u{2014} \(waiting) requests.")
                    .font(DS.Font.chip)
                    .foregroundStyle(secondaryInk)
                proposalBody(proposal)
            }
        case .agentProposal(let proposal):
            proposalBody(proposal)

        case .agentListening(let transcript, let level):
            HStack(spacing: DS.Space.s) {
                LevelBar(level: level)
                    .frame(width: DS.Size.islandBarWidth)
                Text(state.listeningDetail(transcript))
                    .font(DS.Font.callout)
                    .tracking(0)
                    .foregroundStyle(secondaryInk)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .agentWorking(let steps, let current, let total):
            // Expanded: the current step's title and the counter. Two lines is all the
            // notch has; the step list itself lives in the Agent pane's working card.
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(steps.last ?? "Thinking\u{2026}")
                    .font(DS.Font.callout)
                    .foregroundStyle(secondaryInk)
                    .lineLimit(2)
                Text("Step \(current) of \(total)")
                    .font(DS.Font.caption)
                    .monospacedDigit()
                    .foregroundStyle(secondaryInk)
                    .contentTransition(.numericText())
            }

        case .agentReply(let text):
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(text)
                    .font(DS.Font.callout)
                    .foregroundStyle(secondaryInk)
                    .lineLimit(3)
                // P2-6: the disclaimer is persistent on every surface that speaks.
                Text("Next Notes is AI and can make mistakes.")
                    .font(DS.Font.caption)
                    .foregroundStyle(secondaryInk)
            }

        case .summarizing(let progress), .diarizing(let progress):
            if let progress {
                ProgressView(value: progress)
                    .frame(width: DS.Size.islandExpandedBarWidth)
            }

        case .problem(let message):
            // The sentence itself, not a summary of it. This card exists because the notch
            // used to answer a failed dictation with a silent animation, and a shortened
            // version of the explanation would be the same mistake in smaller print.
            Text(message)
                .font(DS.Font.callout)
                .foregroundStyle(secondaryInk)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

        case .transcribing, .hidden:
            EmptyView()
        }
    }

    private func track(_ label: String, level: Float) -> some View {
        HStack(spacing: DS.Space.s) {
            Text(label)
                .font(DS.Font.caption)
                .foregroundStyle(secondaryInk)
                .frame(width: DS.Size.trackLabelWidth, alignment: .leading)
            LevelBar(level: level)
                .frame(width: DS.Size.islandExpandedBarWidth)
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch state.kind {
        case .meetingArmed(let event), .callQuestion(let event):
            HStack(spacing: DS.Space.s) {
                Button("Skip") { state.skip(event) }
                Button("Record now") { state.recordNow(event) }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)

        case .notesReady(let id, _):
            Button("Open") { state.openNotes(meetingID: id) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

        case .agentListening:
            HStack(spacing: DS.Space.s) {
                // The one place a wake that fired on the wrong speech can be disowned.
                // It records the false accept, closes the session and drops the turn;
                // background work keeps running.
                Button("That wasn\u{2019}t for you") { state.disownAgentListen() }
                Button("Done") { state.endAgentListen() }
            }
            .controlSize(.small)

        case .agentWorking:
            Button("Stop") { state.cancelAgentWork() }
                .controlSize(.small)

        case .agentReply:
            Button("Dismiss") { state.dismissNotice() }
                .controlSize(.small)

        case .pendingApproval(let proposal, _):
            // The same buttons the notice carried, and the same call: `decide` answers the
            // gate, and the gate's `respond` sets `pending = nil`, which is what clears the
            // badge. Nothing here clears a notice, because there is no notice to clear — the
            // card is being *drawn* by the live kind, and the answer is what ends it.
            proposalActions(proposal)

        case .agentProposal(let proposal):
            proposalActions(proposal)
        case .problem:
            // Shown only while there is something to replay (D-03). The card has the
            // words on it and the button is the whole reason the recording was kept —
            // a failure that says what went wrong and offers no way back is the thing
            // this task exists to remove.
            if state.canRetryLastHold {
                Button("Try again") { state.retryLastHold() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }

        default:
            EmptyView()
        }
    }

    // MARK: - Words

    private func armedDetail(_ event: MeetingEvent) -> String {
        // A detected call started before the card did, so the countdown wording would read
        // "Recording now." on a card whose whole purpose is that it has not started.
        if event.providerID == .detectedCall { return "Record this call?" }
        let time = event.start.formatted(date: .omitted, time: .shortened)
        return event.start > Date()
            ? "Recording starts at \(time)."
            : "Recording now."
    }

    /// The island's substrate is the bezel, not the window, so its ink is fixed rather than
    /// semantic — `.primary` on a permanently black card resolves to black in light mode.
    private var ink: Color {
        metrics.hugsNotch ? DS.Color.islandInk : DS.Color.text
    }

    private var secondaryInk: Color {
        ink.opacity(DS.Opacity.islandInkSecondary)
    }
}

/// The island's working orb, isolated from microphone-level ticks.
///
/// `ThinkingOrb` must not be `scaleEffect`'d — the geometry is a function of size, and
/// scaling it smears the lattice. It also must not remount on every VU buffer: its clock
/// is a `TimelineView`, and tearing that down is a blank badge. `Equatable` plus
/// `.equatable()` keeps the view in place while `kind`'s associated values move.
private struct IslandWorkMark: View, Equatable {
    let orb: OrbGeometry.State
    let ink: Color
    let isAnimated: Bool

    var body: some View {
        ThinkingOrb(state: orb, ink: ink, isAnimated: isAnimated)
    }
}

/// The island's character, kept in place by the same rule and for the same reason.
///
/// It carries no environment of its own: `AgentAvatarView` reads Reduce Motion, and a view
/// that reads the environment cannot be compared by value — so the comparison lives here,
/// on the four things the island chooses.
private struct IslandAvatarMark: View, Equatable {
    let config: NotionAvatarConfig
    let state: AgentAvatarState
    let ink: Color

    var body: some View {
        AgentAvatarView(
            config: config,
            state: state,
            size: DS.Size.islandAvatar,
            ink: ink
        )
    }
}

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

    @State private var meetings = MeetingController.shared
    @Namespace private var namespace

    var body: some View {
        card
            .frame(width: size.width, height: size.height)
            // Top-anchored inside the panel, which is always the expanded bounds: the
            // island hangs from the top edge of the screen and grows downwards.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(expansion, value: state.isExpanded)
            // A question arrives with a little bounce and a readout simply changes: the
            // island is at the top of the screen either way, and only one of the two is
            // asking to be looked at.
            .animation(
                state.kind.demandsAttention ? DS.Motion.bouncy : DS.Motion.fluid,
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

    private var card: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background { substrate }
            .clipShape(shape)
            // The card grows out of the notch rather than fading in on top of it: keyed
            // rather than sprung, so the arrival, the overshoot and the settle can each be
            // given their own share of the same duration.
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
                    .glassEffect(DS.Material.hudGlass, in: shape)
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
                Text(title)
                    .font(DS.Font.headline)
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
        default: false
        }
    }

    /// The orb for whatever work is running, or the glyph that stands in where none does.
    @ViewBuilder
    private var mark: some View {
        if let orb = state.kind.orb {
            // Identity is the orb's mode, not the microphone level sitting on `kind`.
            // Without `Equatable`, a VU tick would rebuild this wrapper and tear down
            // the `TimelineView` inside `ThinkingOrb` — a blank badge, several times a
            // second, which is the "animation is missing" half of the island report.
            IslandWorkMark(orb: orb, ink: ink)
                .equatable()
        } else {
            switch state.kind {
            case .meetingArmed:
                glyph("calendar.badge.clock")
            case .notesReady:
                glyph("doc.text")
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
        case .summarizing(let progress), .diarizing(let progress):
            if let progress {
                Text(progress.formatted(.percent.precision(.fractionLength(0))))
                    .font(DS.Font.caption)
                    .monospacedDigit()
                    .foregroundStyle(secondaryInk)
                    .contentTransition(.numericText())
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
            }

        case .meetingArmed(let event):
            Text(armedDetail(event))
                .font(DS.Font.callout)
                .foregroundStyle(secondaryInk)

        case .notesReady:
            Text("Notes are ready.")
                .font(DS.Font.callout)
                .foregroundStyle(secondaryInk)

        case .agentProposal(let proposal):
            Text(proposal.detail)
                .font(DS.Font.callout)
                .foregroundStyle(secondaryInk)
                .lineLimit(2)

        case .summarizing(let progress), .diarizing(let progress):
            if let progress {
                ProgressView(value: progress)
                    .frame(width: DS.Size.islandExpandedBarWidth)
            }

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
        case .meetingArmed(let event):
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

        case .agentProposal(let proposal):
            HStack(spacing: DS.Space.s) {
                Button("Dismiss") { state.decide(proposal, approved: false) }
                // Nothing that speaks in the user's name is approved from here: the card
                // shows two lines, and the message it would send is longer than that.
                if proposal.needsReview {
                    Button("Review\u{2026}") { state.review(proposal) }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Approve") { state.decide(proposal, approved: true) }
                        .buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.small)

        default:
            EmptyView()
        }
    }

    // MARK: - Words

    private var title: String {
        switch state.kind {
        case .hidden: ""
        case .dictating(_, _, let capturing): capturing ? "Dictating" : "Transcribing"
        case .meetingArmed(let event): event.title
        case .meetingRecording: meetings.session?.meeting.title ?? "Recording"
        case .transcribing: MeetingStatus.transcribing.displayName
        case .diarizing: MeetingStatus.diarizing.displayName
        case .summarizing: MeetingStatus.summarizing.displayName
        case .notesReady(_, let title): title
        case .agentProposal(let proposal): proposal.title
        }
    }

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

    var body: some View {
        ThinkingOrb(state: orb, ink: ink)
    }
}

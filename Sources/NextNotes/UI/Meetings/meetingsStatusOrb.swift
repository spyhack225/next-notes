import SwiftUI

/// The one place a meeting's state turns into a shape.
///
/// Meetings is the surface with the most states, so it is the surface where the orb
/// vocabulary either earns itself or reads as decoration. Every mapping below is a row of
/// the table in `AGENTS.md` rather than a choice made here: recording a meeting is
/// `weaving` because two tracks are being braided into one transcript, turning it into
/// text is `working`, telling the speakers apart is `solving`, writing the notes is
/// `composing`, and a meeting that has been claimed but has not started is `breathing` —
/// present on purpose, processing nothing.
///
/// It lives in one place so the list, the header, the empty states and the progress strips
/// cannot drift apart. A state that means one thing in a row and another in a pane is worse
/// than no state at all: the whole point is that the shape can be read without the word.
extension MeetingStatus {
    /// `nil` for the two states that are not work.
    ///
    /// `done` and `failed` deliberately have no orb. An orb says *which long thing is
    /// happening*; a meeting that finished, or fell over, is not doing anything, and a mark
    /// turning over it would be a claim the app cannot back up. Those two are read from the
    /// absence of a shape — which only works if the column is reserved either way, so that
    /// the rows still line up and the eye can find the few that are busy.
    var orb: OrbGeometry.State? {
        switch self {
        case .scheduled, .armed: .breathing
        case .recording: .weaving
        case .transcribing: .working
        case .diarizing: .solving
        case .summarizing: .composing
        case .done, .failed: nil
        }
    }
}

/// A meeting's state as a mark beside its title, in a column of fixed width.
///
/// **Always still, and that is the rule this screen runs on.** Meetings shows a list and a
/// detail pane at the same time, so an animated orb per row would be a dozen canvases
/// re-deriving dots behind a pane that is also transcribing audio. A row's orb is a label
/// for what that meeting *is*; the one orb that actually turns lives in the pane, beside
/// the job that is actually running. Same shapes, different jobs.
///
/// Hidden from accessibility because the row already carries a status chip or a recording
/// indicator saying the same thing in words.
struct MeetingStatusOrb: View {
    let state: OrbGeometry.State?
    var size: CGFloat = DS.Size.orbInline

    init(status: MeetingStatus, size: CGFloat = DS.Size.orbInline) {
        self.state = status.orb
        self.size = size
    }

    init(state: OrbGeometry.State?, size: CGFloat = DS.Size.orbInline) {
        self.state = state
        self.size = size
    }

    var body: some View {
        Group {
            if let state {
                ThinkingOrb(state: state, size: size, isAnimated: false)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        // A canvas has no text in it, so it has no baseline of its own — the same guide
        // `SectionHeading` uses, so an orb beside a title sits the same way everywhere.
        .alignmentGuide(.firstTextBaseline) { $0[.bottom] }
    }
}

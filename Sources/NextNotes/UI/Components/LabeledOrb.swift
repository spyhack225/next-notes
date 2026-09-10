import SwiftUI

/// A small orb and the line of text it belongs to: the app's status line.
///
/// The landing page never sets an orb down on its own — every one of them labels something,
/// and the label is what makes the state legible to somebody who has not learned the nine
/// shapes yet. This is that pairing, and it is the shape a status line should take anywhere
/// the app is doing a named piece of work: transcribing, cleaning up, writing notes, looking
/// something up.
///
/// The orb is hidden from accessibility here and the row is read as one element, because
/// the text already says what the orb says — a screen reader announcing "Working. Working."
/// is the orb's own label leaking through a component that has a better one.
struct LabeledOrb: View {
    /// From the vocabulary in `AGENTS.md`. It must match the work actually running.
    let state: OrbGeometry.State
    let title: String
    /// A second line under the title — what is being worked on, or how far along it is.
    var detail: String?
    var style: Style = .status
    var size: CGFloat = DS.Size.orbInline
    var ink: Color = DS.Color.text
    /// Stop the orb when the work stops. An orb runs on a clock rather than on the work, so
    /// one left animating over a finished job is a claim the app cannot back up.
    var isAnimated = true

    /// How the text is set. The orb and the spacing are the same either way — what changes
    /// is whether the row is announcing a section or reporting on a job.
    enum Style {
        /// A sentence: "Writing notes…", with an optional second line. Reads at body size.
        case status
        /// A capitalised, letterspaced label, the way the landing page labels a card.
        case eyebrow
    }

    var body: some View {
        HStack(alignment: detail == nil ? .center : .top, spacing: DS.Space.orbGap) {
            ThinkingOrb(
                state: state,
                size: size,
                ink: ink,
                isAnimated: isAnimated
            )
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                titleText
                if let detail {
                    Text(detail)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var titleText: some View {
        switch style {
        case .status:
            Text(title)
                .font(DS.Font.callout)
                .foregroundStyle(ink)
        case .eyebrow:
            Text(title)
                .font(DS.Font.eyebrow)
                .tracking(DS.Font.eyebrowTracking)
                .textCase(.uppercase)
                .foregroundStyle(DS.Color.textSecondary)
        }
    }
}

import SwiftUI

/// The site's border beam as a native card-border treatment (spec §6 + §10,
/// UX-11 treatment 3). Reimplements the `border-beam` npm package with native
/// layers — the package itself is never installed.
///
/// The site wraps its hero demo card in a full-border glow that travels the whole
/// perimeter. This view is that overlay: a quiet hairline edge that is always
/// present, plus a colorful comet head (bright head, fading tail) riding the same
/// rounded rectangle. The comet is painted with an angular gradient whose opaque
/// sector ends at the travelling head, so the shape never moves — only the light
/// does. The angular sweep is an approximation of the package's path-following
/// beam, and is documented as one rather than hidden.
///
/// Spec → token map (all values in `DS.Theme.Beam`, palette in `DS.Theme.Palette`):
/// - `size "md"` → `lineWidth` (beam stroke width).
/// - `colorVariant "colorful"` → `inkA/inkB/inkC` (tail → head stops).
/// - `strength 0.7` → `strength` (layer opacity class).
/// - Base edge → `Palette.border` at `edgeOpacity` (spec §3 range).
/// - Loop timing → `period`; redraw cadence → `frameInterval`;
///   comet span → `arcFraction`; glow spread → `glowRadius`.
/// - Still frame under Reduce Motion / paused → head parked at `stillPhase`.
///
/// Pausing contract (matches the site's `active={isInView && !paused && !reduceMotion}`):
/// pass `isAnimated: false` when the card is off-screen, the demo is paused, or the
/// work the beam belongs to has finished. Under Reduce Motion there is no
/// `TimelineView` at all — the parked head is a constant, so there is nothing for a
/// schedule to hold (same cheapest-first shape as `ThinkingOrb.clock`).
///
/// Cost and meaning rules, unchanged: this is decoration (`allowsHitTesting(false)`,
/// hidden from accessibility), it never reports work state — orb states keep that
/// job — and its palette must never sustain record red. A travelling multicolor
/// glow on a card edge is not a status dot, and the tokens worker keeps it that way
/// by keeping the palette clear of a sustained `DS.Color.record`. No store, no
/// queue, no gate: phase is a pure function of the timeline date.
struct ThemeBorderBeam: View {
    /// Corner radius of the card this rims. Passed by the caller so the beam and
    /// the card it rims always share one shape; defaults to the glass geometry.
    var cornerRadius: CGFloat = DS.Radius.glass
    /// False when off-screen, paused, or the work finished. Reduce Motion freezes
    /// regardless of this flag.
    var isAnimated = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(
                    DS.Theme.Palette.border.opacity(DS.Theme.Beam.edgeOpacity),
                    lineWidth: DS.Border.hairline
                )
            beamOverlay
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// Cheapest first: a frozen head needs no clock; a live one redraws on the
    /// token cadence rather than the display's.
    @ViewBuilder
    private var beamOverlay: some View {
        if reduceMotion || !isAnimated {
            beam(at: Self.wrap(DS.Theme.Beam.stillPhase))
        } else {
            TimelineView(.periodic(from: .now, by: DS.Theme.Beam.frameInterval)) { timeline in
                beam(at: Self.phase(at: timeline.date))
            }
        }
    }

    /// The comet: one blurred copy for the glow plus one crisp copy for the head,
    /// both scaled by the strength class.
    private func beam(at head: Double) -> some View {
        ZStack {
            beamStroke(head: head)
                .blur(radius: DS.Theme.Beam.glowRadius)
                .opacity(DS.Theme.Beam.strength)
            beamStroke(head: head)
                .opacity(DS.Theme.Beam.strength)
        }
    }

    private func beamStroke(head: Double) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .stroke(beamGradient(head: head), lineWidth: DS.Theme.Beam.lineWidth)
    }

    /// Transparent everywhere except the sector ending at the head, where it ramps
    /// tail → head through the colorful stops at one-third and two-thirds of the
    /// arc (two-thirds spelled as arc minus a third). Locations are fractions of
    /// the one full turn the gradient sweeps from the tail angle, so the sector
    /// tracks the head without the shape ever moving. The leading falloff spans a
    /// twelfth of the arc — a shaping fraction, not a design value.
    private func beamGradient(head: Double) -> AngularGradient {
        let arc = DS.Theme.Beam.arcFraction
        let third = arc / Self.arcThirds
        let drop = min(arc + arc / Self.leadingFalloffDivisor, Self.fullTurn)
        return AngularGradient(
            gradient: Gradient(stops: [
                Gradient.Stop(color: .clear, location: 0),
                Gradient.Stop(color: DS.Theme.Beam.inkA, location: third),
                Gradient.Stop(color: DS.Theme.Beam.inkB, location: arc - third),
                Gradient.Stop(color: DS.Theme.Beam.inkC, location: arc),
                Gradient.Stop(color: .clear, location: drop),
                Gradient.Stop(color: .clear, location: Self.fullTurn),
            ]),
            center: .center,
            startAngle: .radians((head - arc) * 2 * .pi),
            endAngle: .radians((head - arc + Self.fullTurn) * 2 * .pi)
        )
    }

    /// Head position in turns. `rounded(.down)` keeps the fractional part without
    /// any literal bounds — the arithmetic is the cycle, not a design value.
    private static func phase(at date: Date) -> Double {
        let turns = (date.timeIntervalSinceReferenceDate - epoch) / DS.Theme.Beam.period
        return turns - turns.rounded(.down)
    }

    /// Normalises any phase (including the still token) into one turn.
    private static func wrap(_ phase: Double) -> Double {
        phase - phase.rounded(.down)
    }

    /// Shared epoch so every beam on screen runs in phase, and the clock stays in
    /// a range where a `Double` still has precision to spare.
    private static let epoch = Date().timeIntervalSinceReferenceDate
    /// One full turn, the gradient domain and the phase cycle.
    private static let fullTurn = 1.0
    /// The ramp is subdivided into thirds across the arc (structural bucketing,
    /// the same idea as the orb's ink levels).
    private static let arcThirds = 3.0
    /// The head's leading edge falls over a twelfth of the arc.
    private static let leadingFalloffDivisor = 12.0
}

extension View {
    /// Rims this view's card with the travelling border beam. The caller owns the
    /// animation budget: at most one live treatment per screen, paused off-screen.
    func themeBorderBeam(
        cornerRadius: CGFloat = DS.Radius.glass,
        isAnimated: Bool = true
    ) -> some View {
        overlay {
            ThemeBorderBeam(cornerRadius: cornerRadius, isAnimated: isAnimated)
        }
    }
}

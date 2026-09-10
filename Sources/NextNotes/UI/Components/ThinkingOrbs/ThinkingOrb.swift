import SwiftUI

/// A dotted thought-orb: what the app looks like while it is thinking.
///
/// It replaces the spinner where the wait is measured in minutes rather than in frames, and
/// it is the app's mark as well — the same nine states, at every size from a badge beside a
/// list row to the ambient backdrop behind a whole screen. A `ProgressView` says "wait"; the
/// orb says which of nine different things is happening, and it does so with one ink and no
/// chrome, so it belongs on the notch's black substrate and in a window both.
///
/// **The vocabulary is fixed.** Each state means one thing in this app and means it
/// everywhere — the table in `AGENTS.md` is the whole list. Picking a state because it looks
/// nice here is a lie about what the machine is doing, not a style choice.
///
/// Geometry comes from `OrbGeometry`, which is a port of thinking-orbs (MIT © Jakub
/// Antalik). Everything below it is drawing: one `Canvas`, one colour, no filters.
struct ThinkingOrb: View {
    let state: OrbGeometry.State
    /// The inline tuning (a tenth of the dots, twice the radius) or the large one. Two
    /// designs rather than one scaled — see `OrbGeometry.preset`. Ignored when `size` is
    /// given, because then the size decides: see `usesInlineTuning`.
    var isInline = true
    /// An explicit canvas side, for a scale that is neither of the two defaults.
    ///
    /// Pass a `DS.Size.orb…` token. The geometry is a pure function of size, so an orb is
    /// asked for the size it will occupy rather than drawn once and magnified — a
    /// `scaleEffect` on one grows the dot radii along with the sphere and turns the lattice
    /// into a smear.
    var size: CGFloat?
    /// What the dots are drawn in. The island passes its own ink because its substrate is
    /// the bezel rather than the window.
    var ink: Color = DS.Color.text
    /// Freezes the animation without unmounting the view.
    var isAnimated = true
    /// How fast the state runs against its own clock. Below 1 for anything decorative —
    /// see `DS.Motion.orbBackdropScale`.
    var timeScale: Double = 1
    /// Caps the redraw rate instead of following the display. `nil` means every frame,
    /// which is right for a working orb at reading size and wasteful for a slowed backdrop.
    var frameInterval: TimeInterval?
    /// Overrides the per-state accessibility label.
    var label: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        clock
            .frame(width: side, height: side)
            .accessibilityElement()
            .accessibilityLabel(label ?? state.accessibilityLabel)
    }

    /// Three ways to drive the same canvas, cheapest first.
    ///
    /// Reduce Motion gets no `TimelineView` at all rather than a paused one: the frozen
    /// picture is a constant, so there is nothing for a schedule to hold. A capped orb gets
    /// a periodic schedule, and everything else follows the display.
    @ViewBuilder
    private var clock: some View {
        if reduceMotion {
            canvas(at: Self.stillFrame)
        } else if let frameInterval, isAnimated {
            TimelineView(.periodic(from: .now, by: frameInterval)) { timeline in
                canvas(at: elapsed(to: timeline.date))
            }
        } else {
            TimelineView(.animation(paused: !isAnimated)) { timeline in
                canvas(at: elapsed(to: timeline.date))
            }
        }
    }

    private func canvas(at time: Double) -> some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            draw(in: &context, size: size, at: time)
        }
    }

    private var side: CGFloat { size ?? (isInline ? DS.Size.orbInline : DS.Size.orbLarge) }

    /// Which of the two tunings this size wants.
    ///
    /// An explicit size decides for itself, at the same threshold the app icon uses: the
    /// large design's several hundred dots are correct at 64pt and turn to grey mud below
    /// 96px, which is the entire reason the library ships two designs.
    private var usesInlineTuning: Bool {
        if let size { size < DS.Size.orbInlineCeiling } else { isInline }
    }

    /// Seconds since the first orb was drawn, on this orb's own clock.
    ///
    /// Measured from a shared epoch rather than from the reference date for two reasons:
    /// every orb on screen then runs in phase, the way the original's single clock makes
    /// them, and the trigonometry stays in a range where a `Double` still has precision to
    /// spare. `timeIntervalSinceReferenceDate` is eight hundred million seconds wide.
    private func elapsed(to date: Date) -> Double {
        (date.timeIntervalSinceReferenceDate - Self.epoch) * timeScale
    }

    private static let epoch = Date().timeIntervalSinceReferenceDate
    /// A representative instant, for `prefers-reduced-motion`. Not zero: every mode starts
    /// its cycle at a pose that reads as a diagram rather than as a thing in motion.
    private static let stillFrame: Double = 1.7

    private func draw(in context: inout GraphicsContext, size: CGSize, at time: Double) {
        let frame = OrbGeometry.fullFrame(
            for: state,
            size: min(size.width, size.height),
            time: time,
            inline: usesInlineTuning
        )
        let dots = frame.dots
        guard !dots.isEmpty else { return }

        // Edges first, so the nodes sit on top of the wires they join. Empty for every state
        // but `connecting`.
        if !frame.segments.isEmpty {
            var wires = [(path: Path, width: CGFloat)](
                repeating: (Path(), 0), count: Self.inkLevels
            )
            for segment in frame.segments {
                let level = min(Self.inkLevels - 1, Int(segment.opacity * Double(Self.inkLevels)))
                wires[level].path.move(to: CGPoint(x: segment.x1, y: segment.y1))
                wires[level].path.addLine(to: CGPoint(x: segment.x2, y: segment.y2))
                wires[level].width = max(wires[level].width, segment.width)
            }
            for (level, wire) in wires.enumerated() where !wire.path.isEmpty {
                let opacity = (Double(level) + 0.5) / Double(Self.inkLevels)
                context.stroke(
                    wire.path, with: .color(ink.opacity(opacity)), lineWidth: wire.width
                )
            }
        }

        // Bucketed by opacity rather than filled one at a time: a large orb is five hundred
        // dots, and five hundred `context.fill` calls per frame is most of the cost. The
        // depth order survives the regrouping because opacity *is* the depth — buckets are
        // drawn from faintest to heaviest, which is the same far-to-near order the geometry
        // was sorted into.
        var buckets = [Path](repeating: Path(), count: Self.inkLevels)
        for dot in dots {
            let level = min(Self.inkLevels - 1, Int(dot.opacity * Double(Self.inkLevels)))
            buckets[level].addEllipse(in: CGRect(
                x: dot.x - dot.radius,
                y: dot.y - dot.radius,
                width: dot.radius * 2,
                height: dot.radius * 2
            ))
        }
        for (level, path) in buckets.enumerated() where !path.isEmpty {
            let opacity = (Double(level) + 0.5) / Double(Self.inkLevels)
            context.fill(path, with: .color(ink.opacity(opacity)))
        }
    }

    /// How finely the ink is quantized. Twelve steps is below what the eye resolves on a
    /// 2pt dot and an order of magnitude fewer fills than one per dot.
    private static let inkLevels = 12
}

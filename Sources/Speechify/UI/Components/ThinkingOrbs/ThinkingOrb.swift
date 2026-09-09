import SwiftUI

/// A dotted thought-orb: what the app looks like while it is thinking.
///
/// It replaces the spinner in the two places where the wait is measured in minutes rather
/// than in frames — the island, and the meeting detail view while notes are being written.
/// A `ProgressView` says "wait"; the orb says which of nine different things is happening,
/// and it does so with one ink and no chrome, so it belongs on the notch's black substrate
/// and in a window both.
///
/// Geometry comes from `OrbGeometry`, which is a port of thinking-orbs (MIT © Jakub
/// Antalik). Everything below it is drawing: one `Canvas`, one colour, no filters.
struct ThinkingOrb: View {
    let state: OrbGeometry.State
    /// The inline tuning (a tenth of the dots, twice the radius) or the large one. Two
    /// designs rather than one scaled — see `OrbGeometry.preset`.
    var isInline = true
    /// What the dots are drawn in. The island passes its own ink because its substrate is
    /// the bezel rather than the window.
    var ink: Color = DS.Color.text
    /// Freezes the animation without unmounting the view.
    var isAnimated = true
    /// Overrides the per-state accessibility label.
    var label: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: !isAnimated || reduceMotion)) { timeline in
            Canvas(opaque: false, rendersAsynchronously: false) { context, size in
                draw(in: &context, size: size, at: time(from: timeline.date))
            }
        }
        .frame(width: side, height: side)
        .accessibilityElement()
        .accessibilityLabel(label ?? state.accessibilityLabel)
    }

    private var side: CGFloat { isInline ? DS.Size.orbInline : DS.Size.orbLarge }

    /// Seconds since the first orb was drawn.
    ///
    /// Measured from a shared epoch rather than from the reference date for two reasons:
    /// every orb on screen then runs in phase, the way the original's single clock makes
    /// them, and the trigonometry stays in a range where a `Double` still has precision to
    /// spare. `timeIntervalSinceReferenceDate` is eight hundred million seconds wide.
    private func time(from date: Date) -> Double {
        reduceMotion
            ? Self.stillFrame
            : date.timeIntervalSinceReferenceDate - Self.epoch
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
            inline: isInline
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

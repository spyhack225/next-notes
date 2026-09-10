import SwiftUI

/// The dotted matrix: the landing page's texture, as a background you can put anything on.
///
/// The page has no separate dot pattern — its texture *is* the orbs, several hundred marks
/// on a lattice, fading with depth. This is that lattice flattened and laid out behind
/// content, so a screen carrying no orb still speaks the same language as one that does.
///
/// **It does not animate, and that is the design.** A window-sized field is a few thousand
/// dots; driving it from a `TimelineView` would cost more per frame than every working orb
/// in the app put together, for a texture nobody looks directly at. `Canvas` redraws it only
/// when the size changes, so a field that is never resized is drawn once for the life of the
/// screen. If a background needs to move, that is what `OrbBackdrop` is for — one shape,
/// slowed, capped, and meaningful.
struct DottedField: View {
    /// How the field gives out at its edges. A field with a hard boundary reads as a
    /// texture swatch; one that dies before the edge reads as depth.
    enum Fade {
        /// Even weight everywhere. For a small panel, where there is no room to fall off.
        case flat
        /// Heaviest at the centre, gone before the corners.
        case radial
        /// Heaviest at the top edge — a header band settling into the page.
        case top
        /// Heaviest at the bottom edge.
        case bottom
    }

    var ink: Color = DS.Color.text
    var opacity: Double = DS.Opacity.field
    var dot: CGFloat = DS.Field.dot
    var spacing: CGFloat = DS.Field.spacing
    var fade: Fade = .radial

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            draw(in: &context, size: size)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        guard size.width > 0, size.height > 0, spacing > 0, opacity > 0 else { return }

        // Bucketed by weight, exactly as `ThinkingOrb` buckets its dots: the whole field is
        // eight paths and eight fills however many thousand marks it holds.
        var buckets = [Path](repeating: Path(), count: DS.Field.inkLevels)
        let radius = dot / 2
        let rowHeight = spacing * Self.rowRatio
        let rows = Int(size.height / rowHeight) + 1
        let columns = Int(size.width / spacing) + 1

        for row in 0...rows {
            let y = CGFloat(row) * rowHeight
            // Every other row is offset by half a step, so the field has no verticals to
            // line up with the window's own edges and reads as a lattice rather than a grid.
            let inset = row.isMultiple(of: 2) ? 0 : spacing / 2
            for column in 0...columns {
                let x = CGFloat(column) * spacing + inset
                guard x <= size.width else { continue }
                let weight = self.weight(atX: x, y: y, in: size)
                let level = Int(weight * Double(DS.Field.inkLevels))
                guard level > 0 else { continue }
                buckets[min(DS.Field.inkLevels - 1, level)].addEllipse(
                    in: CGRect(x: x - radius, y: y - radius, width: dot, height: dot)
                )
            }
        }

        for (level, path) in buckets.enumerated() where !path.isEmpty {
            let weight = (Double(level) + 0.5) / Double(DS.Field.inkLevels)
            context.fill(path, with: .color(ink.opacity(opacity * weight)))
        }
    }

    /// 0…1 for one lattice point, before the field's own opacity is applied.
    private func weight(atX x: CGFloat, y: CGFloat, in size: CGSize) -> Double {
        switch fade {
        case .flat:
            return 1
        case .radial:
            let dx = Double(x - size.width / 2)
            let dy = Double(y - size.height / 2)
            let half = Double(hypot(size.width, size.height)) / 2 * DS.Field.reach
            guard half > 0 else { return 1 }
            return pow(max(0, 1 - hypot(dx, dy) / half), DS.Field.falloff)
        case .top:
            return pow(max(0, 1 - Double(y / size.height)), DS.Field.falloff)
        case .bottom:
            return pow(max(0, Double(y / size.height)), DS.Field.falloff)
        }
    }

    /// Rows sit closer together than columns, because staggering them by half a step
    /// already spreads them sideways. Equal spacing on both axes leaves diagonal lines the
    /// eye picks out; √3/2 is the hexagonal packing that doesn't — a fact about the lattice
    /// rather than a number anyone chose, which is why it is written out and not a token.
    private static let rowRatio = CGFloat(3).squareRoot() / 2
}

extension View {
    /// Lays a dotted field behind this view, clipped to it.
    ///
    /// Clipped through a `Color.clear` rather than `.clipped()` on the content, so a
    /// popover, a shadow or a focus ring belonging to the content is not cut off with it.
    func dottedField(
        ink: Color = DS.Color.text,
        opacity: Double = DS.Opacity.field,
        dot: CGFloat = DS.Field.dot,
        spacing: CGFloat = DS.Field.spacing,
        fade: DottedField.Fade = .radial
    ) -> some View {
        background {
            Color.clear.overlay {
                DottedField(ink: ink, opacity: opacity, dot: dot, spacing: spacing, fade: fade)
            }
            .clipped()
        }
    }
}

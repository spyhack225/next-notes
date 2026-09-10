import SwiftUI

/// The landing page's `.liquid-glass`, as a macOS 26 surface.
///
/// The page draws that treatment by hand — a 1% white wash, a 4px backdrop blur, and a
/// gradient rim light on the top and bottom lips. Only the first two of those are ideas;
/// the third is a workaround for the fact that CSS has no glass. macOS 26 does, so this is
/// `.glassEffect`, and the rim light is **not** ported: the system draws its own specular
/// edge, it draws it against whatever is actually behind the pane, and it draws it correctly
/// in both appearances — where a hard-coded white lip is only ever right on a black page.
/// That also keeps the rule that there are no gradients on chrome in this app.
///
/// Under **Reduce Transparency** it falls back to an opaque-ish material. Not a nicety: the
/// setting exists because refraction behind text is unreadable for some people, and a glass
/// pane that ignores it is broken rather than pretty.
struct GlassSurfaceModifier<S: Shape>: ViewModifier {
    let shape: S
    let glass: Glass
    let material: SwiftUI.Material

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(material, in: shape)
        } else {
            content.glassEffect(glass, in: shape)
        }
    }
}

extension View {
    /// The glass treatment on an arbitrary shape — a capsule, an uneven rectangle, anything.
    func glassSurface(
        in shape: some Shape,
        glass: Glass = DS.Material.surfaceGlass,
        fallback: SwiftUI.Material = DS.Material.card
    ) -> some View {
        modifier(GlassSurfaceModifier(shape: shape, glass: glass, material: fallback))
    }

    /// The glass treatment on a rounded rectangle, which is nearly always what is wanted.
    func glassSurface(
        cornerRadius: CGFloat = DS.Radius.glass,
        glass: Glass = DS.Material.surfaceGlass,
        fallback: SwiftUI.Material = DS.Material.card
    ) -> some View {
        glassSurface(
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
            glass: glass,
            fallback: fallback
        )
    }
}

/// A padded glass pane. The landing page's hero cards, in a window.
///
/// Padding is part of the component because glass has no border: the corner radius and the
/// distance from the content to the edge are the only two things saying where the pane is,
/// and a pane whose text runs to its edge stops reading as a pane at all.
struct GlassCard<Content: View>: View {
    var cornerRadius: CGFloat = DS.Radius.glass
    var padding: CGFloat = DS.Space.card
    var glass: Glass = DS.Material.surfaceGlass
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .glassSurface(cornerRadius: cornerRadius, glass: glass)
    }
}

/// Several glass pieces resolved as one.
///
/// Adjacent panes each sample what is behind them separately, so two that touch — or one
/// that is animating its size next to another — shear apart along the seam. A container
/// resolves them together. The island already does this for the same reason; anywhere two
/// glass surfaces sit side by side wants it too.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = DS.Space.s
    @ViewBuilder var content: () -> Content

    var body: some View {
        GlassEffectContainer(spacing: spacing) {
            content()
        }
    }
}

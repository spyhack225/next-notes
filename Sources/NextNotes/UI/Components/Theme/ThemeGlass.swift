import SwiftUI

/// The site's glass pane tuned to the spec §4 light values (UX-11 treatment 2).
///
/// A thin delegate over the existing `glassSurface` seam — one renderer owns the
/// rule, and this adapter carries no rendering of its own. The themed tuning
/// (ink-tinted glass, solid theme fallback under Reduce Transparency) travels
/// through `DS.Material.surfaceGlass` and the shared fallback branch, so every
/// themed and unthemed pane resolves together.
struct ThemeGlassModifier<S: Shape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        content.glassSurface(in: shape)
    }
}

extension View {
    /// The themed glass treatment on an arbitrary shape.
    func themeGlass(in shape: some Shape) -> some View {
        modifier(ThemeGlassModifier(shape: shape))
    }

    /// The themed glass treatment on a rounded rectangle, which is nearly always
    /// what is wanted.
    func themeGlass(cornerRadius: CGFloat = DS.Radius.glass) -> some View {
        themeGlass(
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
    }
}

/// A padded themed glass pane, mirroring `GlassCard`'s contract (padding is part of
/// the component for the same reason: glass has no border, so the corner radius and
/// the distance from content to edge are the only two things saying where it is).
struct ThemeGlassCard<Content: View>: View {
    var cornerRadius: CGFloat = DS.Radius.glass
    var padding: CGFloat = DS.Space.card
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .themeGlass(cornerRadius: cornerRadius)
    }
}

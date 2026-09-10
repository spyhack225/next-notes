import SwiftUI

/// One large, slow, nearly-invisible orb behind a screen's content — the landing page's
/// hero, brought inside.
///
/// The page puts a 520pt `breathing` ring behind its headline at half opacity, on pure
/// black, with nothing else on the canvas. A window is not that: it already carries text, a
/// sidebar and controls, in whichever appearance the user picked. So the backdrop here is an
/// order of magnitude fainter, a quarter as fast, and redrawn twenty times a second instead
/// of sixty. The test it has to pass is that you notice it only once you go looking.
///
/// **A screen gets one.** Every orb is a `Canvas` re-deriving several hundred dots per
/// frame; this is the most expensive one in the app, and two of them on one screen is a
/// laptop fan. Use the backdrop for the screen's ambient state and a `LabeledOrb` for the
/// specific thing that is running — never a second backdrop.
///
/// It is decoration and says so: no hit testing, hidden from accessibility. Everything it
/// implies is said in words by the content in front of it.
struct OrbBackdrop: View {
    /// What the screen is *about*, not what it is doing this second. `breathing` for a
    /// screen at rest — see the vocabulary table in `AGENTS.md`.
    var state: OrbGeometry.State = .breathing
    var size: CGFloat = DS.Size.orbBackdrop
    var ink: Color = DS.Color.text
    var opacity: Double = DS.Opacity.orbBackdrop
    /// Freeze it. A backdrop over a screen that is doing nothing at all can stop moving,
    /// and a frozen `Canvas` costs nothing at all.
    var isAnimated = true

    /// Stops the backdrop while the app is not the one being used.
    ///
    /// Safe here in a way it would not be on a working orb: a backdrop only ever lives in a
    /// window, and nothing is lost by its standing still behind a window nobody is looking
    /// at. The HUD and the island deliberately do **not** do this — they are panels over
    /// somebody else's frontmost app, which is precisely when they matter.
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        ThinkingOrb(
            state: state,
            size: size,
            ink: ink,
            isAnimated: isAnimated && activeState != .inactive,
            timeScale: DS.Motion.orbBackdropScale,
            frameInterval: DS.Motion.orbBackdropFrameInterval
        )
        .opacity(opacity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension View {
    /// Puts an orb backdrop behind this view, clipped to it.
    ///
    /// Clipped through a `Color.clear` rather than `.clipped()` on the content, so a
    /// popover, a shadow or a focus ring belonging to the content is not cut off with it.
    /// The orb is deliberately allowed to be larger than the pane and run off its edges —
    /// a backdrop that fits inside the content reads as an illustration sitting behind it
    /// rather than as the ground the content is standing on.
    func orbBackdrop(
        _ state: OrbGeometry.State = .breathing,
        size: CGFloat = DS.Size.orbBackdrop,
        opacity: Double = DS.Opacity.orbBackdrop,
        alignment: Alignment = .center,
        isAnimated: Bool = true
    ) -> some View {
        background(alignment: alignment) {
            Color.clear
                .overlay(alignment: alignment) {
                    OrbBackdrop(
                        state: state, size: size, opacity: opacity, isAnimated: isAnimated
                    )
                }
                .clipped()
        }
    }
}

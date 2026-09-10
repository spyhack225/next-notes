import AppKit

/// Where the island goes, and how big it is.
///
/// macOS has no Dynamic Island API, so all of this is measured off the screen. Two numbers
/// do the work: `safeAreaInsets.top` is non-zero exactly on a display with a notch and is
/// the notch's height, and `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` are the two
/// strips of menu bar either side of it — so what is left of the width between them is the
/// notch. A display without a notch reports neither, and the island becomes a capsule
/// hanging just under the menu bar instead.
///
/// Pure and static so `--selftest-island` can print what it computed for every attached
/// display without putting a panel on screen.
@MainActor
enum IslandGeometry {

    /// Everything the panel and the view need to place themselves on one screen.
    struct Metrics: Equatable {
        /// The panel's frame, in screen coordinates. Always the expanded bounds — the panel
        /// never resizes, only its contents do. See `IslandPanel` for why.
        let bounds: NSRect
        let collapsedSize: CGSize
        let expandedSize: CGSize
        /// The width of the hole the island wraps around, or zero when it is floating.
        let notchWidth: CGFloat
        /// Whether the island is continuous with the bezel. Decides its substrate, its
        /// corner radii and whether it has a hole in the middle.
        let hugsNotch: Bool

        /// The island's own rectangle inside `bounds`, in the content view's own
        /// coordinates. What the panel hit-tests against, so the transparent part of the
        /// window never swallows a click meant for the app underneath.
        func islandRect(expanded: Bool) -> NSRect {
            let size = expanded ? expandedSize : collapsedSize
            return NSRect(
                x: (bounds.width - size.width) / 2,
                y: bounds.height - size.height,
                width: size.width,
                height: size.height
            )
        }
    }

    /// Whether the Mac this is running on has a notch at all. Decides the default
    /// `Settings.hudPlacement`.
    ///
    /// Every attached display is asked, not `NSScreen.main`. The question is about the
    /// machine, not about where a window happens to be — and `main` is whichever screen
    /// holds the key window, so on this Mac with an external monitor plugged in it answers
    /// "no notch" for a MacBook that plainly has one.
    static var hasNotch: Bool {
        NSScreen.screens.contains { notchWidth(of: $0) != nil }
    }

    /// The width of a screen's notch, or nil when it hasn't got one.
    ///
    /// Both halves are required. `safeAreaInsets.top` alone is also non-zero on an external
    /// display in some configurations, and the auxiliary areas alone are nil on a screen
    /// that simply hasn't been asked about them yet.
    static func notchWidth(of screen: NSScreen) -> CGFloat? {
        guard screen.safeAreaInsets.top > 0 else { return nil }
        guard let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea
        else { return nil }
        let width = screen.frame.width - left.width - right.width
        return width > 0 ? width : nil
    }

    static func metrics(for screen: NSScreen) -> Metrics {
        let notch = notchWidth(of: screen)
        let hugsNotch = notch != nil
        let notchWidth = notch ?? 0

        // Hugging the notch, the collapsed island is exactly as tall as the menu-bar inset,
        // so its top edge is the top of the screen and only its bottom corners are curved.
        let collapsedHeight = hugsNotch
            ? max(screen.safeAreaInsets.top, DS.Size.islandCapsuleHeight)
            : DS.Size.islandCapsuleHeight
        let collapsedWidth = notchWidth + 2 * DS.Size.islandFlank
        let collapsed = CGSize(width: collapsedWidth, height: collapsedHeight)
        let expanded = CGSize(
            width: max(collapsedWidth, DS.Size.islandExpandedWidth),
            height: collapsedHeight + DS.Size.islandExpandedDrop
        )

        // The top edge: the physical top of the screen when there is a notch to merge with,
        // and a hair below the menu bar when there isn't.
        let top = hugsNotch
            ? screen.frame.maxY
            : screen.visibleFrame.maxY - DS.Size.islandFloatingInset
        let bounds = NSRect(
            x: screen.frame.midX - expanded.width / 2,
            y: top - expanded.height,
            width: expanded.width,
            height: expanded.height
        )

        return Metrics(
            bounds: bounds,
            collapsedSize: collapsed,
            expandedSize: expanded,
            notchWidth: notchWidth,
            hugsNotch: hugsNotch
        )
    }

    /// The screen the pointer is on, which is the one the island follows.
    ///
    /// `NSScreen.main` is the screen with the key window, and an accessory panel that never
    /// becomes key never gives anyone one — so it answers with the wrong display, or with
    /// nil. The pointer is the honest answer to "which screen is the user looking at".
    static func screenUnderMouse() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(point) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }
}

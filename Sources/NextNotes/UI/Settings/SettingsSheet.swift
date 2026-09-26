import AppKit
import SwiftUI

/// `--settings-sheet [dir] [--width <pt>]` — every Settings pane rendered offscreen at the
/// width it will actually meet, one PNG per pane.
///
/// A diagnostic rather than a self-test, for the same reason as `--avatar-sheet`: a
/// self-test answers a yes/no question from a terminal, and this one produces something to
/// *look* at. The fault it is for is the one the narrow-window screenshots had — a pane
/// asking for more width than its host has, so the form is drawn past the window's right
/// edge and clipped, with every picker's value cut off mid-word. `--selftest-settings`
/// answers that numerically by fitting size; whether the *layout* that remains is right at
/// each width is a question only an eye answers, and this is the eye. It is also what
/// proved the adaptive card grid needs no narrow-width clamp: rendered with the column
/// minimum pinned at `settingsCardMinWidth` and at the pane's own width, a 320pt pane is
/// pixel-for-pixel the same.
///
/// It renders through `SettingsPane` (the band, the divider, the real form style), at a
/// fixed height with the rest scrolled off, because the top of the pane is where the
/// header, the first card and the first rows are — the width behaviour, not the scroll
/// position, is the question. `cacheDisplay` of the app's own view needs no Screen
/// Recording grant, so this runs on any machine; it does read the live stores, which is why
/// it is dispatched before the self-test harness replaces them.
@MainActor
enum SettingsSheet {
    /// The widths a pane meets in the product: the narrowest the main window can hand it,
    /// the standalone window's form column, and a wide window sharing its row in two.
    static let widths: [CGFloat] = [
        DS.Size.settingsPaneMinWidth,
        DS.Size.settingsWidth,
        DS.Size.settingsWidth * 2,
    ]

    /// What one rendered pane is called on disk.
    private static func fileName(_ tab: SettingsTab, _ width: CGFloat) -> String {
        "settings-\(tab.rawValue)-\(Int(width)).png"
    }

    static func write(
        to directory: String,
        controller: DictationController,
        widths: [CGFloat] = widths
    ) -> Bool {
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            print("SETTINGS_SHEET_FAILED: \(error.localizedDescription)")
            return false
        }

        var rendered: [String] = []
        for tab in SettingsTab.allCases {
            for width in widths {
                let content = SettingsPane(tab: tab) {
                    SettingsWindow.pane(for: tab, controller: controller)
                }
                // The band is transparent over the window, and an offscreen panel's own
                // background is not the window's — the surface has to be stated.
                .background(DS.Color.window)
                guard let png = render(content, width: width) else {
                    print("SETTINGS_SHEET_FAILED: \(tab.rawValue) at \(Int(width))pt did not render")
                    return false
                }
                let path = root.appendingPathComponent(fileName(tab, width))
                do {
                    try png.write(to: path)
                } catch {
                    print("SETTINGS_SHEET_FAILED: \(error.localizedDescription)")
                    return false
                }
                rendered.append(path.lastPathComponent)
            }
        }
        print("SETTINGS_SHEET_OK \(rendered.count) pane(s): \(root.path)")
        for name in rendered { print("  \(name)") }
        return true
    }

    /// One pane, laid out and drawn through a real hosting view. `ImageRenderer` is no use
    /// here and `--avatar-sheet`'s blank form is the reason: a native grouped `Form` draws
    /// nothing into an `ImageRenderer` pass, while a hosted view in an offscreen window
    /// lays out and `cacheDisplay` draws it. Never ordered on screen.
    private static func render(_ view: some View, width: CGFloat) -> Data? {
        let height = DS.Size.settingsWindowMinHeight * 2
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { panel.close() }

        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        // The pane's ink and material resolve against the appearance, and an offscreen
        // panel would otherwise draw the window's own light one — white heading on white.
        panel.appearance = NSApp.effectiveAppearance
        panel.contentView = hosting
        panel.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()

        guard let representation = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)
        else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: representation)
        return representation.representation(using: .png, properties: [:])
    }
}

import AppKit
import SwiftUI

/// `--meeting-console-preview [dir]` renders the two editable sections at the window's
/// actual content size. It uses a fresh meeting ID, so it never reads or changes a real
/// meeting, and an offscreen hosting view, so no screen recording or microphone grant is
/// needed. This is a visual diagnostic, not a self-test verdict.
@MainActor
enum MeetingConsolePreview {
    static func write(to directory: String) -> Bool {
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            print("MEETING_CONSOLE_PREVIEW_FAILED: \(error.localizedDescription)")
            return false
        }

        let meeting = Meeting(title: "Preview meeting", start: Date(), status: .recording)
        let session = MeetingSession(meeting: meeting, store: .isolated())
        for section in [MeetingConsoleSection.notes, .ask] {
            let view = MeetingConsoleSheet(session: session, initialSection: section, close: {})
                .background(DS.Color.window)
            guard let png = render(view) else {
                print("MEETING_CONSOLE_PREVIEW_FAILED: \(section.title) did not render")
                return false
            }
            do {
                try png.write(to: root.appendingPathComponent("meeting-console-\(section.id).png"))
            } catch {
                print("MEETING_CONSOLE_PREVIEW_FAILED: \(error.localizedDescription)")
                return false
            }
        }
        return true
    }

    private static func render(_ view: some View) -> Data? {
        let size = DS.Size.meetingConsoleWindow
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        defer { panel.close() }
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.appearance = NSApp.effectiveAppearance
        panel.contentView = hosting
        panel.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        guard let image = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            return nil
        }
        hosting.cacheDisplay(in: hosting.bounds, to: image)
        return image.representation(using: .png, properties: [:])
    }
}

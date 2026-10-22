import AppKit
import Darwin
import SwiftUI

/// `--meeting-console-preview [dir]` renders the four panel sections at the window's
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
        // Every section on the rail, so the visual review covers the whole panel rather
        // than the two editable halves. History reads the isolated store (empty) and
        // Actions reads no live review for a fresh id, so both render honest empty
        // states and no fixture touches an owner's meeting.
        for section in MeetingConsoleSection.allCases {
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

    /// Optional visual proof for generated reliability fixtures. This accepts the
    /// real views and never reads or writes an owner's meeting or preference store.
    static func writeReliabilitySheet(
        _ view: some View, named name: String, to directory: String, size: CGSize
    ) -> Bool {
        func blocked(_ stage: String, code: Int? = nil) -> Bool {
            print("MEETING_RELIABILITY_RENDER_BLOCKED stage=\(stage) error_code=\(code.map(String.init) ?? "none")")
            return false
        }
        guard SelfTest.isRunning, Settings.shared.usesHarnessPreferencesForTesting else { return blocked("harness") }
        guard name.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil else { return blocked("basename") }
        guard let root = physicalURL(URL(fileURLWithPath: directory, isDirectory: true)) else {
            return blocked("root-resolution")
        }
        let temporaryRoots = [FileManager.default.temporaryDirectory,
                              URL(fileURLWithPath: "/private/tmp", isDirectory: true)]
            .compactMap(physicalURL)
        guard temporaryRoots.contains(where: {
            root.pathComponents.count > $0.pathComponents.count
                && root.pathComponents.starts(with: $0.pathComponents)
        }) else { return blocked("temporary-boundary") }
        guard root.pathComponents.contains(where: { $0.hasPrefix("meeting-reliability-") }) else {
            return blocked("fixture-namespace")
        }
        let began = ContinuousClock.now
        var stage = "directory-create"
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let content = view.environment(\._accessibilityReduceMotion, true)
                .background(DS.Color.window)
            guard let png = render(content, size: size) else { return blocked("bitmap") }
            let output = root.appendingPathComponent(name + ".png")
            guard let resolvedOutput = physicalURL(output),
                  resolvedOutput.path.hasPrefix(root.path + "/") else { return blocked("output-boundary") }
            stage = "png-write"
            try png.write(to: output, options: .atomic)
            stage = "png-stat"
            let exists = ((try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.intValue ?? 0) > 0
            if exists {
                print("MEETING_RELIABILITY_RENDER name=\(name) seconds=\(String(format: "%.6f", ChunkedTranscriber.seconds(began.duration(to: .now)))) offscreen=true")
            }
            return exists ? true : blocked("empty-png")
        } catch { return blocked(stage, code: (error as NSError).code) }
    }

    /// Foundation resolves an existing `/private/tmp` URL to `/tmp`, but may leave
    /// a nonexistent descendant under `/private/tmp`. Resolve the existing ancestor
    /// physically first, then append the missing suffix so containment uses one form.
    private static func physicalURL(_ url: URL) -> URL? {
        var ancestor = url.standardizedFileURL
        var suffix: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path) {
            guard ancestor.path != "/" else { return nil }
            suffix.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        let path: String? = ancestor.withUnsafeFileSystemRepresentation { pointer in
            guard let pointer, let resolved = Darwin.realpath(pointer, nil) else { return nil }
            defer { Darwin.free(resolved) }
            return String(cString: resolved)
        }
        guard let path else { return nil }
        var result = URL(fileURLWithPath: path)
        for component in suffix.reversed() { result.appendPathComponent(component) }
        return result
    }

    private static func render(_ view: some View, size: CGSize = DS.Size.meetingConsoleWindow) -> Data? {
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

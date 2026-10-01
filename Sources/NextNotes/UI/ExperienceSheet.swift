import AppKit
import SwiftUI

/// Isolated layout diagnostic. Uses production view types and placeholder values, without
/// starting a worker, opening a permission request, recording audio, or reading a meeting.
/// The OK marker means images were written and owner stores stayed unchanged; it is not an
/// accessibility, real-journey, animation-performance, or first-visible-feedback verdict.
@MainActor
enum ExperienceSheet {
    static func write(to directory: String) -> Bool {
        guard SelfTest.isRunning else {
            SelfTest.diagnostic("EXPERIENCE_SHEET_FAILED: isolated self-test harness required")
            return false
        }
        let root = URL(fileURLWithPath: directory, isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .standardizedFileURL.resolvingSymlinksInPath()
        guard root.path != support.path, !root.path.hasPrefix(support.path + "/") else {
            SelfTest.diagnostic("EXPERIENCE_SHEET_FAILED: choose an output outside Application Support")
            return false
        }
        let before = SelfTestStoreGuard.take()
        let store = AgentActivityStore.shared
        store.resetForSelfTest()
        defer { store.resetForSelfTest() }
        let task = AgentTask(id: "experience-layout", objective: "Prepare for the design meeting", source: "selftest", status: .running)
        store.begin(task: task, title: task.objective)
        store.update(taskID: task.id, kind: .reading, title: "Reading the meeting notes")
        store.update(taskID: task.id, kind: .executing, title: "Preparing your follow-up", avatar: .writing)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var count = 0
            for dark in [false, true] {
                for reduced in [false, true] {
                    // 560pt is DS's actual detail floor in the 900x600 main window;
                    // 1000pt represents a larger detail area. These are content captures.
                    for width in [DS.Size.detailMin, CGFloat(1000)] {
                        for fixture in Fixture.allCases {
                            let name = "\(fixture.rawValue)-\(Int(width))-\(dark ? "dark" : "light")-\(reduced ? "reduced" : "standard").png"
                            let view = content(fixture, task: task)
                                .padding(DS.Space.l)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                .background(DS.Color.window)
                                .environment(\.colorScheme, dark ? .dark : .light)
                                .environment(\._accessibilityReduceMotion, reduced)
                                .environment(\._accessibilityReduceTransparency, reduced)
                            guard let data = render(view, width: width, dark: dark) else {
                                throw SheetError.render(fixture.rawValue)
                            }
                            try data.write(to: root.appendingPathComponent(name))
                            count += 1
                        }
                    }
                }
            }
            guard before == SelfTestStoreGuard.take() else {
                SelfTest.diagnostic("EXPERIENCE_SHEET_FAILED: owner stores changed")
                return false
            }
            SelfTest.diagnostic("EXPERIENCE_SHEET_OK: \(count) isolated layout images; \(root.path)")
            return true
        } catch {
            SelfTest.diagnostic("EXPERIENCE_SHEET_FAILED: \(error.localizedDescription)")
            return false
        }
    }

    private enum Fixture: String, CaseIterable {
        case working, reviewReady, reviewMissing, failed, dictationReady, dictationRecording
        case dictationFinishing, dictationFailed, transcript
    }

    private enum SheetError: LocalizedError {
        case render(String)
        var errorDescription: String? {
            switch self { case .render(let name): "Could not render \(name)." }
        }
    }

    @ViewBuilder
    private static func content(_ fixture: Fixture, task: AgentTask) -> some View {
        switch fixture {
        case .working:
            AgentWorkingCard(task: task, stop: {})
        case .reviewReady, .reviewMissing:
            ToolReviewCard(review: review(missing: fixture == .reviewMissing), isCompact: true,
                           approve: {}, dismiss: {})
        case .failed:
            FailureCard(summary: "I couldn’t finish this request.",
                        undo: "Review any changes before trying again.",
                        actions: [.init(id: "open", title: "Open what I made", run: {})])
        case .dictationReady:
            DictationStatusBand(state: .idle, isCapturingAudio: false, elapsed: 0, holdKey: "Option")
        case .dictationRecording:
            DictationStatusBand(state: .starting, isCapturingAudio: true, elapsed: 12, holdKey: "Option")
        case .dictationFinishing:
            DictationStatusBand(state: .finishing, isCapturingAudio: false, elapsed: 12, holdKey: "Option")
        case .dictationFailed:
            DictationStatusBand(state: .error("Your words are saved in History. Copy them there, then paste them into your app."),
                                isCapturingAudio: false, elapsed: 12, holdKey: "Option")
        case .transcript:
            TranscriptView(segments: [
                .init(start: 0, end: 4, text: "Let’s prepare the design review for tomorrow.", source: .mic),
                .init(start: 5, end: 10, text: "I’ll share the updated deck with the team before the meeting.", source: .system, speaker: "Maya"),
                .init(start: 11, end: 15, text: "Thanks. We should keep a note of the decisions and next steps.", source: .mic),
            ])
        }
    }

    private static func review(missing: Bool) -> ToolCallReview {
        ToolCallReview(id: missing ? "experience-missing" : "experience-ready", toolID: "send_email",
                       title: "Send the follow-up to Maya", trigger: .youSaid("Send Maya the notes after our meeting."),
                       fields: [
                        .init(name: "to", label: "Who it goes to", value: missing ? "" : "maya@example.org",
                              isRequired: true, kind: .email, provenance: missing ? .missing : .edited,
                              prompt: "Which address should I use?", problem: missing ? .missing : nil),
                        .init(name: "subject", label: "Subject", value: "Our design review",
                              isRequired: true, kind: .text, provenance: .edited, prompt: "What’s the subject?"),
                        .init(name: "body", label: "Message", value: "Hi Maya, here are the decisions and next steps from our design review. Please send the updated deck before tomorrow’s meeting. Thanks!",
                              isRequired: true, kind: .longText, provenance: .edited, prompt: "What should the message say?"),
                       ], risk: .send, previewField: "body")
    }

    /// Same hosting/cacheDisplay approach as SettingsSheet: native controls and List are
    /// absent from an ImageRenderer pass. Never orders a panel on screen or takes focus.
    private static func render(_ view: some View, width: CGFloat, dark: Bool) -> Data? {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: DS.Size.windowMin.height),
                            styleMask: [.titled], backing: .buffered, defer: false)
        defer { panel.close() }
        panel.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: DS.Size.windowMin.height)
        panel.contentView = hosting
        panel.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        guard let representation = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return nil }
        hosting.cacheDisplay(in: hosting.bounds, to: representation)
        return representation.representation(using: .png, properties: [:])
    }
}

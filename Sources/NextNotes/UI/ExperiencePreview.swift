import AppKit
import SwiftUI

/// Diagnostic-only interaction window. Requires the existing self-test harness.
/// It reproduces native shell/layout pressure with real ToolReviewCard controls; its
/// local draft/status values are example UI, not a second product task/conversation store.
@MainActor
enum ExperiencePreview {
    private static var retained: Controller?

    static func show() -> Bool {
        guard SelfTest.isRunning else {
            SelfTest.diagnostic("EXPERIENCE_PREVIEW_FAILED: isolated self-test harness required")
            return false
        }
        retained = Controller()
        retained?.show()
        SelfTest.diagnostic("EXPERIENCE_PREVIEW_OPEN: example controls only; no work will run")
        return true
    }

    private final class Controller: NSObject, NSWindowDelegate {
        private let before = SelfTestStoreGuard.take()
        private let window: NSWindow

        override init() {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: DS.Size.windowMin.width, height: DS.Size.windowMin.height),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false
            )
            super.init()
            window.title = "Next Notes — isolated interaction preview"
            window.contentMinSize = DS.Size.windowMin
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: Content())
            window.delegate = self
        }

        func show() {
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        func windowWillClose(_ notification: Notification) {
            ToolCallReviewStore.shared.remove(id: Content.readyID)
            ToolCallReviewStore.shared.remove(id: Content.missingID)
            ToolCallReviewStore.shared.remove(id: Content.calendarID)
            let changes = SelfTestStoreGuard.diff(before, SelfTestStoreGuard.take())
            if changes.isEmpty {
                SelfTest.diagnostic("EXPERIENCE_PREVIEW_CLOSED: owner stores unchanged; manual findings belong in the report")
            } else {
                for change in changes { SelfTest.diagnostic("EXPERIENCE_PREVIEW_WRONG: \(change)") }
                SelfTest.failed = true
                SelfTest.diagnostic("EXPERIENCE_PREVIEW_FAILED: owner stores changed")
            }
            ExperiencePreview.retained = nil
            NSApp.terminate(nil)
        }
    }

    private struct Content: View {
        static let readyID = "experience-preview-ready"
        static let missingID = "experience-preview-missing"
        static let calendarID = "experience-preview-calendar"

        private enum Scenario: String, CaseIterable, Identifiable {
            case ready = "Ready message"
            case missing = "Missing address"
            case calendar = "Calendar action"
            var id: String { rawValue }
        }
        @State private var scenario = Scenario.missing
        @State private var draft = ""
        @State private var status = "Example controls. No message or calendar event will be created."
        @State private var reducedMotion = false
        @State private var reducedTransparency = false
        @State private var dark = false

        private var review: ToolCallReview { Self.makeReview(scenario) }

        var body: some View {
            NavigationSplitView {
                List {
                    Section("Isolated preview") {
                        Label("Review example", systemImage: "bubble.left.and.bubble.right")
                        Text("Placeholder data only")
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.textSecondary)
                    }
                }
                .navigationSplitViewColumnWidth(min: DS.Size.sidebarMin, ideal: DS.Size.sidebarIdeal, max: DS.Size.sidebarMax)
            } detail: {
                VStack(spacing: DS.Space.s) {
                    controls
                    Divider()
                    ScrollView {
                        VStack(alignment: .leading, spacing: DS.Space.m) {
                            Text("Example conversation")
                                .font(DS.Font.title3)
                            Text("This fixture uses the actual review card. Open Read and edit, then Tell me instead to inspect keyboard order and height pressure. Resize the native window; the main minimum is 900 × 600.")
                                .font(DS.Font.callout)
                                .textSelection(.enabled)
                            Text(status)
                                .font(DS.Font.caption)
                                .accessibilityLabel(status)
                        }
                        .padding(DS.Space.page)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // Mirrors AgentView's existing safe-area placement, without AgentView's
                    // model prewarm or application data observers. This is a layout test.
                    .safeAreaInset(edge: .bottom) {
                        VStack(spacing: DS.Space.s) {
                            ToolReviewCard(
                                review: review, isCompact: true,
                                approve: { status = "Example primary button selected. Nothing was sent or created." },
                                dismiss: { status = "Example Dismiss button selected. Nothing was sent or created." },
                                alwaysAllow: { status = "Example preference button selected. No permission was saved." }
                            )
                            .id(review.id)
                            Text("Example model caption")
                                .font(DS.Font.caption)
                                .foregroundStyle(DS.Color.textSecondary)
                            HStack(alignment: .bottom, spacing: DS.Space.m) {
                                TextField("Example draft; typing here sends nothing", text: $draft, axis: .vertical)
                                    .textFieldStyle(.plain)
                                    .lineLimit(1...5)
                                Button("Example Send", systemImage: "arrow.up") {
                                    status = "Example composer button selected. Nothing was sent."
                                }
                                .labelStyle(.iconOnly)
                                .accessibilityLabel("Example Send")
                                .buttonStyle(.borderedProminent)
                                .frame(width: DS.Size.composerControl.width, height: DS.Size.composerControl.height)
                            }
                            Text("Isolated layout fixture. No account, model, microphone or action is used.")
                                .font(DS.Font.caption)
                                .foregroundStyle(DS.Color.textSecondary)
                        }
                        .padding(.horizontal, DS.Space.page)
                        .padding(.top, DS.Space.s)
                        .background(DS.Color.window)
                    }
                }
                .frame(minWidth: DS.Size.detailMin)
                .navigationTitle("Interaction preview")
            }
            .navigationSplitViewStyle(.balanced)
            .frame(minWidth: DS.Size.windowMin.width, minHeight: DS.Size.windowMin.height)
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\._accessibilityReduceMotion, reducedMotion)
            .environment(\._accessibilityReduceTransparency, reducedTransparency)
            .onAppear { prepare() }
            .onChange(of: scenario) { _, _ in prepare() }
        }

        private var controls: some View {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Picker("Example", selection: $scenario) {
                    ForEach(Scenario.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu)
                HStack(spacing: DS.Space.m) {
                    Toggle("Dark", isOn: $dark)
                    Toggle("Reduce Motion", isOn: $reducedMotion)
                    Toggle("Reduce Transparency", isOn: $reducedTransparency)
                }
                Button("Reset example") { prepare() }
                    .buttonStyle(.bordered)
            }
            .padding(DS.Space.m)
        }

        private func prepare() {
            let value = review
            ToolCallReviewStore.shared.remove(id: value.id)
            let request = PermissionRequest(id: value.id, toolID: value.toolID, title: value.title,
                                            detail: "Isolated layout preview", risk: value.risk,
                                            arguments: value.arguments, trigger: value.trigger)
            // Registers editable review data only, through its existing seam. Never
            // calls PermissionGate, submits a worker, stores a grant or invokes a tool.
            ToolCallReviewStore.shared.begin(request, restoredReview: value)
            status = "Example reset. No message or event will be created."
        }

        private static func makeReview(_ scenario: Scenario) -> ToolCallReview {
            let calendar = scenario == .calendar
            let missing = scenario == .missing
            let fields: [ToolCallField] = calendar ? [
                .init(name: "title", label: "Event", value: "Design review with the team",
                      isRequired: true, kind: .text, provenance: .edited, prompt: "What is the event?"),
                .init(name: "start", label: "When", value: "2026-10-02T10:00:00-04:00",
                      isRequired: true, kind: .dateTime, provenance: .edited, prompt: "When should it start?"),
            ] : [
                .init(name: "to", label: "Who it goes to", value: missing ? "" : "maya@example.org",
                      isRequired: true, kind: .email, provenance: missing ? .missing : .edited,
                      prompt: "Which address should I use?", problem: missing ? .missing : nil),
                .init(name: "subject", label: "Subject", value: "Our design review",
                      isRequired: true, kind: .text, provenance: .edited, prompt: "What’s the subject?"),
                .init(name: "body", label: "Message", value: "Hi Maya, here are the decisions and next steps from our review. Please share the updated deck before tomorrow’s meeting. Thanks!",
                      isRequired: true, kind: .longText, provenance: .edited, prompt: "What should the message say?"),
            ]
            return ToolCallReview(id: calendar ? calendarID : missing ? missingID : readyID,
                                  toolID: calendar ? "create_event" : "send_email",
                                  title: calendar ? "Add the design review to your calendar" : "Send the follow-up to Maya",
                                  trigger: .youSaid(calendar ? "Add a design review to my calendar." : "Send Maya the notes."),
                                  fields: fields, risk: calendar ? .write : .send,
                                  previewField: calendar ? nil : "body")
        }
    }
}

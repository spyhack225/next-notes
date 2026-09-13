import AppKit
import SwiftUI

/// Settings, as a system `TabView` of grouped forms.
///
/// The system draws the sidebar (`.sidebarAdaptable`). A hand-rolled `HStack` + `List`
/// looked like the main window; `NavigationSplitView` collapsed to an unlabeled icon
/// and placeholder bars; a toolbar `TabView` in a `settingsWidth` window put
/// Integrations, Models and Permissions behind a chevron that did not list them.
///
/// The window's minimum size is sidebar plus form. Without that, macOS 26 opens
/// Settings as a compact inspector — a Dictation-titled strip of names and no pane.
struct SettingsWindow: View {
    @Bindable var controller: DictationController

    @State private var models = LocalModelStore.shared
    /// Shared, so that a screen which found the problem can open the pane that fixes it.
    @State private var navigation = NavigationState.shared

    var body: some View {
        TabView(selection: $navigation.selectedSettingsTab) {
            ForEach(SettingsTab.allCases) { tab in
                Tab(tab.title, systemImage: tab.systemImage, value: tab) {
                    content(for: tab)
                        .frame(minWidth: DS.Size.settingsWidth)
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .frame(minWidth: DS.Size.settingsWindowMinWidth)
        .frame(minHeight: DS.Size.settingsWindowMinHeight)
        .background(SettingsWindowFrame(minSize: SettingsTab.windowMinSize))
        .onAppear { models.refresh() }
    }

    /// Every tab gets the same band above it, so the ten of them read as one book with
    /// chapters rather than as unrelated forms that happen to share a window.
    private func content(for tab: SettingsTab) -> some View {
        SettingsPane(tab: tab) { pane(for: tab) }
    }

    @ViewBuilder
    private func pane(for tab: SettingsTab) -> some View {
        switch tab {
        case .general: GeneralSettingsTab(controller: controller)
        case .dictation: DictationSettingsTab()
        case .formatting: FormattingSettingsTab()
        case .meetings: MeetingsSettingsTab()
        case .calendar: CalendarSettingsTab()
        case .workspace: WorkspaceSettingsTab()
        case .agent: AgentSettingsTab()
        case .integrations: IntegrationsSettingsTab()
        case .models: ModelsSettingsTab()
        case .permissions: PermissionsSettingsTab()
        }
    }
}

/// The panes, in the order they appear in the system sidebar.
///
/// Adding one is a case here plus a `<Name>SettingsTab.swift` beside this file; the
/// `TabView` is driven from `allCases`, so nothing else has to change.
enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
    case general
    case dictation
    case formatting
    case meetings
    case calendar
    case workspace
    case agent
    case integrations
    case models
    case permissions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .dictation: "Dictation"
        case .formatting: "Formatting"
        case .meetings: "Meetings"
        case .calendar: "Calendar"
        case .workspace: "Workspace"
        case .agent: "Agent"
        case .integrations: "Integrations"
        case .models: "Models"
        case .permissions: "Permissions"
        }
    }

    /// The question the pane answers, which is a different thing from its name. The
    /// sidebar already says "Models"; the band says what you came here to settle.
    var heading: String {
        switch self {
        case .general: "The keys you hold"
        case .dictation: "Which engine hears you"
        case .formatting: "How the text lands in each app"
        case .meetings: "When a meeting records itself"
        case .calendar: "Where meetings are read from"
        case .workspace: "What Next Notes may do in your account"
        case .agent: "How you wake it and what it may do"
        case .integrations: "Other apps it can reach"
        case .models: "What lives on this Mac"
        case .permissions: "What macOS has agreed to"
        }
    }

    /// The mark for the pane's subject, from the vocabulary in `AGENTS.md`. Six distinct
    /// states over the panes, and none of them borrowed to fill a hole: Permissions has
    /// none because no state in the vocabulary means "a grant", and inventing one — or
    /// bending `connecting`, which means Google — would cost the table its meaning.
    ///
    /// The rest are read straight off it. `breathing` for General because a push-to-talk
    /// app between holds is exactly present-and-idle; `listening` for Dictation, one voice
    /// being heard; `composing` for Formatting, which is the shape the prose comes out in;
    /// `weaving` for Meetings, two tracks braided into one; `searching` for Calendar, which
    /// reads a diary it did not write to find what is worth recording; `connecting` for
    /// Workspace; `shaping` for Models, fetched and assembled out of nothing.
    var orb: OrbGeometry.State? {
        switch self {
        case .general: .breathing
        case .dictation: .listening
        case .formatting: .composing
        case .meetings: .weaving
        case .calendar: .searching
        case .workspace: .connecting
        case .agent: .searching
        case .integrations: .connecting
        case .models: .shaping
        case .permissions: nil
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .dictation: "waveform"
        case .formatting: "text.alignleft"
        case .meetings: SidebarSection.meetings.systemImage
        case .calendar: "calendar"
        case .workspace: "point.3.connected.trianglepath.dotted"
        case .agent: "ear"
        case .integrations: "link"
        case .models: "shippingbox"
        case .permissions: "lock.shield"
        }
    }

    /// Panes a toolbar overflow hid, and panes a compact Settings frame cropped off.
    /// `--selftest-settings` fails if any drop out of `allCases`.
    static let requiredPanes: [SettingsTab] = [
        .general, .dictation, .formatting, .meetings, .calendar, .workspace,
        .agent, .integrations, .models, .permissions,
    ]

    static var windowMinSize: NSSize {
        NSSize(
            width: DS.Size.settingsWindowMinWidth,
            height: DS.Size.settingsWindowMinHeight
        )
    }

    /// What `--selftest-settings` answers: every pane is listed, Formatting is one of
    /// them, every heading still contains U+0020, letter-spacing is not collapsing
    /// words, each pane's real form can be built, and a captured output profile
    /// actually reaches the cleanup prompt — a `NavigationSplitView` inside `Settings`
    /// drew ten gray bars instead, and an unused `OutputProfileStore` wrote
    /// `formatting.txt` that dictation never read.
    @MainActor
    static func catalogFailures() -> [String] {
        var failures: [String] = []

        for pane in requiredPanes where !allCases.contains(pane) {
            failures.append("\(pane.rawValue) is missing from allCases")
        }

        if !allCases.contains(.formatting) {
            failures.append("formatting is missing from allCases")
        }
        if allCases.first(where: { $0 == .formatting })?.title != "Formatting" {
            failures.append("formatting sidebar title is not Formatting")
        }

        if allCases.map(\.title).contains(where: \.isEmpty) {
            failures.append("a sidebar row has an empty title")
        }

        for tab in allCases {
            if spaceCount(in: tab.heading) == 0 {
                failures.append("\(tab.rawValue) heading has no spaces: \(tab.heading.debugDescription)")
            }
            if tab.title.contains("  ") || tab.heading.contains("  ") {
                failures.append("\(tab.rawValue) has a doubled space")
            }
        }

        if spaceCount(in: AgentView.headingTitle) == 0 {
            failures.append("Agent heading has no spaces: \(AgentView.headingTitle.debugDescription)")
        }
        if DS.Font.eyebrowTracking < 0 {
            failures.append("eyebrow tracking \(DS.Font.eyebrowTracking) collapses letters")
        }
        if DS.Font.wordTracking != 0 {
            failures.append("word tracking \(DS.Font.wordTracking) is not the system default")
        }

        if DS.Size.settingsWindowMinWidth < DS.Size.settingsSidebarWidth + DS.Size.settingsWidth {
            failures.append(
                "window min width \(Int(DS.Size.settingsWindowMinWidth))pt is narrower than "
                    + "sidebar \(Int(DS.Size.settingsSidebarWidth))pt plus form "
                    + "\(Int(DS.Size.settingsWidth))pt"
            )
        }

        failures.append(contentsOf: OutputProfileStore.captureFailures())

        return failures
    }

    /// Hosts `SettingsWindow` on every pane. Fails if a body cannot be built — the
    /// skeleton-bar window was a body that never produced the form — or if the host
    /// is only as wide as the sidebar, which is the cropped Dictation strip.
    @MainActor
    static func renderFailures(controller: DictationController) -> [String] {
        var failures: [String] = []
        let navigation = NavigationState.shared
        let previous = navigation.selectedSettingsTab
        let size = windowMinSize

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { panel.close() }

        for tab in allCases {
            navigation.selectedSettingsTab = tab
            let hosting = NSHostingView(rootView: SettingsWindow(controller: controller))
            hosting.frame = NSRect(origin: .zero, size: size)
            panel.contentView = hosting
            panel.layoutIfNeeded()
            hosting.layoutSubtreeIfNeeded()
            if hosting.bounds.width + 0.5 < DS.Size.settingsWindowMinWidth {
                failures.append("\(tab.rawValue) hosted narrower than sidebar plus form")
            }
            if hosting.bounds.width + 0.5 < DS.Size.settingsWidth {
                failures.append("\(tab.rawValue) hosted narrower than the form")
            }
            if hosting.bounds.isEmpty {
                failures.append("\(tab.rawValue) hosted in an empty frame")
            }
        }

        navigation.selectedSettingsTab = previous
        return failures
    }

    static func spaceCount(in string: String) -> Int {
        string.unicodeScalars.filter { $0 == " " }.count
    }
}

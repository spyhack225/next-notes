import SwiftUI

/// Settings, as a standard macOS tabbed preferences window.
///
/// One `Form { }.formStyle(.grouped)` per tab, each in its own file. The window is a fixed
/// width and grows to whatever the tallest tab needs — the system convention, and the
/// reason nothing here sets a height.
struct SettingsWindow: View {
    @Bindable var controller: DictationController

    @State private var models = LocalModelStore.shared
    /// Shared, so that a screen which found the problem can open the tab that fixes it.
    @State private var navigation = NavigationState.shared

    var body: some View {
        TabView(selection: $navigation.selectedSettingsTab) {
            ForEach(SettingsTab.allCases) { tab in
                content(for: tab)
                    .tabItem { Label(tab.title, systemImage: tab.systemImage) }
                    .tag(tab)
            }
        }
        .frame(width: DS.Size.settingsWidth)
        .frame(minHeight: DS.Size.settingsMinHeight)
        .onAppear { models.refresh() }
    }

    /// Every tab gets the same band above it, so the eight of them read as one book with
    /// eight chapters rather than as eight unrelated panes that happen to share a window.
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
        case .models: ModelsSettingsTab()
        case .permissions: PermissionsSettingsTab()
        }
    }
}

/// The tabs, in the order they appear.
///
/// Adding one is a case here plus a `<Name>SettingsTab.swift` beside this file; the
/// `TabView` is driven from `allCases`, so nothing else has to change.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case dictation
    case formatting
    case meetings
    case calendar
    case workspace
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
        case .models: "Models"
        case .permissions: "Permissions"
        }
    }

    /// The question the tab answers, which is a different thing from its name. The tab bar
    /// already says "Models"; the band says what you came here to settle.
    var heading: String {
        switch self {
        case .general: "The keys you hold"
        case .dictation: "Which engine hears you"
        case .formatting: "How the text lands in each app"
        case .meetings: "When a meeting records itself"
        case .calendar: "Where meetings are read from"
        case .workspace: "What Speechify may do in your account"
        case .models: "What lives on this Mac"
        case .permissions: "What macOS has agreed to"
        }
    }

    /// The mark for the tab's subject, from the vocabulary in `AGENTS.md`. Six distinct
    /// states over eight tabs, and none of them borrowed to fill a hole: Permissions has
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
        case .models: "shippingbox"
        case .permissions: "lock.shield"
        }
    }
}

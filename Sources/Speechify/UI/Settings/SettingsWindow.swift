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

    @ViewBuilder
    private func content(for tab: SettingsTab) -> some View {
        switch tab {
        case .general: GeneralSettingsTab(controller: controller)
        case .dictation: DictationSettingsTab()
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
        case .meetings: "Meetings"
        case .calendar: "Calendar"
        case .workspace: "Workspace"
        case .models: "Models"
        case .permissions: "Permissions"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .dictation: "waveform"
        case .meetings: SidebarSection.meetings.systemImage
        case .calendar: "calendar"
        case .workspace: "point.3.connected.trianglepath.dotted"
        case .models: "shippingbox"
        case .permissions: "lock.shield"
        }
    }
}

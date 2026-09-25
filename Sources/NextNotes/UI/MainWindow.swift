import SwiftUI

/// The main window: a standard macOS sidebar shell.
///
/// Every section is a plain detail view that brings its own toolbar and title, so the
/// window chrome is the system's rather than something drawn here. The selection lives in
/// `NavigationState` instead of local state because the URL handler and the app delegate
/// need to steer it from outside SwiftUI's environment.
struct MainWindow: View {
    @Bindable var controller: DictationController

    @State private var navigation = NavigationState.shared
    @State private var settings = Settings.shared
    @State private var visionConsent = VisionConsentCoordinator.shared

    var body: some View {
        NavigationSplitView {
            Sidebar(controller: controller, selection: $navigation.selectedSection)
        } detail: {
            detail
                .frame(minWidth: DS.Size.detailMin)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(
            minWidth: DS.Size.windowMin.width,
            minHeight: DS.Size.windowMin.height
        )
        // P1-2: the per-run vision consent sheet. The hook is only installed while this
        // window can show it; with the window closed, `VisionConsentGate` stays nil and
        // a screenshot cannot leave the Mac.
        .sheet(item: $visionConsent.pending) { pending in
            VisionConsentSheet(
                request: pending.request,
                approve: { visionConsent.respond(true) },
                deny: { visionConsent.respond(false) }
            )
        }
        .task {
            VisionConsentCoordinator.shared.install()
        }
        .onDisappear {
            VisionConsentCoordinator.shared.uninstall()
        }
        // First run, in its own window rather than a sheet on this one. It can only be
        // raised once there is an app to attach system prompts to, which is why it is here
        // and not in `applicationDidFinishLaunching`. `OnboardingPresenter` decides whether
        // it appears at all — including the rule that it never appears under a self-test,
        // where a window on screen would stop `NSApp.terminate` from completing.
        .task {
            OnboardingPresenter.presentIfNeeded(controller: controller)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch navigation.selectedSection {
        case .agent:
            AgentView()
        case .meetings:
            MeetingsView()
        case .dictation:
            DictationView(controller: controller)
        // The Agent's panes that are places rather than conversation modes. They used to
        // live in the Agent's switcher; each carries its own title here because they are no
        // longer drawn inside a view that sets one.
        case .graph:
            KnowledgeGraphPane().navigationTitle(SidebarSection.graph.title)
        case .portrait:
            PortraitView().navigationTitle(SidebarSection.portrait.title)
        case .ideas:
            IdeasView().navigationTitle(SidebarSection.ideas.title)
        case .goals:
            GoalsView().navigationTitle(SidebarSection.goals.title)
        case .reminders:
            RoutinesView().navigationTitle(SidebarSection.reminders.title)
        case .skills:
            SkillsView().navigationTitle(SidebarSection.skills.title)
        case .search:
            KnowledgeSearchView()
        case .dictionary:
            DictionaryPanel()
        case .comparison, .settings:
            // Settings, in this window. The retired Comparison section steers here too —
            // `NavigationState` opens the pane that replaced it — and the ⌘, scene keeps
            // its own copy of this same view.
            SettingsWindow(controller: controller)
        }
    }
}

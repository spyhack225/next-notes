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
        case .dictation:
            DictationView(controller: controller)
        case .meetings:
            MeetingsView()
        case .search:
            KnowledgeSearchView()
        case .agent:
            AgentView()
        case .dictionary:
            DictionaryPanel()
        case .comparison:
            ComparisonView(controller: controller)
        }
    }
}

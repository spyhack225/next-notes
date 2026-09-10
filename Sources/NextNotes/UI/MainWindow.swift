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
    @State private var isShowingOnboarding = false

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
        .sheet(isPresented: $isShowingOnboarding) {
            OnboardingSheet {
                settings.hasCompletedOnboarding = true
                isShowingOnboarding = false
            }
        }
        // The checklist asks for microphone and Accessibility, and both prompts are modal
        // to the app — so it can only run once there is a window to attach them to. Never
        // during a self-test: a sheet on screen stops `NSApp.terminate` from completing.
        .task {
            isShowingOnboarding = !settings.hasCompletedOnboarding && !SelfTest.isRunning
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch navigation.selectedSection {
        case .dictation:
            DictationView(controller: controller)
        case .meetings:
            MeetingsView()
        case .dictionary:
            DictionaryPanel()
        case .comparison:
            ComparisonView(controller: controller)
        }
    }
}

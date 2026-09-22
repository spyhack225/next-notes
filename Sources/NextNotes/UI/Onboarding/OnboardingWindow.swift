import AppKit
import SwiftUI

/// First run, as one window: the seven screens, the chevrons, and the dots.
///
/// The screens cross-fade rather than slide. A slide implies a place you are moving through;
/// a fade implies one window changing its mind about what it is asking, which is what this
/// is.
struct OnboardingFlowView: View {
    let controller: DictationController
    /// Closes the window. Progress is already on disk by then — every transition writes —
    /// so this is genuinely "come back later", not "start again".
    let close: () -> Void

    @State private var model = OnboardingModel.shared
    @State private var identity = AgentIdentityStore.shared
    /// How far the user has actually been. The forward chevron only goes where they have
    /// already been, so it is navigation rather than a second, quieter Continue that could
    /// carry somebody past a screen they never saw.
    @State private var furthest = 0

    var body: some View {
        ZStack(alignment: .top) {
            DS.Color.window.ignoresSafeArea()

            VStack(spacing: DS.Space.xl) {
                Spacer(minLength: 0)

                step
                    .id(model.step)
                    .transition(.opacity)

                OnboardingDots(index: model.flow.index, total: model.flow.total)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Space.xl)
            .padding(.vertical, DS.Space.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                Spacer()
                OnboardingChevrons(
                    canGoBack: model.canGoBack,
                    canGoForward: model.flow.index < furthest,
                    back: { move { model.back() } },
                    forward: { move { model.advance() } }
                )
            }
            .padding(DS.Space.l)
        }
        // The landing page's mark, at watermark strength, behind everything. One slow
        // breathing ring: the app is present and idle, which is exactly true here.
        .orbBackdrop(.breathing, opacity: DS.Opacity.orbWatermark)
        .animation(DS.Motion.reveal, value: model.step)
        .onAppear { furthest = max(furthest, model.flow.index) }
        // Escape closes the window. It never loses anything, because there is nothing held
        // only in memory to lose.
        .onExitCommand(perform: close)
        .frame(
            minWidth: DS.Onboarding.window.width,
            minHeight: DS.Onboarding.window.height
        )
    }

    @ViewBuilder
    private var step: some View {
        switch model.step {
        case .welcome:
            OnboardingWelcomeStep(onContinue: { move { model.advance() } })
        case .dictation:
            OnboardingDictationStep(controller: controller, onContinue: { move { model.advance() } })
        case .shortcut:
            OnboardingShortcutStep(controller: controller, onContinue: { move { model.advance() } })
        case .meetings:
            OnboardingMeetingsStep(
                onContinue: { move { model.advance() } },
                onSkip: { move { model.skip() } }
            )
        case .files:
            OnboardingFilesStep(
                onContinue: { move { model.advance() } },
                onSkip: { move { model.skip() } }
            )
        case .brain:
            OnboardingBrainStep(onContinue: { move { model.advance() } })
        case .allSet:
            OnboardingAllSetStep(
                assistantName: identity.name,
                controller: controller,
                model: model,
                onDone: finish
            )
        }
    }

    private func move(_ transition: () -> Void) {
        transition()
        furthest = max(furthest, model.flow.index)
    }

    private func finish() {
        model.finish()
        close()
    }
}

/// The window first run lives in.
///
/// Its own window rather than a sheet on the main one. Two reasons, both learned from the
/// old checklist: a sheet is modal to a window that the user may never have opened, and a
/// sheet cannot survive the main window being closed — which is exactly what happens when
/// somebody crosses to System Settings and comes back by clicking the Dock icon.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(controller: DictationController) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = OnboardingFlowView(controller: controller) { [weak self] in
            self?.close()
        }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: DS.Onboarding.window),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // AppKit releases a code-created window itself when it closes, on top of ARC's own
        // release of the strong reference held here — and this window is closed on every
        // exit: Escape, Done, and the title-bar button. Matches
        // `ComputerSelfTestHarness`, the only other hand-built window in the app.
        window.isReleasedWhenClosed = false
        window.title = "Welcome to Next Notes"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.contentView = NSHostingView(rootView: view)
        window.delegate = self
        window.center()
        // Never restored into a half-size frame from a previous version of this window.
        window.setContentSize(DS.Onboarding.window)
        self.window = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
        window = nil
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

/// Who decides whether first run appears, and puts it on screen.
@MainActor
enum OnboardingPresenter {
    /// Held for the life of the process: AppKit will not keep a window controller alive for
    /// us, and a released one takes its window with it mid-setup.
    private static let windows = OnboardingWindowController()

    /// Called once the main window exists. Shows setup only on a Mac that has not finished
    /// it, and never during a self-test — `OnboardingPolicy` owns that rule so it can be
    /// tested without a screen.
    static func presentIfNeeded(controller: DictationController) {
        guard OnboardingPolicy.shouldPresent(
            hasCompleted: OnboardingModel.shared.isComplete,
            isSelfTest: SelfTest.isRunning
        ) else { return }
        windows.show(controller: controller)
    }

    /// Settings → General → "Run setup again". Clears the flow first, so this is a first run
    /// rather than a replay of a finished one.
    static func restart(controller: DictationController) {
        OnboardingModel.shared.restart()
        windows.show(controller: controller)
    }
}

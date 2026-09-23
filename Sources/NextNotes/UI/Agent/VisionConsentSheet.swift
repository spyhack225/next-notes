import AppKit
import SwiftUI

/// P1-2's per-run vision consent, wired to a sheet that shows the exact bytes.
///
/// `VisionConsentGate.hook` is nil by default and nil denies, so a screenshot can only
/// leave the Mac when this coordinator has a surface to put the thumbnail on. It is
/// installed by `MainWindow` and uninstalled when that window goes away: with no window
/// there is nowhere to show the question, and the fail-closed answer is the correct one.
///
/// The answer is also recorded in the run's step list — `VisionStepLine.sentScreenshot`
/// — so the Activity screen says "sent 1 screenshot" beside everything else the run did.
@MainActor
@Observable
final class VisionConsentCoordinator {
    static let shared = VisionConsentCoordinator()

    struct Pending: Identifiable {
        let id = UUID()
        let request: VisionConsentRequest
    }

    var pending: Pending?

    @ObservationIgnored private var continuation: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private var installed = false

    private init() {}

    /// Called from the main window's task. Never installs under a self-test: a sheet
    /// would keep `NSApp.terminate` from completing.
    func install() {
        guard !installed, !SelfTest.isRunning else { return }
        installed = true
        VisionConsentGate.hook = { request in
            await VisionConsentCoordinator.shared.present(request)
        }
    }

    /// The window went away. A question nobody can see must not hold a model call open.
    func uninstall() {
        guard installed else { return }
        installed = false
        VisionConsentGate.hook = nil
        cancelPending()
    }

    /// Shows the thumbnail and waits for a person. One question at a time; anything
    /// arriving while the sheet is up is denied rather than queued.
    func present(_ request: VisionConsentRequest) async -> Bool {
        guard pending == nil else { return false }
        // A blocking question behind another app's window is a hang dressed as a prompt.
        // The sheet lives on the main window, so the main window is raised first.
        AppDelegate.showMainWindow()
        let timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled else { return }
            self?.respond(false)
        }
        let answer = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            pending = Pending(request: request)
            self.continuation = continuation
        }
        timeout.cancel()
        return answer
    }

    func respond(_ approved: Bool) {
        guard let continuation else {
            pending = nil
            return
        }
        self.continuation = nil
        pending = nil
        continuation.resume(returning: approved)
        if approved {
            // The yes is what puts the picture in the model call; the step line says so
            // in the run's own list.
            AgentActivityStore.shared.noteScreenshotSent()
        }
    }

    func cancelPending() {
        guard continuation != nil || pending != nil else { return }
        respond(false)
    }
}

/// The sheet: the exact picture, the exact sentence, and two buttons.
struct VisionConsentSheet: View {
    let request: VisionConsentRequest
    let approve: () -> Void
    let deny: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text("Send this picture?")
                .font(DS.Font.title3)
            if let image = NSImage(data: request.thumbnail) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: DS.Size.messagePreviewHeight * 2,
                           maxHeight: DS.Size.messagePreviewHeight * 2)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.glassSmall))
                    .accessibilityLabel("The exact picture that would be sent")
            }
            Text("This exact picture of your screen goes to the model for this one step. "
                 + "It is not saved, and it is never sent again without asking.")
                .font(DS.Font.callout)
                .fixedSize(horizontal: false, vertical: true)
            if let reason = request.reason, !reason.isEmpty {
                Text("Why: \(reason)")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Your Activity list will show: \(VisionStepLine.sentScreenshot(1))")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
            HStack {
                Spacer()
                Button("Don’t send", role: .cancel, action: deny)
                    .keyboardShortcut(.cancelAction)
                Button("Send it", action: approve)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DS.Space.page)
        .frame(width: 420)
    }
}

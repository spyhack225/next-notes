import SwiftUI

/// Every grant Next Notes can ask for, with the one button that gets it.
///
/// Shown as a sheet on first launch and again in Settings, because TCC ties grants to the
/// code signature: a reinstalled or re-signed build loses them, and the app has to be able
/// to say which one is missing rather than simply not working.
struct PermissionsChecklist: View {
    @Environment(\.openSettings) private var openSettings
    @State private var agent = AgentService.shared
    @State private var hasAccessibility = false
    @State private var hasMicrophone = false
    @State private var hasCalendar = false
    @State private var hasNotifications = false
    @State private var isGrantingAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            PermissionRow(
                title: "Microphone",
                detail: "Hears you dictate.",
                systemImage: "mic",
                isGranted: hasMicrophone,
                actionTitle: "Grant…"
            ) {
                Task {
                    // `requestMicrophone` only prompts the first time; afterwards the
                    // Settings pane is the only way to change the answer.
                    let granted = await Permissions.requestMicrophone()
                    if !granted { Permissions.openMicrophoneSettings() }
                    refresh()
                }
            }

            PermissionRow(
                title: "Accessibility",
                detail: "Arms the push-to-talk key and types the result.",
                systemImage: "keyboard",
                isGranted: hasAccessibility,
                actionTitle: "Grant…"
            ) {
                Permissions.promptForAccessibility()
                Permissions.openAccessibilitySettings()
            }

            PermissionRow(
                title: "System audio",
                detail: "Hears the other side of a meeting. Without it a recording is only "
                    + "your half, in silence.",
                systemImage: "speaker.wave.2",
                // `nil`, not false. This grant has no query API — macOS decides it on the
                // first tap — so claiming either answer would be inventing one. The row says
                // "ask", and `--selftest-systemaudio` is where a real answer comes from.
                isGranted: nil,
                actionTitle: "Ask…"
            ) {
                // Raises the prompt by opening a tap, then shows the pane, because a grant
                // already decided will not prompt again and the pane is the only way back.
                Permissions.requestSystemAudio()
                Permissions.openSystemAudioSettings()
            }

            PermissionRow(
                title: "Calendar",
                detail: "Finds the meetings worth recording.",
                systemImage: "calendar",
                isGranted: hasCalendar,
                actionTitle: "Grant…"
            ) {
                Task {
                    let granted = await Permissions.requestCalendar()
                    if !granted { Permissions.openCalendarSettings() }
                    refresh()
                }
            }

            // Not a macOS grant at all, and the only row that leads outside Next Notes: the
            // Workspace CLI is Google's own tool, signed in through a Terminal window. It is
            // here because the checklist is where a user finds out what is not yet set up,
            // and "the agent proposes nothing" is otherwise indistinguishable from "there
            // was nothing to propose".
            PermissionRow(
                title: "Google Workspace",
                detail: "Lets a finished meeting offer to write the Doc and send the email "
                    + "it asked for. Optional.",
                systemImage: "point.3.connected.trianglepath.dotted",
                isGranted: agent.authState.isSignedIn,
                actionTitle: workspaceActionTitle,
                // The only row whose answer is not a bit the kernel already knows: it is a
                // `gws` process being spawned and asked. `connecting` is the orb for two
                // parties being wired together, which is the whole of what this row is.
                busy: agent.isProbing ? .connecting : nil
            ) {
                switch agent.authState {
                case .notInstalled, .failed: WorkspaceInstaller.install()
                case .needsOAuthClient:
                    // Deliberately not `setUpWithGcloud()`. Getting a client has two routes
                    // — a 700 MB SDK install, or importing a JSON already downloaded — and
                    // committing a user to the heavy one from a checklist that offers a
                    // single button is a choice they never got to make. The Workspace tab
                    // puts both in front of them.
                    NavigationState.shared.selectedSettingsTab = .workspace
                    openSettings()
                case .signedOut, .signedIn: WorkspaceInstaller.signIn()
                }
                // The step just launched happens in Terminal and takes minutes; the answer
                // is re-read when the user comes back to this window, not now.
                Task { await agent.refreshStatus() }
            }

            // Last, because everything above it is a capability and this one is only a way
            // of being told. Next Notes records the meeting either way; without this it just
            // does it without saying so, and the notes land silently.
            PermissionRow(
                title: "Notifications",
                detail: "Says a meeting is about to record, and that its notes are ready.",
                systemImage: "bell",
                isGranted: hasNotifications,
                actionTitle: "Allow\u{2026}"
            ) {
                Task {
                    let granted = await Notifications.shared.requestAuthorization()
                    // The prompt only ever appears once per install. After that the answer
                    // lives in System Settings, so a second press has to go there.
                    if !granted { Permissions.openNotificationSettings() }
                    refresh()
                }
            }

            Divider()

            // Five separate prompts, in a row, without having to find five buttons.
            //
            // Sequential rather than concurrent, and deliberately so: each of these puts a
            // system dialog on screen, and firing them together stacks modal alerts over one
            // another in an order nobody chose. Each `await` returns when that dialog is
            // answered, so the next one appears on a clear screen.
            //
            // Only the rows the OS can actually prompt for. Accessibility has no programmatic
            // request and Workspace is not a TCC grant at all, so both stay one-at-a-time
            // above rather than pretending to be part of a sweep.
            HStack {
                Text("Next Notes asks for each of these separately. This walks through them.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if isGrantingAll {
                    // `breathing` — present and idle, waiting on purpose. It is the honest
                    // state: the sweep is not computing anything, it is standing still in
                    // front of a system dialog until somebody answers it.
                    ThinkingOrb(state: .breathing, label: "Waiting for an answer")
                }
                Button(isGrantingAll ? "Asking…" : "Grant All…") { grantAll() }
                    .disabled(isGrantingAll || hasEveryPromptableGrant)
                    .help(hasEveryPromptableGrant
                          ? "Everything macOS can prompt for is already granted"
                          : "Ask for the microphone, system audio, calendar and notifications "
                            + "one after another, then opens the system audio pane")
            }
        }
        // Probed once rather than on the poll below: every answer here is a bit the kernel
        // already knows, except this one — which is a process spawn, and spawning `gws`
        // every two seconds to redraw a checkmark is not a trade worth making.
        .task { await agent.refreshStatus() }
        // There is no notification when a grant is toggled in System Settings, so a visible
        // checklist polls. It stops the moment the view goes away.
        .task {
            while !Task.isCancelled {
                refresh()
                try? await Task.sleep(for: .seconds(DS.Motion.permissionPoll))
            }
        }
    }

    /// What the Workspace row's button does next, which is a different thing in each state.
    private var workspaceActionTitle: String {
        switch agent.authState {
        case .notInstalled, .failed: "Install\u{2026}"
        case .needsOAuthClient: "Set up\u{2026}"
        case .signedOut, .signedIn: "Sign in\u{2026}"
        }
    }

    /// Everything macOS will put a dialog up for and then let us read back. Accessibility is
    /// excluded because it has no programmatic request; system audio because it has no way to
    /// be read, so it can be asked for but never ticked off.
    private var hasEveryPromptableGrant: Bool {
        hasMicrophone && hasCalendar && hasNotifications
    }

    private func grantAll() {
        isGrantingAll = true
        Task {
            if !hasMicrophone, await Permissions.requestMicrophone() == false {
                Permissions.openMicrophoneSettings()
            }
            // No `if` guard, because there is nothing to guard on: this grant cannot be
            // read. Opening a tap is harmless when it is already granted — it prompts only
            // when macOS has not yet decided.
            Permissions.requestSystemAudio()
            if !hasCalendar, await Permissions.requestCalendar() == false {
                Permissions.openCalendarSettings()
            }
            if !hasNotifications, await Notifications.shared.requestAuthorization() == false {
                Permissions.openNotificationSettings()
            }
            isGrantingAll = false
            refresh()
        }
    }

    private func refresh() {
        hasAccessibility = Permissions.hasAccessibility
        hasMicrophone = Permissions.hasMicrophone
        hasCalendar = Permissions.hasCalendar
        // The only row that can't be answered synchronously — the notification center's
        // settings are fetched, not read off a bit.
        Task { hasNotifications = await Notifications.shared.isAuthorized() }
    }
}

/// One grant. `isGranted == nil` means the system offers no way to ask — the answer only
/// appears when the feature is first used.
private struct PermissionRow: View {
    let title: String
    let detail: String
    let systemImage: String
    let isGranted: Bool?
    let actionTitle: String
    /// Work this row is waiting on, while it is waiting. The orb goes beside the button
    /// rather than in place of the icon: the symbol says *which* grant this is, which no
    /// orb in the vocabulary can, and the orb says what the row is doing about it.
    var busy: OrbGeometry.State?
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            Image(systemName: systemImage)
                .font(DS.Font.title3)
                .foregroundStyle(DS.Color.textSecondary)
                .frame(width: DS.Size.iconLarge)

            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(title)
                    .font(DS.Font.headline)
                Text(detail)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: DS.Space.s)

            if isGranted == true {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.success)
                    .labelStyle(.titleAndIcon)
            } else {
                HStack(spacing: DS.Space.s) {
                    if let busy {
                        ThinkingOrb(state: busy, size: DS.Size.orbBadge)
                            .accessibilityHidden(true)
                    }
                    Button(actionTitle, action: action)
                }
            }
        }
        .animation(DS.Motion.standard, value: isGranted)
    }
}

/// The first-launch wrapper around the checklist.
struct OnboardingSheet: View {
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.l) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("Welcome to Next Notes")
                    .font(DS.Font.title)
                Text("Hold a key, talk, let go — the text lands in whatever had focus. "
                     + "Two of these grants are needed for that; the rest can wait.")
                .font(DS.Font.callout)
                .foregroundStyle(DS.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            PermissionsChecklist()

            HStack {
                Spacer()
                Button("Start Dictating", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DS.Space.xl)
        .frame(width: DS.Size.onboardingWidth)
        // The landing page's hero, brought inside: one slow `breathing` ring behind the
        // type, at a fraction of the page's opacity because this is a window in the user's
        // own appearance rather than white ink on black. The first screen anyone sees is
        // the one place the mark can be large, and there is no work running behind it to
        // misrepresent — the app is present and idle, which is what `breathing` means.
        .orbBackdrop(.breathing, opacity: DS.Opacity.orbWatermark)
    }
}

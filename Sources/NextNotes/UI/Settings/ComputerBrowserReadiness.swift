import SwiftUI

/// The `ocu doctor` pattern for the computer and browser tools: four questions, each
/// with a status and, when the answer is not the ready one, a single sentence naming
/// what to do.
///
/// This screen is a report, not a switch. Every grant it mentions is changed in System
/// Settings; the browser answers describe the moment the check ran, not a standing
/// state — what is frontmost and what is listening on the debugging port can both
/// change between two checks, which is why the answers are read on appear and on
/// Check again and never claimed to be current after that.
struct ComputerBrowserReadiness: View {
    @State private var hasAccessibility = false
    @State private var runningBrowsers: [String] = []
    @State private var cdpState: CDPState = .notChecked
    @State private var setupState: SetupState = .idle
    /// Lets a superseded probe's late answer yield to a newer one instead of writing
    /// an older result over it.
    @State private var cdpCheck = 0

    /// What the debugging port said, held until the next check. The probe itself runs
    /// over `URLSession` and never blocks the thread it is asked from.
    enum CDPState: Equatable {
        case notChecked
        case checking
        case reachable(browser: String, pages: Int)
        case unreachable
    }

    /// The one-click setup's own progress, separate from the probe: a launch takes a
    /// few seconds before the port answers, and the button owes the person that wait.
    enum SetupState: Equatable {
        case idle
        case starting
        case started(name: String)
        case failed(String)
    }

    var body: some View {
        Form {
            Section {
                accessibilityRow
                systemAudioRow
                browserRow
                agentBrowserRow
                HStack {
                    Spacer()
                    Button("Check again") { refresh() }
                }
            } header: {
                Text("Readiness")
            } footer: {
                SettingsNote(text: "Grants are tied to this build's code signature — "
                                 + "reinstalling Next Notes can reset them. macOS never "
                                 + "announces a change, so press Check again after "
                                 + "changing anything.")
            }
        }
        .formStyle(.grouped)
        .onAppear { refresh() }
    }

    private var accessibilityRow: some View {
        ReadinessRow(
            title: "Accessibility",
            status: hasAccessibility ? "Granted" : "Not granted",
            statusColor: hasAccessibility ? DS.Color.success : DS.Color.warning,
            detail: hasAccessibility
                ? "The agent can read windows, click and type."
                : "Clicking and typing need this grant — press Grant, then switch Next "
                    + "Notes on in the pane that opens.",
            actionTitle: hasAccessibility ? nil : "Grant…",
            action: hasAccessibility ? nil : {
                Permissions.promptForAccessibility()
                Permissions.openAccessibilitySettings()
            }
        )
    }

    /// The one row that can never turn green. The grant lives in the second list of the
    /// Screen & System Audio Recording pane and has no query API — a tap without it
    /// succeeds and delivers silence — so claiming granted or failed would be
    /// inventing an answer. `--selftest-systemaudio` is where a real one comes from.
    private var systemAudioRow: some View {
        ReadinessRow(
            title: "Screen & System Audio Recording",
            status: "Unanswerable",
            statusColor: DS.Color.textSecondary,
            detail: "macOS offers no way to read this grant, so this row never says "
                + "granted or failed — opening the pane and playing any sound is what tells.",
            actionTitle: "Open the pane…",
            action: {
                Permissions.requestSystemAudio()
                Permissions.openSystemAudioSettings()
            }
        )
    }

    private var browserRow: some View {
        ReadinessRow(
            title: "Browser for everyday tasks",
            status: runningBrowsers.isEmpty ? "None running" : runningBrowsers.joined(separator: ", "),
            statusColor: runningBrowsers.isEmpty ? DS.Color.textSecondary : DS.Color.success,
            detail: runningBrowsers.isEmpty
                ? "Open any browser — Safari, Firefox, Chrome, Edge, Brave, Chromium, Arc "
                    + "or Opera — and the agent can work on the window in front, focusing "
                    + "it itself when you ask."
                : "The agent reads and acts on whichever browser window is in front. "
                    + "Bring one forward, or just ask the agent."
        )
    }

    /// The full-page-access row. This is the one a non-technical person must be able to
    /// act on, so it never mentions a flag, a port number or an address: the set-up is
    /// one button that launches a separate browser just for agent tasks, on its own
    /// profile, and says what that means.
    private var agentBrowserRow: some View {
        ReadinessRow(
            title: "Agent browser",
            status: agentBrowserStatus,
            statusColor: agentBrowserColor,
            detail: agentBrowserDetail,
            actionTitle: agentBrowserAction,
            action: agentBrowserAction == nil ? nil : { setUpAgentBrowser() },
            busy: isWaiting ? OrbGeometry.State.connecting : nil
        )
    }

    /// Waiting on either the probe or the launch — the one asynchronous pair this row
    /// runs, shown with the orb that says two parties are being wired together.
    private var isWaiting: Bool {
        setupState == .starting
            || (cdpState == .checking && {
                if case .idle = setupState { return true }
                return false
            }())
    }

    private var agentBrowserStatus: String {
        if case .reachable(let browser, _) = cdpState {
            return "Running \(browser.isEmpty ? "" : "(\(browser))")".trimmingCharacters(in: .whitespaces)
        }
        switch setupState {
        case .starting: return "Starting…"
        case .started(let name): return "\(name) is starting…"
        case .failed: return "Not running"
        case .idle: return cdpState == .checking ? "Checking" : "Not running"
        }
    }

    private var agentBrowserColor: SwiftUI.Color {
        if case .reachable = cdpState { return DS.Color.success }
        if case .failed = setupState { return DS.Color.warning }
        return DS.Color.textSecondary
    }

    private var agentBrowserDetail: String {
        if case .reachable(let browser, let pages) = cdpState {
            return "A browser just for agent tasks is running"
                + (browser.isEmpty ? "" : " — \(browser)")
                + ". Full page reading, clicks and screenshots all work. "
                + "\(pages) page(s) open."
        }
        if case .failed(let sentence) = setupState {
            return sentence
        }
        if case .started(let name) = setupState {
            return "\(name) is starting up for the first time — this takes a few seconds."
        }
        return "Optional, and separate from your own browsing: the agent runs its own copy "
            + "of the browser, so nothing you use day to day is shared with it. Press Set up "
            + "and approve — no terminal, no settings."
    }

    private var agentBrowserAction: String? {
        switch setupState {
        case .starting, .started: return nil
        case .failed, .idle:
            if case .reachable = cdpState { return nil }
            return "Set up…"
        }
    }

    /// One press, one visible browser with its own profile. No approval card here on
    /// purpose: the person pressed the button themselves, in the screen that explains
    /// what it does, and the browser is a scratch profile rather than their own — the
    /// agent path (`browser.relaunch_debug`) keeps its approval card for when the agent
    /// decides it, where there is no press to name the intent.
    private func setUpAgentBrowser() {
        setupState = .starting
        Task { @MainActor in
            do {
                _ = try DebugBrowser.launchWithDebugPort()
            } catch {
                setupState = .failed(error.localizedDescription)
                return
            }
            setupState = .started(name: "The agent browser")
            // The port answers a beat after the window appears; poll rather than claim.
            for _ in 0..<16 {
                try? await Task.sleep(for: .milliseconds(500))
                let probe = await BrowserCDPClient.probe()
                if probe != nil {
                    setupState = .idle
                    refreshCDPState()
                    return
                }
            }
            setupState = .failed("The agent browser started, but the agent could not reach "
                + "it yet. Press Check again in a moment, or try Set up again.")
        }
    }

    private func refresh() {
        hasAccessibility = Permissions.hasAccessibility
        runningBrowsers = Self.runningBrowsers()
        refreshCDPState()
    }

    private func refreshCDPState() {
        cdpCheck += 1
        let generation = cdpCheck
        cdpState = .checking
        Task {
            let probe = await BrowserCDPClient.probe()
            // An earlier check the user has already replaced must not overwrite a
            // newer answer with an older port.
            guard generation == cdpCheck else { return }
            cdpState = probe.map { .reachable(browser: $0.browser, pages: $0.targets.count) }
                ?? .unreachable
        }
    }

    private static func runningBrowsers() -> [String] {
        var names: [String] = []
        for app in NSWorkspace.shared.runningApplications {
            guard let bundle = app.bundleIdentifier,
                  BrowserToolExecutor.browserBundleIDs.contains(bundle) else { continue }
            if let name = app.localizedName, !names.contains(name) { names.append(name) }
        }
        return names
    }
}

/// One readiness question. Status text only, in the two status inks the design system
/// allows plus secondary for the honest "we cannot know"; the busy orb shows while the
/// one asynchronous answer, the port probe, is in flight.
private struct ReadinessRow: View {
    let title: String
    let status: String
    let statusColor: SwiftUI.Color
    var detail: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    /// Work this row is waiting on, while it waits — `connecting`, the two parties
    /// being wired together, which is exactly what a port probe is.
    var busy: OrbGeometry.State? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(spacing: DS.Space.s) {
                Text(title)
                    .font(DS.Font.headline)
                Spacer()
                if let busy {
                    ThinkingOrb(state: busy, size: DS.Size.orbBadge)
                        .accessibilityHidden(true)
                }
                Text(status)
                    .font(DS.Font.callout)
                    .foregroundStyle(statusColor)
                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .font(DS.Font.caption)
                }
            }
            if let detail {
                Text(detail)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

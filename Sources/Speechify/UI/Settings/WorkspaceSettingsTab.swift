import SwiftUI

/// The Workspace agent: whether its tool layer is ready, and how much rope it gets.
///
/// The whole tab is one question — can Speechify act in your Google Workspace — and it has
/// four possible answers, each with a different next step. Nothing here happens silently:
/// every step that changes the machine or talks to Google opens Terminal, in front of the
/// user, and the status is re-read when they come back.
struct WorkspaceSettingsTab: View {
    @State private var settings = Settings.shared
    @State private var agent = AgentService.shared
    @State private var isImportingClient = false
    @State private var importFailure: String?

    var body: some View {
        Form {
            statusSection
            agentSection
            toolsSection
        }
        .formStyle(.grouped)
        .task { await agent.refreshStatus() }
        // The user answers these questions in a Terminal window beside this one, so the
        // moment they come back is the moment the answer has changed.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await agent.refreshStatus() }
        }
        .fileImporter(
            isPresented: $isImportingClient,
            allowedContentTypes: [.json]
        ) { result in
            switch result {
            case .success(let url):
                do {
                    try WorkspaceInstaller.importClientConfig(from: url)
                    importFailure = nil
                    Task { await agent.refreshStatus(force: true) }
                } catch {
                    importFailure = error.localizedDescription
                }
            case .failure(let error):
                importFailure = error.localizedDescription
            }
        }
    }

    // MARK: - Status

    private var statusSection: some View {
        Section {
            LabeledContent("Workspace CLI") {
                HStack(spacing: DS.Space.s) {
                    StatusChip(text: agent.authState.displayName, color: statusColor)
                    if let version = agent.version {
                        Text(version)
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.textTertiary)
                    }
                    Button("Re-check") { Task { await agent.refreshStatus(force: true) } }
                        .disabled(agent.isProbing)
                    if agent.isProbing {
                        ThinkingOrb(state: .connecting, label: "Checking")
                    }
                }
            }

            // No orb here: the row above already carries `connecting` while the probe is
            // out, and a second canvas naming the same wait is the scattering the design
            // system rules out.
            SettingsNote(text: agent.authState.detail)

            nextStep

            if let importFailure {
                Text(importFailure)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Google Workspace")
        } footer: {
            footnote("Speechify acts through Google's own command-line tool rather than "
                     + "carrying its own Workspace credentials. Everything it runs is a "
                     + "command you could type yourself, and nothing runs without the "
                     + "approval shown in the meeting.")
        }
    }

    /// The one thing worth doing next, given where the CLI has got to.
    @ViewBuilder
    private var nextStep: some View {
        switch agent.authState {
        case .notInstalled:
            LabeledContent("Install") {
                Button("Install\u{2026}") {
                    WorkspaceInstaller.install()
                }
            }
        case .needsOAuthClient:
            // Two ways, side by side, because they suit different machines: gcloud is the
            // supported path and a 700 MB install, and a client JSON is a two-minute trip
            // to a web console — the same client Phase 3's Google Calendar uses.
            LabeledContent("OAuth client") {
                HStack(spacing: DS.Space.s) {
                    Button("Set up with gcloud\u{2026}") { WorkspaceInstaller.setUpWithGcloud() }
                    Button("Use an existing client\u{2026}") { isImportingClient = true }
                }
            }
            SettingsNote(text: "A client of type \u{201c}Desktop app\u{201d}, created in the "
                         + "Google Cloud console with the Gmail, Calendar, Drive and Docs "
                         + "APIs enabled. Its JSON is copied to "
                         + "\(GoogleWorkspaceCLI.clientConfigURL.path), and the same client "
                         + "is applied to Google Calendar \u{2014} import it once, here or in "
                         + "the Calendar tab, and both are set up.")
        case .signedOut:
            LabeledContent("Account") {
                Button("Sign in\u{2026}") { WorkspaceInstaller.signIn() }
            }
        case .signedIn:
            LabeledContent("Account") {
                Button("Sign in again\u{2026}") { WorkspaceInstaller.signIn() }
            }
        case .failed:
            LabeledContent("Workspace CLI") {
                Button("Install\u{2026}") { WorkspaceInstaller.install() }
            }
        }
    }

    // MARK: - Agent

    private var agentSection: some View {
        Section {
            Toggle("Propose follow-up actions after a meeting", isOn: $settings.agentEnabled)
                .disabled(!agent.authState.isSignedIn)

            Toggle("Look things up without asking", isOn: $settings.agentAutoRunReadTools)
                .disabled(!settings.agentEnabled)

            Toggle("Listen for requests during a meeting", isOn: $settings.agentLiveDuringMeeting)
                .disabled(!settings.agentEnabled)
        } header: {
            Text("Agent")
        } footer: {
            footnote("Reading your mail, calendar and Drive changes nothing and nobody else "
                     + "sees it, so the agent does that by itself while it works out what to "
                     + "suggest. Everything that creates or sends waits for you, and anything "
                     + "being sent is shown in full first. Listening during a meeting spends "
                     + "model time on the busiest minutes of the day and only acts on an "
                     + "explicit request \u{2014} \u{201c}send me the deck\u{201d} \u{2014} so "
                     + "it is off unless you want it.")
        }
    }

    // MARK: - Tools

    /// What the agent is able to propose, in full.
    ///
    /// Listed rather than summarised because this is the honest answer to "what can it do to
    /// my account", and a footnote saying "manages your Workspace" is not one.
    private var toolsSection: some View {
        Section {
            ForEach(AgentRisk.allCases, id: \.self) { risk in
                LabeledContent(risk.displayName) {
                    Text(WorkspaceTools.all.filter { $0.risk == risk }
                        .map(\.name)
                        .joined(separator: ", "))
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text("What it can do")
        } footer: {
            footnote("These are the only Workspace calls Speechify will make. Each one is "
                     + "proposed with the exact arguments it would run, and can be edited "
                     + "before it is approved.")
        }
    }

    // MARK: - Helpers

    /// Status colours are text colours, never the meter palette.
    private var statusColor: Color {
        switch agent.authState {
        case .signedIn: DS.Color.success
        case .failed: DS.Color.warning
        case .notInstalled, .needsOAuthClient, .signedOut: DS.Color.info
        }
    }

    private func footnote(_ text: String) -> some View {
        SettingsNote(text: text)
    }
}

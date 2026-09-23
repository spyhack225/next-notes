import SwiftUI

/// Activation, execution backend and the standing permission answers.
struct AgentSettingsTab: View {
    @State private var settings = Settings.shared
    @State private var models = LocalModelStore.shared
    @State private var harness = AgentHarnessRouter.shared
    @State private var calibrator = WakeWordCalibrator.shared
    @State private var wakeMonitor = WakeWordAudioMonitor.shared
    @State private var grants = PermissionGrantStore.shared

    var body: some View {
        Form {
            // Persona / SOUL editor lives under Agent → About (single editor).
            PersonaSection()
            activation
            wakeModel
            wakeTest
            execution
            ModelRoleSection()
            modelSection
            FastListeningSection()
            permissions
            remembered
            MemoriesSection()
            RemindersSection()
            KnowledgeSection()
        }
        .formStyle(.grouped)
        .onAppear { models.refresh() }
        .onDisappear {
            calibrator.stop()
            // New memory badges stay visible while the tab is open; closing it marks them seen.
            if NextMemory.shared.newCount > 0 { NextMemory.shared.markListViewed() }
        }
    }

    /// The online catalogue, shown only once a job above has been pointed at an online
    /// model. Two pickers for the same decision was the old shape of this screen; the job
    /// rows now own the choice and this is only where the online one is named.
    @ViewBuilder
    private var modelSection: some View {
        if usesOnlineModel {
            Section {
                OpenRouterModelSelection(
                    modelID: $settings.openRouterAgentModelID,
                    contextTokens: $settings.openRouterAgentContextTokens
                )
            } header: {
                Text("Online model")
            } footer: {
                SettingsNote(text: "Requests go to OpenRouter and may cost money. Add the "
                             + "key in Models settings. Everything else above stays on this Mac.")
            }
        }
    }

    private var usesOnlineModel: Bool {
        ModelRole.allCases.contains { role in
            if case .cloud = ModelRoleStore.shared.choice(for: role) { return true }
            return false
        }
    }

    private var activation: some View {
        Section {
            Toggle("Voice wake", isOn: $settings.voiceWakeEnabled)
            TextField("Wake phrase", text: $settings.wakePhrase)
                .textFieldStyle(.roundedBorder)
                .disabled(!settings.voiceWakeEnabled)
            if settings.voiceWakeEnabled, let problem = wakePhraseProblem {
                Text(problem)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.warning)
            }
            Slider(value: $settings.wakeSensitivity, in: 0...1) {
                Text("Sensitivity")
            } minimumValueLabel: {
                Text("Conservative")
            } maximumValueLabel: {
                Text("Sensitive")
            }
            Toggle("Listen while sleeping", isOn: $settings.listenWhileSleeping)
                .disabled(!settings.voiceWakeEnabled)
            // What the microphone is actually doing right now, in plain words. Until
            // this line existed there was no way to tell "listening" from "stopped
            // half an hour ago and never came back".
            LabeledContent("Right now") {
                Text(wakeMonitor.status.plainWords)
                    .foregroundStyle(
                        wakeMonitor.isListening ? DS.Color.success : DS.Color.textSecondary
                    )
            }
            .font(DS.Font.caption)
            Toggle("Agent shortcut", isOn: $settings.agentShortcutEnabled)
            Picker("Shortcut", selection: $settings.agentShortcut) {
                ForEach(AgentShortcut.allCases) { shortcut in
                    Text(shortcut.displayName).tag(shortcut)
                }
            }
            .disabled(!settings.agentShortcutEnabled)
        } header: {
            Text("Activation")
        } footer: {
            SettingsNote(text: activationFooter)
        }
        .onChange(of: settings.wakePhrase) { _, _ in applyWakePhrase() }
        .onChange(of: settings.voiceWakeEnabled) { _, _ in applyWakePhrase() }
        .onChange(of: settings.listenWhileSleeping) { _, _ in applyWakePhrase() }
        // Sensitivity had no hook at all, so moving the slider changed nothing until
        // the next relaunch — and the reload test only compared the phrase, so even
        // then it was ignored.
        .onChange(of: settings.wakeSensitivity) { _, _ in applyWakePhrase() }
    }

    private var activationFooter: String {
        if WakeWordPhoneLexicon.isAvailable {
            return "Push-to-talk stays dictation. The shortcut and the wake phrase open the "
                + "agent. English phrases use the keyword model’s pronunciation dictionary "
                + "(~126k words), so common names and words work without a rebuild. The "
                + "keyboard shortcut always works; wake-word audio stays on this Mac."
        }
        return "Push-to-talk stays dictation. The shortcut and the wake phrase open the agent. "
            + "Download the keyword model below to unlock the full English pronunciation "
            + "dictionary for custom phrases. The keyboard shortcut always works."
    }

    /// Shown under the field when the typed phrase cannot be loaded safely.
    private var wakePhraseProblem: String? {
        let normalized = WakeWordConfiguration.normalize(settings.wakePhrase)
        guard !normalized.isEmpty else { return nil }
        if normalized.count < 3 || normalized.split(separator: " ").count > 6 {
            return "Use a short phrase of a few spoken words."
        }
        let unknown = WakeWordKeywords.unknownWords(in: normalized)
        guard !unknown.isEmpty else { return nil }
        let listed = unknown.map { "“\($0)”" }.joined(separator: ", ")
        if !WakeWordPhoneLexicon.isAvailable {
            return "\(listed) isn’t available until the keyword model is downloaded (or isn’t "
                + "in the small offline list). The keyboard shortcut still works."
        }
        return "\(listed) isn’t in the pronunciation dictionary, so voice wake won’t use this "
            + "phrase. Try a different word, or use the keyboard shortcut."
    }

    /// Keep the on-disk keywords and the live spotter in step with the field — and never
    /// leave a crashing keywords.txt behind after an edit.
    private func applyWakePhrase() {
        Task { @MainActor in
            WakeWordAudioMonitor.shared.sync()
        }
    }

    private var wakeModel: some View {
        Section {
            // The download itself lives in Settings ▸ Models now, alongside every other
            // model this app fetches — this row only says whether it's there yet.
            HStack(spacing: DS.Space.xs) {
                Text(models.wakeWordState == .ready ? "Ready" : "Not downloaded yet")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
                Spacer()
                Button("Manage in Models") {
                    NavigationState.shared.selectedSettingsTab = .models
                }
                .buttonStyle(.link)
                .font(DS.Font.caption)
            }
        } header: {
            Text("Wake-from-sleep")
        } footer: {
            SettingsNote(text: models.wakeWordState == .ready
                         ? wakeModelFooter
                         : WakeWordModelManager.unavailableReason)
        }
    }

    private var wakeModelFooter: String {
        if let phrase = WakeWordConfiguration.current.validatedPhrase() {
            return "The keyword model is loaded. “\(phrase)” on the microphone wakes the agent."
        }
        return "The keyword model is loaded, but the current wake phrase can’t be used until every word is in the pronunciation list. The agent shortcut still works."
    }

    private var wakeTest: some View {
        Section {
            Text("Test “\(calibrator.phrase)”")
                .font(DS.Font.headline)

            if calibrator.isRunning {
                HStack(spacing: DS.Space.orbGap) {
                    ThinkingOrb(state: .listening, size: DS.Size.orbSmall)
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text("Listening…")
                            .font(DS.Font.callout)
                        Text(calibrator.prompt)
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.textSecondary)
                    }
                }
                LevelBar(level: calibrator.level, isActive: true)
                Button("Stop") { calibrator.stop() }
            } else {
                Button(calibrator.phase == .finished ? "Test again" : "Start test") {
                    calibrator.start()
                }
                .disabled(!settings.voiceWakeEnabled || !WakeWordModelManager.isReadyToLoad)
            }

            ForEach(calibrator.attempts, id: \.index) { attempt in
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    HStack {
                        Text("Attempt \(attempt.index)")
                        Spacer()
                        Text(attempt.accepted
                             ? String(format: "%.2f ✓", attempt.confidence)
                             : String(format: "%.2f", attempt.confidence))
                            .foregroundStyle(attempt.accepted ? DS.Color.success : DS.Color.textSecondary)
                    }
                    .font(DS.Font.callout)
                    ProgressView(value: attempt.confidence)
                    // Why it landed where it did. A bare number cannot tell someone
                    // that they were heard but the slider is too conservative.
                    Text(attempt.explanation)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                }
            }

            if case .finished = calibrator.phase {
                Text(calibrator.prompt)
                    .font(DS.Font.callout)
                    .foregroundStyle(
                        WakeWordTrainer.shouldSave(calibrator.attempts)
                            ? DS.Color.success
                            : DS.Color.textSecondary
                    )
            }

            if case .unavailable(let reason) = calibrator.phase {
                Text(reason)
                    .font(DS.Font.callout)
                    .foregroundStyle(DS.Color.warning)
            }

            if WakeWordTrainer.shouldSave(calibrator.attempts) {
                Button("Use “\(calibrator.phrase)”") {
                    calibrator.commit()
                }
            }
        } header: {
            Text("Test phrase")
        } footer: {
            SettingsNote(
                text: WakeWordModelManager.isReadyToLoad
                    ? "The same keyword detector that wakes the agent. Say the phrase — do not type it."
                    : WakeWordModelManager.unavailableReason
            )
        }
    }

    private var remembered: some View {
        Section {
            if grants.grants.isEmpty {
                Text("None yet")
                    .foregroundStyle(DS.Color.textSecondary)
            } else {
                ForEach(grants.grants) { grant in
                    // A person revoking a standing yes needs to read what it was: the
                    // human title the approval card used, never a raw tool id (§8.3).
                    LabeledContent(ToolCallReviewBuilder.humanTitle(forToolID: grant.toolID)) {
                        HStack(spacing: DS.Space.s) {
                            Text(grant.scope.displayName)
                                .foregroundStyle(DS.Color.textSecondary)
                            Button("Revoke") {
                                grants.revoke(id: grant.id)
                            }
                        }
                    }
                }
            }
        } header: {
            Text("Remembered permissions")
        } footer: {
            SettingsNote(text: "A yes is scoped to an app, site, folder or project. "
                         + "It is not a blanket allow.")
        }
    }

    private var execution: some View {
        Section {
            Picker("Responsiveness", selection: $settings.agentResponsiveness) {
                ForEach(AgentResponsiveness.allCases) { choice in
                    Text(choice.displayName).tag(choice)
                }
            }
            Picker("Run work with", selection: $settings.agentBackend) {
                ForEach(AgentBackendKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            if settings.agentBackend == .acp {
                Picker("Coding agent", selection: $settings.acpBackendID) {
                    Text("First on PATH").tag("")
                    Text("Claude Code").tag("claude")
                    Text("Codex").tag("codex")
                    Text("Qwen Code").tag("qwen")
                    Text("OpenCode").tag("opencode")
                }
                Text(ACPAgentBackend.statusText(for: settings.acpBackendID))
                    .font(.caption)
                    .foregroundStyle(DS.Color.textSecondary)
            }
            if let last = harness.lastChoice {
                LabeledContent("Last turn") {
                    Text(last.usingLine)
                        .foregroundStyle(DS.Color.textSecondary)
                }
            }
        } header: {
            Text("Execution")
        } footer: {
            SettingsNote(text: "Fast favors short answers and fewer checks; Deep allows "
                         + "longer answers and more tool rounds. Dictation is unaffected. "
                         + "The backend is the default when there is no past request to learn "
                         + "from. Say “use Claude Code” or “do it locally” to pick for one "
                         + "turn. Calendar, mail, Drive, Docs, click and type stay on this "
                         + "Mac unless you say otherwise. Claude Code and Codex each need a "
                         + "small helper installed alongside them before Next Notes can hand "
                         + "them work; until it is there, they show as not ready.")
        }
    }

    private var permissions: some View {
        Section {
            Toggle("Read calendar and mail without asking", isOn: $settings.agentAutoRunReadTools)
            Toggle("Search local files without asking", isOn: $settings.agentAutoSearchFiles)
            Toggle("Click and type without asking", isOn: $settings.agentAllowComputerControl)
        } header: {
            Text("Allow without asking")
        } footer: {
            SettingsNote(text: "Inspecting the front window is automatic. Clicks and typing "
                         + "ask unless this is on. Sending, deleting and privileged commands "
                         + "always ask. There is no switch that allows everything.")
        }
    }
}

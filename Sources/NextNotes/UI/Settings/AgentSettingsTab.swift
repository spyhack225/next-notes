import SwiftUI

/// Activation, execution backend and the standing permission answers.
struct AgentSettingsTab: View {
    @State private var settings = Settings.shared
    @State private var models = LocalModelStore.shared
    @State private var harness = AgentHarnessRouter.shared
    @State private var calibrator = WakeWordCalibrator.shared
    @State private var grants = PermissionGrantStore.shared

    var body: some View {
        Form {
            activation
            wakeModel
            wakeTest
            execution
            permissions
            remembered
        }
        .formStyle(.grouped)
        .onAppear { models.refresh() }
        .onDisappear { calibrator.stop() }
    }

    private var activation: some View {
        Section {
            Toggle("Voice wake", isOn: $settings.voiceWakeEnabled)
            TextField("Wake phrase", text: $settings.wakePhrase)
                .textFieldStyle(.roundedBorder)
                .disabled(!settings.voiceWakeEnabled)
            Slider(value: $settings.wakeSensitivity, in: 0...1) {
                Text("Sensitivity")
            } minimumValueLabel: {
                Text("Conservative")
            } maximumValueLabel: {
                Text("Sensitive")
            }
            Toggle("Listen while sleeping", isOn: $settings.listenWhileSleeping)
                .disabled(!settings.voiceWakeEnabled)
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
            SettingsNote(text: "Push-to-talk stays dictation. The shortcut and the wake phrase "
                         + "open the agent. Changing the phrase never locks you out — the "
                         + "shortcut always works. Wake-word audio stays on this Mac.")
        }
    }

    private var wakeModel: some View {
        Section {
            ModelStatusRow(
                title: "Keyword model",
                detail: "sherpa-onnx zipformer · \(WakeWordModels.archive.displaySize)",
                state: models.wakeWordState,
                downloadTitle: "Download…"
            ) {
                models.prepareWakeWord()
            }
        } header: {
            Text("Wake-from-sleep")
        } footer: {
            SettingsNote(text: models.wakeWordState == .ready
                         ? "The keyword model is loaded. “\(WakeWordConfiguration.normalize(settings.wakePhrase))” on the microphone wakes the agent."
                         : WakeWordModelManager.unavailableReason)
        }
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
                    LabeledContent(grant.toolID) {
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
            SettingsNote(text: "This is the default when there is no past request to learn "
                         + "from. Say “use Claude Code” or “do it locally” to pick for one "
                         + "turn. Calendar, mail, Drive, Docs, click and type stay on this "
                         + "Mac unless you name a coding agent.")
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

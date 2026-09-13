import SwiftUI

/// Activation, execution backend and the standing permission answers.
struct AgentSettingsTab: View {
    @State private var settings = Settings.shared
    @State private var models = LocalModelStore.shared
    @State private var harness = AgentHarnessRouter.shared
    @State private var attempts: [WakeWordAttempt] = []
    @State private var testTranscript = ""

    var body: some View {
        Form {
            activation
            wakeModel
            wakeTest
            execution
            permissions
        }
        .formStyle(.grouped)
        .onAppear { models.refresh() }
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
            TextField("Say the phrase, then type what you said", text: $testTranscript)
            Button("Score this attempt") {
                var attempt = WakeWordTrainer.score(
                    transcript: testTranscript,
                    configuration: WakeWordConfiguration.current
                )
                attempt.index = attempts.count + 1
                attempts.append(attempt)
                testTranscript = ""
            }
            .disabled(testTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            ForEach(attempts, id: \.index) { attempt in
                LabeledContent("Attempt \(attempt.index)") {
                    Text(attempt.accepted
                         ? String(format: "%.2f ✓", attempt.confidence)
                         : String(format: "%.2f", attempt.confidence))
                    .foregroundStyle(attempt.accepted ? DS.Color.success : DS.Color.textSecondary)
                }
            }

            if WakeWordTrainer.shouldSave(attempts) {
                Button("Use “\(WakeWordConfiguration.normalize(settings.wakePhrase))”") {
                    try? WakeWordModelManager.writeKeywords(WakeWordConfiguration.current)
                    attempts = []
                }
            }
        } header: {
            Text("Test phrase")
        } footer: {
            SettingsNote(text: WakeWordModelManager.isDownloaded
                         ? "Keyword model is on disk."
                         : WakeWordModelManager.unavailableReason)
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

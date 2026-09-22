import SwiftUI

/// Keys and feedback: what you hold, what the second key does, whether it ticks.
struct GeneralSettingsTab: View {
    @Bindable var controller: DictationController
    @State private var settings = Settings.shared

    var body: some View {
        Form {
            Section {
                Picker("Push-to-talk key", selection: Binding(
                    get: { settings.pushToTalkKey },
                    set: { key in
                        settings.pushToTalkKey = key
                        controller.reloadHotkey()
                    }
                )) {
                    ForEach(pushToTalkChoices, id: \.self) { key in
                        Text(key.displayName).tag(key)
                    }
                }
                Toggle("Play a tick when capture starts and stops", isOn: $settings.soundEnabled)
            } footer: {
                SettingsNote(text: "Hold this key anywhere to dictate. The Record button "
                             + "works regardless of what's focused.")
            }

            Section {
                Toggle("Edit selected text by voice", isOn: Binding(
                    get: { settings.commandModeEnabled },
                    set: { enabled in
                        settings.commandModeEnabled = enabled
                        controller.reloadHotkey()
                    }
                ))
                .disabled(!FoundationModelCommandProcessor.isAvailable)

                if settings.commandModeEnabled {
                    Picker("Key to hold", selection: Binding(
                        get: { settings.commandModeKey },
                        set: { key in
                            settings.commandModeKey = key
                            controller.reloadHotkey()
                        }
                    )) {
                        ForEach(commandModeChoices, id: \.self) { key in
                            Text(key.displayName).tag(key)
                        }
                    }
                }
            } header: {
                Text("Command Mode")
            } footer: {
                SettingsNote(text: commandModeNote)
            }

            // The way back into first run. It is here rather than under Permissions
            // because it is not only about grants — it is the whole walkthrough, and
            // somebody who wants it usually cannot remember what it was called.
            Section {
                HStack {
                    Text("Setup")
                    Spacer()
                    Button("Run setup again") {
                        OnboardingPresenter.restart(controller: controller)
                    }
                }
            } footer: {
                SettingsNote(text: "Walks through the same questions Next Notes asked the "
                             + "first time. Nothing you have already set up is undone.")
            }
        }
        .formStyle(.grouped)
        .animation(DS.Motion.standard, value: settings.commandModeEnabled)
    }

    /// The two hotkeys must never name the same key. `Settings` resolves that collision by
    /// switching Command Mode back off, which from the outside looks like the feature broke
    /// itself — so each picker simply omits the key the other one owns, and the collision
    /// stops being reachable. (Marking a picker's row `.disabled` does not work: the
    /// modifier lands on the `Text`, and a macOS menu picker still lets it be chosen.)
    private var pushToTalkChoices: [PushToTalkKey] {
        PushToTalkKey.allCases.filter {
            !settings.commandModeEnabled || $0 != settings.commandModeKey
        }
    }

    private var commandModeChoices: [PushToTalkKey] {
        PushToTalkKey.allCases.filter { $0 != settings.pushToTalkKey }
    }

    private var commandModeNote: String {
        if let reason = FoundationModelCommandProcessor.unavailableReason { return reason }
        // Says what the key does, and — just as important — what it does *not* do. The key
        // is usually ⌘, so the first thing anyone does with it by accident is press it on
        // its own or inside a shortcut, and for a while that put an unexplained animation
        // on screen. Both are now nothing, and the sentence says so.
        return "Highlight some text, hold \(settings.commandModeKey.spokenName) for a "
            + "moment, and say what to change — \u{201c}make this shorter.\u{201d} A quick "
            + "tap does nothing, and neither does using that key in an ordinary shortcut "
            + "like Command-C or Command-click. Your words never leave this Mac."
    }
}

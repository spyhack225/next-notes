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
                Text("Hold this key anywhere to dictate. The Record button works regardless "
                     + "of what's focused.")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.textSecondary)
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
                    Picker("Command key", selection: Binding(
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
                Text(commandModeNote)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
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
        return "Select editable text, hold the second key, and say an instruction such as "
            + "\u{201c}make this more formal.\u{201d} Processing stays on this Mac."
    }
}

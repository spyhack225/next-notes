import SwiftUI

/// Which engine hears you, and what happens to the text before it is typed.
struct DictationSettingsTab: View {
    @State private var settings = Settings.shared
    @State private var models = LocalModelStore.shared

    var body: some View {
        Form {
            Section {
                Picker("Engine", selection: Binding(
                    get: { settings.engine },
                    set: { choice in
                        settings.engine = choice
                        if choice == .parakeet { models.prepareParakeet() }
                    }
                )) {
                    ForEach(SpeechEngineChoice.allCases, id: \.self) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
                .disabled(settings.compareMode)

                Toggle("Compare mode (run every engine)", isOn: $settings.compareMode)
            } header: {
                Text("Transcription")
            } footer: {
                Text(engineNote)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
            }

            Section {
                Picker("While dictating, show", selection: $settings.hudPlacement) {
                    ForEach(HUDPlacement.allCases) { placement in
                        Text(placement.displayName).tag(placement)
                    }
                }
            } header: {
                Text("Heads-up display")
            } footer: {
                Text(placementNote)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
            }

            Section {
                Toggle("Clean up transcripts", isOn: $settings.cleanupEnabled)

                if settings.cleanupEnabled {
                    Picker("Cleanup model", selection: Binding(
                        get: { settings.cleanupEngine },
                        set: { choice in
                            settings.cleanupEngine = choice
                            if choice == .s1Mini { models.prepareS1Mini() }
                        }
                    )) {
                        ForEach(CleanupEngineChoice.allCases, id: \.self) { choice in
                            Text(choice.displayName).tag(choice)
                        }
                    }
                    Picker("Tone", selection: $settings.cleanupTone) {
                        ForEach(CleanupTone.allCases, id: \.self) { tone in
                            Text(tone.displayName).tag(tone)
                        }
                    }
                    Picker("Context", selection: $settings.cleanupContext) {
                        ForEach(CleanupContext.allCases, id: \.self) { context in
                            Text(context.displayName).tag(context)
                        }
                    }
                    Toggle("Format spoken lists", isOn: $settings.cleanupFormatsLists)
                }
            } header: {
                Text("Cleanup")
            } footer: {
                Text(cleanupNote)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
            }
        }
        .formStyle(.grouped)
        .animation(DS.Motion.standard, value: settings.cleanupEnabled)
    }

    private var placementNote: String {
        switch settings.hudPlacement {
        case .notch:
            return IslandGeometry.hasNotch
                ? "The island hugs the notch and expands when you point at it. It announces "
                    + "meetings and finished notes wherever this is set."
                : "This Mac has no notch, so the island floats just under the menu bar."
        case .bottom:
            return "The capsule floats above the Dock, as it always has. Meetings and "
                + "finished notes still appear at the top of the screen."
        }
    }

    private var engineNote: String {
        if settings.compareMode {
            return "Every engine transcribes each recording and the results appear in the "
                + "Comparison section. Nothing is typed into the focused app in this mode."
        }
        switch settings.engine {
        case .apple:
            return "Apple's on-device transcriber. Streams text while you speak; no download."
        case .parakeet:
            switch models.parakeetState {
            case .notDownloaded: return "Parakeet resolves on release. Selecting it downloads ~470 MB once."
            case .preparing(let message): return message
            case .ready: return "Parakeet is installed and ready. It resolves after key release."
            case .failed(let message): return "Parakeet failed: \(message) Retry from the Models tab."
            }
        }
    }

    private var cleanupNote: String {
        guard settings.cleanupEnabled else {
            return "Raw engine output is inserted. Personal dictionary corrections still run."
        }
        switch settings.cleanupEngine {
        case .apple:
            if let reason = FoundationModelFormatter.unavailableReason {
                return "\(reason) Rule-based cleanup will be used until it is available."
            }
            return "Apple's Foundation Model removes fillers, honors corrections, and formats "
                + "text locally."
        case .s1Mini:
            switch models.s1MiniState {
            case .ready:
                return "S1-mini by Superwhisper runs locally through llama.cpp; no transcript "
                    + "leaves this Mac."
            case .preparing(let message): return message
            case .failed(let message): return "S1-mini failed: \(message)"
            case .notDownloaded:
                return "S1-mini by Superwhisper requires a one-time download. Fetch it from the "
                    + "Models tab."
            }
        }
    }
}

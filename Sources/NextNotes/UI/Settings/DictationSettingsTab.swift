import AppKit
import SwiftUI

/// Which engine hears you, and what happens to the text before it is typed.
struct DictationSettingsTab: View {
    @State private var settings = Settings.shared
    @State private var models = LocalModelStore.shared
    @State private var isPickingAutoSendApp = false

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
                SettingsNote(text: engineNote, orb: engineWork)
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
                SettingsNote(text: placementNote)
            }

            Section {
                Picker("If you switch apps first", selection: $settings.switchAwayBehavior) {
                    ForEach(SwitchAwayBehavior.allCases) { behavior in
                        Text(behavior.displayName).tag(behavior)
                    }
                }
            } header: {
                Text("Where the text goes")
            } footer: {
                SettingsNote(text: switchAwayNote)
            }

            Section {
                Toggle("Auto-send after dictation", isOn: $settings.autoSendEnabled)

                if !settings.autoSendEnabled {
                    if autoSendApps.isEmpty {
                        LabeledOrb(
                            state: .breathing,
                            title: "No apps yet",
                            detail: "Add an app to press Return only there. Everywhere else "
                                + "you send it yourself.",
                            size: DS.Size.orbBadge,
                            isAnimated: false
                        )
                    }

                    ForEach(autoSendApps) { app in
                        LabeledContent {
                            Button("Remove", role: .destructive) {
                                settings.removeAutoSendApp(bundleID: app.bundleID)
                            }
                        } label: {
                            HStack(spacing: DS.Space.s) {
                                if let icon = appIcon(for: app.bundleID) {
                                    Image(nsImage: icon)
                                        .resizable()
                                        .frame(width: DS.Size.appIcon, height: DS.Size.appIcon)
                                }
                                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                                    Text(app.name)
                                    Text(app.bundleID)
                                        .font(DS.Font.caption)
                                        .foregroundStyle(DS.Color.textSecondary)
                                }
                            }
                        }
                    }

                    Button("Add App\u{2026}") { isPickingAutoSendApp = true }
                }
            } header: {
                Text("After inserting")
            } footer: {
                SettingsNote(text: autoSendNote)
            }

            Section {
                Picker("When you correct a transcript", selection: $settings.dictionaryLearning) {
                    ForEach(DictionaryLearning.allCases) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }
            } header: {
                Text("Learning from your corrections")
            } footer: {
                SettingsNote(text: learningNote)
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
                    // Said where the picker is, not only in the section footer. The two
                    // controls combine silently — S1-mini plus grammar repair runs Apple's
                    // model and not S1-mini at all — so a picker reading "S1-mini" with no
                    // word beside it tells the user something untrue about their own Mac.
                    if settings.cleanupEngine == .s1Mini, settings.cleanupFixesGrammar {
                        Label(
                            "Apple's on-device model is doing the cleanup, not S1-mini. S1-mini "
                                + "can only add punctuation, so grammar repair runs on Apple. Turn "
                                + "off “Fix grammar” below to use S1-mini.",
                            systemImage: "info.circle"
                        )
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
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
                    Toggle("Fix grammar, not just punctuation (uses Apple's model)",
                           isOn: $settings.cleanupFixesGrammar)
                        .help("Repairs agreement, tense and word order — \"there is some "
                              + "lags\" becomes \"there are some lags\". Runs on Apple's "
                              + "on-device model; S1-mini cannot do this on its own.")

                    Toggle("Format spoken lists", isOn: $settings.cleanupFormatsLists)

                    Toggle("Skip the cleanup model when the Mac is busy", isOn: $settings.cleanupSkipsModelWhenBusy)
                        .help("While memory is low, the Mac is hot or in Low Power Mode, or live "
                              + "transcription or meeting notes are using the model, short "
                              + "dictations get quick rule-based cleanup instead of waiting. "
                              + "Faster, but noticeably rougher. Dictations that name a file on "
                              + "screen always use the model.")
                }
            } header: {
                Text("Cleanup")
            } footer: {
                SettingsNote(text: cleanupNote, orb: cleanupWork)
            }
        }
        .formStyle(.grouped)
        .animation(DS.Motion.standard, value: settings.cleanupEnabled)
        .animation(DS.Motion.standard, value: settings.autoSendEnabled)
        .sheet(isPresented: $isPickingAutoSendApp) {
            InstalledAppPickerSheet(alreadyListed: Set(settings.autoSendApps.keys)) { app in
                settings.addAutoSendApp(bundleID: app.bundleID, name: app.displayName)
            }
        }
    }

    private struct AutoSendApp: Identifiable {
        let bundleID: String
        let name: String
        var id: String { bundleID }
    }

    /// Sorted by the name a person would recognise, not by when it was added: a list that
    /// reorders itself while Settings is open moves the row under the pointer.
    private var autoSendApps: [AutoSendApp] {
        settings.autoSendApps
            .map { AutoSendApp(bundleID: $0.key, name: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func appIcon(for bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private var autoSendNote: String {
        if settings.autoSendEnabled {
            return "After the text is typed, Return is pressed so Slack, Messages and mail "
                + "compose windows send it. Turn this off to choose which apps do that."
        }
        if autoSendApps.isEmpty {
            return "Return is not pressed. Add an app to send automatically only there."
        }
        return "Return is pressed only in the apps listed here. Everywhere else you send "
            + "the dictation yourself."
    }

    /// The orb the transcription note carries — `shaping`, a model being fetched and
    /// assembled, and only while that is actually happening. Nothing else on this tab is
    /// work: every other control resolves the instant it is touched. Compare mode is
    /// excluded because its note is about compare mode rather than about the download.
    private var engineWork: OrbGeometry.State? {
        guard !settings.compareMode, settings.engine == .parakeet,
              case .preparing = models.parakeetState
        else { return nil }
        return .shaping
    }

    /// The same, for the cleanup model. Only S1-mini is downloaded; Apple's is already here.
    private var cleanupWork: OrbGeometry.State? {
        guard settings.cleanupEnabled, settings.cleanupEngine == .s1Mini,
              case .preparing = models.s1MiniState
        else { return nil }
        return .shaping
    }

    /// Only the chosen row's consequence, rather than all three at once: the reason to
    /// read this is to find out what the setting you are looking at will do to you.
    private var switchAwayNote: String {
        "Transcribing takes a moment, and you are free to move on inside it. "
            + settings.switchAwayBehavior.explanation
    }

    private var learningNote: String {
        "Any past dictation can be corrected in the list. "
            + settings.dictionaryLearning.explanation
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
                return settings.cleanupFixesGrammar
                    ? "Grammar repair uses Apple's on-device model. S1-mini is the "
                        + "punctuation-only engine; turn grammar off to use it alone."
                    : "S1-mini by Superwhisper punctuates locally through llama.cpp; no "
                        + "transcript leaves this Mac."
            case .preparing(let message): return message
            case .failed(let message): return "S1-mini failed: \(message)"
            case .notDownloaded:
                return "S1-mini by Superwhisper requires a one-time download. Fetch it from the "
                    + "Models tab."
            }
        }
    }
}

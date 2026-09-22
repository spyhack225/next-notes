import AppKit
import SwiftUI

/// Which engine hears you, and what happens to the text before it is typed.
struct DictationSettingsTab: View {
    @State private var settings = Settings.shared
    @State private var models = LocalModelStore.shared
    @State private var runs = RunStore.shared
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
                            "Fixing grammar needs Apple's on-device model, so that is what runs "
                                + "for these dictations. Nothing to change \u{2014} it is picked "
                                + "for you, and nothing leaves this Mac either way.",
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
                    Toggle("Fix grammar and spelling, not just punctuation",
                           isOn: $settings.cleanupFixesGrammar)
                        .help("Repairs agreement, tense, plurals and word order — \"there is "
                              + "some lags\" becomes \"there are some lags\", \"how it walks\" "
                              + "becomes \"how it works\". With this off, only punctuation and "
                              + "capitals are tidied and everything else is typed as heard.")

                    Toggle("Format the lists, quotes and code you speak",
                           isOn: $settings.cleanupFormatsLists)
                        .help("Say \u{201C}first point\u{2026} second point\u{2026}\u{201D}, "
                              + "\u{201C}start the list\u{2026} close the list\u{201D}, "
                              + "\u{201C}quote\u{2026} end quote\u{201D} or \u{201C}start the "
                              + "code\u{2026} end the code\u{201D} and it comes out formatted. "
                              + "Nothing you did not say out loud is turned into a list.")

                    Toggle("Skip the cleanup model when the Mac is busy", isOn: $settings.cleanupSkipsModelWhenBusy)
                        .help("While memory is low, the Mac is hot or in Low Power Mode, or live "
                              + "transcription or meeting notes are using the model, short "
                              + "dictations get quick rule-based cleanup instead of waiting. "
                              + "Faster, but noticeably rougher. Dictations that name a file on "
                              + "screen always use the model.")

                    CleanupPromiseList(rows: promises)
                }
            } header: {
                Text("Cleanup")
            } footer: {
                SettingsNote(text: cleanupNote, orb: cleanupWork)
            }

            if settings.cleanupEnabled, let last = runs.lastCleanup {
                Section {
                    LastCleanupRow(run: last.run, record: last.record)
                } header: {
                    Text("Your last dictation")
                } footer: {
                    SettingsNote(
                        text: "What actually happened to the words you spoke, rather than what "
                            + "the switches above promise. If something here does not match "
                            + "them, this row is the truth."
                    )
                }
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
                    ? "Fixing grammar needs Apple's on-device model, so that runs instead. "
                        + "Either way, no transcript leaves this Mac."
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

    /// What the switches above actually promise, in the order the text passes through them.
    ///
    /// It exists because the switches lied by omission. "Fix grammar" off and "Format spoken
    /// lists" on is a perfectly reachable state, and in it the second switch did nothing
    /// whatsoever — the engine that runs when grammar is off takes no instructions, so the
    /// list rule never reached a model, and an app with no row in the Formatting table was
    /// told to keep lists as prose anyway. Both of those are fixed; this list is how the
    /// person in front of the window can tell.
    private var promises: [CleanupPromiseList.Row] {
        var rows: [CleanupPromiseList.Row] = [
            .init(isOn: true, text: "Fillers, punctuation and capitals are always tidied up.")
        ]

        if settings.cleanupFixesGrammar {
            if let reason = FoundationModelFormatter.unavailableReason {
                rows.append(.init(
                    isOn: false,
                    text: "Grammar and spelling cannot be fixed on this Mac right now. \(reason)"
                ))
            } else {
                rows.append(.init(
                    isOn: true,
                    text: "Grammar, plurals and misheard words are corrected."
                ))
            }
        } else {
            // Actionable, not just informative. This is the line that describes the state
            // this user has actually been dictating in, and telling someone to go and find
            // a switch they have already walked past is not telling them anything.
            rows.append(.init(
                isOn: false,
                text: "Grammar and spelling are left exactly as heard \u{2014} missing plurals, "
                    + "wrong tenses and misheard words stay in.",
                actionTitle: "Fix grammar too",
                action: { settings.cleanupFixesGrammar = true }
            ))
        }

        if settings.cleanupFormatsLists {
            rows.append(.init(
                isOn: true,
                text: "Lists, quotes and code you say out loud become lists, quotes and code "
                    + "\u{2014} in every app, whether or not it shows formatting marks."
            ))
        } else {
            rows.append(.init(
                isOn: false,
                text: "\u{201C}First point\u{2026} second point\u{2026}\u{201D} stays as a "
                    + "sentence. Nothing you speak is turned into a list."
            ))
        }

        if settings.cleanupSkipsModelWhenBusy {
            rows.append(.init(
                isOn: false,
                text: "While the Mac is busy, short dictations skip all of this and get the "
                    + "quick version instead."
            ))
        }
        return rows
    }
}

/// The plain-language consequence of the switches above it, one line each.
///
/// A tick or a dash rather than a colour alone, because "off" here is often the setting the
/// person meant to choose and must not read as an error.
private struct CleanupPromiseList: View {
    struct Row: Identifiable {
        let isOn: Bool
        let text: String
        /// A one-tap way to change what this line says, for a line describing something the
        /// person probably did not mean to choose.
        var actionTitle: String?
        var action: (() -> Void)?
        var id: String { text }
    }

    let rows: [Row]

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            ForEach(rows) { row in
                HStack(alignment: .top, spacing: DS.Space.s) {
                    Image(systemName: row.isOn ? "checkmark.circle.fill" : "minus.circle")
                        .foregroundStyle(row.isOn ? DS.Color.accent : DS.Color.textTertiary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text(row.text)
                            .font(DS.Font.caption)
                            .foregroundStyle(row.isOn ? DS.Color.text : DS.Color.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let title = row.actionTitle, let action = row.action {
                            Button(title, action: action)
                                .buttonStyle(.link)
                                .font(DS.Font.caption)
                        }
                    }
                }
                .accessibilityElement(children: row.action == nil ? .combine : .contain)
                .accessibilityLabel((row.isOn ? "On. " : "Off. ") + row.text)
            }
        }
        .padding(.vertical, DS.Space.xxs)
    }
}

/// The last dictation's cleanup, said in words rather than in fields.
///
/// This is the answer to "check the dictation logs and you will see it does no grammar":
/// before it, `runs.jsonl` stored one string and no version of that question was answerable
/// without a terminal. The two texts are behind a disclosure because most of the time the
/// summary line is the whole answer.
private struct LastCleanupRow: View {
    let run: DictationRun
    let record: CleanupRecord

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                Text(record.plainSummary)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: DS.Space.s)
                Text(run.date, style: .time)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
            }

            if let target = record.targetName {
                Text(renderingNote(target: target))
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if changed {
                DisclosureGroup("Compare what you said with what was typed", isExpanded: $isExpanded) {
                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        labelled("You said", record.rawText)
                        labelled("It typed", record.cleanedText ?? run.text)
                    }
                    .padding(.top, DS.Space.xs)
                }
                .font(DS.Font.caption)
            }
        }
        .padding(.vertical, DS.Space.xxs)
    }

    private var changed: Bool {
        guard let raw = record.rawText else { return false }
        return raw != (record.cleanedText ?? run.text)
    }

    @ViewBuilder
    private func labelled(_ title: String, _ body: String?) -> some View {
        if let body, !body.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(title)
                    .font(DS.Font.caption2)
                    .foregroundStyle(DS.Color.textTertiary)
                Text(body)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func renderingNote(target: String) -> String {
        let renders = record.targetRenders ?? []
        if renders.isEmpty {
            return "Sent to \(target), which shows no formatting marks, so anything you spoke as "
                + "a list was written as plain numbered lines."
        }
        return "Sent to \(target), which shows formatting, so lists and quotes were written the "
            + "way it draws them."
    }
}

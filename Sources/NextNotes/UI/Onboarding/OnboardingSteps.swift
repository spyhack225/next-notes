import AppKit
import SwiftUI

// The seven screens. One file, because they are seven variations on one layout and reading
// them together is the only way to keep the voice consistent.
//
// House rules for every string below:
// - No product of a technology is ever named. No model names, no file formats, no "API",
//   no "TCC", no "function calling", no gigabyte counts dressed up as parameter counts.
// - Each headline is a question the user can answer or a benefit they can want.
// - Each subhead is one sentence saying why, and stops.
// - Nothing is ever required that cannot be undone in Settings afterwards.

// MARK: - 1. Welcome

struct OnboardingWelcomeStep: View {
    let onContinue: () -> Void

    @State private var identity = AgentIdentityStore.shared
    @State private var name = AgentIdentityStore.shared.name
    @State private var avatar = AgentIdentityStore.shared.avatar
    @FocusState private var isNameFocused: Bool

    var body: some View {
        OnboardingScreen(
            symbol: "waveform",
            headline: "Talk, and Next Notes types it",
            subhead: "Hold one key anywhere on your Mac, say what you mean, and the words "
                + "land in whatever you were writing in.",
            primaryTitle: "Get started",
            primary: commit
        ) {
            OnboardingCard {
                HStack(alignment: .center, spacing: DS.Space.m) {
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text("What would you like to call it?")
                            .font(DS.Font.subheadline.weight(.semibold))
                        Text("You can change this whenever you like.")
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.textSecondary)
                    }
                    Spacer(minLength: DS.Space.s)
                    TextField("Name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: DS.Size.settingsFieldWidth / 2)
                        .focused($isNameFocused)
                        .onSubmit(commit)
                        .accessibilityLabel("Assistant's name")
                }
                .padding(.horizontal, DS.Space.m)
                .padding(.vertical, DS.Space.s)
                .frame(minHeight: DS.Onboarding.rowMinHeight)

                OnboardingRowDivider()

                // The face arrives with the name rather than in a settings screen: this is
                // the moment the assistant stops being a feature and becomes somebody's.
                // The portrait is the real animated one, idling — so what is generated
                // here is what will be seen at work.
                HStack(alignment: .center, spacing: DS.Space.m) {
                    AgentAvatarView(config: avatar, state: .idle, size: DS.Size.avatarOnboarding)
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text("Give it a face")
                            .font(DS.Font.subheadline.weight(.semibold))
                        Text("Generate one now. You can make another whenever you like.")
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: DS.Space.s)
                    Button("Generate", systemImage: "dice", action: generate)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityHint("Makes a new look for your assistant")
                }
                .padding(.horizontal, DS.Space.m)
                .padding(.vertical, DS.Space.s)
                .frame(minHeight: DS.Onboarding.rowMinHeight)
            }
        }
    }

    /// Saving an empty field would leave the assistant nameless everywhere it is mentioned,
    /// so an empty field means "keep the one you had" rather than "erase it".
    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != identity.name {
            identity.setDisplayName(trimmed)
        }
        onContinue()
    }

    /// Saved as it is generated, not on Continue: the face on screen is the one that was
    /// chosen, and quitting setup halfway should not throw it away.
    private func generate() {
        avatar = .random()
        identity.setAvatar(avatar)
    }
}

// MARK: - 2. Dictation

struct OnboardingDictationStep: View {
    let controller: DictationController
    let onContinue: () -> Void

    @State private var hasMicrophone = Permissions.hasMicrophone
    @State private var hasAccessibility = Permissions.hasAccessibility
    @State private var isAskingMicrophone = false
    /// Set when the user is sent to System Settings. Only after that, and only after a
    /// decent interval, is the stale-grant explanation offered — showing it up front would
    /// teach somebody that the thing they have not tried yet is broken.
    @State private var sentToSettingsAt: Date?
    @State private var now = Date()
    /// The switch reads as on and the key still will not arm: the signature trap, caught
    /// rather than guessed. See `Permissions.accessibilityRepairAdvice`.
    @State private var isTrustedButNotArmed = false

    var body: some View {
        OnboardingScreen(
            symbol: "mic.fill",
            headline: "Let Next Notes hear you, and type for you",
            subhead: "Two switches in macOS. Next Notes asks; you say yes.",
            primary: onContinue
        ) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                OnboardingCard {
                    OnboardingGrantRow(
                        title: "Microphone",
                        detail: "So it can hear what you say.",
                        symbol: "mic",
                        state: microphoneState,
                        action: askMicrophone
                    )
                    OnboardingRowDivider()
                    OnboardingGrantRow(
                        title: "Typing into other apps",
                        detail: "So your words appear in Mail, Slack, Notes — wherever you "
                            + "were already writing.",
                        symbol: "keyboard",
                        state: accessibilityState,
                        action: askAccessibility
                    )
                }

                if let hint {
                    OnboardingHint(text: hint, symbol: hintSymbol)
                }
            }
        }
        .task { await watch() }
        // macOS says nothing when a switch is flipped in System Settings, so the answer is
        // re-read when the user comes back — and polled while they are still over there,
        // because on a second display they never "come back" at all.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    private var microphoneState: OnboardingGrantState {
        if hasMicrophone { return .done }
        return isAskingMicrophone ? .waiting : .ask
    }

    private var accessibilityState: OnboardingGrantState {
        if hasAccessibility, !isTrustedButNotArmed { return .done }
        return sentToSettingsAt == nil ? .ask : .waiting
    }

    /// The one sentence under the card, or none. Ordered by how stuck the user is.
    private var hint: String? {
        if isTrustedButNotArmed {
            return "macOS says Next Notes is allowed, but the key still isn't working. "
                + Permissions.accessibilityRepairAdvice
        }
        if !hasAccessibility, let sentToSettingsAt,
           now.timeIntervalSince(sentToSettingsAt) > DS.Onboarding.staleGrantHint {
            return "Still waiting. " + Permissions.accessibilityRepairAdvice
        }
        if !hasMicrophone || !hasAccessibility {
            return "You can carry on without these — dictation just won't work until they're on."
        }
        return nil
    }

    private var hintSymbol: String {
        isTrustedButNotArmed || sentToSettingsAt != nil ? "exclamationmark.circle" : "info.circle"
    }

    private func askMicrophone() {
        isAskingMicrophone = true
        Task {
            // The system prompt only ever appears once. After that the pane is the only
            // route, so a refusal opens it rather than doing nothing visible.
            let granted = await Permissions.requestMicrophone()
            if !granted { Permissions.openMicrophoneSettings() }
            isAskingMicrophone = false
            refresh()
        }
    }

    private func askAccessibility() {
        Permissions.promptForAccessibility()
        Permissions.openAccessibilitySettings()
        sentToSettingsAt = Date()
    }

    private func watch() async {
        while !Task.isCancelled {
            now = Date()
            refresh()
            try? await Task.sleep(for: .seconds(DS.Onboarding.poll))
        }
    }

    /// Re-reads both grants, and — the part that matters — tries to actually arm the key.
    ///
    /// `AXIsProcessTrusted()` answering yes is not the same as the event tap starting:
    /// a grant recorded against a previous build of Next Notes keeps its switch on while
    /// the tap refuses. Arming it is the only honest test, and `activate()` is idempotent,
    /// so doing it here costs nothing and turns an invisible failure into a sentence.
    private func refresh() {
        hasMicrophone = Permissions.hasMicrophone
        let trusted = Permissions.hasAccessibility
        hasAccessibility = trusted
        guard trusted else {
            isTrustedButNotArmed = false
            return
        }
        if !controller.hotkeyReady {
            isTrustedButNotArmed = !controller.activate()
        } else {
            isTrustedButNotArmed = false
        }
    }
}

// MARK: - 3. Your shortcut

struct OnboardingShortcutStep: View {
    let controller: DictationController
    let onContinue: () -> Void

    @State private var settings = Settings.shared
    @State private var trial = ""
    @State private var didHearSomething = false
    @FocusState private var isTrialFocused: Bool

    var body: some View {
        OnboardingScreen(
            symbol: "keyboard",
            headline: "Pick your keys",
            subhead: "One to hold while you talk. One to start and stop without holding.",
            primary: onContinue
        ) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                OnboardingCard {
                    OnboardingChoiceRow(
                        title: "Hold to talk",
                        detail: "Hold this key, say something, let go."
                    ) {
                        Picker("", selection: Binding(
                            get: { settings.pushToTalkKey },
                            set: { key in
                                settings.pushToTalkKey = key
                                controller.reloadHotkey()
                            }
                        )) {
                            ForEach(holdChoices, id: \.self) { key in
                                Text(key.displayName).tag(key)
                            }
                        }
                        .accessibilityLabel("Key to hold while talking")
                    }

                    OnboardingRowDivider()

                    OnboardingChoiceRow(
                        title: "Hands-free",
                        detail: "Press once to start talking to your assistant, press again "
                            + "when you're done."
                    ) {
                        Picker("", selection: handsFree) {
                            ForEach(AgentShortcut.allCases) { shortcut in
                                Text(shortcut.displayName).tag(Optional(shortcut))
                            }
                            Text("No shortcut").tag(Optional<AgentShortcut>.none)
                        }
                        .accessibilityLabel("Hands-free shortcut")
                    }
                }

                OnboardingCard {
                    VStack(alignment: .leading, spacing: DS.Space.s) {
                        HStack(spacing: DS.Space.s) {
                            Text("Try it now")
                                .font(DS.Font.subheadline.weight(.semibold))
                            Spacer()
                            if didHearSomething {
                                Label("That's it", systemImage: "checkmark.circle.fill")
                                    .font(DS.Font.caption)
                                    .foregroundStyle(DS.Color.success)
                            } else if controller.state.isActive {
                                ThinkingOrb(state: .breathing, size: DS.Size.orbBadge)
                                    .accessibilityHidden(true)
                            }
                        }
                        TextField(trialPrompt, text: $trial, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(DS.Font.body)
                            .lineLimit(2...3)
                            .focused($isTrialFocused)
                            .disabled(!canTry)
                            .accessibilityLabel("Practice field")
                            .accessibilityHint(trialPrompt)
                        if !canTry {
                            Text("You'll be able to try this once macOS lets Next Notes type "
                                 + "for you — the previous step.")
                                .font(DS.Font.caption)
                                .foregroundStyle(DS.Color.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, DS.Space.m)
                    .padding(.vertical, DS.Space.s)
                }
            }
            .onChange(of: trial) { _, new in
                if !new.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    didHearSomething = true
                }
            }
            .onAppear { isTrialFocused = canTry }
            .animation(DS.Motion.standard, value: didHearSomething)
        }
    }

    /// Dictation types into whatever has focus, and during this step that is the practice
    /// field — so the test is the real thing rather than a simulation of it. It needs the
    /// same grant the previous step asks for.
    private var canTry: Bool { Permissions.hasAccessibility && Permissions.hasMicrophone }

    private var trialPrompt: String {
        "Hold \(settings.pushToTalkKey.spokenName) and say something…"
    }

    /// The two keys must never be the same one; Settings resolves a collision by switching
    /// Command Mode off, which from outside looks like the feature breaking itself. Offering
    /// only the keys that are free makes the collision unreachable instead.
    private var holdChoices: [PushToTalkKey] {
        PushToTalkKey.allCases.filter {
            !settings.commandModeEnabled || $0 != settings.commandModeKey
        }
    }

    /// "No shortcut" is `nil` rather than a fourth case, so the off state is the absence of
    /// a choice rather than a choice that means nothing.
    private var handsFree: Binding<AgentShortcut?> {
        Binding(
            get: { settings.agentShortcutEnabled ? settings.agentShortcut : nil },
            set: { choice in
                if let choice {
                    settings.agentShortcut = choice
                    settings.agentShortcutEnabled = true
                } else {
                    settings.agentShortcutEnabled = false
                }
            }
        )
    }
}

// MARK: - 4. Meetings

struct OnboardingMeetingsStep: View {
    let onContinue: () -> Void
    let onSkip: () -> Void

    @State private var hasCalendar = Permissions.hasCalendar
    @State private var hasNotifications = false
    @State private var isAskingCalendar = false
    @State private var didAskForCallAudio = false

    var body: some View {
        OnboardingScreen(
            symbol: "calendar",
            headline: "Should it sit in on your meetings?",
            subhead: "Next Notes can listen and write the notes, so you don't have to.",
            primary: onContinue,
            skip: onSkip
        ) {
            OnboardingCard {
                OnboardingGrantRow(
                    title: "Your calendar",
                    detail: "So it knows when a meeting is about to start.",
                    symbol: "calendar",
                    state: hasCalendar ? .done : (isAskingCalendar ? .waiting : .ask),
                    action: askCalendar
                )
                OnboardingRowDivider()
                OnboardingGrantRow(
                    title: "The other side of a call",
                    detail: "So the notes have everyone in them, not just you.",
                    symbol: "speaker.wave.2",
                    // macOS offers no way to read this one back, and a tick we cannot stand
                    // behind is worse than no tick at all — so the only tick is evidence: a
                    // tap in this app has delivered real sound.
                    state: Permissions.hasHeardSystemAudio
                        ? .done : (didAskForCallAudio ? .waiting : .unknowable),
                    actionTitle: "Allow",
                    action: askCallAudio
                )
                OnboardingRowDivider()
                OnboardingGrantRow(
                    title: "A quiet heads-up",
                    detail: "A small note when a meeting starts recording, and when its "
                        + "notes are ready.",
                    symbol: "bell",
                    state: hasNotifications ? .done : .ask,
                    action: askNotifications
                )
            }
        }
        .task { await watch() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    private func askCalendar() {
        isAskingCalendar = true
        Task {
            let granted = await Permissions.requestCalendar()
            if !granted { Permissions.openCalendarSettings() }
            isAskingCalendar = false
            refresh()
        }
    }

    /// Opening a tap is what raises the prompt — there is no request API for this one — and
    /// the pane follows because a decision macOS has already made will never prompt again.
    private func askCallAudio() {
        Permissions.requestSystemAudio()
        Permissions.openSystemAudioSettings()
        didAskForCallAudio = true
    }

    private func askNotifications() {
        Task {
            let granted = await Notifications.shared.requestAuthorization()
            if !granted { Permissions.openNotificationSettings() }
            refresh()
        }
    }

    private func watch() async {
        while !Task.isCancelled {
            refresh()
            try? await Task.sleep(for: .seconds(DS.Onboarding.poll))
        }
    }

    private func refresh() {
        hasCalendar = Permissions.hasCalendar
        Task { hasNotifications = await Notifications.shared.isAuthorized() }
    }
}

// MARK: - 5. Files

struct OnboardingFilesStep: View {
    let onContinue: () -> Void
    let onSkip: () -> Void

    @State private var store = IndexedFoldersStore.shared

    var body: some View {
        OnboardingScreen(
            symbol: "folder",
            headline: "Let your assistant find your files",
            subhead: "Ask for something by name instead of hunting through folders. "
                + "Nothing is sent anywhere — it all stays on this Mac.",
            primary: onContinue,
            skip: onSkip
        ) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                OnboardingCard {
                    ForEach(Array(IndexedFoldersStore.suggested.enumerated()), id: \.element) { index, folder in
                        if index > 0 { OnboardingRowDivider() }
                        OnboardingToggleRow(
                            title: folder.lastPathComponent,
                            detail: "",
                            symbol: "folder",
                            isOn: binding(for: folder)
                        )
                    }

                    ForEach(extraFolders, id: \.self) { folder in
                        OnboardingRowDivider()
                        OnboardingToggleRow(
                            title: folder.lastPathComponent,
                            detail: folder.deletingLastPathComponent().path,
                            symbol: "folder",
                            isOn: binding(for: folder)
                        )
                    }

                    OnboardingRowDivider()

                    HStack {
                        Button("Add a folder…", action: chooseFolder)
                            .buttonStyle(.link)
                        Spacer()
                    }
                    .padding(.horizontal, DS.Space.m)
                    .padding(.vertical, DS.Space.s)
                    .frame(minHeight: DS.Onboarding.rowMinHeight)
                }

                OnboardingHint(
                    text: "macOS may ask you to confirm the first time your assistant looks "
                        + "in one of these. That's normal — say yes.",
                    symbol: "hand.raised"
                )
            }
        }
    }

    /// Folders the user added by hand, kept apart from the three offered by default so the
    /// list does not show the same folder twice.
    private var extraFolders: [URL] {
        let suggested = Set(IndexedFoldersStore.suggested.map(\.path))
        // `store.revision` is read so the list redraws when a folder is added or removed.
        _ = store.revision
        return store.folders.filter { !suggested.contains($0.path) }
    }

    /// One folder's switch. Turning the first one on also turns on the master switch: from
    /// the user's side there is one decision here, not two.
    private func binding(for folder: URL) -> Binding<Bool> {
        Binding(
            get: {
                _ = store.revision
                return store.isEnabled && store.folders.contains { $0.path == folder.path }
            },
            set: { isOn in
                if isOn {
                    if !store.isEnabled { store.isEnabled = true }
                    store.add(folder)
                } else {
                    store.remove(folder)
                }
            }
        )
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add"
        panel.message = "Pick a folder your assistant may look through."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !store.isEnabled { store.isEnabled = true }
        store.add(url)
    }
}

// MARK: - 6. Your assistant's brain

struct OnboardingBrainStep: View {
    let onContinue: () -> Void

    @State private var models = LocalModelStore.shared
    /// Free space. Re-read while the screen is up, because "free some space and Next Notes
    /// will pick this up" is only true if something is actually looking — a user who empties
    /// the Bin in the next window must not have to come back through setup.
    @State private var freeBytes = ModelDownloader.availableDiskBytes()

    var body: some View {
        OnboardingScreen(
            symbol: "sparkles",
            headline: headline,
            subhead: subhead,
            primaryTitle: "Continue",
            primary: onContinue
        ) {
            OnboardingCard {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    if hasRoom {
                        ProgressView(value: fraction) {
                            Text(statusLine)
                                .font(DS.Font.subheadline)
                        }
                        .progressViewStyle(.linear)
                        .frame(width: DS.Onboarding.barWidth)
                        .accessibilityLabel("Setting up your assistant")
                        .accessibilityValue(statusLine)
                    } else {
                        Label(statusLine, systemImage: "externaldrive.badge.exclamationmark")
                            .font(DS.Font.subheadline)
                            .foregroundStyle(DS.Color.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text(footnote)
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DS.Space.m)
                .padding(.vertical, DS.Space.m)
            }
        }
        .task { await watch() }
        .animation(DS.Motion.standard, value: statusLine)
    }

    private var headline: String {
        hasRoom ? "Setting up your assistant" : "Your Mac is nearly full"
    }

    private var subhead: String {
        hasRoom
            ? "This is the part that understands you and writes your notes. It lives on "
                + "this Mac and never leaves it."
            : "Next Notes needs a little room for the part that understands you. Everything "
                + "else already works."
    }

    /// Whether there is room, in the terms `ModelDownloader` itself refuses on — so the
    /// screen never promises a download that the downloader will then decline.
    private var hasRoom: Bool {
        isReady || freeBytes >= neededBytes + ModelDownloader.minimumFreeBytesAfterDownload
    }

    private var neededBytes: Int64 { NotesModels.spec.expectedBytes }

    private var isReady: Bool {
        if case .ready = models.notesModelState { return true }
        return false
    }

    /// The one line the user reads. Never the store's own message: that one names the model
    /// and its file size, which is exactly the vocabulary this flow exists to avoid.
    private var statusLine: String {
        if !hasRoom {
            let short = neededBytes + ModelDownloader.minimumFreeBytesAfterDownload - freeBytes
            return "About \(bytes(short)) more free space is needed."
        }
        switch models.notesModelState {
        case .ready:
            return "Ready."
        case .notDownloaded:
            return "Starting…"
        case .failed:
            // True, and only since `OnboardingModelResume` existed: reaching this screen is
            // what makes the app pick the transfer up again by itself.
            return "That didn't finish. Next Notes will try again on its own."
        case .preparing(let message):
            if let percent = Self.percentage(in: message) {
                return "Setting up… \(Int((percent * 100).rounded()))%"
            }
            return "Setting up…"
        }
    }

    private var fraction: Double {
        if isReady { return 1 }
        if case .preparing(let message) = models.notesModelState,
           let percent = Self.percentage(in: message) {
            return percent
        }
        return 0
    }

    private var footnote: String {
        if !hasRoom {
            return "Free some space and Next Notes will pick this up on its own. "
                + "Dictation works in the meantime."
        }
        if isReady { return "All set. Nothing you say is sent anywhere." }
        if case .failed = models.notesModelState {
            return "Dictation works in the meantime. Next Notes tries again each time you "
                + "come back to it, and Settings has a button if you'd rather not wait."
        }
        return "About \(bytes(neededBytes)), once. Carry on — this finishes in the background."
    }

    /// Re-reads the disk while the screen is on, and starts as soon as there is room.
    ///
    /// Cancelled when the screen goes away, so this is a while-you-are-looking loop rather
    /// than a timer the app carries around. Once setup has been through here,
    /// `OnboardingModelResume` takes over for good.
    private func watch() async {
        while !Task.isCancelled {
            freeBytes = ModelDownloader.availableDiskBytes()
            start()
            try? await Task.sleep(for: .seconds(DS.Onboarding.poll))
        }
    }

    /// Starts the download, unless it is already done, already running, already failed, or
    /// there is no room.
    ///
    /// A failed transfer is deliberately not retried from here: the loop above runs every
    /// couple of seconds, and a screen that reconnected that often would be hammering a
    /// network that has just told it no. Retrying is `OnboardingModelResume`'s job, on its
    /// own interval.
    ///
    /// Never under a self-test: a first run must not be able to pull gigabytes onto a
    /// machine that only asked a question about a state machine.
    private func start() {
        guard !SelfTest.isRunning, hasRoom else { return }
        if case .notDownloaded = models.notesModelState {
            models.prepareNotesModel()
        }
        // The speech model only when it is the one dictation will actually use — the other
        // engine is built into macOS and has nothing to fetch.
        if Settings.shared.engine == .parakeet || Settings.shared.compareMode,
           case .notDownloaded = models.parakeetState {
            models.prepareParakeet()
        }
    }

    private func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, count), countStyle: .file)
    }

    /// Pulls the percentage out of the store's progress message and throws the rest away.
    static func percentage(in message: String) -> Double? {
        guard let range = message.range(of: "[0-9]{1,3}%", options: .regularExpression),
              let value = Double(message[range].dropLast())
        else { return nil }
        return min(1, max(0, value / 100))
    }
}

// MARK: - 7. All set

struct OnboardingAllSetStep: View {
    let assistantName: String
    let controller: DictationController
    /// Read for what the user passed over, so the ending never names a thing they declined.
    let model: OnboardingModel
    let onDone: () -> Void

    @State private var settings = Settings.shared
    @State private var problem: String?
    @State private var hasMicrophone = Permissions.hasMicrophone
    @State private var hasAccessibility = Permissions.hasAccessibility
    @State private var isTypingBlocked = false
    @State private var hasCalendar = Permissions.hasCalendar
    @State private var folders = IndexedFoldersStore.shared

    var body: some View {
        OnboardingScreen(
            symbol: outcome.canDictate ? "checkmark.circle.fill" : "exclamationmark.circle",
            headline: outcome.headline,
            subhead: outcome.subhead,
            primaryTitle: "Done",
            primary: onDone
        ) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                OnboardingCard {
                    ForEach(Array(outcome.tips.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { OnboardingRowDivider() }
                        tip(row)
                    }
                }

                OnboardingCard {
                    OnboardingToggleRow(
                        title: "Open Next Notes when I log in",
                        detail: "So it's ready without you having to think about it.",
                        symbol: "power",
                        isOn: Binding(
                            get: { settings.agentLaunchAtLogin },
                            set: { enabled in
                                settings.agentLaunchAtLogin = enabled
                                problem = LaunchAtLogin.apply(enabled)
                            }
                        )
                    )
                }

                if let problem {
                    OnboardingHint(text: problem, symbol: "exclamationmark.circle")
                }
            }
        }
        .task { await watch() }
        // Somebody who reads the last screen, realises a switch is off and goes to fix it
        // comes back to a screen that already knows.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
        .animation(DS.Motion.standard, value: outcome)
    }

    /// What setup actually achieved, read rather than assumed. The old version of this
    /// screen congratulated everybody identically — see `OnboardingOutcome`.
    private var outcome: OnboardingOutcome {
        // Read so this summary follows a folder being added or removed.
        _ = folders.revision
        return .live(
            assistantName: assistantName,
            hasMicrophone: hasMicrophone,
            hasAccessibility: hasAccessibility,
            isTypingBlocked: isTypingBlocked,
            hasCalendar: hasCalendar,
            model: model,
            settings: settings,
            folders: folders
        )
    }

    private func watch() async {
        while !Task.isCancelled {
            refresh()
            try? await Task.sleep(for: .seconds(DS.Onboarding.poll))
        }
    }

    /// The same honest test the dictation screen makes: trusted is not the same as armed,
    /// and only an armed key is dictation.
    private func refresh() {
        hasMicrophone = Permissions.hasMicrophone
        hasCalendar = Permissions.hasCalendar
        let trusted = Permissions.hasAccessibility
        hasAccessibility = trusted
        guard trusted else {
            isTypingBlocked = false
            return
        }
        isTypingBlocked = controller.hotkeyReady ? false : !controller.activate()
    }

    private func tip(_ row: OnboardingTip) -> some View {
        HStack(alignment: .center, spacing: DS.Space.m) {
            Image(systemName: row.symbol)
                .font(DS.Font.body)
                .foregroundStyle(row.isOutstanding ? DS.Color.warning : DS.Color.accent)
                .frame(width: DS.Size.iconLarge)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(row.title)
                    .font(DS.Font.subheadline.weight(.semibold))
                Text(row.detail)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s)
        .frame(minHeight: DS.Onboarding.rowMinHeight)
        .accessibilityElement(children: .combine)
    }
}

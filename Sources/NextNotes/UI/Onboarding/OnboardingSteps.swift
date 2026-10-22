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
    @Environment(\.onboardingVisualFixture) private var visualFixture
    let onContinue: () -> Void

    @State private var identity = AgentIdentityStore.shared
    @State private var name = AgentIdentityStore.shared.name
    @State private var avatar = AgentIdentityStore.shared.avatar
    @FocusState private var isNameFocused: Bool

    var body: some View {
        OnboardingScreen(
            symbol: "waveform",
            headline: "Your companion.",
            headlineAccent: "Home and work.",
            subhead: "One familiar companion on your Mac—for your words, meetings, "
                + "and the things you want to get done.",
            primaryTitle: "Get started",
            primary: commit
        ) {
            OnboardingFigure(scene: .welcome)
            // Put the default privacy promise before the optional identity choices,
            // so it is readable at the initial scroll position of the setup window.
            OnboardingHint(
                text: "No account needed. Your words stay on this Mac by default.",
                symbol: "lock"
            )

            OnboardingCard {
                HStack(alignment: .center, spacing: DS.Space.m) {
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text("What would you like to call your companion?")
                            .font(DS.Font.subheadline.weight(.semibold))
                        Text("You can change this whenever you like.")
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Theme.Palette.mutedForeground)
                    }
                    Spacer(minLength: DS.Space.s)
                    TextField("Name", text: visualFixture == nil ? $name : .constant("Next"))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: DS.Size.settingsFieldWidth / 2)
                        .focused($isNameFocused)
                        .onSubmit(commit)
                        .accessibilityLabel("Companion's name")
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
                    AgentAvatarView(config: visualFixture == nil ? avatar : .default, state: .idle, size: DS.Size.avatarOnboarding)
                    VStack(alignment: .leading, spacing: DS.Space.xxs) {
                        Text("Give it a face")
                            .font(DS.Font.subheadline.weight(.semibold))
                        Text("Generate one now. You can make another whenever you like.")
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Theme.Palette.mutedForeground)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: DS.Space.s)
                    Button("Generate", systemImage: "dice", action: generate)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityHint("Makes a new look for your companion")
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
            // A fresh name earns its face deterministically: same name, same face,
            // every launch. An already-chosen face (Generate pressed) is never
            // overwritten by typing.
            if avatar == .default {
                avatar = .forName(trimmed)
                identity.setAvatar(avatar)
            }
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
    @Environment(\.onboardingVisualFixture) private var visualFixture
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
            headline: "Let Next Notes hear you.",
            headlineAccent: "And type for you.",
            subhead: "Two switches in macOS. Next Notes asks; you say yes.",
            primary: onContinue
        ) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                OnboardingFigure(scene: .dictation)
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
        .task {
            guard visualFixture == nil else { return }
            await watch()
        }
        // macOS says nothing when a switch is flipped in System Settings, so the answer is
        // re-read when the user comes back — and polled while they are still over there,
        // because on a second display they never "come back" at all.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard visualFixture == nil else { return }
            refresh()
        }
    }

    private var microphoneState: OnboardingGrantState {
        if let visualFixture { return visualFixture.hasPermissions ? .done : .ask }
        if hasMicrophone { return .done }
        return isAskingMicrophone ? .waiting : .ask
    }

    private var accessibilityState: OnboardingGrantState {
        if let visualFixture { return visualFixture.hasPermissions ? .done : .ask }
        if hasAccessibility, !isTrustedButNotArmed { return .done }
        return sentToSettingsAt == nil ? .ask : .waiting
    }

    /// The one sentence under the card, or none. Ordered by how stuck the user is.
    private var hint: String? {
        if let visualFixture {
            return visualFixture.hasPermissions ? nil : "You can carry on without these — dictation just won’t work until they’re on."
        }
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
    @Environment(\.onboardingVisualFixture) private var visualFixture
    let controller: DictationController
    let onContinue: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var settings = Settings.shared
    @State private var trial = ""
    @State private var practice = OnboardingPracticeReceipt()
    @State private var practiceObserverID = UUID()
    @FocusState private var isTrialFocused: Bool

    var body: some View {
        OnboardingScreen(
            symbol: "keyboard",
            headline: "Pick",
            headlineAccent: "your keys.",
            subhead: "One to hold while you talk. One to start and stop without holding.",
            primary: onContinue
        ) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                OnboardingFigure(scene: .shortcut)
                OnboardingCard {
                    OnboardingChoiceRow(
                        title: "Hold to talk",
                        detail: "Hold this key, say something, let go."
                    ) {
                        Picker("", selection: Binding(
                            get: { visualFixture == nil ? settings.pushToTalkKey : .fn },
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
                            if practice.hasDeliveredWords {
                                Label("Nice — your words landed here", systemImage: "checkmark.circle.fill")
                                    .font(DS.Font.caption)
                                    .foregroundStyle(DS.Color.success)
                            } else if controller.state.isActive {
                                // The hold's real stage, in the same words the dictation pane
                                // and HUD use for it — never a delivery claim. Success still
                                // waits on the controller's actual insertion receipt, so this
                                // is progress, not proof.
                                HStack(spacing: DS.Space.s) {
                                    Text(practiceLiveStatus)
                                        .font(DS.Font.caption)
                                        .foregroundStyle(DS.Theme.Palette.mutedForeground)
                                    ThinkingOrb(state: practiceLiveOrb, size: DS.Size.orbBadge)
                                        .accessibilityHidden(true)
                                }
                                .accessibilityElement(children: .combine)
                                .accessibilityLabel(practiceLiveStatus)
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
                                .foregroundStyle(DS.Theme.Palette.mutedForeground)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text("Every take also lands in History. Find them under Dictation.")
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Theme.Palette.mutedForeground)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.horizontal, DS.Space.m)
                    .padding(.vertical, DS.Space.s)
                }
            }
            .onAppear {
                guard visualFixture == nil else { return }
                practice.beginObserving(latestDeliveryID: controller.latestDelivery?.id)
                controller.observeHoldBeginnings(owner: practiceObserverID) { id in
                    practice.beganHold(
                        id: id, inPracticeField: isTrialFocused, fieldText: trial
                    )
                }
                isTrialFocused = canTry
            }
            .onDisappear {
                guard visualFixture == nil else { return }
                controller.stopObservingHoldBeginnings(owner: practiceObserverID)
            }
            .onChange(of: controller.latestDelivery) { _, _ in consumePracticeDelivery() }
            .onChange(of: trial) { _, _ in consumePracticeDelivery() }
            .animation(reduceMotion ? nil : DS.Motion.standard, value: practice.hasDeliveredWords)
        }
    }

    /// Dictation types into whatever has focus, and during this step that is the practice
    /// field — so the test is the real thing rather than a simulation of it. It needs the
    /// same grant the previous step asks for.
    private var canTry: Bool { visualFixture?.hasPermissions ?? (Permissions.hasAccessibility && Permissions.hasMicrophone) }

    private func consumePracticeDelivery() {
        guard visualFixture == nil else { return }
        guard let delivery = controller.latestDelivery else { return }
        practice.received(
            id: delivery.id, text: delivery.text, inserted: delivery.kind == .inserted,
            fieldText: trial
        )
    }

    private var trialPrompt: String {
        "Hold \(visualFixture == nil ? settings.pushToTalkKey.spokenName : PushToTalkKey.fn.spokenName) and say something…"
    }

    /// What the practice card says while a hold is running: the controller's actual
    /// stage, with capture (not just `.starting`) deciding between setup and
    /// listening — the same rule `DictationStatusBand` reads.
    private var practiceLiveStatus: String {
        switch controller.state {
        case .listening: "Listening…"
        case .starting: controller.isCapturingAudio ? "Listening…" : "Getting ready…"
        case .finishing: "Finishing…"
        case .idle, .error: ""
        }
    }

    private var practiceLiveOrb: OrbGeometry.State {
        switch controller.state {
        case .listening: .listening
        case .starting: controller.isCapturingAudio ? .listening : .working
        case .finishing: .working
        case .idle, .error: .breathing
        }
    }

    /// The two keys must never be the same one; Settings resolves a collision by switching
    /// Command Mode off, which from outside looks like the feature breaking itself. Offering
    /// only the keys that are free makes the collision unreachable instead.
    private var holdChoices: [PushToTalkKey] {
        if visualFixture != nil { return PushToTalkKey.allCases }
        return PushToTalkKey.allCases.filter {
            !settings.commandModeEnabled || $0 != settings.commandModeKey
        }
    }

    /// "No shortcut" is `nil` rather than a fourth case, so the off state is the absence of
    /// a choice rather than a choice that means nothing.
    private var handsFree: Binding<AgentShortcut?> {
        if visualFixture != nil { return .constant(nil) }
        return Binding(
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

/// A practice success needs both a real delivery receipt and the words in this field.
/// Manual typing, an old receipt, clipboard delivery and a hold begun elsewhere cannot
/// produce a congratulation. The controller's actual insertion outcome supplies the receipt;
/// neither dictation history nor the usage log is evidence that the words arrived here.
struct OnboardingPracticeReceipt: Equatable {
    private(set) var hasDeliveredWords = false
    private var baselineDeliveryID: UUID?
    private var holdID: UUID?
    private var holdBeganInPractice = false
    private var fieldTextBeforeHold = ""

    mutating func beginObserving(latestDeliveryID: UUID?) {
        baselineDeliveryID = latestDeliveryID
        holdID = nil
        holdBeganInPractice = false
        hasDeliveredWords = false
    }

    mutating func beganHold(id: UUID, inPracticeField: Bool, fieldText: String = "") {
        holdID = id
        holdBeganInPractice = inPracticeField
        fieldTextBeforeHold = fieldText
    }

    mutating func received(
        id: UUID, text: String, inserted: Bool, fieldText: String
    ) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id != baselineDeliveryID, id == holdID, holdBeganInPractice, inserted,
              !words.isEmpty, fieldText != fieldTextBeforeHold,
              fieldText.contains(text) else { return }
        hasDeliveredWords = true
    }
}

// MARK: - 4. Meetings

struct OnboardingMeetingsStep: View {
    @Environment(\.onboardingVisualFixture) private var visualFixture
    let onContinue: () -> Void
    let onSkip: () -> Void

    @State private var hasCalendar = Permissions.hasCalendar
    @State private var hasNotifications = false
    @State private var isAskingCalendar = false
    @State private var didAskForCallAudio = false
    /// The real calendar store, read for the post-grant beat below. Same pattern as
    /// the Meetings list — observed, never written from here.
    @State private var calendar = CalendarService.shared

    var body: some View {
        OnboardingScreen(
            symbol: "calendar",
            headline: "Should it sit in on",
            headlineAccent: "your meetings?",
            subhead: "Next Notes can listen and write the notes, so you don't have to.",
            primary: onContinue,
            skip: onSkip
        ) {
            OnboardingFigure(scene: .meetings)
            OnboardingCard {
                OnboardingGrantRow(
                    title: "Your calendar",
                    detail: "So it knows when a meeting is about to start.",
                    symbol: "calendar",
                    state: (visualFixture?.hasPermissions ?? hasCalendar) ? .done : (isAskingCalendar ? .waiting : .ask),
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
                    state: (visualFixture?.hasPermissions ?? Permissions.hasHeardSystemAudio)
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
                    state: (visualFixture?.hasPermissions ?? hasNotifications) ? .done : .ask,
                    action: askNotifications
                )
            }

            // Post-grant, and only from the real store: the soonest event
            // `CalendarService` actually holds. No event, no beat — nothing invented.
            if let beat {
                OnboardingHint(text: beat, symbol: "calendar")
                    .padding(.top, DS.Space.m)
            }
        }
        .task {
            guard visualFixture == nil else { return }
            await watch()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard visualFixture == nil else { return }
            refresh()
        }
    }

    /// The post-grant beat: the soonest event the real calendar store holds, in
    /// plain words. Nil unless the grant is in hand, the store has actually been
    /// read, and an event is there — an empty or unread store shows nothing, so
    /// this screen can never name a meeting nobody has.
    private var beat: String? {
        // Diagnostic captures never display the owner’s calendar events.
        guard visualFixture == nil else { return nil }
        guard hasCalendar, calendar.lastRefresh != nil,
              let next = CalendarService.nextEvent(in: calendar.upcoming)
        else { return nil }
        let when = next.start.formatted(date: .abbreviated, time: .shortened)
        return "Next up: \(next.title) — \(when). Nothing records unless you choose it."
    }

    private func askCalendar() {
        isAskingCalendar = true
        Task {
            let granted = await Permissions.requestCalendar()
            if !granted {
                Permissions.openCalendarSettings()
            } else {
                // The beat above reads the real store, so read it: granting usually
                // refreshes through the store's own observer, but the beat must not
                // depend on usually.
                await CalendarService.shared.refresh()
            }
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
    @Environment(\.onboardingVisualFixture) private var visualFixture
    let onContinue: () -> Void
    let onSkip: () -> Void

    @State private var store = IndexedFoldersStore.shared

    var body: some View {
        OnboardingScreen(
            symbol: "folder",
            headline: "Let your companion find",
            headlineAccent: "your files.",
            subhead: "Ask for something by name instead of hunting through folders. "
                + "Nothing is sent anywhere — it all stays on this Mac.",
            primary: onContinue,
            skip: onSkip
        ) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                OnboardingFigure(scene: .files)
                OnboardingCard {
                    ForEach(Array(suggestedFolders.enumerated()), id: \.element) { index, folder in
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
    private var suggestedFolders: [URL] {
        visualFixture?.folders ?? IndexedFoldersStore.suggested
    }

    private var extraFolders: [URL] {
        if visualFixture != nil { return [] }
        let suggested = Set(IndexedFoldersStore.suggested.map(\.path))
        // `store.revision` is read so the list redraws when a folder is added or removed.
        _ = store.revision
        return store.folders.filter { !suggested.contains($0.path) }
    }

    /// One folder's switch. Turning the first one on also turns on the master switch: from
    /// the user's side there is one decision here, not two.
    private func binding(for folder: URL) -> Binding<Bool> {
        if visualFixture != nil { return .constant(false) }
        return Binding(
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
    @Environment(\.onboardingVisualFixture) private var visualFixture
    let onContinue: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var models = LocalModelStore.shared
    /// Free space. Re-read while the screen is up, because "free some space and Next Notes
    /// will pick this up" is only true if something is actually looking — a user who empties
    /// the Bin in the next window must not have to come back through setup.
    @State private var freeBytes = ModelDownloader.availableDiskBytes()

    var body: some View {
        OnboardingScreen(
            symbol: "sparkles",
            // Once the model is on disk the setup is over even though the screen
            // is still up: saying "Setting up" beside a full bar and "Ready."
            // reads as a stuck download. The done headline names the state.
            headline: isReady ? "Your companion is" : (hasRoom ? "Setting up" : "Your Mac is"),
            headlineAccent: isReady ? "ready." : (hasRoom ? "your companion." : "nearly full."),
            subhead: subhead,
            primaryTitle: "Continue",
            primary: onContinue
        ) {
            OnboardingFigure(scene: .brain)
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
                        .foregroundStyle(DS.Theme.Palette.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DS.Space.m)
                .padding(.vertical, DS.Space.m)
            }
        }
        .task {
            guard visualFixture == nil else { return }
            await watch()
        }
        .animation(reduceMotion ? nil : DS.Motion.standard, value: statusLine)
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
        if visualFixture != nil { return true }
        return isReady || freeBytes >= neededBytes + ModelDownloader.minimumFreeBytesAfterDownload
    }

    private var neededBytes: Int64 { NotesModels.spec.expectedBytes }

    private var isReady: Bool {
        if visualFixture != nil { return false }
        if hasSharedBrain { return true }
        if case .ready = models.notesModelState { return true }
        return false
    }

    /// Owner decision 2026-10-04: the MiniCPM file, when it is already here, is the brain
    /// every role defaults to — so setup is done and the built-in model is not fetched.
    private var hasSharedBrain: Bool { ModelRoleStore.shared.sharedLocalModelID != nil }

    /// The one line the user reads. Never the store's own message: that one names the model
    /// and its file size, which is exactly the vocabulary this flow exists to avoid.
    private var statusLine: String {
        if visualFixture != nil { return "Setting up…" }
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
        if visualFixture != nil { return 0 }
        if isReady { return 1 }
        if case .preparing(let message) = models.notesModelState,
           let percent = Self.percentage(in: message) {
            return percent
        }
        return 0
    }

    private var footnote: String {
        if visualFixture != nil { return "Carry on — this finishes in the background." }
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
        if !hasSharedBrain, case .notDownloaded = models.notesModelState {
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
    @Environment(\.onboardingVisualFixture) private var visualFixture
    let assistantName: String
    let controller: DictationController
    /// Read for what the user passed over, so the ending never names a thing they declined.
    let model: OnboardingModel
    let onDone: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            headline: outcome.canDictate ? "You’re" : "Nearly",
            headlineAccent: outcome.canDictate ? "all set." : "there.",
            subhead: outcome.subhead,
            primaryTitle: "Done",
            primary: onDone
        ) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                OnboardingFigure(scene: .allSet)
                OnboardingCard {
                    ForEach(Array(outcome.tips.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { OnboardingRowDivider() }
                        tip(row)
                    }
                }

                // The follow-through shape: ask → approve → done, labelled as the
                // example it is. Static — no button here acts, and nothing here is
                // the owner's data.
                OnboardingExampleCard()

                // First door: where they want to begin. Setup is done either way —
                // these finish first run and open the chosen section, so the same
                // seven screens end at a different door for each person.
                OnboardingCard {
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        Text("Where to begin?")
                            .font(DS.Font.subheadline.weight(.semibold))
                        Text("Setup is done. Open the door you want first.")
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Theme.Palette.mutedForeground)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: DS.Space.s) {
                            intentButton("Dictate", section: .dictation)
                            intentButton("Ask", section: .agent)
                            intentButton("Meetings", section: .meetings)
                        }
                    }
                    .padding(.horizontal, DS.Space.m)
                    .padding(.vertical, DS.Space.s)
                }

                OnboardingCard {
                    OnboardingToggleRow(
                        title: "Open Next Notes when I log in",
                        detail: "So it's ready without you having to think about it.",
                        symbol: "power",
                        isOn: Binding(
                            get: { visualFixture == nil ? settings.agentLaunchAtLogin : false },
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
        .task {
            guard visualFixture == nil else { return }
            await watch()
        }
        // Somebody who reads the last screen, realises a switch is off and goes to fix it
        // comes back to a screen that already knows.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard visualFixture == nil else { return }
            refresh()
        }
        .animation(reduceMotion ? nil : DS.Motion.standard, value: outcome)
    }

    /// What setup actually achieved, read rather than assumed. The old version of this
    /// screen congratulated everybody identically — see `OnboardingOutcome`.
    private var outcome: OnboardingOutcome {
        if let visualFixture { return visualFixture.outcome }
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

    /// A first door out of setup: finishes first run and opens the chosen section
    /// in the main window. Module policy may resolve a disabled section elsewhere —
    /// that is the honest landing, not a second promise.
    private func intentButton(_ title: String, section: SidebarSection) -> some View {
        Button(title) {
            NavigationState.shared.selectedSection = section
            onDone()
        }
        .buttonStyle(.bordered)
    }

    private func tip(_ row: OnboardingTip) -> some View {        HStack(alignment: .center, spacing: DS.Space.m) {
            Image(systemName: row.symbol)
                .font(DS.Font.body)
                .foregroundStyle(row.isOutstanding ? DS.Color.warning : DS.Theme.Palette.foreground)
                .frame(width: DS.Size.iconLarge)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(row.title)
                    .font(DS.Font.subheadline.weight(.semibold))
                Text(row.detail)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Theme.Palette.mutedForeground)
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

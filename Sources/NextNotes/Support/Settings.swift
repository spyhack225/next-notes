import Foundation
import Observation

/// Which speech engine transcribes an utterance.
enum SpeechEngineChoice: String, CaseIterable, Sendable {
    case apple
    case parakeet

    var displayName: String {
        switch self {
        case .apple: "Apple (streaming)"
        case .parakeet: "Parakeet (batch)"
        }
    }

    /// Apple shows text while you talk; Parakeet only resolves on release.
    var showsLiveText: Bool { self == .apple }
}

/// Which local model performs the semantic cleanup pass.
enum CleanupEngineChoice: String, CaseIterable, Sendable {
    case apple
    case s1Mini

    var displayName: String {
        switch self {
        case .apple: "Apple Foundation Model"
        case .s1Mini: "S1-mini by Superwhisper"
        }
    }
}

/// User-facing tone names. S1-mini has four trained control values; `balanced` deliberately
/// maps to its recommended `semi-formal` register rather than inventing an unsupported token.
enum CleanupTone: String, CaseIterable, Sendable {
    case casual
    case semiCasual
    case balanced
    case semiFormal
    case formal

    var displayName: String {
        switch self {
        case .casual: "Casual"
        case .semiCasual: "Semi-casual"
        case .balanced: "Balanced"
        case .semiFormal: "Semi-formal"
        case .formal: "Formal"
        }
    }

    var s1MiniValue: String {
        switch self {
        case .casual: "casual"
        case .semiCasual: "semi-casual"
        case .balanced, .semiFormal: "semi-formal"
        case .formal: "formal"
        }
    }
}

/// Where the app shows what it is hearing while you dictate.
/// What to do when the user switches apps while a dictation is still being transcribed.
///
/// The tail between releasing the key and having text to insert is seconds long — drain,
/// transcribe, then cleanup — and the user is free to walk away inside it. Something has to
/// happen to that text, and which thing is genuinely a matter of taste: interrupting to
/// deliver it, or holding it somewhere safe.
enum SwitchAwayBehavior: String, CaseIterable, Sendable, Identifiable {
    /// Bring the original app back to the front and type it there.
    case returnToApp
    /// Type it wherever the caret happens to be now.
    case insertWhereFocused
    /// Copy it and leave the front app alone.
    case copyToClipboard

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .returnToApp: "Switch back and insert it"
        case .insertWhereFocused: "Insert it wherever I am"
        case .copyToClipboard: "Copy it to the clipboard"
        }
    }

    var explanation: String {
        switch self {
        case .returnToApp:
            "The app you dictated into comes back to the front. This interrupts whatever "
                + "you moved on to, which is the price of the text arriving where you meant it."
        case .insertWhereFocused:
            "Whatever you have moved to receives the text. If that is not a text field, "
                + "the dictation is lost — this is how Next Notes behaved before the setting "
                + "existed."
        case .copyToClipboard:
            "Nothing is typed and nothing is interrupted; press ⌘V when you are ready. "
                + "Your previous clipboard contents are replaced."
        }
    }
}

/// What to do with the corrections implied by editing a past transcript.
enum DictionaryLearning: String, CaseIterable, Sendable, Identifiable {
    /// Show what was learned and let the user pick. The default, because a dictionary rule
    /// applies to every future transcript and a wrong one is quietly expensive.
    case ask
    /// Trust the edit and file it.
    case automatic
    /// Edit the transcript, learn nothing from it.
    case off

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ask: "Ask before adding it"
        case .automatic: "Add it to the dictionary"
        case .off: "Don't learn from edits"
        }
    }

    var explanation: String {
        switch self {
        case .ask:
            "Correcting a past transcript proposes the change as a dictionary rule, and "
                + "you choose which ones to keep."
        case .automatic:
            "Corrections are filed as you make them. Faster, but a rule you did not mean "
                + "applies to every transcript after it — the Dictionary tab is where to undo one."
        case .off:
            "Transcripts stay editable; nothing is inferred from the edit."
        }
    }
}

enum HUDPlacement: String, CaseIterable, Sendable, Identifiable {
    /// The island at the top of the screen — hugging the notch on a Mac that has one, and
    /// a capsule under the menu bar on one that doesn't.
    case notch
    /// The floating capsule above the Dock, which is where the HUD has always been.
    case bottom

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .notch: "At the top of the screen"
        case .bottom: "Above the Dock"
        }
    }
}

enum CleanupContext: String, CaseIterable, Sendable {
    case general
    case email

    var displayName: String { self == .general ? "General" : "Email" }
}

struct CleanupPreferences: Sendable {
    let tone: CleanupTone
    let formatsLists: Bool
    let context: CleanupContext
}

@MainActor
@Observable
final class Settings {
    static let shared = Settings()

    var pushToTalkKey: PushToTalkKey {
        didSet {
            if commandModeEnabled, commandModeKey == pushToTalkKey {
                commandModeEnabled = false
            }
            defaults.set(pushToTalkKey.rawValue, forKey: Keys.pushToTalkKey)
        }
    }

    /// Opt-in because a second global modifier key must never be intercepted unexpectedly.
    var commandModeEnabled: Bool {
        didSet {
            // Two event taps consuming the same modifier would start two recordings and make
            // the key unusable. Refuse that persisted/configured state by switching the
            // optional feature back off.
            if commandModeEnabled, commandModeKey == pushToTalkKey {
                commandModeEnabled = false
            }
            defaults.set(commandModeEnabled, forKey: Keys.commandModeEnabled)
        }
    }

    /// Hold this key after selecting editable text, then speak an editing instruction.
    var commandModeKey: PushToTalkKey {
        didSet {
            if commandModeEnabled, commandModeKey == pushToTalkKey {
                commandModeEnabled = false
            }
            defaults.set(commandModeKey.rawValue, forKey: Keys.commandModeKey)
        }
    }

    var engine: SpeechEngineChoice {
        didSet { defaults.set(engine.rawValue, forKey: Keys.engine) }
    }

    /// Run every engine on each recording and show them side by side, instead of
    /// transcribing with one. Nothing is typed into the focused app in this mode.
    var compareMode: Bool {
        didSet { defaults.set(compareMode, forKey: Keys.compareMode) }
    }

    /// Run the cleanup pass before injecting. Off = raw engine output.
    var cleanupEnabled: Bool {
        didSet { defaults.set(cleanupEnabled, forKey: Keys.cleanupEnabled) }
    }

    /// Choose between the two entirely local semantic cleanup engines.
    var cleanupEngine: CleanupEngineChoice {
        didSet { defaults.set(cleanupEngine.rawValue, forKey: Keys.cleanupEngine) }
    }

    /// Repair grammar, not only punctuation — the Grammarly job, done locally.
    ///
    /// Only the Apple engine can do this. S1-mini is a purpose-trained punctuation and
    /// capitalisation model, not an instruction-following one; it has no grammar mode to
    /// switch on. `activeFormatter` therefore ignores this for `.s1Mini`, and the Dictation
    /// settings tab says so rather than offering a switch that would do nothing.
    ///
    /// On by default because it measured both better and faster than the alternative: over
    /// the 28 evaluation cases, Apple returned 19 clean against Qwen's 14, at a warm median
    /// of 0.686s against 7.41s. See `--selftest-cleanup apple-grammar`.
    var cleanupFixesGrammar: Bool {
        didSet { defaults.set(cleanupFixesGrammar, forKey: Keys.cleanupFixesGrammar) }
    }

    var cleanupTone: CleanupTone {
        didSet { defaults.set(cleanupTone.rawValue, forKey: Keys.cleanupTone) }
    }

    var cleanupFormatsLists: Bool {
        didSet { defaults.set(cleanupFormatsLists, forKey: Keys.cleanupFormatsLists) }
    }

    var cleanupContext: CleanupContext {
        didSet { defaults.set(cleanupContext.rawValue, forKey: Keys.cleanupContext) }
    }

    /// Read the file, folder and tab names visible in the app being dictated into, and use them
    /// to resolve a spoken file name. See `ScreenContextStore`, which owns the harvest itself
    /// and reads this through `isEnabled`.
    ///
    /// On by default. The harvest costs 120 ms of a window in which the user is holding a key
    /// anyway, and it is scoped to three hand-tested editors — everywhere else the answer is
    /// already "no adapter", so the switch has nothing to turn off. Off is for somebody who does
    /// not want another application's window read at all, which is a position worth honouring
    /// without argument.
    var screenContextEnabled: Bool {
        didSet { defaults.set(screenContextEnabled, forKey: Keys.screenContextEnabled) }
    }

    /// Where the dictation HUD appears.
    ///
    /// The default is decided by the hardware rather than fixed: on a Mac with a notch the
    /// island grows out of a strip of screen that is already dead, and on one without it
    /// the same capsule would sit over the top of whatever the user is typing into — so
    /// that machine keeps the HUD above the Dock. Only dictation is placed by this; the
    /// island still announces meetings and notes either way, because those are
    /// notifications rather than a live readout of something being held down.
    var hudPlacement: HUDPlacement {
        didSet { defaults.set(hudPlacement.rawValue, forKey: Keys.hudPlacement) }
    }

    /// What happens to a dictation when the user changes apps before it is ready.
    ///
    /// Only consulted when they actually switched: staying put takes the same path it
    /// always did.
    var switchAwayBehavior: SwitchAwayBehavior {
        didSet { defaults.set(switchAwayBehavior.rawValue, forKey: Keys.switchAwayBehavior) }
    }

    /// Whether editing a past transcript teaches the dictionary.
    var dictionaryLearning: DictionaryLearning {
        didSet { defaults.set(dictionaryLearning.rawValue, forKey: Keys.dictionaryLearning) }
    }

    /// Play a short tick when capture starts and stops.
    var soundEnabled: Bool {
        didSet { defaults.set(soundEnabled, forKey: Keys.soundEnabled) }
    }

    /// Let llama.cpp use the GPU. The escape hatch for the Metal backend wedging
    /// MTLCompilerService on some macOS 26 builds; takes effect at next launch because the
    /// backend is initialized once per process.
    var llmMetalEnabled: Bool {
        didSet { defaults.set(llmMetalEnabled, forKey: Keys.llmMetalEnabled) }
    }

    /// Keep the recorded meeting audio next to the transcript.
    ///
    /// Off by default: an hour of two-channel 16 kHz audio is roughly 230 MB, and the
    /// transcript — the thing the notes are actually written from — is a few kilobytes.
    /// Turn it on to be able to listen back. Diarization does not need it: a meeting that
    /// is going to have its speakers identified records audio either way and drops it again
    /// afterwards.
    var meetingsKeepAudio: Bool {
        didSet { defaults.set(meetingsKeepAudio, forKey: Keys.meetingsKeepAudio) }
    }

    /// Tell the other participants apart on the system track once a meeting has finished.
    ///
    /// Off by default: it is a second model to download, it adds minutes to the end of a
    /// long meeting, and a two-person call is already attributed correctly by the two
    /// tracks alone. It earns its keep on a call with a room full of people.
    var meetingsDiarize: Bool {
        didSet { defaults.set(meetingsDiarize, forKey: Keys.meetingsDiarize) }
    }

    /// Throw the recording away once the notes have been written.
    ///
    /// For keeping the audio only as long as the things made from it need it — diarization
    /// reads the system channel, and nothing after that does. Ignored when the audio isn't
    /// being kept in the first place; a meeting recorded only so its speakers could be
    /// identified always drops its audio afterwards.
    var meetingsDeleteAudioAfterNotes: Bool {
        didSet { defaults.set(meetingsDeleteAudioAfterNotes, forKey: Keys.meetingsDeleteAudioAfterNotes) }
    }

    /// Start recording by itself when a calendar meeting begins.
    ///
    /// On by default because a note-taker that has to be remembered is a note-taker that
    /// misses the meeting you most wanted notes from. Every event is still individually
    /// refusable through `meetingAutoRecordOverrides`, and the scheduler only ever claims
    /// events that look like real meetings.
    var meetingsAutoRecord: Bool {
        didSet { defaults.set(meetingsAutoRecord, forKey: Keys.meetingsAutoRecord) }
    }

    /// How many minutes before the start time the meeting is armed and announced.
    ///
    /// One minute by default: long enough to press Skip on the notification, short enough
    /// that the armed row isn't sitting there through the previous meeting.
    var meetingLeadMinutes: Int {
        didSet { defaults.set(meetingLeadMinutes, forKey: Keys.meetingLeadMinutes) }
    }

    /// Per-event answers to "record this one?", keyed by `MeetingEvent.overrideKey`.
    ///
    /// An explicit answer beats both the heuristic and the global switch, in either
    /// direction: the one recurring stand-up you never want recorded, and the one-to-one
    /// with no conference link that you do.
    var meetingAutoRecordOverrides: [String: Bool] {
        didSet { defaults.set(meetingAutoRecordOverrides, forKey: Keys.meetingAutoRecordOverrides) }
    }

    /// Notice that the Mac is on a call and offer to record it.
    ///
    /// On by default, and on by itself it records nothing. Detection needs no permission at
    /// all — Core Audio's process list reads without a TCC grant — and all it ever does on
    /// its own is raise the same armed card a calendar meeting raises, with Record now and
    /// Skip on it. The switch that turns that question into a recording is the next one.
    var callDetectionEnabled: Bool {
        didSet { defaults.set(callDetectionEnabled, forKey: Keys.callDetectionEnabled) }
    }

    /// Record a detected call without asking first.
    ///
    /// **Off by default, and that default is the argument.** A calendar meeting is
    /// something the user agreed to in advance; a call that rang out of nowhere could be a
    /// doctor or a lawyer, and consent law for recording a call varies by jurisdiction —
    /// several places require every party to agree. Asking costs nothing to build, because
    /// the island already has the card. Anyone who wants the calendar behaviour turns this
    /// on, and `callAppAnswers` makes "always record Zoom" one switch without making it
    /// the answer for every app.
    var callDetectionAutoRecord: Bool {
        didSet { defaults.set(callDetectionAutoRecord, forKey: Keys.callDetectionAutoRecord) }
    }

    /// Per-app answers to "record calls in this app?", keyed by bundle identifier and
    /// holding `CallPolicy.AppAnswer` raw values.
    ///
    /// Keyed by the *app*, where `meetingAutoRecordOverrides` is keyed by the occurrence,
    /// and the difference is deliberate: a calendar event recurs, so an answer about one
    /// occurrence is worth keeping and an answer about the series would be wrong. A call
    /// happens once and never again under the same key, so a per-call answer would be a row
    /// that is written and never read. Every call in an app is the same kind of call.
    ///
    /// Strings rather than the `Bool` this held first, because the control has three
    /// positions and a `Bool?` has only two plus "unanswered" — with auto-record on there
    /// was no way to store "ask me about this one".
    var callAppAnswers: [String: String] {
        didSet { defaults.set(callAppAnswers, forKey: Keys.callAppAnswers) }
    }

    /// Apps that have actually been seen holding the microphone: bundle identifier to the
    /// name a person would recognise.
    ///
    /// Written by `CallDetector`, read by the Meetings settings tab, and the reason that
    /// tab can offer a per-app answer without anybody typing `us.zoom.xos` into a text
    /// field. A record of what happened on this Mac, not a catalogue of what exists — an
    /// app nobody has ever used the microphone in is an app with no calls to answer for.
    var callAppsSeen: [String: String] {
        didSet { defaults.set(callAppsSeen, forKey: Keys.callAppsSeen) }
    }

    /// Read meetings from the Mac's own calendars through EventKit.
    var calendarEventKitEnabled: Bool {
        didSet { defaults.set(calendarEventKitEnabled, forKey: Keys.calendarEventKitEnabled) }
    }

    /// Read meetings from Google Calendar over its HTTP API.
    ///
    /// Off by default, and useless until `googleClientID` is filled in: Google has no
    /// client credentials to give an unsigned desktop app, so the user brings their own
    /// OAuth client from Google Cloud.
    var calendarGoogleEnabled: Bool {
        didSet { defaults.set(calendarGoogleEnabled, forKey: Keys.calendarGoogleEnabled) }
    }

    /// The user's own Google Cloud OAuth client ID, of type "Desktop app".
    ///
    /// Not a secret worth hiding — desktop clients are public by design, which is exactly
    /// why the flow uses PKCE — so it lives in defaults beside the rest of the settings.
    /// The refresh token it earns does not: that goes to the Keychain.
    var googleClientID: String {
        didSet { defaults.set(googleClientID, forKey: Keys.googleClientID) }
    }

    /// The secret printed beside that client ID.
    ///
    /// Google's token endpoint asks an installed client for it even though PKCE is what
    /// actually protects the exchange — the "secret" is public by construction, since it
    /// ships inside every copy of an app that has one, so it lives in defaults next to the
    /// ID rather than in the Keychain. Left empty for a client type that doesn't need one.
    var googleClientSecret: String {
        didSet { defaults.set(googleClientSecret, forKey: Keys.googleClientSecret) }
    }

    /// Which Google calendars to read. Empty means "every calendar the account shows".
    var googleCalendarIDs: [String] {
        didSet { defaults.set(googleCalendarIDs, forKey: Keys.googleCalendarIDs) }
    }

    /// Write notes by themselves when a meeting finishes transcribing.
    ///
    /// On by default: the notes are the reason a meeting was recorded, and a summarisation
    /// that has to be asked for is one that happens after the user has already moved on.
    var notesAutoGenerate: Bool {
        didSet { defaults.set(notesAutoGenerate, forKey: Keys.notesAutoGenerate) }
    }

    /// Which local model writes them.
    ///
    /// Qwen by default even before it is downloaded: the picker is where the download is
    /// explained, and silently defaulting to Apple's 4K window would hide the fact that long
    /// meetings are then summarised in pieces. `LLMProviders.resolve` falls back to whichever
    /// provider can actually run, so the default never blocks notes.
    var notesProvider: LLMProviderID {
        didSet { defaults.set(notesProvider.rawValue, forKey: Keys.notesProvider) }
    }

    /// Let the meeting agent propose follow-up actions in Google Workspace.
    ///
    /// Off until the user has signed the Workspace CLI in, because an agent with no way to
    /// perform anything is a switch that produces a list of things that can't happen. The
    /// Workspace tab turns it on as part of finishing the sign-in.
    var agentEnabled: Bool {
        didSet { defaults.set(agentEnabled, forKey: Keys.agentEnabled) }
    }

    /// Let the agent run read-only tools by itself while it plans.
    ///
    /// On by default, and it is the one thing the agent does without being asked: searching
    /// the user's own mail for the deck somebody promised changes nothing and is invisible
    /// to everyone else. Every tool that creates or sends is a click whatever this says.
    var agentAutoRunReadTools: Bool {
        didSet { defaults.set(agentAutoRunReadTools, forKey: Keys.agentAutoRunReadTools) }
    }

    /// Look at the last couple of minutes of a running meeting and propose as it goes.
    ///
    /// Off by default: it spends model time during the call — the moment the machine is
    /// busiest — to catch the requests that are made out loud and then forgotten. Worth
    /// turning on for meetings that end in "can you send me…", and not otherwise.
    var agentLiveDuringMeeting: Bool {
        didSet { defaults.set(agentLiveDuringMeeting, forKey: Keys.agentLiveDuringMeeting) }
    }

    /// Local wake-phrase detection. Off until the user turns it on — a hot microphone
    /// while the app is sleeping is a choice, not a default.
    var voiceWakeEnabled: Bool {
        didSet {
            defaults.set(voiceWakeEnabled, forKey: Keys.voiceWakeEnabled)
            WakeWordAudioMonitor.shared.sync()
        }
    }

    var wakePhrase: String {
        didSet { defaults.set(wakePhrase, forKey: Keys.wakePhrase) }
    }

    /// 0 = conservative, 1 = sensitive.
    var wakeSensitivity: Double {
        didSet { defaults.set(wakeSensitivity, forKey: Keys.wakeSensitivity) }
    }

    var listenWhileSleeping: Bool {
        didSet {
            defaults.set(listenWhileSleeping, forKey: Keys.listenWhileSleeping)
            WakeWordAudioMonitor.shared.sync()
        }
    }

    var agentShortcutEnabled: Bool {
        didSet { defaults.set(agentShortcutEnabled, forKey: Keys.agentShortcutEnabled) }
    }

    var agentShortcut: AgentShortcut {
        didSet { defaults.set(agentShortcut.rawValue, forKey: Keys.agentShortcut) }
    }

    var agentBackend: AgentBackendKind {
        didSet { defaults.set(agentBackend.rawValue, forKey: Keys.agentBackend) }
    }

    var acpBackendID: String {
        didSet { defaults.set(acpBackendID, forKey: Keys.acpBackendID) }
    }

    var agentAutoSearchFiles: Bool {
        didSet { defaults.set(agentAutoSearchFiles, forKey: Keys.agentAutoSearchFiles) }
    }

    /// Standing yes for local click / type / open. Off by default — observe still runs.
    var agentAllowComputerControl: Bool {
        didSet { defaults.set(agentAllowComputerControl, forKey: Keys.agentAllowComputerControl) }
    }

    var composioEnabled: Bool {
        didSet { defaults.set(composioEnabled, forKey: Keys.composioEnabled) }
    }

    var composioAPIKey: String {
        didSet { defaults.set(composioAPIKey, forKey: Keys.composioAPIKey) }
    }

    var composioURL: String {
        didSet { defaults.set(composioURL, forKey: Keys.composioURL) }
    }

    var composioAllowlist: [String] {
        didSet { defaults.set(composioAllowlist, forKey: Keys.composioAllowlist) }
    }

    var mcpServersJSON: String {
        didSet { defaults.set(mcpServersJSON, forKey: Keys.mcpServersJSON) }
    }

    /// Whether the first-launch permissions checklist has been dismissed. The checklist
    /// itself stays reachable from Settings, so this only decides whether it opens by
    /// itself — not whether the app is usable.
    var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.hasCompletedOnboarding) }
    }

    /// The stored answer for one event, or nil when the heuristic decides.
    func autoRecordOverride(forEvent key: String) -> Bool? {
        meetingAutoRecordOverrides[key]
    }

    /// Records or clears one event's answer. `nil` hands the event back to the heuristic.
    func setAutoRecordOverride(_ value: Bool?, forEvent key: String) {
        var overrides = meetingAutoRecordOverrides
        overrides[key] = value
        meetingAutoRecordOverrides = overrides
    }

    /// The stored answer for one app's calls, or nil when the global switch decides.
    func callAnswer(forApp bundleID: String) -> CallPolicy.AppAnswer? {
        callAppAnswers[bundleID].flatMap(CallPolicy.AppAnswer.init(rawValue:))
    }

    /// Records or clears one app's answer. `nil` hands its calls back to the global switch.
    func setCallAnswer(_ value: CallPolicy.AppAnswer?, forApp bundleID: String) {
        var answers = callAppAnswers
        answers[bundleID] = value?.rawValue
        callAppAnswers = answers
    }

    /// Notes that an app has used the microphone, so it can be answered for.
    ///
    /// The name is refreshed as well as the identifier: an app that was running unbundled
    /// the first time it was seen, or was renamed, should not be listed forever under
    /// whatever it was called then.
    func rememberCallApp(bundleID: String, name: String) {
        var seen = callAppsSeen
        seen[bundleID] = name
        callAppsSeen = seen
    }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let pushToTalkKey = "pushToTalkKey"
        static let commandModeEnabled = "commandModeEnabled"
        static let commandModeKey = "commandModeKey"
        static let cleanupEnabled = "cleanupEnabled"
        static let soundEnabled = "soundEnabled"
        static let engine = "engine"
        static let cleanupEngine = "cleanupEngine"
        static let cleanupFixesGrammar = "cleanupFixesGrammar"
        static let cleanupTone = "cleanupTone"
        static let cleanupFormatsLists = "cleanupFormatsLists"
        static let cleanupContext = "cleanupContext"
        /// The key `ScreenContextStore` wrote before this moved onto `Settings`. Unchanged on
        /// purpose: a renamed key is a silently reset preference.
        static let screenContextEnabled = "screenContextEnabled"
        static let legacySmartCleanup = "smartCleanup"
        static let compareMode = "compareMode"
        static let llmMetalEnabled = "llmMetalEnabled"
        static let hudPlacement = "hudPlacement"
        static let switchAwayBehavior = "switchAwayBehavior"
        static let dictionaryLearning = "dictionaryLearning"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let meetingsKeepAudio = "meetingsKeepAudio"
        static let meetingsDiarize = "meetingsDiarize"
        static let meetingsDeleteAudioAfterNotes = "meetingsDeleteAudioAfterNotes"
        static let notesAutoGenerate = "notesAutoGenerate"
        static let notesProvider = "notesProvider"
        static let meetingsAutoRecord = "meetingsAutoRecord"
        static let meetingLeadMinutes = "meetingLeadMinutes"
        static let meetingAutoRecordOverrides = "meetingAutoRecordOverrides"
        static let callDetectionEnabled = "callDetectionEnabled"
        static let callDetectionAutoRecord = "callDetectionAutoRecord"
        static let callAppAnswers = "callAppAnswers"
        static let callAppsSeen = "callAppsSeen"
        static let calendarEventKitEnabled = "calendarEventKitEnabled"
        static let calendarGoogleEnabled = "calendarGoogleEnabled"
        static let googleClientID = "googleClientID"
        static let googleClientSecret = "googleClientSecret"
        static let googleCalendarIDs = "googleCalendarIDs"
        static let agentEnabled = "agentEnabled"
        static let agentAutoRunReadTools = "agentAutoRunReadTools"
        static let agentLiveDuringMeeting = "agentLiveDuringMeeting"
        static let voiceWakeEnabled = "voiceWakeEnabled"
        static let wakePhrase = "wakePhrase"
        static let wakeSensitivity = "wakeSensitivity"
        static let listenWhileSleeping = "listenWhileSleeping"
        static let agentShortcutEnabled = "agentShortcutEnabled"
        static let agentShortcut = "agentShortcut"
        static let agentBackend = "agentBackend"
        static let acpBackendID = "acpBackendID"
        static let agentAutoSearchFiles = "agentAutoSearchFiles"
        static let agentAllowComputerControl = "agentAllowComputerControl"
        static let composioEnabled = "composioEnabled"
        static let composioAPIKey = "composioAPIKey"
        static let composioURL = "composioURL"
        static let composioAllowlist = "composioAllowlist"
        static let mcpServersJSON = "mcpServersJSON"
    }

    private init() {
        let raw = defaults.string(forKey: Keys.pushToTalkKey) ?? PushToTalkKey.rightOption.rawValue
        pushToTalkKey = PushToTalkKey(rawValue: raw) ?? .rightOption
        commandModeEnabled = defaults.object(forKey: Keys.commandModeEnabled) as? Bool ?? false
        let commandRaw = defaults.string(forKey: Keys.commandModeKey)
            ?? PushToTalkKey.rightCommand.rawValue
        commandModeKey = PushToTalkKey(rawValue: commandRaw) ?? .rightCommand
        // Apple by default: no download, no dependency, live text while speaking.
        engine = SpeechEngineChoice(rawValue: defaults.string(forKey: Keys.engine) ?? "") ?? .apple
        cleanupEnabled = defaults.object(forKey: Keys.cleanupEnabled) as? Bool ?? true
        cleanupFixesGrammar = defaults.object(forKey: Keys.cleanupFixesGrammar) as? Bool ?? true
        if let rawCleanupEngine = defaults.string(forKey: Keys.cleanupEngine) {
            cleanupEngine = CleanupEngineChoice(rawValue: rawCleanupEngine) ?? .apple
        } else {
            // The previous smart-cleanup switch only had one semantic provider: Apple.
            // Preserve that intent, while making Apple the sensible default for new users.
            cleanupEngine = .apple
            if defaults.bool(forKey: Keys.legacySmartCleanup) {
                defaults.set(CleanupEngineChoice.apple.rawValue, forKey: Keys.cleanupEngine)
            }
        }
        cleanupTone = CleanupTone(
            rawValue: defaults.string(forKey: Keys.cleanupTone) ?? ""
        ) ?? .balanced
        cleanupFormatsLists = defaults.object(forKey: Keys.cleanupFormatsLists) as? Bool ?? true
        cleanupContext = CleanupContext(
            rawValue: defaults.string(forKey: Keys.cleanupContext) ?? ""
        ) ?? .general
        screenContextEnabled = defaults.object(forKey: Keys.screenContextEnabled) as? Bool ?? true
        compareMode = defaults.object(forKey: Keys.compareMode) as? Bool ?? false
        soundEnabled = defaults.object(forKey: Keys.soundEnabled) as? Bool ?? true
        llmMetalEnabled = defaults.object(forKey: Keys.llmMetalEnabled) as? Bool ?? true
        hudPlacement = HUDPlacement(
            rawValue: defaults.string(forKey: Keys.hudPlacement) ?? ""
        ) ?? (IslandGeometry.hasNotch ? .notch : .bottom)
        // Defaults to returning: the alternative was losing the text outright, which is
        // the bug this setting was added alongside.
        dictionaryLearning = DictionaryLearning(
            rawValue: defaults.string(forKey: Keys.dictionaryLearning) ?? ""
        ) ?? .ask
        switchAwayBehavior = SwitchAwayBehavior(
            rawValue: defaults.string(forKey: Keys.switchAwayBehavior) ?? ""
        ) ?? .returnToApp
        hasCompletedOnboarding = defaults.object(forKey: Keys.hasCompletedOnboarding) as? Bool ?? false
        meetingsKeepAudio = defaults.object(forKey: Keys.meetingsKeepAudio) as? Bool ?? false
        meetingsDiarize = defaults.object(forKey: Keys.meetingsDiarize) as? Bool ?? false
        meetingsDeleteAudioAfterNotes = defaults.object(forKey: Keys.meetingsDeleteAudioAfterNotes)
            as? Bool ?? false
        notesAutoGenerate = defaults.object(forKey: Keys.notesAutoGenerate) as? Bool ?? true
        notesProvider = LLMProviderID(
            rawValue: defaults.string(forKey: Keys.notesProvider) ?? ""
        ) ?? .qwen35_4b
        meetingsAutoRecord = defaults.object(forKey: Keys.meetingsAutoRecord) as? Bool ?? true
        // Clamped on read as well as on write: a hand-edited or corrupted default of 0 or
        // 4000 would either arm at the start time or arm every meeting of the week.
        let leadMinutes = defaults.object(forKey: Keys.meetingLeadMinutes) as? Int ?? 1
        meetingLeadMinutes = min(max(leadMinutes, Self.leadMinutesRange.lowerBound), Self.leadMinutesRange.upperBound)
        meetingAutoRecordOverrides = defaults.dictionary(forKey: Keys.meetingAutoRecordOverrides)
            as? [String: Bool] ?? [:]
        callDetectionEnabled = defaults.object(forKey: Keys.callDetectionEnabled) as? Bool ?? true
        callDetectionAutoRecord = defaults.object(forKey: Keys.callDetectionAutoRecord) as? Bool ?? false
        callAppAnswers = defaults.dictionary(forKey: Keys.callAppAnswers) as? [String: String] ?? [:]
        callAppsSeen = defaults.dictionary(forKey: Keys.callAppsSeen) as? [String: String] ?? [:]
        calendarEventKitEnabled = defaults.object(forKey: Keys.calendarEventKitEnabled) as? Bool ?? true
        calendarGoogleEnabled = defaults.object(forKey: Keys.calendarGoogleEnabled) as? Bool ?? false
        googleClientID = defaults.string(forKey: Keys.googleClientID) ?? ""
        googleClientSecret = defaults.string(forKey: Keys.googleClientSecret) ?? ""
        googleCalendarIDs = defaults.stringArray(forKey: Keys.googleCalendarIDs) ?? []
        agentEnabled = defaults.object(forKey: Keys.agentEnabled) as? Bool ?? false
        agentAutoRunReadTools = defaults.object(forKey: Keys.agentAutoRunReadTools) as? Bool ?? true
        agentLiveDuringMeeting = defaults.object(forKey: Keys.agentLiveDuringMeeting) as? Bool ?? false
        voiceWakeEnabled = defaults.object(forKey: Keys.voiceWakeEnabled) as? Bool ?? false
        wakePhrase = defaults.string(forKey: Keys.wakePhrase) ?? WakeWordConfiguration.defaultPhrase
        wakeSensitivity = defaults.object(forKey: Keys.wakeSensitivity) as? Double ?? 0.5
        listenWhileSleeping = defaults.object(forKey: Keys.listenWhileSleeping) as? Bool ?? true
        agentShortcutEnabled = defaults.object(forKey: Keys.agentShortcutEnabled) as? Bool ?? true
        agentShortcut = AgentShortcut(rawValue: defaults.string(forKey: Keys.agentShortcut) ?? "") ?? .shiftCommandSpace
        agentBackend = AgentBackendKind(rawValue: defaults.string(forKey: Keys.agentBackend) ?? "") ?? .local
        acpBackendID = defaults.string(forKey: Keys.acpBackendID) ?? ""
        agentAutoSearchFiles = defaults.object(forKey: Keys.agentAutoSearchFiles) as? Bool ?? false
        agentAllowComputerControl = defaults.object(forKey: Keys.agentAllowComputerControl) as? Bool ?? false
        composioEnabled = defaults.object(forKey: Keys.composioEnabled) as? Bool ?? false
        composioAPIKey = defaults.string(forKey: Keys.composioAPIKey) ?? ""
        composioURL = defaults.string(forKey: Keys.composioURL) ?? ComposioProvider.defaultURL
        composioAllowlist = defaults.stringArray(forKey: Keys.composioAllowlist) ?? []
        mcpServersJSON = defaults.string(forKey: Keys.mcpServersJSON) ?? ""

        // Old/default values can be loaded without invoking property observers.
        if commandModeEnabled, commandModeKey == pushToTalkKey {
            commandModeEnabled = false
        }
    }

    /// What the lead-time stepper offers, and what a stored value is clamped to.
    static let leadMinutesRange = 0...15

    var cleanupPreferences: CleanupPreferences {
        CleanupPreferences(
            tone: cleanupTone,
            formatsLists: cleanupFormatsLists,
            context: cleanupContext
        )
    }
}

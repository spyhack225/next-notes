import Foundation

/// The rules that decide whether the Mac is on a call, with no Core Audio in sight.
///
/// Split out from `CallDetector` for the same reason `DictationSelectionPolicy` is split out
/// of its view: the subscription to the process list cannot be exercised from a terminal —
/// it needs a real call to be happening — but every decision made about what that list means
/// can be, and those are the decisions that get this wrong. `--selftest-calls` asserts every
/// case below.
enum CallPolicy {
    /// One process's audio state at one instant — the four properties the probe on
    /// 2026-09-09 proved readable per process, and nothing else.
    struct AudioProcess: Sendable, Hashable {
        var pid: pid_t
        /// Absent for processes that are not in a bundle. `afplay` reports none.
        var bundleID: String?
        var name: String
        var isRunningInput: Bool
        var isRunningOutput: Bool
    }

    // MARK: - Thresholds

    /// How long a candidate must hold both flags before it counts as a call.
    ///
    /// Sampling at 1 Hz during continuous microphone use showed the flag drop for three
    /// consecutive samples and come back, so anything shorter than a few seconds would
    /// announce a call that is really a stutter.
    static let onThreshold: TimeInterval = 3

    /// How long a live call must be gone before it stops counting. Deliberately much
    /// larger than `onThreshold`: the cost of ending a call late is a card that lingers,
    /// and the cost of ending it early is the card flashing off and on mid-conversation.
    static let offThreshold: TimeInterval = 15

    /// Processes that hold the microphone on someone else's behalf and are never themselves
    /// a call. A denylist rather than an allowlist so a conferencing app nobody here has
    /// heard of still works on the day it is installed.
    ///
    /// `com.apple.CoreSpeech` is the one that was actually measured — `corespeechd` appeared
    /// repeatedly during the probe with no call in progress. The rest are its neighbours in
    /// the dictation and accessibility stack, added by name rather than by measurement.
    ///
    /// Fathom is *not* here, though it records meetings and holds the microphone to do it.
    /// It only holds it during a call, so denying it would suppress a real detection; a user
    /// who does not want Next Notes arming on Fathom's account gets the per-app control in
    /// Phase 3 instead.
    static let deniedBundleIDs: Set<String> = [
        "com.apple.CoreSpeech",
        "com.apple.SpeechRecognitionCore",
        "com.apple.speech.speechsynthesisd",
        "com.apple.assistantd",
        "com.apple.Siri",
        "com.apple.accessibility.AXVisualSupportAgent",
        // Our own bundle, as well as our own pid. A helper or a second copy of Next Notes
        // shares the identifier but not the process id, and the app triggering on its own
        // dictation is the failure this whole filter exists to prevent.
        AppIdentity.bundleIdentifier,
    ]

    // MARK: - The rules

    /// The answer one app's calls get.
    ///
    /// Three named states rather than the `Bool?` this started as, because `ask` has to be
    /// storable in its own right: with auto-record on, "record everything, except in this
    /// app where you ask me" is a real answer, and "nobody has answered for this app" is
    /// not it. `nil` still means exactly that — no answer, follow the global switch.
    enum AppAnswer: String, CaseIterable, Sendable, Identifiable {
        case always
        case ask
        case never

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .always: "Always record"
            case .ask: "Ask first"
            case .never: "Never"
            }
        }
    }

    /// Whether this process is an app the settings list should offer an answer for.
    ///
    /// The microphone alone, where `isCall` needs both flags, and that difference is the
    /// point: a per-app answer is only worth anything if it can be given *before* the first
    /// call in that app rather than after it. Everything `isCall` throws out is thrown out
    /// here too — our own process, our own bundle, and the daemons that hold the microphone
    /// on somebody else's behalf, which are rows nobody could answer sensibly.
    ///
    /// A process with no bundle id never qualifies. The answer is stored against the app,
    /// and a pid is not an app: it names a different program after the next reboot.
    static func isMicrophoneApp(_ process: AudioProcess, ownPID: pid_t) -> Bool {
        guard process.isRunningInput else { return false }
        guard process.pid != ownPID else { return false }
        guard let bundleID = process.bundleID else { return false }
        return !deniedBundleIDs.contains(bundleID)
    }

    /// A call holds the microphone **and** the speakers.
    ///
    /// That single requirement is what separates a call from the two things that look like
    /// one: dictation is microphone only, and watching a video is speakers only.
    static func isCall(_ process: AudioProcess, ownPID: pid_t) -> Bool {
        guard process.isRunningInput, process.isRunningOutput else { return false }
        guard process.pid != ownPID else { return false }
        if let bundleID = process.bundleID, deniedBundleIDs.contains(bundleID) { return false }
        return true
    }

    /// The one process to treat as the call, out of everything the system is running.
    ///
    /// `incumbent` is the pid the debounce is already tracking, and while there is one this
    /// answers about **that** process and nothing else: it is either still holding both flags
    /// or it is not. Falling back to another qualifying process is what let a single
    /// flickered sample end a live call. Zoom drops its input flag for one sample — measured,
    /// during continuous use — Fathom or a browser is in the same call holding both flags,
    /// and the machine is handed a different pid, which it can only read as "the call moved
    /// on". It skips `.fading`, the state that exists to absorb precisely that flicker, and
    /// the recording of a call that never stopped is finalised.
    ///
    /// The cost is that a genuinely new call waits for the old one to fade out. That is at
    /// most `offThreshold`, and it is the same wait a call that ends with nothing else
    /// running already imposes.
    ///
    /// With nothing tracked the lowest pid wins, which is arbitrary but *deterministic*: the
    /// order Core Audio returns the process list in is not promised, and a rule that depended
    /// on it would be untestable.
    static func candidate(
        in processes: [AudioProcess],
        ownPID: pid_t,
        preferring incumbent: pid_t?
    ) -> AudioProcess? {
        let calls = processes.filter { isCall($0, ownPID: ownPID) }
        if let incumbent { return calls.first { $0.pid == incumbent } }
        return calls.min { $0.pid < $1.pid }
    }

    // MARK: - Debounce

    /// Where a possible call is in its life. Carries the process it is about, so the caller
    /// keeps nothing beside this value.
    enum DebounceState: Sendable, Equatable {
        case quiet
        /// Seen, but has not held both flags for `onThreshold` yet.
        case rising(AudioProcess, held: TimeInterval)
        case live(AudioProcess)
        /// Was live and its flags have gone, but not for `offThreshold` yet. Still reported
        /// as a call: this is the state that absorbs the measured flicker.
        case fading(AudioProcess, gone: TimeInterval)

        /// The call the rest of the app should believe in, which is only ever a settled one.
        var call: AudioProcess? {
            switch self {
            case .quiet, .rising: nil
            case .live(let process): process
            case .fading(let process, _): process
            }
        }

        /// The process this state is tracking, settled or not — what `candidate(…)` should
        /// be told to prefer on the next pass.
        var subject: AudioProcess? {
            switch self {
            case .quiet: nil
            case .rising(let process, _), .live(let process), .fading(let process, _): process
            }
        }
    }

    /// One step of the state machine: a pure function of where it was, what is being
    /// observed now, and how long it has been since the last step.
    ///
    /// `elapsed` is passed in rather than read from a clock so the whole machine can be
    /// driven through minutes of behaviour in a self-test that finishes instantly.
    ///
    /// A fresh sighting starts at zero rather than crediting itself the elapsed interval,
    /// because the backstop poll is 5 s and would otherwise clear a 3 s threshold on the
    /// very first sample it ever saw the process in.
    static func next(
        _ state: DebounceState,
        observing candidate: AudioProcess?,
        elapsed: TimeInterval
    ) -> DebounceState {
        switch (state, candidate) {
        case (.quiet, nil):
            return .quiet
        case (.quiet, .some(let process)):
            return .rising(process, held: 0)

        case (.rising, nil):
            // A candidate that never settled is not worth fading out. Nothing was announced,
            // so nothing has to be un-announced.
            return .quiet
        case (.rising(let previous, let held), .some(let process)):
            guard previous.pid == process.pid else { return .rising(process, held: 0) }
            let total = held + elapsed
            return total >= onThreshold ? .live(process) : .rising(process, held: total)

        // A live call leaves only by fading. Both cases below ask one question — is the
        // tracked pid still holding both flags? — and anything else, nobody or some other
        // process, is the same answer: it is absent. Reading a different pid as a handover
        // is what dropped a live call on one flickered sample, and it is not a distinction
        // this machine can make anyway: the two flags say a process has audio, never that
        // one call ended and another began.
        case (.live(let previous), _):
            guard let process = candidate, process.pid == previous.pid else {
                return .fading(previous, gone: 0)
            }
            return .live(process)

        case (.fading(let previous, let gone), _):
            // Back inside the window: this is the flicker, and the call never stopped.
            if let process = candidate, process.pid == previous.pid { return .live(process) }
            let total = gone + elapsed
            return total >= offThreshold ? .quiet : .fading(previous, gone: total)
        }
    }
}

// MARK: - Arming

extension CallPolicy {
    /// Everything the app can honestly say about its ability to record, the moment a call
    /// is noticed.
    ///
    /// One field, and it is deliberately not two. The microphone grant is queryable and
    /// definitive — `MeetingSession.start()` throws on it before it does anything else — so
    /// a call armed without it is a recording that cannot happen. The **system audio**
    /// grant, which is what actually carries the far end of the call, has no query API at
    /// all: a tap created without it is created *successfully* and delivers digital
    /// silence, so a probe would report "granted" on a machine that records nothing.
    /// AGENTS.md spells out why that answer is worse than no answer. So this struct does
    /// not pretend to know, and the far end stays unanswerable until a recording is made —
    /// `--selftest-systemaudio` and `MeetingSession.systemAudioProblem` are the honest
    /// reports of it.
    struct RecordingReadiness: Sendable, Hashable {
        var hasMicrophone: Bool

        var canRecord: Bool { hasMicrophone }
    }

    /// A meeting the app is already holding, reduced to what correlation needs.
    struct MeetingWindow: Sendable, Hashable {
        /// Recording, or somewhere in the pipeline that follows one.
        var isActive: Bool
        var start: Date
        /// The scheduled end, when whatever created it knew one.
        var end: Date?
    }

    /// How far either side of a scheduled meeting a call is still the same event.
    ///
    /// Ten minutes because that is roughly how early people join and how late meetings
    /// start; the failure this bounds is a Zoom call that is on the calendar producing two
    /// recordings of itself.
    static let correlationWindow: TimeInterval = 10 * 60

    /// Whether an existing meeting is plausibly the call that has just been detected.
    ///
    /// Correlation is by time and nothing else, as the plan settled: a recording already in
    /// flight *is* the call whatever its scheduled times claim, and an armed one counts
    /// while the clock is anywhere near it.
    static func covers(_ meeting: MeetingWindow, at now: Date) -> Bool {
        if meeting.isActive { return true }
        let end = meeting.end ?? meeting.start
        return now >= meeting.start.addingTimeInterval(-correlationWindow)
            && now <= end.addingTimeInterval(correlationWindow)
    }

    /// What to do about a call that has just settled.
    enum ArmDecision: Sendable, Equatable {
        case arm
        /// A meeting already covers this call, so the right number of new meetings is zero.
        case attach
        case decline(Decline)

        enum Decline: Sendable, Equatable {
            case detectionOff
            case appNever
            case noMicrophone

            /// Why nothing was armed, in a sentence fit for the log and for a banner.
            var explanation: String {
                switch self {
                case .detectionOff:
                    "call detection is switched off"
                case .appNever:
                    "calls in this app are set never to record"
                case .noMicrophone:
                    "Next Notes has no Microphone grant, so the recording would be empty"
                }
            }
        }
    }

    /// The whole arming rule, in the order the checks have to happen.
    ///
    /// `attach` is tested before the grant, because a meeting that is already recording has
    /// answered the permission question by existing — refusing there would report a missing
    /// grant about a recording that is visibly running.
    static func armDecision(
        enabled: Bool,
        answer: AppAnswer?,
        readiness: RecordingReadiness,
        meetings: [MeetingWindow],
        now: Date
    ) -> ArmDecision {
        guard enabled else { return .decline(.detectionOff) }
        if answer == .never { return .decline(.appNever) }
        if meetings.contains(where: { covers($0, at: now) }) { return .attach }
        guard readiness.canRecord else { return .decline(.noMicrophone) }
        return .arm
    }

    /// Apps that may be asked about but are never recorded without an answer.
    ///
    /// The plan's R1: a browser holding the microphone and the speakers might be a Meet
    /// call and might be anything at all, and there is no cheap way to tell. Google Meet
    /// installed as a Chrome web app carries its *own* bundle id and is deliberately not in
    /// here, so the case that can be identified precisely still can be.
    static let askOnlyBundleIDs: Set<String> = [
        "com.google.Chrome",
        "com.apple.Safari",
        "org.mozilla.firefox",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",
    ]

    /// The answers this app's calls may be given.
    ///
    /// A browser gets two rather than three. `askOnlyBundleIDs` already refuses to record
    /// one without asking, so offering "Always record" for Chrome would be a control that
    /// does nothing — worse than absent, because the user would believe it.
    static func availableAnswers(forApp bundleID: String) -> [AppAnswer] {
        askOnlyBundleIDs.contains(bundleID) ? [.ask, .never] : AppAnswer.allCases
    }

    /// What the next call in this app would actually get, given both switches.
    ///
    /// An app nobody has answered for follows the global one, and a browser is held to
    /// Ask however it was answered — a stored `always` survives from an app being added to
    /// `askOnlyBundleIDs` after the fact, and reporting it back would be a lie about what
    /// `recordsWithoutAsking` is going to do.
    static func effectiveAnswer(
        forApp bundleID: String,
        autoRecord: Bool,
        stored: AppAnswer?
    ) -> AppAnswer {
        let answer = stored ?? (autoRecord ? .always : .ask)
        guard availableAnswers(forApp: bundleID).contains(answer) else { return .ask }
        return answer
    }

    /// Whether a detected call may start recording without waiting for an answer.
    ///
    /// The default answer is no, and that is a consent decision rather than a technical
    /// one: a calendar meeting was agreed to in advance, an ad-hoc call was not, and in
    /// several jurisdictions recording one needs every party's agreement.
    static func recordsWithoutAsking(
        bundleID: String?,
        autoRecord: Bool,
        answer: AppAnswer?
    ) -> Bool {
        if let bundleID, askOnlyBundleIDs.contains(bundleID) { return false }
        switch answer {
        case .always: return true
        // `never` cannot reach here in the app — `armDecision` has already declined it —
        // but it is answered rather than defaulted, so that adding a case to `AppAnswer`
        // fails to compile instead of quietly recording something.
        case .ask, .never: return false
        case nil: return autoRecord
        }
    }
}

import AVFoundation
import Foundation
import Observation

/// What saying yes to a catch-up's closing question does.
///
/// The backend gives a catch-up no structured next step: its closing question is the last
/// sentence of the words, so the only honest way to act on it is the way the person would —
/// say yes in the conversation. That is an ordinary turn, and anything it would write or send
/// uses normal permissions, including standing grants. This seam is that one hand-off, so a check can watch it
/// without a model and the day a catch-up carries a prepared action it is the one place to
/// change.
@MainActor
protocol CatchUpOfferActing {
    /// Opens the conversation and sends `text` as the person's own words.
    func say(_ text: String)
    func say(_ text: String, for entry: CatchUpEntry)
}

extension CatchUpOfferActing {
    // Existing presentation recorders can still record the ordinary user words.
    func say(_ text: String, for entry: CatchUpEntry) { say(text) }
}

struct LiveCatchUpOfferActing: CatchUpOfferActing {
    private let session: AgentSession?
    private let open: @MainActor () -> Void
    private let submit: @MainActor (String, CatchUpAcceptance?) -> Void

    init(session: AgentSession? = nil,
         open: @escaping @MainActor () -> Void = { NavigationState.shared.showConversation() },
         submit: (@MainActor (String) -> Void)? = nil,
         submitAccepted: (@MainActor (String, CatchUpAcceptance?) -> Void)? = nil) {
        self.session = session
        self.open = open
        self.submit = submitAccepted ?? { text, context in
            if let submit { submit(text) }
            else { Task { await RealtimeAgent.shared.handleLive(text, source: .text, catchUpAcceptance: context) } }
        }
    }

    func say(_ text: String) {
        open()
        submit(text, nil)
    }

    func say(_ text: String, for entry: CatchUpEntry) {
        (session ?? .shared).recordBackgroundTask(entry.text, taskID: entry.id)
        open()
        submit(text, CatchUpAcceptance(entry: entry))
    }
}

/// The catch-ups on this Mac, newest first, read off the finished runs that wrote them.
///
/// There is no catch-up store. A catch-up is a finished run of the catch-up routine: its
/// words are the run's result, and its saved audio is the file linked to that same run
/// (`AgentTask.artifacts`). This reads the one task list the Agent already keeps, keeps the
/// runs the catch-up routine made, and notices the moment one gains its audio — that moment
/// is "ready", and it is announced once, never auto-played.
///
/// Reuse, not new logic: no scheduling, no rendering, no second list. The only thing owned
/// here is which closing offers the person has already answered, kept in preferences
/// because it is one person's own convenience rather than a fact about the catch-up.
@MainActor
@Observable
final class CatchUpLibrary {
    static let shared = CatchUpLibrary()

    /// Newest first. At most `Self.keep` rows.
    private(set) var entries: [CatchUpEntry] = []
    /// Bumped when an offer is answered. Preferences are not observable, so rows that read
    /// `openOffer` read this too and redraw.
    private(set) var answeredOffers = 0
    /// Set by whoever shows the "ready" moment (the island). Called once per catch-up, when
    /// its audio first appears after launch.
    @ObservationIgnored var onReady: ((CatchUpEntry) -> Void)?

    static let keep = 14

    @ObservationIgnored private let tasks: @MainActor () -> [AgentTask]
    @ObservationIgnored private let catchUpScheduleIDs: @MainActor () -> Set<UUID>
    @ObservationIgnored private let fileExists: (URL) -> Bool
    @ObservationIgnored private let measure: (URL) -> TimeInterval?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let offers: any CatchUpOfferActing

    @ObservationIgnored private var started = false
    @ObservationIgnored private var withAudio: Set<String> = []
    @ObservationIgnored private var durations: [URL: TimeInterval] = [:]
    @ObservationIgnored private var expiry: Task<Void, Never>?
    /// What the last read looked at. The Agent's task list changes many times a minute while
    /// it works; a read that finds the catch-up runs exactly as they were touches no file.
    @ObservationIgnored private var lastLook: [Look] = []

    private struct Look: Equatable {
        var id: String
        var finishedAt: Date?
        var resultLength: Int
        var artifactCount: Int
    }

    private static let handledKey = "catchUp.handledOffers"
    private static let handledKeep = 60

    init(
        tasks: @escaping @MainActor () -> [AgentTask] = { AgentTaskManager.shared.tasks },
        catchUpScheduleIDs: @escaping @MainActor () -> Set<UUID> = {
            Set(ScheduleStore.shared.schedules.filter(\.isCatchUp).map(\.id))
        },
        fileExists: @escaping (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) },
        measure: @escaping (URL) -> TimeInterval? = CatchUpLibrary.audioLength,
        defaults: UserDefaults? = nil,
        now: @escaping () -> Date = { Date() },
        offers: any CatchUpOfferActing = LiveCatchUpOfferActing()
    ) {
        self.tasks = tasks
        self.catchUpScheduleIDs = catchUpScheduleIDs
        self.fileExists = fileExists
        self.measure = measure
        self.defaults = defaults ?? (SelfTest.isRunning ? SelfTestHarnessDefaults.shared : .standard)
        self.now = now
        self.offers = offers
    }

    /// Reads the runs once without announcing anything that already exists, then follows the
    /// task list. Called once from the island, which is where "ready" is shown.
    func start() {
        guard !started else { return }
        started = true
        reload(announce: false)
        track()
    }

    /// A screen that is about to draw the list asks for a fresh read, which also notices a
    /// file the person has since deleted. It never announces anything.
    func refresh() {
        reload(announce: false, force: true)
    }

    /// The runs of the catch-up routine, as rows. `announce` is false for the first read, so
    /// a catch-up that was made yesterday is not announced again at launch.
    func reload(announce: Bool = true, force: Bool = false) {
        let scheduleIDs = catchUpScheduleIDs()
        let moments = Set(CatchUpTemplate.Moment.allCases.map { CatchUpTemplate.title(for: $0) })
        // The routine's own runs: by the routine's identity, or by the title it wore while
        // it was running if the routine has since been deleted. Cheap fields only, so the
        // files are not touched until this is the newest few.
        var candidates = tasks().filter { task in
            guard task.status == .completed, let scheduleID = task.scheduleID else { return false }
            return scheduleIDs.contains(scheduleID) || moments.contains(task.objective)
        }
        candidates.sort { ($0.finishedAt ?? $0.createdAt) > ($1.finishedAt ?? $1.createdAt) }
        candidates = Array(candidates.prefix(Self.keep))

        let look = candidates.map {
            Look(id: $0.id, finishedAt: $0.finishedAt, resultLength: $0.result?.count ?? 0,
                 artifactCount: $0.artifacts.count)
        }
        guard force || look != lastLook else { return }
        lastLook = look

        var next: [CatchUpEntry] = []
        for task in candidates {
            let audio = audioFile(of: task)
            let entry = CatchUpText.entry(
                id: task.id, title: task.objective, madeAt: task.finishedAt ?? task.createdAt,
                text: task.result ?? "", audioURL: audio, duration: audio.flatMap(length))
            if let entry { next.append(entry) }
        }
        next.sort { $0.madeAt > $1.madeAt }

        let audible = Set(next.filter { $0.audioURL != nil }.map(\.id))
        let arrived = next.filter { $0.audioURL != nil && !withAudio.contains($0.id) }
        withAudio.formUnion(audible)
        if next != entries { entries = next }
        scheduleExpiry()
        if announce, started, let newest = arrived.first { onReady?(newest) }
    }

    /// The file a run's saved-audio step linked to it, if it is still there.
    private func audioFile(of task: AgentTask) -> URL? {
        let directory = LongFormRenderer.audioDirectory.standardizedFileURL.path
        for value in task.artifacts {
            guard let url = URL(string: value), url.isFileURL,
                  url.standardizedFileURL.path.hasPrefix(directory + "/"),
                  ["m4a", "wav"].contains(url.pathExtension.lowercased()),
                  fileExists(url) else { continue }
            return url
        }
        return nil
    }

    private func length(of url: URL) -> TimeInterval? {
        if let known = durations[url] { return known }
        guard let measured = measure(url) else { return nil }
        durations[url] = measured
        return measured
    }

    nonisolated static func audioLength(_ url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else {
            return nil
        }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    // MARK: - Following the task list

    /// `withObservationTracking` fires once, so it re-arms from a hop — the same shape the
    /// island uses. Only the task list is read, and a read that finds the catch-up runs as
    /// they were costs one filter, so the many progress updates a busy Agent makes are cheap.
    private func track() {
        withObservationTracking {
            _ = tasks()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.reload()
                self.track()
            }
        }
    }

    /// A catch-up still waiting for its audio stops claiming it is "getting it ready" after
    /// `audioWaitWindow`, and nothing else changes at that moment, so one sleep re-reads.
    private func scheduleExpiry() {
        expiry?.cancel()
        expiry = nil
        let current = now()
        guard let waiting = entries.first(where: { $0.isPreparingAudio(now: current) }) else { return }
        let remaining = waiting.madeAt.addingTimeInterval(CatchUpEntry.audioWaitWindow)
            .timeIntervalSince(current)
        expiry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(1, remaining + 1)))
            guard !Task.isCancelled else { return }
            self?.reload(announce: false, force: true)
        }
    }

    // MARK: - The closing offer

    private var handled: Set<String> {
        Set(defaults.stringArray(forKey: Self.handledKey) ?? [])
    }

    /// The one catch-up whose closing question is still worth a button: the newest, still
    /// fresh, not yet answered. Older ones keep their words and lose their buttons.
    func openOffer(for entry: CatchUpEntry) -> CatchUpOffer? {
        _ = answeredOffers
        guard entry.id == entries.first?.id, entry.offerIsFresh(now: now()),
              !handled.contains(entry.id) else { return nil }
        return entry.offer
    }

    /// "Not now", or the answer being given: either way the question is closed.
    func closeOffer(_ entry: CatchUpEntry) {
        var ids = (defaults.stringArray(forKey: Self.handledKey) ?? []).filter { $0 != entry.id }
        ids.append(entry.id)
        defaults.set(Array(ids.suffix(Self.handledKeep)), forKey: Self.handledKey)
        answeredOffers += 1
    }

    /// Saying yes starts an ordinary turn in the conversation. Whatever it would write or send
    /// uses normal permissions: an existing covering grant can run it without a new card.
    func acceptOffer(_ entry: CatchUpEntry) {
        guard let offer = openOffer(for: entry) else { return }
        closeOffer(entry)
        offers.say(offer.yesText, for: entry)
    }
}

/// The existing file transport, replaced by a recorder in headless checks.
@MainActor
protocol CatchUpAudioPlaying: AnyObject {
    var duration: TimeInterval { get }
    var currentTime: TimeInterval { get }
    var isPlaying: Bool { get }
    func prepareToPlay() -> Bool
    func play() -> Bool
    func pause()
    func stop()
}

extension AVAudioPlayer: CatchUpAudioPlaying {}

struct CatchUpPlaybackActivity {
    var activationIdle = true
    var dictating = false
    var recording = false
    var speaking = false
    var callActive = false

    var permitsPlayback: Bool {
        activationIdle && !dictating && !recording && !speaking && !callActive
    }

    @MainActor static var live: Self {
        Self(activationIdle: ActivationController.shared.mode == .idle,
             dictating: AppDelegate.current?.controller.state.isActive ?? false,
             recording: MeetingController.shared.isRecording,
             speaking: RealtimeAudioSession.shared.isSpeaking || AgentSpeechSynthesizer.shared.isSpeaking,
             callActive: CallDetector.shared.current != nil)
    }
}

/// Plays a catch-up's saved audio when the person presses Play. Nothing starts it otherwise.
///
/// One player for the whole app, so a second Play replaces the first and the island's Play
/// and the Library's Play are the same button. It yields to a conversation: while the Agent is
/// listening or working the briefing pauses, and stays paused until another tap.
/// File PCM is not an echo reference: detection suppression and interruption are
/// conservative mitigations, not acoustic isolation.
@MainActor
@Observable
final class CatchUpPlayer {
    static let shared = CatchUpPlayer()

    private(set) var playingID: String?
    private(set) var isPlaying = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    /// A plain sentence when the file would not open, cleared by the next Play.
    private(set) var problem: String?

    @ObservationIgnored private var player: (any CatchUpAudioPlaying)?
    @ObservationIgnored private let activity: @MainActor () -> CatchUpPlaybackActivity
    @ObservationIgnored private let makePlayer: @MainActor (URL) throws -> any CatchUpAudioPlaying

    init(activity: @escaping @MainActor () -> CatchUpPlaybackActivity = { .live },
         makePlayer: @escaping @MainActor (URL) throws -> any CatchUpAudioPlaying = { try AVAudioPlayer(contentsOf: $0) },
         now: @escaping () -> Date = { Date() }) {
        self.activity = activity
        self.makePlayer = makePlayer
        self.now = now
    }
    @ObservationIgnored private var ticker: Task<Void, Never>?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var wakeSuppressedUntil = Date.distantPast
    var suppressesWakeDetection: Bool { isPlaying || now() < wakeSuppressedUntil }


    var progress: Double { duration > 0 ? min(1, elapsed / duration) : 0 }

    func isCurrent(_ entry: CatchUpEntry) -> Bool { playingID == entry.id }

    func toggle(_ entry: CatchUpEntry) {
        if isCurrent(entry), let player {
            if isPlaying { pause() } else { resume(player) }
        } else {
            play(entry)
        }
    }

    func play(_ entry: CatchUpEntry) {
        stop()
        problem = nil
        guard let url = entry.audioURL, permitPlayback() else { return }
        do {
            let next = try makePlayer(url)
            guard next.prepareToPlay(), next.play() else { throw CocoaError(.fileReadUnknown) }
            player = next
            playingID = entry.id
            duration = next.duration
            elapsed = 0
            isPlaying = true
            observeActivity()
            tick()
        } catch {
            problem = "That recording can\u{2019}t be played right now."
        }
    }

    func pause() {
        if isPlaying { wakeSuppressedUntil = now().addingTimeInterval(1) }
        player?.pause()
        isPlaying = false
        ticker?.cancel()
        ticker = nil
        elapsed = player?.currentTime ?? elapsed
    }

    private func resume(_ player: any CatchUpAudioPlaying) {
        guard permitPlayback(), player.play() else { return }
        isPlaying = true
        observeActivity()
        tick()
    }

    func stop() {
        if isPlaying { wakeSuppressedUntil = now().addingTimeInterval(1) }
        player?.stop()
        player = nil
        ticker?.cancel()
        ticker = nil
        playingID = nil
        isPlaying = false
        elapsed = 0
        duration = 0
    }

    /// Four times a second while playing: moves the bar, notices the end, and steps aside for
    /// a conversation. Stops itself the moment there is nothing to follow.
    private func tick() {
        ticker?.cancel()
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.player != nil, !Task.isCancelled else { return }
                self.pollPlayback()
                if !self.isPlaying { return }
            }
        }
    }


    /// No await: read the same activity facts before opening/starting/resuming a file
    /// and on the existing tick. Never resumes automatically when the activity ends.
    private func permitPlayback() -> Bool {
        guard activity().permitsPlayback else {
            problem = "Finish talking or recording, then try Play again."
            return false
        }
        problem = nil
        return true
    }

    /// Observation fires synchronously at the activity producer's willSet. Pause on
    /// any tracked change (conservative), without waiting for the progress tick.
    /// All live activity producers are MainActor; no microphone seat is stopped.
    @ObservationIgnored private var activityObserved = false
    private func observeActivity() {
        guard !activityObserved else { return }
        activityObserved = true
        withObservationTracking {
            _ = activity()
        } onChange: { [weak self] in
            MainActor.assumeIsolated {
                self?.activityObserved = false
                self?.pause()
            }
        }
    }

    func pollPlayback() {
        guard isPlaying, let player else { return }
        elapsed = player.currentTime
        if !permitPlayback() {
            pause()
            return
        }
        if !player.isPlaying { stop() }
    }
}

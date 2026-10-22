import NextNotesDictionary
import AVFoundation
import AppKit
import Foundation
import Observation
import OSLog

/// Where the dictation controller's error lines go (D-15c).
///
/// A seam, not a `SelfTest.isRunning` branch: the controller asks `log` where an error goes
/// and never knows which of the two it was handed.
///
/// `--selftest-dictation` drives the real state machine with deliberately tiny deadlines —
/// a 2-second transcription bound against an injected engine that never finishes on cue — so
/// every one of those holds logs exactly the sentences a production failure logs. In the
/// unified log they were indistinguishable from the real thing (I1-19 counted 8 + 4 + 4 of
/// them on 2026-09-23), which is a slower audit and a real failure that a reader could talk
/// herself out of. `.selfTest` writes the same sentences at **info** in a `selftest`
/// category with a `[selftest]` prefix, so a run that injected the failure says so in the
/// line itself and `--last 3m` greps for it by category.
///
/// Two closures rather than the single `error` the seam was specified with: `fail` writes
/// under the `app` category and the three deadline lines under `speech`, and collapsing them
/// would move a user-facing failure message into the speech category in production, which
/// is a change nobody asked for. Production here is byte-identical to before.
struct DictationLogger: Sendable {
    var speechError: @Sendable (String) -> Void
    var appError: @Sendable (String) -> Void

    static let production = DictationLogger(
        speechError: { message in
            Log.speech.error("\(message, privacy: .public)")
        },
        appError: { message in
            Log.app.error("\(message, privacy: .public)")
        }
    )

    static let selfTest = DictationLogger(
        speechError: { SelfTestLogger.shared.error($0) },
        appError: { SelfTestLogger.shared.error($0) }
    )
}

/// The one logger `--selftest-dictation`'s failures are written to. A type of its own so the
/// category string is spelled once, and lazily created so an ordinary run pays nothing.
private struct SelfTestLogger {
    static let shared = SelfTestLogger()

    private let logger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "selftest")

    func error(_ message: String) {
        logger.info("[selftest] \(message, privacy: .public)")
    }
}

/// Builds the engine named by the current setting.
///
/// Deliberately at file scope rather than a static on `DictationController`: the class is
/// `@MainActor`, which would make a static method main-actor-isolated and therefore
/// ineligible to be `@Sendable`. Reading the setting per-utterance is what lets the menu's
/// engine picker take effect on the very next hold instead of needing a restart.
@MainActor
func engineForCurrentSetting() -> any TranscriptionEngine {
    let settings = Settings.shared
    let selected = settings.resolvedSpeechEngine
    let store = ASRModelStore.shared
    let ready = ASRModelCatalog.readyChoice(settings.engine, language: settings.dictationLanguage,
                                          readyModel: store.readyModel)
    if ready != selected, store.preparing == nil, store.failure == nil { store.prepare(selected) }
    return engineForSetting(ready, language: settings.dictationLanguage)
}

@MainActor
func engineForSetting(_ choice: SpeechEngineChoice, language: DictationLanguage) -> any TranscriptionEngine {
    let resolved = ASRModelCatalog.resolved(choice, language: language)
    if resolved == .apple {
        return AppleSpeechEngine(locale: language == .english ? Locale(identifier: "en-US") : .current)
    }
    return ParakeetEngine(model: resolved, englishOnly: language == .english)
}

/// Resumes its caller with whichever of two racers arrives first, and drops the other.
///
/// A one-shot latch rather than a task group, and the difference is the whole point: a
/// group awaits every child before it returns, so the child that hung would still be
/// awaited after the timeout fired.
private actor RaceGate<T: Sendable> {
    private var waiter: CheckedContinuation<T?, Never>?
    private var settled = false
    private var result: T?

    func settle(_ value: T?) {
        guard !settled else { return }
        settled = true
        result = value
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: value)
        }
    }

    func value() async -> T? {
        if settled { return result }
        return await withCheckedContinuation { waiter = $0 }
    }
}

/// Counts buffers that actually made it through the shared hub into this hold.
/// The audio callback is off the main actor, while key-up reads the result there.
private final class DictationAudioCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    /// 20 ms windows at or above the speech threshold (D-03), counted through
    /// the injected `speechDetector` on the capture callback.
    private var voiced = 0
    /// Frames yielded into the engine stream but not yet fed (D-02 pre-roll depth).
    private var pending = 0
    /// Hub worker overflows and pre-roll cap drops (D-01b's `droppedHubBuffers`
    /// and `droppedStreamBuffers`; filed once the usage rows land).
    private var hubDrops = 0
    private var streamDrops = 0
    /// The hold's captured audio (D-03), kept in memory until its outcome is known
    /// so a hold that came back with nothing can be tried again. Memory only: never
    /// written to disk, never filed into a run or a usage row.
    private var recording: [AudioChunk] = []
    private var recordingFrames = 0
    private var recordingCapped = false
    /// The format capture opened in (D-03). A kept hold is only replayable into an
    /// engine that wants this one — SpeechAnalyzer aborts the process on anything
    /// but int16 — so the retry compares before it feeds.
    private var inputFormat: AVAudioFormat?

    func add(_ frames: Int) {
        lock.lock()
        count += frames
        lock.unlock()
    }

    func addVoiced(_ windows: Int) {
        lock.lock()
        voiced += windows
        lock.unlock()
    }

    func noteFormat(_ format: AVAudioFormat) {
        lock.lock()
        inputFormat = format
        lock.unlock()
    }

    /// Keeps the chunk for "Try again" (D-03), up to `capFrames` of audio. Past the
    /// cap the appends stop and the hold is marked truncated rather than growing
    /// without bound; what it kept is still retryable.
    func keep(_ chunk: AudioChunk, capFrames: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard !recordingCapped else { return }
        let frames = Int(chunk.buffer.frameLength)
        guard recordingFrames + frames <= capFrames else {
            recordingCapped = true
            return
        }
        recording.append(chunk)
        recordingFrames += frames
    }

    /// Restores a kept failed hold into a fresh counter (D-03's retry), so the replay
    /// is an ordinary hold whose "capture" is the audio the last one kept. `pending`
    /// is seeded alongside the frame count so the drain's `release` stays balanced.
    func seed(chunks: [AudioChunk], frames: Int, voicedWindows: Int, format: AVAudioFormat?) {
        lock.lock()
        defer { lock.unlock() }
        recording = chunks
        recordingFrames = frames
        recordingCapped = false
        count = frames
        pending = frames
        voiced = voicedWindows
        inputFormat = format
    }

    /// The kept audio, and whether the 180 s cap cut it short (D-01b's `truncated`).
    var kept: [AudioChunk] {
        lock.lock()
        defer { lock.unlock() }
        return recording
    }

    var isRecordingCapped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return recordingCapped
    }

    var captureFormat: AVAudioFormat? {
        lock.lock()
        defer { lock.unlock() }
        return inputFormat
    }

    /// Reserve room for `frames` more under `cap`. False means the buffer is not
    /// yielded and the drop is counted; the hold still transcribes what it kept.
    func reserve(_ frames: Int, cap: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard pending + frames <= cap else {
            streamDrops += 1
            return false
        }
        pending += frames
        return true
    }

    func release(_ frames: Int) {
        lock.lock()
        defer { lock.unlock() }
        pending = max(0, pending - frames)
    }

    func addHubDrops(_ n: Int) {
        lock.lock()
        defer { lock.unlock() }
        hubDrops += n
    }

    /// Read at outcome time for the hold's `droppedHubBuffers` count (D-01b).
    var hubDropCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return hubDrops
    }

    /// Read at outcome time for the hold's `droppedStreamBuffers` count (D-01b).
    var streamDropCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return streamDrops
    }

    var frames: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    var voicedFrames: Int {
        lock.lock()
        defer { lock.unlock() }
        return voiced
    }
}

/// Default speech-energy detector (D-03): counts the 20 ms windows in a buffer
/// at or above the meeting silence gate (RMS 0.01 ≈ −40 dBFS — the kept limit
/// reused here, never changed). First channel only, float or int16, whichever
/// the engine's input format carries. A partial trailing window is ignored.
@Sendable func defaultSpeechDetector(_ buffer: AVAudioPCMBuffer) -> Int {
    let count = Int(buffer.frameLength)
    guard count > 0 else { return 0 }
    let window = 320
    let threshold: Float = 0.01
    let stride = buffer.stride
    if let samples = buffer.floatChannelData?[0] {
        var voiced = 0
        var start = 0
        while start + window <= count {
            var sum: Float = 0
            for i in 0..<window {
                let s = samples[(start + i) * stride]
                sum += s * s
            }
            if (sum / Float(window)).squareRoot() >= threshold { voiced += 1 }
            start += window
        }
        return voiced
    } else if let samples = buffer.int16ChannelData?[0] {
        var voiced = 0
        var start = 0
        while start + window <= count {
            var sum: Float = 0
            for i in 0..<window {
                let s = Float(samples[(start + i) * stride]) / 32_768
                sum += s * s
            }
            if (sum / Float(window)).squareRoot() >= threshold { voiced += 1 }
            start += window
        }
        return voiced
    }
    return 0
}

/// One failed hold's audio, kept in memory so the user can say "Try again" (D-03).
///
/// Exactly one of these exists at a time and it is never written anywhere — not to
/// disk, not into a run row, not into a usage row. The counts ride along because the
/// retry is a new hold that still has to make the same empty-vs-silence decision, and
/// `format` because a kept hold is only replayable into an engine that wants the format
/// it was captured in.
private struct FailedHold {
    let chunks: [AudioChunk]
    let capturedFrames: Int
    let voicedFrames: Int
    let format: AVAudioFormat?
}

/// Runs `work` with a deadline. Returns `nil` — and abandons the work — if it overruns.
///
/// Every await in the `endDictation` tail is behind this. Unbounded, any one of them
/// (`finish()` waiting on a model load, a cleanup pass, a transcript stream nobody
/// finished) leaves the controller in `.finishing` for as long as it takes, and
/// `.finishing` is indistinguishable from recording in the HUD and the island. A
/// dictation that fails loudly after N seconds and returns to `.idle` is strictly
/// better than one that never comes back.
///
/// The losing task is cancelled, but cancellation is only a request: CoreML inference
/// and a llama.cpp decode loop both run to completion regardless. That is accepted —
/// what matters is that the *user's* wait is bounded, not that the CPU stops.
func withBoundedWait<T: Sendable>(
    _ limit: Duration,
    joinCancelledWork: Bool = false,
    _ work: @escaping @Sendable () async -> T
) async -> T? {
    let gate = RaceGate<T>()
    let job = Task(priority: .userInitiated) { await gate.settle(await work()) }
    let timer = Task {
        try? await Task.sleep(for: limit)
        await gate.settle(nil)
    }

    return await withTaskCancellationHandler {
        let result = await gate.value()
        timer.cancel()
        if result == nil {
            job.cancel()
            // Background voice ownership cannot report return while its SAME
            // cancelled child is still entered. Foreground callers keep their
            // existing bounded return; cancellation receipts never await this drain.
            if joinCancelledWork { await job.value }
        }
        return result
    } onCancel: {
        // A new spoken turn cancels the old planner's parent task. Without
        // forwarding that cancellation, its unstructured model job kept
        // running until the deadline and competed with live ASR/TTS.
        job.cancel()
        timer.cancel()
        Task { await gate.settle(nil) }
    }
}

@MainActor
@Observable
final class DictationController {
    enum State: Equatable {
        case idle
        case starting
        case listening
        case finishing
        case error(String)

        var isActive: Bool {
            switch self {
            case .starting, .listening, .finishing: true
            case .idle, .error: false
            }
        }

        /// Errors stay visible for their three-second lifetime without being considered an
        /// active recording by state guards, menu indicators, or waveform animation.
        var shouldShowHUD: Bool { self != .idle }
    }

    private(set) var state: State = .idle
    /// The actual injector's latest successful outcome. Memory only: the usage row
    /// deliberately carries no words, and the history row is written before insertion.
    struct Delivery: Equatable {
        enum Kind: Equatable { case inserted, copied }
        let id: UUID
        let text: String
        let kind: Kind
    }
    private(set) var latestDelivery: Delivery?

    /// One mounted practice surface may observe accepted holds synchronously. Sampling
    /// focus here avoids inferring key-down focus from a later SwiftUI state update.
    @ObservationIgnored private var holdPresentationObserver:
        (owner: UUID, receive: (UUID) -> Void)?

    func observeHoldBeginnings(owner: UUID, receive: @escaping (UUID) -> Void) {
        holdPresentationObserver = (owner, receive)
    }

    func stopObservingHoldBeginnings(owner: UUID) {
        guard holdPresentationObserver?.owner == owner else { return }
        holdPresentationObserver = nil
    }
    /// Whether the global event tap is actually armed. Accessibility can appear enabled in
    /// System Settings while a rebuilt/ad-hoc-signed binary is no longer trusted.
    private(set) var hotkeyReady = false
    /// Live transcript, updated as the engine revises it. Drives the HUD.
    private(set) var transcript = ""
    /// Smoothed 0…1 mic level for the waveform.
    private(set) var level: Float = 0
    private var audioCounter: DictationAudioCounter?
    /// Open from `.listening` until the first non-empty ASR chunk — speech → first partial.
    private var firstPartialTrace: LatencyTrace?
    /// Open from key-down until hub subscribe succeeds — keyDown → capture started.
    private var keyDownToCaptureTrace: LatencyTrace?
    /// Key-down → hub subscribe, in seconds, set when the pre-roll subscribe succeeds.
    /// Read by `--selftest-dictation` (D-02 case c); D-01b files it as
    /// `counts["keyDownToCaptureMs"]` on the hold row, absent when capture never started.
    private(set) var keyDownToCaptureSeconds: TimeInterval?
    /// True from the pre-roll hub subscribe until the microphone closes. The island
    /// and the HUD read it so a hold shows as capturing while `.starting` (D-02):
    /// the mic is open and the utterance is being kept, even though no partial
    /// has arrived yet.
    private(set) var isCapturingAudio = false
    /// Which half of the tail a `.finishing` hold is in. The tail already runs these as
    /// separate legs (`runTail`: transcribe, then clean up); this only publishes which one
    /// it is on, so the HUD and the island can say "Writing it out…" and then "Tidying
    /// up…" over the words already heard instead of one opaque "Finishing…". Read only
    /// while `state == .finishing`; every entry into `.finishing` resets it.
    enum FinishingStage: Equatable { case transcribing, tidying }
    private(set) var finishingStage: FinishingStage = .transcribing
    /// The session whose key was released while `.starting`. The start Task feeds
    /// that session's pre-roll into the engine and runs the normal tail for it
    /// instead of failing (D-02). Reset on every new hold.
    private var releasedDuringStartup: Int?

    private let hotkey = HotkeyMonitor()
    private let commandHotkey = HotkeyMonitor()
    private let makeEngine: @MainActor @Sendable () -> any TranscriptionEngine

    /// Injected only by tests; production reads the setting per-utterance below.
    private let formatter: (any TextFormatter)?
    /// Injected only by tests; production types into whatever had focus. A self-test that
    /// used the real injector would type its fixture into the terminal that started it.
    private let insert: (@MainActor (String, TextInjector.Origin?) async -> TextInjector.Outcome)?
    /// Injected only by tests; production files the run for the Dictation list. A self-test
    /// that used the real log would write its fixtures into the user's own history — which
    /// it did, until this seam existed.
    private let record: @MainActor (DictationRun) -> Void
    /// Where this controller's error sentences go (D-15c). Production writes them at error
    /// level; `--selftest-dictation` writes the same sentences at info in a `selftest`
    /// category, because that run injects the failures on purpose.
    private let log: DictationLogger
    /// Where one hold's outcome row goes (D-01b). Production writes a `dictation.hold`
    /// row through `UsageLog.shared`; a self-test passes its own sink so it can assert on
    /// the outcomes without touching any store.
    private let outcomeSink: @MainActor (DictationHoldOutcome) -> Void
    /// Where the dictation's usage rows go (P0-20c). Injected only by tests; production
    /// appends to the real `usage.jsonl`, and a test injects a directory of its own so it
    /// can read the rows back without touching the harness temp store.
    private let usage: UsageLog
    private let commandProcessor: any TextCommandProcessor

    /// Chosen per-utterance so the menu toggle applies to the very next hold.
    ///
    /// A function rather than a computed property because of `context`: the names visible on
    /// screen are harvested on a detached task and have to be awaited, and a property has
    /// nowhere to put the await. It stays private, so nothing outside this file is affected.
    private func activeFormatter(
        context: ScreenContext,
        trace: CleanupTrace?,
        head: CleanupHead? = nil
    ) -> any TextFormatter {
        if let formatter { return formatter }
        let settings = Settings.shared
        // What the app about to receive this text can actually render, captured at
        // key-down. Resolving it here rather than at injection time is the whole point:
        // formatting a list as Slack bullets and then dropping it into Mail is worse than
        // not formatting at all.
        let target = referenceProfile ?? OutputProfileStore.shared.capturedProfile
        // Rules first, then the engine this hold already would have built — on every
        // transcript unless the user opted into skipping it while the Mac is busy. The
        // picker, the S1-takes-no-instructions rule, "grammar on means Apple alone" and the
        // busy shortcut all live on the router so this switch cannot drift from the policy.
        return CleanupRouter.production(
            choice: settings.cleanupEngine,
            preferences: settings.cleanupPreferences,
            fixesGrammar: settings.cleanupFixesGrammar,
            target: target,
            context: context,
            skipsModelWhenBusy: settings.cleanupSkipsModelWhenBusy,
            // Filed on the run afterwards. Without it, "the model does no grammar" and "the
            // model's answer was rejected" and "the model timed out" all look identical in
            // `runs.jsonl`, which stores only the finished string.
            trace: trace,
            // What the hold tidied while the key was down (D-12). Nil on a hold that closed
            // no group, and on every hold that is not a plain dictation.
            head: head
        )
    }

    /// The hold's pre-clean session, or nil when this hold cannot use one. (D-12.)
    ///
    /// Ordinary dictation, cleanup switched on, and the engine the router would use anyway
    /// being Apple or MiniCPM — the engines with the budget to be worth running beside a live
    /// recogniser, and the only one whose answer the guard can check. Command Mode and
    /// compare mode get nothing: the first never reaches this formatter, and the second runs
    /// every engine over the same recording and must not be handed a head.
    ///
    /// `context: .empty` on purpose. The screen-name harvest is started at key-down and is
    /// still walking when `.listening` is reached, so a pre-cleaned group is tidied without
    /// the names on screen. A spoken file name in a *finished* sentence is still written by
    /// `FileReferences` after the dictionary, in code, which is the pass that has always
    /// resolved them.
    private func makeIncrementalCleanup() -> IncrementalCleanupSession? {
        guard recordingIntent.kind == .dictation, !isComparing else { return nil }
        let settings = Settings.shared
        let engine = CleanupRouter.preferredEngine(
            choice: settings.cleanupEngine,
            fixesGrammar: settings.cleanupFixesGrammar
        )
        guard settings.cleanupEnabled, engine == .apple || engine == .miniCPM else { return nil }
        let rules: @Sendable (String) -> String = { RuleBasedFormatter().apply($0, isFinal: false) }
        if let cleanupPieces {
            return IncrementalCleanupSession(semantic: cleanupPieces().preclean, rules: rules)
        }
        // The bare-formatter seam replaces the whole chain, so there is no Stage B here to
        // pre-clean with and no way to hand it a head.
        guard formatter == nil else { return nil }
        return IncrementalCleanupSession(
            // The same Stage B the router builds: the guard and D-11's clause salvage
            // included, and no trace — a pre-clean runs before this hold's record exists.
            semantic: CleanupRouter.makeSemantic(
                engine,
                preferences: settings.cleanupPreferences,
                fixesGrammar: settings.cleanupFixesGrammar,
                target: referenceProfile ?? OutputProfileStore.shared.capturedProfile,
                context: .empty
            ),
            rules: rules
        )
    }

    /// Give up this hold's pre-cleans. (D-12.)
    ///
    /// A hold that is over — an error card, a cancel, a new press — must not leave model
    /// work running behind it, and must not let a superseded hold's groups be handed to
    /// this one's tail. Idempotent, so every exit can call it without asking first.
    private func dropIncrementalCleanup() {
        guard let session = incrementalCleanup else { return }
        incrementalCleanup = nil
        Task { await session.cancel() }
    }

    /// Whether the formatter this hold is about to build can be told anything at all about
    /// the screen. False means the harvest is not merely unused but must not be *scored*.
    ///
    /// Mirrors `activeFormatter(context:)` above, and has to be read against it rather than
    /// guessed at: the injected `formatter` test seam ignores the context, and punctuation-only
    /// S1-mini takes no instructions — but S1-mini *with* grammar repair uses Apple, which
    /// does honour it, so the engine alone does not answer the question.
    /// Rewrites the file names the speaker clearly said as the target app's reference syntax.
    /// See `FileReferences` for what "clearly" means, and why this is code rather than a
    /// prompt rule.
    ///
    /// Off the main actor, and with the loose match limited to the names narrowing already found
    /// plausible. Both for the same measurement: a 344-word dictation against 67 names took
    /// 1,986 ms in the debug build `make install` ships when every name could fall back to the
    /// loose match, and 171 ms with that limited to five — the first is a frozen HUD, and the
    /// second is still no business of the thread drawing it.
    private func tagFileReferences(in text: String, screen: ScreenContext) async -> String {
        guard tagsFileReferences, !screen.isEmpty else { return text }
        let style: FileReferences.Style
        switch (referenceProfile ?? OutputProfileStore.shared.capturedProfile).pathReference {
        case .plain: return text
        case .atRelative: style = .atPath
        case .backtickPath: style = .backtickPath
        }
        // The harvest's own file-or-folder answer rather than a guess from the string: it is the
        // only thing that knows `Makefile` is a file and `src` is not.
        let candidates = screen.candidates.map {
            FileReferences.Candidate(reference: $0.reference, isFile: $0.isFile)
        }
        let plausible = screen.mentionCount
        let tagged = await Task.detached(priority: .userInitiated) {
            FileReferences.tag(text, candidates: candidates, style: style, looseMatchLimit: plausible)
        }.value
        if !tagged.references.isEmpty {
            Log.speech.info("file references · tagged \(tagged.references.count, privacy: .public)")
        }
        return tagged.text
    }

    /// Whether the app this hold is going into resolves file references, so a spoken file name
    /// is worth rewriting as one after cleanup — whichever engine ran. `FileReferences` does
    /// that in code, which is what lets S1-mini, with no prompt to carry the names, tag files
    /// too. The test seam opts out for the same reason it does above.
    private var tagsFileReferences: Bool {
        if formatter != nil { return false }
        return (referenceProfile ?? OutputProfileStore.shared.capturedProfile).resolvesPaths
    }

    private var formatterUsesContext: Bool {
        if formatter != nil { return false }
        let settings = Settings.shared
        return settings.cleanupEngine != .s1Mini || settings.cleanupFixesGrammar
    }

    /// The harvested names, narrowed to the ones this transcript plausibly mentions.
    ///
    /// The second read of the harvest that started at key-down, and the patient one: by now the
    /// walk finished seconds ago, so a full second of budget is a formality that only matters
    /// for an utterance short enough to beat a slow tree.
    ///
    /// `narrowed(toMentionsIn:)` is what keeps this list honest. The prompt gets up to
    /// `ScreenContext.promptNameLimit` names rather than the ten the recognizer got, and that is
    /// safe for a reason the recognizer's cap does not share: this pass is editing text that
    /// already exists, so a name nothing was said about is inert here instead of being a word
    /// the model can reach for on quiet audio.
    ///
    /// It is also the most expensive pure computation in the app, and this method exists
    /// because it used to run inline on the main actor. Every candidate is scored against every
    /// window of up to six transcript tokens, so with a Cursor sidebar's 200 names it measured
    /// 3 s for a one-minute utterance in the debug configuration `make install` builds — three
    /// seconds of frozen HUD between transcription and injection, billed to `cleanup` in the
    /// tail log, and paid in full even where the result was thrown away. So: skipped outright
    /// when no formatter can read it, run off the main actor, and bounded.
    ///
    /// The bound stops the *waiting*, not the arithmetic — there is no cancellation point
    /// inside the scoring — so a run that overshoots finishes unobserved on a background
    /// thread while the prompt is built from `rankLimited()`. That is the right trade for a
    /// list whose ordering is an optimisation: rank order is what the ASR slice already uses,
    /// and it is a worse list rather than no list.
    private func screenNames(mentionedIn raw: String) async -> ScreenContext {
        guard formatterUsesContext || tagsFileReferences else { return .empty }

        let harvested: ScreenContext
        if let contextCapture {
            harvested = await contextCapture()
        } else {
            harvested = await ScreenContextStore.shared.awaitCapture(within: .seconds(1))
        }
        guard !harvested.isEmpty else { return harvested }

        // Not `Task.detached`: `withBoundedWait` runs its closure in a task started from a
        // nonisolated function, so the body is already off the main actor. One mechanism for
        // the bound and the hop, rather than two nested ones.
        let narrowed = await withBoundedWait(limits.narrow) {
            harvested.narrowed(toMentionsIn: raw)
        }
        if let narrowed { return narrowed }
        log.speechError("""
            narrowing \(harvested.candidates.count) screen name(s) did not \
            finish within \(String(describing: self.limits.narrow)) — \
            using rank order
            """)
        return harvested.rankLimited()
    }

    private var engine: (any TranscriptionEngine)?
    private var consumeTask: Task<Void, Never>?
    /// Drains the captured buffers into the engine, in capture order. The recording
    /// itself is kept on the hold's counter (D-03), not returned from here.
    private var feedTask: Task<Void, Never>?
    private var audioContinuation: AsyncStream<AudioChunk>.Continuation?
    /// The existing hub worker's accepted packets at key-up, owned by this hold.
    private var captureDrainTask: Task<Bool, Never>?

    /// Controller-owned `.realtimeASR` lane for Apple (Parakeet holds its own
    /// inside `ParakeetEngine`). Nil when idle or when Parakeet is the engine.
    /// Paired with `asrLaneSession` so a superseded start releases *its* id
    /// without clearing a later hold's.
    private var asrLaneID: UUID?
    private var asrLaneSession = 0

    /// The sentences tidied while the key was still down (D-12). One slot, like the three
    /// above it: created at `.listening`, fed by the `consumeTask`, taken by the tail, and
    /// dropped by every exit that ends a hold. A hold with none is the old behaviour in
    /// full, which is why nothing here is required for the pass at key-up to work.
    private var incrementalCleanup: IncrementalCleanupSession?

    /// Which hold the slots above belong to.
    ///
    /// `engine`, `consumeTask`, `feedTask` and `audioContinuation` are one slot each, and
    /// starting a recording is *slow* — `engine.start()` loads Parakeet, which is eleven
    /// seconds cold. So a hold that is released during start-up, followed by a second
    /// hold, has two start-up tasks in flight against one set of slots. Left unguarded the
    /// late one writes its engine over the live one's, and then `endDictation` calls
    /// `finish()` on engine B while awaiting the transcript stream of engine A — a stream
    /// nobody will ever finish. That await never returns and the controller stays in
    /// `.finishing` forever.
    ///
    /// Every continuation that writes back into those slots re-checks this first, and a
    /// start-up that finds it has been superseded tears down *its own* objects and touches
    /// nothing else.
    private var session = 0

    /// Deadlines for the legs of a hold. Generous against measurements on this machine —
    /// Parakeet runs at ~57× realtime once warm and S1-mini cleans a normal utterance in
    /// about a second — so a run that trips one of these has gone wrong rather than merely
    /// being long.
    ///
    /// Injectable so `--selftest-dictation` can prove the deadlines fire without taking
    /// two minutes to do it. Production always uses `.standard`.
    struct Limits: Sendable {
        /// `engine.start()`. Loading Parakeet from disk takes ~11s; the first-ever run
        /// downloads ~470 MB, which is what the message on timeout points at.
        var startup = Duration.seconds(45)
        /// Draining the buffers already captured into the engine.
        var drain = Duration.seconds(10)
        /// `finish()` plus the transcript stream: the actual transcription.
        var transcribe = Duration.seconds(90)
        /// Smart cleanup. On timeout the raw transcript is used — never dropped.
        var cleanup = Duration.seconds(30)
        /// Scoring the harvested names against the transcript.
        ///
        /// Pure arithmetic, but not free arithmetic: every candidate is scored against every
        /// window of up to six transcript tokens, so the cost is linear in the utterance and
        /// multiplied by up to `AXHarvester.Budget.maxCandidates` names. Measured on this
        /// machine with 200 names — a full Cursor sidebar — a 136-word transcript takes 0.13s
        /// optimised and 2.9s at `-Onone`, which is the debug configuration `make install`
        /// actually builds. Two seconds therefore leaves a release build an order of magnitude
        /// of headroom and covers a debug build for anything up to about a minute of speech;
        /// past that the rank-ordered list is the better trade, because this sits between
        /// transcription and injection and the user is waiting on it.
        var narrow = Duration.seconds(2)
        /// Command Mode's model pass.
        var command = Duration.seconds(60)

        static let standard = Limits()
    }

    private let limits: Limits

    /// Timestamps for the dashboard: when the key went down, and when it came up.
    /// When the current hold began. Readable so a view that is built *during* a recording
    /// — switching sections mid-utterance does exactly that — can show the true elapsed
    /// time instead of starting its own clock from zero.
    private(set) var holdStarted: Date?
    private var releasedAt: Date?
    private var engineName = ""

    // MARK: One hold's outcome row (D-01b)

    /// Minted at key-down. The tail mints its run id from this same id, so one id joins
    /// `runs.jsonl`, the P0-20c rows and the hold row.
    private var holdID = UUID()
    /// `reportOutcome`'s exactly-one-row guard: true between holds, false from
    /// `beginDictation` until the hold's outcome is filed.
    private var outcomeReported = true
    /// Key-up, kept for the hold row: `recordRun` clears `releasedAt` before
    /// `finishIdle` reports, and a cancel mid-tail clears the slots under the tail.
    private var holdKeyUpAt: Date?
    /// Key-down → key-up in milliseconds, captured at key-up for the same reason.
    /// A retry hold measures the kept audio it replays instead of its own click.
    private var holdMsAtKeyUp: Int?
    /// Words in this hold's transcript, stashed where the tail knows it. The row
    /// carries a count, never the text.
    private var lastHoldWords = 0
    /// This hold's cleanup record, stashed before injection so the row can say
    /// whether the model was prewarmed and whether its pass timed out.
    private var lastHoldCleanupRecord: CleanupRecord?
    private var lastHoldCleanupTimedOut = false
    /// First cleanup-ready text published to the live view, not a physical paint receipt.
    private var firstFinishingPreviewAt: Date?

    /// What the current recording will do after transcription. Command Mode captures the
    /// selection on key-down so a later focus change can be detected instead of overwriting
    /// an unrelated field.
    private enum RecordingIntent {
        case dictation
        case command(TextInjector.Selection)

        var kind: RecordingKind {
            switch self {
            case .dictation: .dictation
            case .command: .command
            }
        }
    }

    private enum RecordingKind {
        case dictation
        case command
    }

    private var recordingIntent = RecordingIntent.dictation

    /// What Command Mode is saying right now, or `nil` when this hold is ordinary dictation.
    ///
    /// The single switch behind the whole feature's visibility. While it is set the
    /// heads-up display draws `CommandModeCard` and is shown whatever the placement setting
    /// says, and the notch island stands down — so a Command Mode hold is described in one
    /// place, in words, instead of appearing at the notch as a wordless orb borrowed from
    /// dictation.
    private(set) var commandMode: CommandModeStatus?

    /// True while Command Mode owns the heads-up display. Read by the island so the two
    /// surfaces never narrate the same hold at once.
    ///
    /// Not simply "a message exists". A message is allowed to outlive the hold that raised
    /// it — "Select some text first" is only useful if it stays up long enough to read — and
    /// for those four seconds a plain "is there a status?" test handed the next recording,
    /// whatever it was, to the Command Mode card. `beginDictation` clears a stale message, so
    /// this should never be the thing that saves us; it is here because the cost of being
    /// wrong is the user's dictation disappearing from the only surface they watch.
    var commandModeOwnsHUD: Bool {
        Self.commandModeOwnsHUD(
            status: commandMode,
            isRecording: state.isActive,
            isCommandRecording: recordingIntent.kind == .command
        )
    }

    /// The rule behind `commandModeOwnsHUD`, as a function of the three facts it turns on.
    ///
    /// Pure and static so `--selftest-commandkey` can walk the whole table — including the
    /// combination this exists to get right, a leftover message over a running dictation —
    /// without a microphone, a hotkey or a screen.
    static func commandModeOwnsHUD(
        status: CommandModeStatus?,
        isRecording: Bool,
        isCommandRecording: Bool
    ) -> Bool {
        guard status != nil else { return false }
        // An idle message owns the display on its own; a live one only while the recording
        // it is describing is the one actually running.
        return !isRecording || isCommandRecording
    }

    /// Generation counter for the self-dismissing Command Mode messages, so a message that
    /// has already been replaced cannot clear its successor when its own timer fires.
    private var commandModeToken = 0

    /// Generation counter for the self-clearing `.error` card, so a stale timer clears
    /// neither a hold started from the card nor a newer error (D-05). The state check
    /// alone is not enough: a second failure within 3 s is still `.error`.
    private var errorToken = 0

    /// The app that was frontmost when this hold began.
    ///
    /// Captured at key-down rather than read at insertion time, because the tail between
    /// the two is seconds long — drain, transcribe, cleanup — and the user is free to
    /// switch apps inside it. Without this the text goes wherever they ended up, which in
    /// practice means it vanishes.
    private var origin: TextInjector.Origin?

    /// Compare mode only: the recording, kept so every engine sees identical audio.
    private var recorded: [AudioChunk] = []
    private var isComparing = false

    init(
        formatter: (any TextFormatter)? = nil,
        commandProcessor: any TextCommandProcessor = FoundationModelCommandProcessor(),
        makeEngine: @escaping @MainActor @Sendable () -> any TranscriptionEngine = engineForCurrentSetting,
        limits: Limits = .standard,
        insert: (@MainActor (String, TextInjector.Origin?) async -> TextInjector.Outcome)? = nil,
        record: @escaping @MainActor (DictationRun) -> Void = { RunLog.record($0) },
        // D-15c: a self-test passes `.selfTest` so the deadlines it injects on purpose do
        // not read as production failures in the user's unified log.
        log: DictationLogger = .production,
        // D-01b: one `dictation.hold` row per hold, whatever happened.
        outcome: @escaping @MainActor (DictationHoldOutcome) -> Void = {
            UsageLog.shared.record($0.usageRecord())
        },
        usage: UsageLog = .shared,
        // Injectable for the same reason `insert` is: reading the selection needs
        // Accessibility and a focused text field in another app, neither of which a
        // self-test has, and the branch worth checking is the one where there is no
        // selection at all.
        captureSelection: @escaping @MainActor () -> TextInjector.Selection?
            = { TextInjector.captureSelection() },
        // Injected only by tests. Production asks macOS for the microphone; a self-test
        // cannot, because the grant belongs to the responsible process and an ordinary
        // `--selftest-usage-log` run is not the app (AGENTS.md). `--selftest-dictation`
        // launches through LaunchServices instead and uses the real call.
        requestMicrophone: @escaping @MainActor () async -> Bool
            = { await Permissions.requestMicrophone() },
        // Speech-energy check on empty transcripts (D-03): returns the voiced
        // 20 ms frames in a buffer. Production passes the RMS default; only
        // self-tests pass anything else.
        speechDetector: @escaping @Sendable (AVAudioPCMBuffer) -> Int = defaultSpeechDetector,
        // D-12: the two halves of a hold's cleanup, for a self-test that needs to watch both
        // with one fake. Nil in production, which builds them from `Settings` — the
        // pre-clean's Stage B in `makeIncrementalCleanup()`, the key-up pass in
        // `activeFormatter(context:trace:head:)`.
        cleanupPieces: (@MainActor @Sendable () -> CleanupPieces)? = nil,
        // The final context boundary, isolated in tests instead of inspecting a real app.
        contextCapture: (@MainActor @Sendable () async -> ScreenContext)? = nil,
        referenceProfile: OutputProfile? = nil
    ) {
        self.formatter = formatter
        self.commandProcessor = commandProcessor
        self.makeEngine = makeEngine
        self.limits = limits
        self.insert = insert
        self.record = record
        self.log = log
        self.outcomeSink = outcome
        self.usage = usage
        self.captureSelection = captureSelection
        self.requestMicrophone = requestMicrophone
        self.speechDetector = speechDetector
        self.cleanupPieces = cleanupPieces
        self.contextCapture = contextCapture
        self.referenceProfile = referenceProfile
    }

    private let captureSelection: @MainActor () -> TextInjector.Selection?
    private let requestMicrophone: @MainActor () async -> Bool
    private let speechDetector: @Sendable (AVAudioPCMBuffer) -> Int
    private let cleanupPieces: (@MainActor @Sendable () -> CleanupPieces)?
    private let contextCapture: (@MainActor @Sendable () async -> ScreenContext)?
    private let referenceProfile: OutputProfile?

    /// Actual pre-clean producer and finishing consumer, with no model or owner history.
    static func incrementalClosureFailures() async -> [String] {
        guard SelfTest.isRunning, Settings.shared.usesHarnessPreferencesForTesting else {
            return ["incremental closure fixture requires isolated preferences"]
        }
        struct RecordingFormatter: TextFormatter {
            let inputs: LockedBox<[String]>
            func format(_ raw: String) async -> String {
                inputs.value.append(raw)
                return raw.uppercased()
            }
        }
        let settings = Settings.shared
        let old = (settings.cleanupEnabled, settings.cleanupEngine, settings.cleanupFixesGrammar)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DictationClosure-\(UUID().uuidString)")
        defer {
            settings.cleanupEnabled = old.0
            settings.cleanupEngine = old.1
            settings.cleanupFixesGrammar = old.2
            try? FileManager.default.removeItem(at: root)
        }
        settings.cleanupEnabled = true
        settings.cleanupEngine = .apple
        settings.cleanupFixesGrammar = true
        let inputs = LockedBox<[String]>([])
        let semantic = RecordingFormatter(inputs: inputs)
        let trace = CleanupTrace()
        let usage = UsageLog(directory: root)
        var delivered = ""
        let controller = DictationController(
            insert: { text, _ in delivered = text; return .superseded },
            record: { _ in }, log: .selfTest, outcome: { _ in }, usage: usage,
            cleanupPieces: { CleanupPieces(preclean: semantic, pass: { head in
                CleanupRouter(semantic: semantic, engine: .apple, trace: trace,
                              head: head, pressureSample: { .idle })
            }) },
            contextCapture: { .empty }
        )
        guard let producer = controller.makeIncrementalCleanup() else {
            return ["actual controller did not create its pre-clean producer"]
        }
        var failures: [String] = []
        let first = "The first sentence is ready."
        let open = first + " The next sentence is still"
        await producer.notePartial(open, committed: open)
        let early = await producer.head()
        for task in early.cleaned { _ = await task.value }
        if early.rawPrefix != first {
            failures.append("actual pre-clean manufactures a full stop and closes an unfinished sentence")
        }
        let final = open + " being spoken."
        await producer.notePartial(final, committed: final)
        let head = await producer.head()
        for task in head.cleaned { _ = await task.value }
        controller.incrementalCleanup = producer
        controller.transcript = final
        controller.holdStarted = Date().addingTimeInterval(-30)
        controller.releasedAt = Date()
        controller.state = .finishing
        controller.captureDrainTask = Task { true }
        await controller.runTail(session: controller.session, audio: nil)
        usage.flush()
        if inputs.value != [first, "The next sentence is still being spoken."]
            || trace.snapshot.precleanedGroups != 2 || delivered != final.uppercased() {
            failures.append("actual finishing consumer repeats full cleanup after an unchanged committed prefix grows")
        }
        return failures
    }

    private func showFinishingPreview(_ text: String, session: Int) {
        guard self.session == session, state == .finishing, !text.isEmpty else { return }
        if firstFinishingPreviewAt == nil { firstFinishingPreviewAt = Date() }
        if transcript != text { transcript = text }
    }

    /// Actual tail/router/UI data path, held before layout completion. No owner
    /// history, microphone or destination is touched.
    static func finishingPreviewFailures() async -> [String] {
        guard SelfTest.isRunning, Settings.shared.usesHarnessPreferencesForTesting else {
            return ["finishing preview fixture requires isolated preferences"]
        }
        struct Polish: TextFormatter {
            let text: String
            func format(_ raw: String) async -> String { text }
        }
        let settings = Settings.shared
        let wasEnabled = settings.cleanupEnabled
        settings.cleanupEnabled = true
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DictationPreview-\(UUID().uuidString)")
        defer {
            settings.cleanupEnabled = wasEnabled
            try? FileManager.default.removeItem(at: root)
        }
        let raw = ("The project is ready for review. We have finished the first draft. "
            + "Everyone can check the updated version today. "
            + String(repeating: "We will consider every detail carefully before sending it to the whole team. ", count: 4))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let polished = raw.uppercased()
        let release = AsyncStream<Void>.makeStream()
        let shown = AsyncStream<Void>.makeStream()
        let planner = ScriptedStructurePlanner { sentences in
            for await _ in release.stream { break }
            return StructurePlanOutcome(plan: StructurePlan(blocks: [
                .init(kind: .prose, from: 1, to: 1),
                .init(kind: .prose, from: 2, to: sentences.count),
            ]), rejection: nil, seconds: 0)
        }
        let usage = UsageLog(directory: root)
        var delivered = ""
        let controller = DictationController(
            formatter: CleanupRouter(semantic: Polish(text: polished), engine: .apple,
                rules: KeepAsIsFormatter(), formatsLists: true,
                structurePlanner: planner, pressureSample: { .idle }),
            insert: { text, _ in delivered = text; return .superseded },
            record: { _ in }, log: .selfTest, outcome: { _ in }, usage: usage)
        controller.transcript = raw
        controller.holdStarted = Date().addingTimeInterval(-30)
        controller.releasedAt = Date()
        controller.state = .finishing
        withObservationTracking { _ = controller.transcript } onChange: { shown.continuation.yield(()) }
        let tail = Task { await controller.runTail(session: controller.session, audio: nil) }
        let visible = await withBoundedWait(.milliseconds(250)) {
            for await _ in shown.stream { return true }
            return false
        }
        var failures: [String] = []
        if visible != true || controller.transcript != polished || !delivered.isEmpty {
            failures.append("actual controller keeps raw text hidden behind final layout instead of showing completed cleanup")
        }
        release.continuation.yield(())
        release.continuation.finish()
        shown.continuation.finish()
        await tail.value
        usage.flush()
        if !delivered.contains("\n\n") || delivered.replacingOccurrences(of: "\n\n", with: " ") != polished {
            failures.append("finishing preview changes or prematurely delivers final formatting")
        }
        controller.state = .finishing
        controller.transcript = "New hold"
        let oldSession = controller.session
        controller.session += 1
        controller.showFinishingPreview("Old preview", session: oldSession)
        if controller.transcript != "New hold" { failures.append("stale preview overwrites a successor hold") }
        controller.state = .idle
        controller.showFinishingPreview("Late preview", session: controller.session)
        if controller.transcript != "New hold" { failures.append("late preview revives a completed hold") }
        return failures
    }

    /// Real-time file audio through the real recognizer, live consumer, pre-clean producer
    /// and complete finishing path. Only context, history and external insertion are
    /// isolated. This measures text ready for insertion, not an Accessibility delivery.
    static func runPolishingReplay(
        path: String, choice: CleanupEngineChoice, warmFirst: Bool,
        maximumWER: Double? = nil, log: @MainActor (String) -> Void
    ) async -> Bool {
        guard SelfTest.isRunning, Settings.shared.usesHarnessPreferencesForTesting else { return false }
        let rate = 16_000
        guard let samples = try? AudioConversion.monoSamples(
            fromFileAt: URL(fileURLWithPath: (path as NSString).expandingTildeInPath),
            sampleRate: Double(rate)), samples.count > rate else {
            log("DICTATION_POLISH_FAILED: could not read the audio fixture")
            return false
        }
        let gold = SelfTest.value(after: "--dictation-gold").flatMap {
            try? String(contentsOfFile: ($0 as NSString).expandingTildeInPath, encoding: .utf8)
        }
        if maximumWER != nil, gold == nil {
            log("DICTATION_POLISH_FAILED: could not read the required independent transcript")
            return false
        }
        let settings = Settings.shared
        let old = (settings.cleanupEnabled, settings.cleanupEngine, settings.cleanupFixesGrammar,
                   settings.cleanupFormatsLists, settings.cleanupSkipsModelWhenBusy,
                   settings.cleanupTone, settings.cleanupContext)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DictationPolish-\(UUID().uuidString)")
        defer {
            settings.cleanupEnabled = old.0; settings.cleanupEngine = old.1
            settings.cleanupFixesGrammar = old.2; settings.cleanupFormatsLists = old.3
            settings.cleanupSkipsModelWhenBusy = old.4
            settings.cleanupTone = old.5; settings.cleanupContext = old.6
            try? FileManager.default.removeItem(at: root)
        }
        settings.cleanupEnabled = true; settings.cleanupEngine = choice
        settings.cleanupFixesGrammar = true; settings.cleanupFormatsLists = true
        settings.cleanupSkipsModelWhenBusy = false
        settings.cleanupTone = .balanced; settings.cleanupContext = .general
        if warmFirst, choice == .miniCPM {
            let began = Date()
            let ready = await MiniCPMModels.preload()
            log(String(format: "DICTATION_POLISH_PREPARE: resident=%@ seconds=%.3f",
                       String(ready), Date().timeIntervalSince(began)))
        }
        let profile = OutputProfile(bundleID: "fixture.dictation", displayName: "the fixture",
                                    capabilities: [.markdown, .bullets, .numbered, .code])
        var ok = true
        for round in 1...2 {
            var delivered = ""
            var run: DictationRun?
            var firstAt: Date?
            var finalAt: Date?
            var finalASR = ""
            let usage = UsageLog(directory: root.appendingPathComponent("round-\(round)"))
            let controller = DictationController(
                insert: { text, _ in delivered = text; return .superseded },
                record: { run = $0 }, log: .selfTest, outcome: { _ in }, usage: usage,
                contextCapture: { .empty }, referenceProfile: profile
            )
            controller.stageCleanupSessions()
            let engine = ParakeetEngine()
            let stream: AsyncThrowingStream<TranscriptionChunk, Error>
            let startupBegan = Date()
            do { stream = try await engine.start() } catch {
                log("DICTATION_POLISH_FAILED: recognition could not start")
                return false
            }
            guard let format = await engine.preferredInputFormat() else { return false }
            let startupMs = Date().timeIntervalSince(startupBegan) * 1000
            controller.engine = engine
            controller.incrementalCleanup = controller.makeIncrementalCleanup()
            let producer = controller.incrementalCleanup
            controller.state = .listening
            let began = Date()
            controller.holdStarted = began
            controller.consumeTask = Task { @MainActor in
                do {
                    for try await chunk in stream {
                        if !chunk.text.isEmpty, firstAt == nil { firstAt = Date() }
                        if chunk.isFinal { finalAt = Date(); finalASR = chunk.text }
                        await controller.acceptTranscriptChunk(chunk, session: controller.session)
                    }
                } catch { ok = false }
            }
            let clock = ContinuousClock()
            let start = clock.now
            var index = 0
            while index < samples.count {
                let end = min(index + rate / 10, samples.count)
                // Real audio time, not a fast batch that hides whether work fits in speech.
                try? await clock.sleep(until: start + .seconds(Double(end) / Double(rate)))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                    frameCapacity: AVAudioFrameCount(end - index)),
                    let channel = buffer.floatChannelData?.pointee else { return false }
                buffer.frameLength = AVAudioFrameCount(end - index)
                for offset in 0..<(end - index) { channel[offset] = samples[index + offset] }
                await engine.feed(AudioChunk(buffer: buffer))
                index = end
            }
            let released = Date()
            let visibleWords = Self.wordCount(controller.transcript)
            controller.releasedAt = released
            controller.state = .finishing
            controller.captureDrainTask = Task { true }
            await controller.runTail(session: controller.session, audio: nil)
            let readyMs = Date().timeIntervalSince(released) * 1000
            let record = run?.cleanup
            log(String(format: "DICTATION_POLISH_PREVIEW: round=%d cleanupReady=%.0fms finalReady=%.0fms publicationOnly=true",
                round, controller.firstFinishingPreviewAt.map { $0.timeIntervalSince(released) * 1000 } ?? -1,
                readyMs))
            log(String(format: "DICTATION_POLISH: round=%d engine=%@ hold=%.2fs first=%.0fms visibleWords=%d ASRfinal=%.0fms ready=%.0fms finalWords=%d head=%d answeredHead=%d fallback=%@ layout=%.3fs cached=%d model=%.3fs",
                round, choice.rawValue, released.timeIntervalSince(began),
                firstAt.map { $0.timeIntervalSince(began) * 1000 } ?? -1, visibleWords,
                finalAt.map { $0.timeIntervalSince(released) * 1000 } ?? -1,
                readyMs, Self.wordCount(delivered), record?.precleanedGroups ?? 0,
                record?.precleanAnsweredGroups ?? -1, record?.precleanFallback ?? "none", record?.structurePlanSeconds ?? 0,
                record?.cachedTokens ?? 0, record?.modelSeconds ?? 0))
            log(String(format: "DICTATION_POLISH_TARGET: round=%d startup=%.0fms polishedUnder2s=%@ liveAtRelease=%@ layoutOutcome=%@",
                       round, startupMs, String(readyMs <= 2_000), String(visibleWords > 0),
                       record?.structurePlanRejected ?? "accepted or not requested"))
            if let gold {
                let rawWER = DictationSegmentsSelfTest.wordErrorRate(reference: gold, hypothesis: finalASR)
                let finalWER = DictationSegmentsSelfTest.wordErrorRate(reference: gold, hypothesis: delivered)
                log(String(format: "DICTATION_POLISH_WER: round=%d raw=%.3f final=%.3f",
                    round, rawWER, finalWER))
                if let maximumWER, rawWER > maximumWER || finalWER > maximumWER {
                    log("DICTATION_POLISH_WRONG: round=\(round) raw or final independent WER exceeds required \(maximumWER)")
                    ok = false
                }
            }
            if let output = SelfTest.value(after: "--dictation-asr-output") {
                try? finalASR.write(toFile: output + ".\(round).txt", atomically: true, encoding: .utf8)
            }
            if let output = SelfTest.value(after: "--dictation-polish-output") {
                try? delivered.write(toFile: output + ".\(round).txt", atomically: true, encoding: .utf8)
            }
            if delivered.isEmpty || firstAt == nil || finalAt == nil { ok = false }
            // Join the same owned groups after measuring; no pre-clean survives the fixture.
            if let producer {
                let head = await producer.head()
                for task in head.cleaned { _ = await task.value }
            }
            usage.flush()
        }
        log(ok ? "DICTATION_POLISH_OK: full finishing path reached isolated insertion twice"
               : "DICTATION_POLISH_FAILED: incomplete live or final output")
        return ok
    }

    /// Actual finishing path with an already recognized sentence; tests context admission,
    /// narrowing, dictionary, tagging, history and delivery without a microphone or model.
    static func fileTaggingLatencyFailures() async -> [String] {
        guard SelfTest.isRunning, Settings.shared.usesHarnessPreferencesForTesting else {
            return ["file-tag fixture requires isolated self-test preferences"]
        }
        let settings = Settings.shared
        let enabled = settings.cleanupEnabled
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DictationTags-\(UUID().uuidString)")
        defer {
            settings.cleanupEnabled = enabled
            try? FileManager.default.removeItem(at: root)
        }
        settings.cleanupEnabled = false
        let profile = OutputProfile(bundleID: "com.todesktop.230313mzl4w4u92", displayName: "Cursor",
                                    pathReference: .atRelative)
        let context = ScreenContext(
            bundleID: "com.todesktop.230313mzl4w4u92", appName: "Cursor",
            candidates: [CandidateName(text: "login.ts", path: "src/login.ts", kind: .activeTab, rank: 0)],
            projectRoot: nil, truncation: [], elapsed: .zero
        )
        var captures = 0
        var recorded = ""
        var inserted = ""
        let usage = UsageLog(directory: root)
        let controller = DictationController(
            // Stops at the insertion boundary; no shared target cleanup or external effect.
            insert: { text, _ in inserted = text; return .superseded },
            record: { recorded = $0.text }, log: .selfTest, outcome: { _ in },
            usage: usage,
            contextCapture: { captures += 1; return context }, referenceProfile: profile
        )
        controller.transcript = "Please check login.ts."
        controller.holdStarted = Date().addingTimeInterval(-1)
        controller.releasedAt = Date()
        controller.state = .finishing
        controller.captureDrainTask = Task { true }
        await controller.runTail(session: controller.session, audio: nil)
        usage.flush()
        if captures != 1 || !recorded.contains("@src/login.ts") || inserted != recorded {
            return ["polishing off skips captured context and loses file tagging in the actual finishing path"]
        }
        return []
    }

    /// The last hold that ended with nothing typed, with its audio (D-03).
    ///
    /// One slot, memory only, replaced by whichever failed hold came later and cleared
    /// by the next one that succeeds. Filled by `fail` *before* it disowns the slots,
    /// which is why the audio is copied off the counter first.
    private var lastFailedHold: FailedHold?

    /// Whether "Try again" is offered: a failed hold is kept and no hold is running.
    ///
    /// The second half is what stops the island and the status menu from starting a
    /// replay into a hold that is already in flight — the slot survives the whole tail,
    /// so without it a second click would be a second engine over one set of slots.
    var canRetryLastHold: Bool { lastFailedHold != nil && canStartHold }

    /// Moves a hold's kept audio into the one retry slot (D-03), dropping it when there
    /// is nothing worth keeping. Called from `fail` for the paths a recording can be
    /// recovered from; a hold whose audio is already somewhere else (an injection that
    /// fell back to the clipboard) does not call it.
    private func keepForRetry(_ audio: DictationAudioCounter?) {
        guard let audio, recordingIntent.kind == .dictation else { return }
        let chunks = audio.kept
        guard !chunks.isEmpty else { return }
        if audio.isRecordingCapped {
            Log.speech.info("kept failed hold hit the recording cap; the tail is missing")
        }
        lastFailedHold = FailedHold(
            chunks: chunks,
            capturedFrames: audio.frames,
            voicedFrames: audio.voicedFrames,
            format: audio.captureFormat
        )
    }

    // MARK: - Lifecycle

    /// - Returns: `false` if the hotkey tap couldn't be installed (missing Accessibility).
    @discardableResult
    func activate() -> Bool {
        // `activate()` is also used by the Accessibility retry path. Always tear down a
        // possibly stale optional tap before deciding whether it is safe to arm again.
        commandHotkey.stop()
        hotkey.key = Settings.shared.pushToTalkKey
        hotkey.onPress = { [weak self] in self?.beginDictation(intent: .dictation) }
        hotkey.onRelease = { [weak self] in self?.endDictation(expected: .dictation) }
        guard hotkey.start() else {
            hotkeyReady = false
            return false
        }
        hotkeyReady = true

        let settings = Settings.shared
        if settings.commandModeEnabled {
            guard FoundationModelCommandProcessor.isAvailable else {
                Log.hotkey.info("Command Mode model unavailable; command hotkey not armed")
                return true
            }
            guard settings.commandModeKey != settings.pushToTalkKey else {
                Log.hotkey.error("Command Mode key conflicts with push-to-talk; command hotkey not armed")
                return true
            }
            arm(commandHotkey, forCommandModeOn: settings.commandModeKey)
            if !commandHotkey.start() {
                Log.hotkey.error("Command Mode hotkey could not be armed")
            }
        }

        return true
    }

    func deactivate() {
        hotkeyReady = false
        hotkey.stop()
        commandHotkey.stop()
        cancelDictation()
    }

    /// Re-arms the tap after the user picks a different push-to-talk key.
    @discardableResult
    func reloadHotkey() -> Bool {
        hotkeyReady = false
        hotkey.stop()
        commandHotkey.stop()
        return activate()
    }

    // MARK: - Button-driven recording

    /// A press may start a hold from `.idle` or from a visible `.error` card — the
    /// card's whole point is "hold the key again" (D-05). Presses in `.starting`,
    /// `.listening` and `.finishing` stay refused: `.finishing` is D-13's
    /// evidence-gated territory, not this task's.
    private var canStartHold: Bool {
        if case .idle = state { return true }
        if case .error = state { return true }
        return false
    }

    /// Starts a recording from a Record button rather than the hotkey.
    ///
    /// Wispr Flow's hotkey is held down for the duration **only in compare mode**. Reaching
    /// into another app is a comparison affordance; during ordinary dictation it would mean
    /// every recording silently shipped your audio to a third party's servers.
    func startButtonRecording() {
        guard canStartHold else { reportRefusedPress(); return }
        if Settings.shared.compareMode { WisprTrigger.press() }
        beginDictation(intent: .dictation)
    }

    /// Releases Wispr's hotkey first, so its upload starts while our own engines are still
    /// finishing — otherwise every run would wait the full round trip end to end.
    func stopButtonRecording() {
        WisprTrigger.release()
        endDictation()
    }

    /// The capture boundary used by both key-up paths; accepts an isolated hub in tests.
    static func stopDictationCapture(on hub: AudioCaptureHub = .shared) -> Task<Bool, Never> {
        hub.stopAndDrain(.dictation)
    }

    // MARK: - Command Mode

    /// How long the Command Mode key must be held before anything happens.
    ///
    /// Long enough that no shortcut reaches it — ⌘C is tens of milliseconds from press to
    /// press — and short enough that somebody holding the key deliberately does not think
    /// the app is dead. The chord guard in `HotkeyMonitor` is the real protection; this is
    /// what stops a stray tap from putting something on screen.
    static let commandHoldThreshold = Duration.milliseconds(400)

    /// Points a monitor at the Command Mode key and hands it the three answers it needs.
    ///
    /// Unlike push-to-talk, this key is usually ⌘ — the modifier every shortcut on the
    /// machine is built out of. Firing on key-down meant ⌘C opened the microphone against
    /// the selection the user was copying, and a bare tap raised a heads-up display and then
    /// nothing. A hold now has to outlast the threshold with nothing else struck or clicked
    /// inside it; a tap and a chord produce nothing at all.
    ///
    /// This is a named function rather than five lines inside `activate()` because it *is*
    /// the contract: delete the `holdThreshold` line and the original bug comes straight
    /// back, silently, with every unit of the gate still passing. `--selftest-commandkey`
    /// arms a throwaway monitor through here and checks what came out, which is the only
    /// way that regression is catchable without a keyboard and an Accessibility grant.
    func arm(_ monitor: HotkeyMonitor, forCommandModeOn key: PushToTalkKey) {
        monitor.key = key
        monitor.holdThreshold = Self.commandHoldThreshold
        monitor.onPress = { [weak self] in self?.beginCommandMode() }
        monitor.onRelease = { [weak self] in self?.endDictation(expected: .command) }
        monitor.onCancel = { [weak self] in self?.cancelCommandMode() }
    }

    /// The Command Mode key was held long enough to mean it.
    ///
    /// Internal rather than private so `--selftest-commandkey` can drive it: everything
    /// this decides happens before the microphone opens, and none of it is reachable from a
    /// terminal through the event tap.
    func beginCommandMode() {
        guard canStartHold else { reportRefusedPress(); return }
        guard FoundationModelCommandProcessor.isAvailable else {
            // Not `fail`. `fail` is the dictation failure path: it sets `.error`, which the
            // island draws as a dictation card with nothing in it — the wordless animation
            // this feature was reported for. Command Mode says its own piece instead.
            showCommandMode(.problem(FoundationModelCommandProcessor.unavailableReason
                ?? "This Mac can\u{2019}t rewrite text on its own yet."))
            return
        }
        guard let selection = captureSelection() else {
            showCommandMode(.needsSelection)
            return
        }
        showCommandMode(.listening)
        beginDictation(intent: .command(selection))
    }

    /// The key turned out to be part of a shortcut after the hold had already started.
    ///
    /// Silent on purpose: the user pressed ⌘ and then another key, which is an ordinary
    /// thing to do and not something to be told about. Whatever had started is unwound.
    private func cancelCommandMode() {
        guard commandMode != nil else { return }
        showCommandMode(nil)
        if state.isActive, recordingIntent.kind == .command { cancelDictation() }
    }

    /// Puts a Command Mode message up, and takes it down again when it has had its time.
    ///
    /// `nil` clears immediately. The token makes a stale timer harmless: without it, the
    /// four-second life of "Select some text first" would erase a listening card the user
    /// started two seconds later.
    private func showCommandMode(_ status: CommandModeStatus?) {
        commandModeToken &+= 1
        commandMode = status
        guard let lifetime = status?.lifetime else { return }
        let token = commandModeToken
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: lifetime)
            guard let self, self.commandModeToken == token else { return }
            self.commandMode = nil
        }
    }

    // MARK: - Dictation

    /// Re-runs the kept failed hold through a fresh engine and the normal tail (D-03).
    ///
    /// A new hold, not a rewind: its own session, its own `recordRun`, and the origin
    /// captured at the moment of the click. The island and the status menu do not take
    /// focus, so the words go wherever the user is when they press the button — never
    /// back to whatever app had focus when they were spoken, which by now may not exist.
    ///
    /// The kept audio is pre-yielded into the engine's stream and the stream is finished
    /// before anything starts, so this is D-02's released-during-start-up path with the
    /// microphone left out of it: the tail runs as soon as the engine has started. Never
    /// automatic — only this and the menu item call it, and both are a person's click.
    func retryLastFailedHold() {
        guard canRetryLastHold, let kept = lastFailedHold else { return }
        session &+= 1
        let session = self.session
        recordingIntent = .dictation
        isComparing = false
        showCommandMode(nil)
        origin = TextInjector.captureOrigin()
        let target = OutputProfileStore.shared.captureTarget()
        let contextOrigin = origin?.app.bundleIdentifier == AppIdentity.bundleIdentifier ? nil : origin
        ScreenContextStore.shared.beginCapture(
            for: target,
            processID: contextOrigin?.app.processIdentifier,
            originBundleID: contextOrigin?.app.bundleIdentifier
        )
        // The replay is a hold whose "capture" is the audio the last one kept, so the
        // tail reads frames, voiced windows and chunks exactly as it would for a live one.
        let audio = DictationAudioCounter()
        audio.seed(
            chunks: kept.chunks,
            frames: kept.capturedFrames,
            voicedWindows: kept.voicedFrames,
            format: kept.format
        )
        audioCounter = audio
        // A retry is a hold of its own for the history too, measured over the audio it
        // is actually playing rather than over the click that started it.
        let keptSeconds = Double(kept.capturedFrames) / (kept.format?.sampleRate ?? 16_000)
        holdStarted = Date().addingTimeInterval(-keptSeconds)
        releasedAt = Date()
        // A replay is its own hold for the outcome row too (D-01b): its own id, and a
        // held time measured over the audio it actually plays rather than the click.
        holdID = UUID()
        latestDelivery = nil
        holdPresentationObserver?.receive(holdID)
        outcomeReported = false
        holdKeyUpAt = releasedAt
        holdMsAtKeyUp = Int((keptSeconds * 1_000).rounded())
        lastHoldWords = 0
        lastHoldCleanupRecord = nil
        lastHoldCleanupTimedOut = false
        firstFinishingPreviewAt = nil
        engineName = Settings.shared.engine.displayName
        transcript = ""
        level = 0
        isCapturingAudio = false
        keyDownToCaptureSeconds = nil
        releasedDuringStartup = nil
        dropIncrementalCleanup()
        firstPartialTrace = nil
        keyDownToCaptureTrace = nil
        finishingStage = .transcribing
        state = .finishing

        Task { @MainActor in
            do {
                let engine = makeEngine()
                self.engine = engine
                guard let format = await engine.preferredInputFormat() else {
                    await engine.finish()
                    if self.session == session { self.engine = nil }
                    throw TranscriptionError.noAudioFormat
                }
                // The kept audio is in the format the *old* engine captured it in, and
                // the format is decided by the setting, which the user may have changed
                // since. SpeechAnalyzer does not reject a wrong one — it aborts the
                // process — so a mismatch is refused here, with the audio left kept.
                if let keptFormat = kept.format, !Self.sameInputFormat(format, keptFormat) {
                    if self.session == session { self.engine = nil }
                    Task { await engine.finish() }
                    fail("That recording doesn\u{2019}t fit the speech model you are using now. Hold the key and say it again.",
                         result: .failed(.startup))
                    return
                }

                // Unbounded and pre-filled: the kept audio is the whole point, and it is
                // finished on entry so the drain returns as soon as it has been fed.
                let (audioStream, audioContinuation) = AsyncStream<AudioChunk>.makeStream(
                    bufferingPolicy: .unbounded
                )
                for chunk in kept.chunks { audioContinuation.yield(chunk) }
                audioContinuation.finish()
                self.audioContinuation = audioContinuation

                let outcome = await withBoundedWait(limits.startup) { () -> StartOutcome in
                    do { return .started(try await engine.start()) }
                    catch { return .failed(DictationErrorText.plain(error)) }
                }
                guard self.session == session else {
                    audioContinuation.finish()
                    await engine.finish()
                    return
                }

                let chunkStream: AsyncThrowingStream<TranscriptionChunk, Error>
                switch outcome {
                case .started(let stream):
                    chunkStream = stream
                case .failed(let reason):
                    self.engine = nil
                    fail(reason, result: .failed(.startup))
                    return
                case nil:
                    self.engine = nil
                    Task { await engine.finish() }
                    fail("The speech model didn\u{2019}t finish loading in time. If it is still downloading, let Settings \u{25B8} Models finish first.",
                         result: .failed(.startupTimeout))
                    return
                }

                var appleLane: UUID?
                if engine is AppleSpeechEngine {
                    appleLane = await ComputeScheduler.shared.acquire(.realtimeASR)
                }
                guard self.session == session else {
                    if let appleLane {
                        await ComputeScheduler.shared.release(appleLane)
                    }
                    audioContinuation.finish()
                    await engine.finish()
                    return
                }

                let counter = self.audioCounter
                let feedTask = Task.detached(priority: .userInitiated) {
                    for await chunk in audioStream {
                        counter?.release(Int(chunk.buffer.frameLength))
                        await engine.feed(chunk)
                    }
                }
                if let appleLane {
                    self.asrLaneID = appleLane
                    self.asrLaneSession = session
                }
                self.feedTask = feedTask

                self.consumeTask = Task { @MainActor in
                    do {
                        for try await chunk in chunkStream {
                            guard self.session == session else { return }
                            await self.acceptTranscriptChunk(chunk, session: session)
                        }
                    } catch {
                        guard self.session == session else { return }
                        self.fail(DictationErrorText.plain(error), result: .failed(.engine))
                    }
                }

                await runTail(session: session, audio: audio)
            } catch {
                guard self.session == session else { return }
                self.fail(DictationErrorText.plain(error), result: .failed(.engine))
            }
        }
    }

    /// Whether two engine input formats are interchangeable for a replay. Compared on
    /// the three facts that decide whether a buffer can be fed at all; `AVAudioFormat`
    /// equality is not it, since the same format can be built with a different layout.
    private static func sameInputFormat(_ a: AVAudioFormat, _ b: AVAudioFormat) -> Bool {
        a.commonFormat == b.commonFormat
            && abs(a.sampleRate - b.sampleRate) < 0.5
            && a.channelCount == b.channelCount
    }

    private func stageCleanupSessions() {
        // Wake the Apple cleanup model while the key is still down: a session staged here
        // and reused by `FoundationModelFormatter.clean` measured 0.94s versus 4.69s cold
        // (see `CleanupSessionWarmer`). Skipped for Command Mode, which never reaches this
        // formatter at all, and for a hold whose settings would not land on Apple's model
        // regardless — cleanup off, or S1-mini with grammar repair off. Built with `.empty`
        // screen context because the real context is narrowed against the transcript, which
        // does not exist yet; `CleanupSessionWarmer.take(instructions:)` simply will not
        // hand out a session staged for the wrong prompt, so a guess that misses costs
        // nothing beyond the wasted prewarm. Fired on its own task — never awaited here —
        // so staging can never delay the capture this function starts below.
        //
        // Also staged when MiniCPM is the engine: Apple is its guard and fallback, and the
        // fallback is exactly the call that answers when MiniCPM is not resident or the
        // lane is busy — a cold Apple call there measured 6–9 s.
        let stagedEngine = CleanupRouter.preferredEngine(
            choice: Settings.shared.cleanupEngine,
            fixesGrammar: Settings.shared.cleanupFixesGrammar
        )
        if Settings.shared.cleanupEnabled,
           stagedEngine == .apple
               || (stagedEngine == .miniCPM && FoundationModelFormatter.isAvailable) {
            let instructions = CleanupInstructions.system(
                for: Settings.shared.cleanupPreferences,
                fixesGrammar: Settings.shared.cleanupFixesGrammar,
                target: referenceProfile ?? OutputProfileStore.shared.capturedProfile
            )
            // The layout pass is a second call to the same model with different
            // instructions, and it is the one that was timing out cold. Staged on the same
            // hold, and only when formatting is actually switched on.
            let layout = Settings.shared.cleanupPreferences.formatsLists
                ? StructurePlanPrompt.system
                : nil
            Task {
                await CleanupSessionWarmer.shared.stage(instructions: instructions)
                if let layout { await CleanupSessionWarmer.shared.stage(instructions: layout) }
            }
        }
        // MiniCPM's weights are a mapped file, so memory pressure drops them while the model
        // still reads as loaded, and the release-time residency gate then answers with Apple.
        // Reading them back now overlaps the 1.5 GB page-in (~1.5 s from the SSD) with the
        // person still speaking. Off the main thread, coalesced, and refused under pressure
        // by `pageInInBackground` itself; a file already in memory costs one 0.5 ms sample.
        if Settings.shared.cleanupEnabled, stagedEngine == .miniCPM {
            DispatchQueue.global(qos: .utility).async {
                let file = MiniCPMModels.fileURL
                if (WeightPageResidency.fraction(of: file) ?? 1) < 0.9 {
                    WeightPageResidency.pageInInBackground(file)
                }
            }
        }
    }

    /// One producer for both the live stream and the file replay acceptance fixture.
    private func acceptTranscriptChunk(_ chunk: TranscriptionChunk, session: Int) async {
        guard self.session == session else { return }
        if !chunk.text.isEmpty, let trace = firstPartialTrace {
            trace.end()
            firstPartialTrace = nil
        }
        transcript = chunk.text
        if !chunk.isFinal, let producer = incrementalCleanup {
            await LatencyCorrelation.$current.withValue(LatencyCorrelation(workID: holdID)) {
                await producer.notePartial(chunk.text, committed: chunk.committedText)
            }
        }
    }

    private func beginDictation(intent: RecordingIntent) {
        guard canStartHold else { reportRefusedPress(); return }
        // A Command Mode message outlives its hold by design — "Select some text first"
        // stays up for four seconds so it can be read. It must not outlive it *into the
        // next recording*: left standing, an ordinary push-to-talk dictation started inside
        // those four seconds was narrated by the Command Mode card, vanished from the notch
        // entirely, and on key-up promised to replace a selection this hold never captured.
        // Raised after the idle guard so a Command Mode hold already in flight keeps its own.
        if case .dictation = intent { showCommandMode(nil) }
        session &+= 1
        let session = self.session
        recordingIntent = intent
        // Three captures of the same instant, for three different jobs. `origin` holds the
        // running application, because returning to it needs something to activate;
        // `captureTarget()` files the bundle identifier, because choosing the formatting
        // rules needs something to look up — and it falls back to the last foreign app,
        // which matters on the path where the frontmost read comes back empty.
        //
        // The harvest reads the file, folder and tab names visible in that same app, and
        // belongs here for the reason the other two do — the user may switch away
        // mid-utterance — plus one of its own: it is a tree walk with a 250 ms budget, and the
        // only moment that time is free is while the key is still held. `beginCapture` returns
        // immediately and the walk runs off the main actor, so nothing here blocks.
        //
        // It is not, however, unwaited-for further down. `AppleSpeechEngine.start()` waits up to
        // 60 ms for it before opening the microphone, because contextual strings have to be set
        // before the first buffer arrives — often zero, since loading the transcriber has
        // already outlasted the walk, but never guaranteed. That cost is argued where it is
        // paid, on `AppleSpeechEngine.context()`; the honest summary here is that the deadline
        // is small and deliberately shorter than the walk's own.
        origin = TextInjector.captureOrigin()
        let target = OutputProfileStore.shared.captureTarget()
        let contextOrigin = origin?.app.bundleIdentifier == AppIdentity.bundleIdentifier ? nil : origin
        ScreenContextStore.shared.beginCapture(
            for: target,
            // The process id, not the `NSRunningApplication` it came from. The walk happens on
            // a detached task and `AXUIElement` is not `Sendable`; an `Int32` is, and the
            // harvester builds its own element from it on the far side.
            //
            // Deliberately the foreign origin's pid rather than one derived from `target`.
            // When Next Notes is frontmost the insertion origin is still captured, but
            // there is no external screen context to harvest, even if `captureTarget()`
            // resolves a profile from the last foreign app.
            //
            // `originBundleID` is what makes the pid and the bundle identifier name the same
            // running process rather than merely being asserted to. They come from two reads of
            // the frontmost app with different rules: `captureOrigin()` accepts an app with no
            // bundle identifier at all — an unsigned Electron build, something run from a
            // terminal — while `frontmostApp()` requires one and otherwise falls back to the
            // last foreign app. So Cursor could be the target while the pid belonged to
            // something else entirely, and the harvest would then walk an app no adapter and no
            // deny list was ever consulted for and label the result "Cursor".
            processID: contextOrigin?.app.processIdentifier,
            originBundleID: contextOrigin?.app.bundleIdentifier
        )
        if intent.kind == .dictation { stageCleanupSessions() }
        state = .starting
        // An embedder a search loaded is not left beside the dictation for its idle timer.
        Task { await EmbeddingRuntime.shared.stopNow() }
        transcript = ""
        audioCounter = DictationAudioCounter()
        holdStarted = Date()
        // One fresh hold identity for the outcome row (D-01b): minted at key-down,
        // reported exactly once, joined to the tail's run id below.
        holdID = UUID()
        latestDelivery = nil
        if case .dictation = intent { holdPresentationObserver?.receive(holdID) }
        outcomeReported = false
        holdKeyUpAt = nil
        holdMsAtKeyUp = nil
        lastHoldWords = 0
        lastHoldCleanupRecord = nil
        lastHoldCleanupTimedOut = false
        keyDownToCaptureSeconds = nil
        firstFinishingPreviewAt = nil
        releasedDuringStartup = nil
        dropIncrementalCleanup()
        keyDownToCaptureTrace = LatencyTrace.start(.dictationKeyDownToCapture)
        if case .dictation = intent {
            isComparing = Settings.shared.compareMode
        } else {
            isComparing = false
        }
        recorded.removeAll(keepingCapacity: true)
        switch intent {
        case .dictation:
            engineName = isComparing ? "Comparing…" : Settings.shared.engine.displayName
        case .command:
            engineName = "\(Settings.shared.engine.displayName) · Command"
        }

        Task { @MainActor in
            do {
                guard await requestMicrophone() else {
                    guard self.session == session else { return }
                    fail("Microphone access is off. Enable it in System Settings ▸ Privacy & Security ▸ Microphone.",
                         result: .failed(.micPermission))
                    return
                }
                guard self.session == session else { return }

                let engine = makeEngine()
                self.engine = engine

                // The input format is known before the engine has started (D-02), so
                // capture can open at key-down instead of after the model load.
                //
                // Compare mode captures in *Apple's* format, not a format of our choosing.
                //
                // SpeechAnalyzer enforces `Audio sample data must be 16-bit signed integers`
                // as a hard precondition — feeding it float32 doesn't fail gracefully, it
                // kills the process. Parakeet is the flexible one (its `feed` converts
                // int16/int32/float32), so the strict engine picks the format and the
                // tolerant engine adapts. Both still replay the identical buffers.
                let formatOwner: any TranscriptionEngine = isComparing ? AppleSpeechEngine() : engine
                let format = await formatOwner.preferredInputFormat()
                guard let format else {
                    await engine.finish()
                    if self.session == session { self.engine = nil }
                    throw TranscriptionError.noAudioFormat
                }

                // Last chance to notice a newer hold before the microphone opens:
                // after this line the slots and the hub belong to this session, and
                // every exit below has to unwind them. A release that already landed
                // (`releasedDuringStartup`, e.g. a tap faster than the permission
                // check) is still this session's hold: continue below — subscribe,
                // start, and run the tail on whatever was captured, which for a pure
                // tap is room silence and goes quietly idle. Only a newer session
                // bails out here.
                guard self.session == session,
                      self.state == .starting || releasedDuringStartup == session else {
                    await engine.finish()
                    if self.session == session { self.engine = nil }
                    return
                }

                // Audio must reach the engine in capture order. A stream plus a single
                // draining task guarantees that; spawning a Task per buffer would not.
                //
                // Unbounded, because the pre-roll accumulates while `engine.start()`
                // loads the model and nothing drains it meanwhile. The bound is the
                // 30 s cap below, not the stream policy: at 16 kHz mono Float32 that
                // is ~1.9 MB a hold, and beyond it newer buffers are dropped and
                // counted while the hold still transcribes what it kept.
                let (audioStream, audioContinuation) = AsyncStream<AudioChunk>.makeStream(
                    bufferingPolicy: .unbounded
                )
                let preRollFrameCap = 30 * Int(format.sampleRate)
                // The whole hold, not the pre-roll: "Try again" has to be able to replay
                // an utterance longer than the window the engine is fed through. 180 s of
                // Float32 at 16 kHz is ~11.5 MB, and past it the appends stop and the hold
                // is marked truncated rather than growing without bound.
                let recordingFrameCap = 180 * Int(format.sampleRate)
                let detectSpeech = speechDetector

                // Capture starts at key-down, into an in-memory pre-roll owned by
                // this session, and is replayed into the engine once it has started
                // (D-02). A superseded start-up never touches the hub — only the
                // session that owns the slots unsubscribes. Measured reason: on
                // 2026-09-23 a cold start after a 52 s model load put 4.40 s between
                // key-down and capture, and the hold was lost.
                //
                // The engine is NOT fed here: Apple needs its contextual strings set
                // before the first buffer arrives, and Parakeet's partial state is
                // reset in `start()`. The feed task below starts after `start()`
                // returns and drains the pre-roll first, because it was yielded first.
                // Hub subscribe so wake KWS can stay on the same input engine.
                do {
                    let audioCounter = self.audioCounter
                    audioCounter?.noteFormat(format)
                    try AudioCaptureHub.shared.subscribe(
                        .dictation,
                        outputFormat: format,
                        onBuffer: { chunk in
                            let frames = Int(chunk.buffer.frameLength)
                            audioCounter?.add(frames)
                            // D-03: what the hold sounded like, kept for "Try again", and
                            // how much of it was speech — the fact that decides whether an
                            // empty transcript is worth saying anything about. Counted here
                            // rather than at the tail so a hold whose engine never started
                            // still knows it had speech in it.
                            audioCounter?.addVoiced(detectSpeech(chunk.buffer))
                            audioCounter?.keep(chunk, capFrames: recordingFrameCap)
                            if audioCounter?.reserve(frames, cap: preRollFrameCap) == true {
                                audioContinuation.yield(chunk)
                            }
                        },
                        onLevel: { [weak self] level in
                            Task { @MainActor in
                                guard let self, self.session == session, self.isCapturingAudio else { return }
                                self.updateLevel(level)
                            }
                        },
                        // Counted per hold for D-01b's `droppedHubBuffers` (P0-20c's
                        // rows landed without it); the log line the default callback
                        // wrote moves into those rows rather than firing per overflow.
                        onOverflow: { n in audioCounter?.addHubDrops(n) }
                    )
                } catch {
                    audioContinuation.finish()
                    self.engine = nil
                    await engine.finish()
                    fail(error.localizedDescription, result: .failed(.subscribe))
                    return
                }

                self.audioContinuation = audioContinuation
                self.isCapturingAudio = true
                if releasedDuringStartup == session {
                    // Release can beat the microphone permission/format awaits. That
                    // late subscription still belongs to the released hold, and must
                    // not keep recording throughout the model's startup.
                    self.captureDrainTask = Self.stopDictationCapture()
                    self.isCapturingAudio = false
                }
                if let holdStarted {
                    self.keyDownToCaptureSeconds = Date().timeIntervalSince(holdStarted)
                }
                self.keyDownToCaptureTrace?.end()
                self.keyDownToCaptureTrace = nil

                // Bounded, because this is where the model load lives. Without a deadline a
                // first-run download sits behind a HUD that says "Listening…" for as long as
                // the transfer takes. The pre-roll above means the utterance is kept while
                // it loads instead of being lost at the end of it.
                let outcome = await withBoundedWait(limits.startup) { () -> StartOutcome in
                    do { return .started(try await engine.start()) }
                    // D-04: a raw engine string never reaches the island; the raw
                    // text goes to the log inside `plain`. (D-01b will add the
                    // `result: .failed(.startup)` outcome mapping; `fail` keeps
                    // its signature until then.)
                    catch { return .failed(DictationErrorText.plain(error)) }
                }

                // Superseded while the model was loading: this start-up owns nothing
                // but its own engine and its own continuation. It finishes both and
                // never calls `unsubscribe` — that would cut the next hold's mic.
                guard self.session == session else {
                    audioContinuation.finish()
                    await engine.finish()
                    return
                }

                let chunkStream: AsyncThrowingStream<TranscriptionChunk, Error>
                switch outcome {
                case .started(let stream):
                    chunkStream = stream
                case .failed(let reason):
                    self.engine = nil
                    // Parakeet releases inside finish on a successful start that
                    // later unwinds; a failed start never acquired.
                    fail(reason, result: .failed(.startup))
                    return
                case nil:
                    self.engine = nil
                    Task { await engine.finish() }
                    fail("The speech model didn't finish loading in time. If it is still downloading, let Settings ▸ Models finish first.",
                         result: .failed(.startupTimeout))
                    return
                }

                // Apple does local ASR but does not touch the scheduler itself
                // (ParakeetEngine owns that path). Acquired after `start()` returns
                // so a superseded start-up never holds a lane: it releases its own
                // id below without touching a later hold.
                var appleLane: UUID?
                if engine is AppleSpeechEngine {
                    appleLane = await ComputeScheduler.shared.acquire(.realtimeASR)
                }

                // A cancel may have landed while the lane was acquired.
                guard self.session == session else {
                    if let appleLane {
                        await ComputeScheduler.shared.release(appleLane)
                    }
                    audioContinuation.finish()
                    await engine.finish()
                    return
                }

                // Audio must reach the engine in capture order: one draining task, never
                // a task per buffer. The recording itself is kept at capture time rather
                // than in here (D-03) — a hold whose engine never started has no drain to
                // collect from, and its pre-roll is exactly the audio "Try again" needs.
                let audioCounter = self.audioCounter
                let feedTask = Task.detached(priority: .userInitiated) {
                    for await chunk in audioStream {
                        audioCounter?.release(Int(chunk.buffer.frameLength))
                        await engine.feed(chunk)
                    }
                }

                // Commit the Apple lane to the controller slots so end/fail/cancel
                // can release it. Parakeet still releases inside its own finish().
                if let appleLane {
                    self.asrLaneID = appleLane
                    self.asrLaneSession = session
                }
                self.feedTask = feedTask

                self.consumeTask = Task { @MainActor in
                    do {
                        for try await chunk in chunkStream {
                            guard self.session == session else { return }
                            await self.acceptTranscriptChunk(chunk, session: session)
                        }
                    } catch {
                        guard self.session == session else { return }
                        self.fail(DictationErrorText.plain(error), result: .failed(.engine))
                    }
                }

                // Released while starting: the stream is already finished, so the
                // drain below returns as soon as the kept pre-roll is fed. No await
                // sits between this check and the `.listening` assignment, so a
                // release cannot land between them on this actor.
                if releasedDuringStartup == session {
                    await runTail(session: session, audio: self.audioCounter)
                    return
                }

                // D-12: the hold now has a transcript that grows, so the sentences that
                // stop changing can be tidied while the key is down. Assigned immediately
                // before `.listening` and with no await in between, so a release cannot land
                // in the gap — the same rule the line below states.
                self.incrementalCleanup = makeIncrementalCleanup()
                self.state = .listening
                self.firstPartialTrace = LatencyTrace.start(.dictationSpeechToFirstPartial)
                if Settings.shared.soundEnabled { NSSound(named: "Tink")?.play() }
            } catch {
                guard self.session == session else { return }
                self.fail(DictationErrorText.plain(error), result: .failed(.engine))
            }
        }
    }

    /// What `engine.start()` came back with, or didn't.
    private enum StartOutcome: Sendable {
        case started(AsyncThrowingStream<TranscriptionChunk, Error>)
        case failed(String)
    }

    private func endDictation(expected: RecordingKind? = nil) {
        // `.finishing` is "active", so without this a second press during processing would
        // run the whole tail again — re-reading `transcript` before the first pass cleared
        // it and pasting the same utterance twice. The window is wide: Parakeet transcribes
        // inside `finish()`, and smart cleanup adds several seconds on top.
        guard state.isActive, state != .finishing else { return }
        guard expected == nil || recordingIntent.kind == expected else { return }

        // A release that lands while `.starting` (D-02): the pre-roll holds the
        // utterance, so the hold is transcribed instead of failed. The hub closes,
        // the finished stream ends after the kept buffers, and the start Task runs
        // the normal tail as soon as the engine is up.
        if case .starting = state {
            releasedDuringStartup = session
            captureDrainTask = Self.stopDictationCapture()
            isCapturingAudio = false
            level = 0
            if recordingIntent.kind == .command { showCommandMode(.rewriting) }
            let keyUp = Date()
            releasedAt = keyUp
            holdKeyUpAt = keyUp
            if let holdStarted {
                holdMsAtKeyUp = Self.millisecondsBetween(holdStarted, keyUp)
            }
            // Key-up before any partial: close the open speech→partial span rather than drop it.
            firstPartialTrace?.end(note: "key-up")
            firstPartialTrace = nil
            finishingStage = .transcribing
            state = .finishing
            return
        }

        finishingStage = .transcribing
        state = .finishing
        // The Command Mode card stops inviting an instruction the moment the key comes up;
        // everything after this point is the model working on what was already said.
        //
        // Gated on what *this* hold is, not on whether a card happens to be on screen. A
        // leftover message from an earlier hold used to make this branch announce that an
        // ordinary dictation was about to replace the user's selection, which was a lie.
        if recordingIntent.kind == .command { showCommandMode(.rewriting) }
        // Not cleared here: the tail still has to read the hold's audio to decide what an
        // empty transcript means, and `fail` has to keep it for "Try again". `finishIdle`,
        // `fail` and `cancelDictation` are what clear it, and each of them runs at the end
        // of a hold rather than at the start of its tail.
        let audio = audioCounter
        captureDrainTask = Self.stopDictationCapture()
        isCapturingAudio = false
        level = 0
        let keyUp = Date()
        releasedAt = keyUp
        holdKeyUpAt = keyUp
        if let holdStarted {
            holdMsAtKeyUp = Self.millisecondsBetween(holdStarted, keyUp)
        }
        // Key-up before any partial: close the open speech→partial span rather than drop it.
        firstPartialTrace?.end(note: "key-up")
        firstPartialTrace = nil
        let session = self.session

        Task { @MainActor in
            await runTail(session: session, audio: audio)
        }
    }

    /// The tail every finished hold runs: drain, transcribe, clean up, inject.
    ///
    /// Factored out of `endDictation` (D-02) so a release during `.starting` can run
    /// the same tail once the engine has started: the start Task calls this directly
    /// with the pre-roll it kept, while a release from `.listening` goes through the
    /// `Task` above. Either way the stream is already finished on entry, so the
    /// drain returns as soon as the kept audio is fed.
    ///
    /// `audio` is this hold's own counter, passed in rather than read back off the
    /// controller (D-03): the tail is what decides whether an empty transcript had
    /// speech in it, and a tail that outlived its hold must not ask a newer one.
    private func runTail(session: Int, audio: DictationAudioCounter?) async {
        guard self.session == session else { return }
        // Drain every captured buffer into the engine before asking it to finalize,
        // or the tail of the utterance gets dropped.
        let audioContinuation = self.audioContinuation
        let feedTask = self.feedTask
        let engine = self.engine
        let consumeTask = self.consumeTask
        // A very early release can precede subscribe. Stop that late subscription here
        // too, then finish the stream only after its accepted packets have been yielded.
        let captureDrain = captureDrainTask ?? Self.stopDictationCapture()
        self.captureDrainTask = nil
        isCapturingAudio = false
        // Which speech engine actually ran this hold, for the usage row. Read from the
        // engine rather than from the setting: a test injects its own, and the row should
        // name what ran rather than what the picker says today.
        let engineChoice = currentEngineChoice
        self.audioContinuation = nil
        self.feedTask = nil
        self.engine = nil
        self.consumeTask = nil

        let began = Date()
        // One id for the whole run: minted at key-down (`holdID`, D-01b) so `runs.jsonl`,
        // the P0-20c rows and the hold row share one correlation id.
        let runID = holdID
        let captureDrained = await captureDrain.value
        guard self.session == session else {
            audioContinuation?.finish()
            feedTask?.cancel()
            Task { await engine?.finish() }
            return
        }
        if !captureDrained {
            log.speechError("dictation capture did not drain its accepted audio before the deadline")
        }
        audioContinuation?.finish()
        _ = await withBoundedWait(limits.drain) { () -> Bool in
            await feedTask?.value
            return true
        }
        // The recording was kept at capture time (D-03), so the drain's answer is only
        // needed to know the audio reached the engine — and `recorded` is read back off
        // the hold's own counter so compare mode and "Try again" see the same buffers.
        recorded = audio?.kept ?? []
        let drained = Date().timeIntervalSince(began)
        // Same numbers the info log already prints — record them rather than a second clock.
        LatencyTrace.record(.dictationDrain, seconds: drained)

        // Prefer text already stabilized while the key was held. Streaming engines
        // (Apple always; Parakeet every ~2 s) keep `transcript` current — finish still
        // runs to close the session, but a timed-out finish must not wipe ready text.
        let stabilized = self.transcript

        // `finish()` and the transcript stream are one leg: with a batch-on-release
        // engine the transcription happens inside `finish()` and the stream yields once
        // at the end of it, so bounding them separately would only mean two ways to hang.
        // With near-streaming Parakeet, finish often reuses the last partial.
        let transcribed = await withBoundedWait(limits.transcribe) { () -> Bool in
            await engine?.finish()
            await consumeTask?.value
            return true
        } ?? false
        // Apple lane lives on the controller; Parakeet already released inside finish().
        await releaseASRLane(for: session)
        let transcribedAt = Date().timeIntervalSince(began)
        LatencyTrace.record(
            .dictationTranscribe,
            seconds: transcribedAt - drained,
            note: transcribed ? nil : "timeout"
        )
        if let releasedAt {
            LatencyTrace.record(
                .dictationKeyUpToASRFinal,
                seconds: Date().timeIntervalSince(releasedAt),
                note: transcribed ? nil : "timeout"
            )
        }
        if !transcribed {
            log.speechError("transcription did not finish within \(String(describing: self.limits.transcribe))")
        }

        guard self.session == session else { return }

        if isComparing {
            await runComparison()
            return
        }

        let raw = self.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? stabilized
            : self.transcript
        // The row carries a count, never the text (D-01b). Stashed before the empty
        // guard so every exit below files it.
        lastHoldWords = Self.wordCount(raw)
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let capturedFrames = audio?.frames ?? 0
            if capturedFrames == 0 {
                fail("No microphone audio reached dictation. Check the selected input device, then try again.",
                     result: .failed(.noAudio))
                return
            }
            // A timed-out transcription leaves nothing to inject. The audio is kept —
            // "that recording was lost" was the truth only while nothing kept it.
            guard transcribed else {
                fail("Transcription didn\u{2019}t finish in time. That recording is kept, so you can try again.",
                     result: .failed(.transcribeTimeout))
                return
            }
            // Silence is the one thing the user must not be nagged about: an empty
            // transcript over an empty hold is nothing going wrong. Speech with no
            // words out is, and it is the case D-03 exists for — the hold used to go
            // quietly idle here and the words were gone (I1-05).
            //
            // 15 voiced 20 ms windows is 0.3 s above the meeting silence gate, reused
            // here rather than tuned: it is the number this codebase already treats as
            // "there was someone speaking" (kept limit I2 #33, never changed).
            if audio?.voicedFrames ?? 0 >= 15 {
                fail("I heard you but couldn\u{2019}t make out the words. Try again, or hold a little longer.",
                     result: .emptySpeech)
                return
            }
            // D-01b: a tap is a hold released almost immediately, or with too little
            // audio to have been a real utterance — D-04 pads such audio, so a tap can
            // reach this path transcribed-but-empty and still belongs to its own class.
            let holdMs = holdStarted.flatMap { started in
                releasedAt.map { $0.timeIntervalSince(started) }
            } ?? 0
            finishIdle(result: holdMs < 0.3 || capturedFrames < 4_800 ? .tap : .empty)
            return
        }

        if case .command(let selection) = recordingIntent {
            await applyCommand(raw, to: selection)
            return
        }

        // On a cleanup timeout the raw transcript is used rather than dropped: badly
        // punctuated text in the right field beats nothing at all.
        var cleaned = raw
        // Timed separately from the cleanup it feeds, because it used to be billed to it.
        // Scoring the screen names is arithmetic in this process and cleanup is a language
        // model; a tail that reads "cleanup 3.4s" when three of those seconds went on
        // narrowing sends whoever reads it to the wrong machine entirely.
        var narrowedAt = transcribedAt
        var cleanupTimedOut = false
        // Outside the cleanup block because the file tagging below reads it too.
        var screen = ScreenContext.empty
        // Filled in by the pass itself and filed on the run below, so the Dictation
        // history can say what happened to these words rather than only what came out.
        var cleanupRecord: CleanupRecord?
        // Tags require the same captured names even when semantic polishing is off.
        if Settings.shared.cleanupEnabled || tagsFileReferences {
            screen = await screenNames(mentionedIn: raw)
            narrowedAt = Date().timeIntervalSince(began)
            guard self.session == session else { return }
        }
        if Settings.shared.cleanupEnabled {
            finishingStage = .tidying
            let trace = CleanupTrace()
            // D-12: what this hold tidied while the key was down. Taken here, after the
            // session guard above, so a superseded hold's work can never reach a tail that
            // is typing somebody else's words — the same rule the four slots above follow.
            var head: CleanupHead?
            if let session = self.incrementalCleanup { head = await session.head() }
            self.incrementalCleanup = nil
            var formatter: any TextFormatter
            let progressActive = LockedBox(true)
            if let cleanupPieces {
                formatter = cleanupPieces().pass(head)
            } else {
                formatter = activeFormatter(context: screen, trace: trace, head: head)
            }
            if let router = formatter as? CleanupRouter {
                formatter = router.reportingProgress { [weak self] text in
                    Task { @MainActor [weak self] in
                        guard progressActive.value else { return }
                        self?.showFinishingPreview(text, session: session)
                    }
                }
            }
            let finalFormatter = formatter
            let formatted = await LatencyCorrelation.$current.withValue(LatencyCorrelation(workID: runID)) {
                await withBoundedWait(limits.cleanup) { await finalFormatter.format(raw) }
            }
            if let formatted {
                cleaned = formatted
            } else {
                cleanupTimedOut = true
                trace.noteModelFailed(
                    reason: "tidying up took too long, so your words were used as spoken",
                    seconds: Date().timeIntervalSince(began) - narrowedAt
                )
                trace.noteOutput(raw, seconds: Date().timeIntervalSince(began) - narrowedAt)
                log.speechError("cleanup did not finish within \(String(describing: self.limits.cleanup)) — using the raw transcript")
            }
            // A queued progress callback cannot replace the completed or tagged text.
            progressActive.value = false
            showFinishingPreview(cleaned, session: session)
            cleanupRecord = trace.snapshot
        }
        // Stashed for the hold row (D-01b): whether the cleanup pass hit its deadline,
        // and whether a staged session was there when the model was asked (D-01a's
        // field, absent from the row when no model ran).
        lastHoldCleanupTimedOut = cleanupTimedOut
        lastHoldCleanupRecord = cleanupRecord

        // The split, every time, at info level. `runs.jsonl` records one number for the
        // whole tail, and a run that took three minutes when it should have taken two
        // seconds is not diagnosable from one number: draining, transcribing, narrowing the
        // screen names and cleaning up are four different machines and any of them can be
        // the slow one.
        let cleanedAt = Date().timeIntervalSince(began)
        LatencyTrace.record(.dictationNames, seconds: narrowedAt - transcribedAt)
        LatencyTrace.record(
            .dictationCleanup,
            seconds: cleanedAt - narrowedAt,
            note: cleanupTimedOut ? "timeout" : nil
        )
        LatencyTrace.record(
            .dictationASRFinalToCleanup,
            seconds: cleanedAt - transcribedAt,
            note: cleanupTimedOut ? "timeout" : nil
        )
        Log.speech.info("""
            dictation tail · drain \(drained, format: .fixed(precision: 2))s · \
            transcribe \(transcribedAt - drained, format: .fixed(precision: 2))s · \
            names \(narrowedAt - transcribedAt, format: .fixed(precision: 2))s · \
            cleanup \(cleanedAt - narrowedAt, format: .fixed(precision: 2))s
            """)

        guard self.session == session else { return }

        // The dictionary runs last, and runs regardless of the cleanup setting. Biasing
        // only raises the odds of the right word; this is the pass that guarantees it,
        // so it must not be something the user can accidentally switch off.
        let (corrected, corrections) = DictionaryStore.shared.corrector.apply(to: cleaned)
        if !corrections.isEmpty {
            Log.speech.info("dictionary · \(corrections.count, privacy: .public) correction(s) applied")
        }

        // Last text pass before injection: after the dictionary, so a correction can fix a
        // misheard word inside a file name first, and with nothing after it that could
        // rewrite the reference it writes.
        let output = await tagFileReferences(in: corrected, screen: screen)
        guard self.session == session else { return }
        showFinishingPreview(output, session: session)

        // Recorded before injection, deliberately. If the text cannot be placed, the
        // Dictation list is the other way back to it, and an utterance that is hard to
        // deliver is exactly the one worth having filed.
        //
        // The key-held time is read here because `recordRun` clears both dates at the end.
        let heldSeconds = holdStarted.flatMap { started in
            releasedAt.map { $0.timeIntervalSince(started) }
        }
        let keyUp = releasedAt
        recordRun(text: output, corrections: corrections, cleanup: cleanupRecord, runID: runID)

        let injectBegan = Date()
        let outcome: TextInjector.Outcome
        if let insert {
            outcome = await insert(output, origin)
        } else {
            outcome = await TextInjector.insert(
                output,
                returningTo: origin,
                whileCurrent: { [weak self] in self?.session == session }
            )
        }
        // The insertion path can await activation and pasteboard delivery. A cancel may
        // end this hold and a new press may take the controller's single microphone slot
        // while that await is suspended. The old tail must leave the new hold untouched.
        guard self.session == session else { return }
        let injectSeconds = Date().timeIntervalSince(injectBegan)
        // Publish the actual outcome while this tail still owns the session, before
        // the existing asynchronous metrics read. No destination is guessed later.
        if !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            switch outcome {
            case .inserted:
                latestDelivery = Delivery(id: holdID, text: output, kind: .inserted)
            case .copiedByChoice:
                latestDelivery = Delivery(id: holdID, text: output, kind: .copied)
            case .superseded, .couldNotReturn:
                break
            }
        }
        LatencyTrace.record(.dictationCleanupToInjection, seconds: injectSeconds)
        if let keyUp {
            LatencyTrace.record(
                .dictationKeyUpToInjection,
                seconds: Date().timeIntervalSince(keyUp)
            )
        }

        // P0-20c: the durable rows, written after injection so the asr row carries the
        // injection stage. `usage.record` only enqueues, so nothing here waits on disk,
        // and the numbers are the tail's own — the same ones the info line above prints.
        if let heldSeconds {
            // F-01: what the start waited for the shared ASR lane, read off the engine that
            // ran this hold rather than measured here — the wait happened inside its acquire
            // and is gone by the time this row is assembled. A hold whose engine is gone
            // (superseded, or compare mode) has no wait to report and files 0.
            let laneWait = await engine?.startLaneWait ?? 0
            for row in UsageRecord.dictationRows(
                runID: runID,
                engine: engineChoice,
                audioSeconds: heldSeconds,
                drained: drained,
                transcribedAt: transcribedAt,
                narrowedAt: narrowedAt,
                cleanedAt: cleanedAt,
                injectSeconds: injectSeconds,
                transcribed: transcribed,
                cleanup: cleanupRecord,
                cleanupTimedOut: cleanupTimedOut,
                laneWait: laneWait
            ) {
                usage.record(row)
            }
        }

        // The metrics read is an actor hop. A canceled tail keeps its own usage,
        // but cannot finish or fail the next hold.
        guard self.session == session else { return }
        switch outcome {
        case .superseded:
            return
        case .inserted:
            // The words landed, so an earlier failed hold is no longer the one worth
            // keeping (D-03).
            lastFailedHold = nil
            if Settings.shared.soundEnabled { NSSound(named: "Pop")?.play() }
            finishIdle(result: .inserted)

        case .copiedByChoice:
            // The setting asked for this, so it is a success and gets the success
            // sound. Saying "that went to your clipboard" every time would be nagging
            // someone about a choice they already made.
            lastFailedHold = nil
            if Settings.shared.soundEnabled { NSSound(named: "Pop")?.play() }
            finishIdle(result: .copied)

        case .couldNotReturn(let appName):
            // Not silent. The old behaviour here was to paste into whatever the user
            // had switched to — or nowhere — and say nothing, which is indistinguishable
            // from the app losing the recording.
            //
            // `keepsAudio: false`: the words are on the clipboard, so nothing is lost and
            // a "Try again" here would type the same sentence in twice.
            fail("Couldn't switch back to \(appName). That dictation is on your clipboard.",
                 keepsAudio: false, result: .failed(.couldNotReturn))
        }
    }

    /// The one way back to rest after a successful run. `result` files the hold's one
    /// usage row (D-01b) first — the counter and the stashed tail numbers are read
    /// here, before anything below clears them.
    private func finishIdle(result: DictationHoldResult) {
        captureDrainTask = nil
        reportOutcome(result)
        AudioCaptureHub.shared.unsubscribe(.dictation)
        isCapturingAudio = false
        releasedDuringStartup = nil
        audioCounter = nil
        level = 0
        state = .idle
        transcript = ""
        firstPartialTrace = nil
        keyDownToCaptureTrace = nil
        recordingIntent = .dictation
        showCommandMode(nil)
        origin = nil
        OutputProfileStore.shared.clearCapturedTarget()
        ScreenContextStore.shared.clearCaptured()
    }

    // MARK: - Outcome rows (D-01b)

    /// Files the hold's exactly-one usage row, whatever happened.
    ///
    /// The counts are read here rather than carried through the hold, because the only
    /// reliable moment to read the counter and the tail's stashes is the moment the
    /// hold ends. `outcomeReported` makes the call idempotent: a cancel that lands
    /// mid-tail files the row first, and the tail's own finish then finds the guard
    /// closed — no path reports twice, and case g of `--selftest-dictation` pins that.
    ///
    /// Deliberately silent when no hold is in flight: a cancel or a deactivate with
    /// nothing running finds `outcomeReported` still true from the last hold.
    private func reportOutcome(_ result: DictationHoldResult) {
        guard !outcomeReported else { return }
        outcomeReported = true
        let now = Date()
        var counts: [String: Int] = [:]
        if let holdMs = holdMillis(at: now) { counts["holdMs"] = holdMs }
        if let capture = keyDownToCaptureSeconds {
            counts["keyDownToCaptureMs"] = Int((capture * 1_000).rounded())
        }
        counts["words"] = lastHoldWords
        counts["capturedFrames"] = audioCounter?.frames ?? 0
        counts["droppedHubBuffers"] = audioCounter?.hubDropCount ?? 0
        counts["droppedStreamBuffers"] = audioCounter?.streamDropCount ?? 0
        counts["cleanupTimedOut"] = lastHoldCleanupTimedOut ? 1 : 0
        if let prewarmed = lastHoldCleanupRecord?.sessionPrewarmed {
            counts["sessionPrewarmed"] = prewarmed ? 1 : 0
        }
        let keyUpToOutcome: Duration?
        switch result {
        case .lostAtStartup, .cancelled:
            keyUpToOutcome = nil
        default:
            keyUpToOutcome = (releasedAt ?? holdKeyUpAt).map {
                .seconds(now.timeIntervalSince($0))
            }
        }
        outcomeSink(DictationHoldOutcome(
            holdID: holdID,
            result: result,
            keyUpToOutcome: keyUpToOutcome,
            counts: counts,
            engine: currentEngineChoice
        ))
    }

    /// Key-down → hold end, in milliseconds, for the row's `holdMs`. The live pair of
    /// dates wins while it is alive (a failure before key-up measures the hold so
    /// far); the key-up snapshot is what survives `recordRun` clearing both dates
    /// before `finishIdle` reports an inserted or copied hold.
    private func holdMillis(at now: Date) -> Int? {
        if let holdStarted, let releasedAt {
            return Self.millisecondsBetween(holdStarted, releasedAt)
        }
        if let holdStarted {
            return Self.millisecondsBetween(holdStarted, now)
        }
        return holdMsAtKeyUp
    }

    /// One `dictation.press_refused` row per refused press (D-01b). The state names
    /// itself in the row's `errorClass`; `.finishing` carries how long ago the key
    /// came up. A press in a startable state (`.idle`, and `.error` since D-05) is
    /// never refused, so it never reaches here.
    private func reportRefusedPress() {
        let stateName: String
        switch state {
        case .starting: stateName = "starting"
        case .listening: stateName = "listening"
        case .finishing: stateName = "finishing"
        case .idle, .error: return
        }
        var counts: [String: Int] = [:]
        if stateName == "finishing", let releasedAt {
            counts["sinceKeyUpMs"] = Self.millisecondsBetween(releasedAt, Date())
        }
        usage.record(DictationHoldOutcome.pressRefusedRecord(
            state: stateName,
            counts: counts,
            engine: currentEngineChoice,
            holdID: holdID
        ))
    }

    /// The engine this hold ran — or was armed to run — for the usage rows. The tail
    /// reads the engine object (P0-20c); an outcome reported before any engine existed
    /// names the setting, which is what would have run.
    private var currentEngineChoice: SpeechEngineChoice {
        if engine is AppleSpeechEngine { return .apple }
        if let engine = engine as? ParakeetEngine { return engine.modelChoice }
        return engine == nil ? Settings.shared.resolvedSpeechEngine : .parakeet
    }

    private static func millisecondsBetween(_ from: Date, _ to: Date) -> Int {
        max(0, Int((to.timeIntervalSince(from) * 1_000).rounded()))
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    private func applyCommand(_ rawCommand: String, to selection: TextInjector.Selection) async {
        // Corrections still matter in a spoken instruction (for example a product name),
        // but punctuation cleanup does not: the model needs an imperative, not prose.
        let (command, _) = DictionaryStore.shared.corrector.apply(to: rawCommand)
        lastHoldWords = Self.wordCount(command)
        transcript = "Editing selection…"
        showCommandMode(.rewriting)

        // Bounded like the dictation tail, and for the same reason: the model behind this
        // is Apple's, it already has its own timeout, and if that timeout ever fails to
        // fire the HUD would sit on "Editing selection…" indefinitely.
        let processor = commandProcessor
        // `Selection` holds an `AXUIElement` and is deliberately not `Sendable`; only its
        // text crosses into the bounded closure.
        let source = selection.text
        let outcome = await withBoundedWait(limits.command) { () -> CommandOutcome in
            do { return .replaced(try await processor.apply(command: command, to: source)) }
            catch { return .failed(error.localizedDescription) }
        }

        switch outcome {
        case .replaced(let replacement)?:
            guard TextInjector.replace(selection, with: replacement) else {
                fail("The selection changed while Command Mode was processing; nothing was replaced.",
                     result: .failed(.couldNotReturn))
                return
            }
            recordRun(text: replacement)
            if Settings.shared.soundEnabled { NSSound(named: "Pop")?.play() }
            finishIdle(result: .command)
        case .failed(let reason)?:
            fail(reason, result: .failed(.engine))
        case nil:
            fail("Command Mode didn't finish in time; the selection was left alone.",
                 result: .failed(.engine))
        }
    }

    /// What the Command Mode model came back with, or didn't.
    private enum CommandOutcome: Sendable {
        case replaced(String)
        case failed(String)
    }

    /// Internal (not private) so `--selftest-dictation` can prove a superseded
    /// start-up never cuts the next hold's microphone (D-02 case d). Production
    /// callers are `deactivate()` and the Command Mode cancel path below.
    func cancelDictation() {
        captureDrainTask = nil
        // The hold's one outcome row, filed before the slots are cleared (D-01b). A
        // cancel with no hold in flight finds `outcomeReported` still true and files
        // nothing; a cancel mid-tail wins over the tail's own finish, whose report the
        // same guard then refuses.
        reportOutcome(.cancelled)
        let releasing = session
        session &+= 1
        AudioCaptureHub.shared.unsubscribe(.dictation)
        isCapturingAudio = false
        releasedDuringStartup = nil
        audioCounter = nil
        audioContinuation?.finish()
        audioContinuation = nil
        feedTask?.cancel()
        feedTask = nil
        consumeTask?.cancel()
        consumeTask = nil
        // D-12: nothing this hold was tidying behind the key is wanted any more.
        dropIncrementalCleanup()

        let engine = self.engine
        self.engine = nil
        Task { @MainActor in
            await engine?.finish()
            await self.releaseASRLane(for: releasing)
        }

        state = .idle
        transcript = ""
        level = 0
        firstPartialTrace = nil
        keyDownToCaptureTrace?.end(note: "cancelled")
        keyDownToCaptureTrace = nil
        recordingIntent = .dictation
        showCommandMode(nil)
    }

    // MARK: - Helpers

    /// Replays the recording through every engine and files the results as one group.
    ///
    /// Nothing is injected in this mode — the point is to read the outputs side by side,
    /// and typing one of them into whatever had focus would be a surprise.
    private func runComparison() async {
        let chunks = recorded
        recorded.removeAll(keepingCapacity: false)

        guard !chunks.isEmpty, let holdStarted, let releasedAt else {
            reportOutcome(.compare)
            state = .idle
            transcript = ""
            return
        }

        transcript = "Running both engines…"

        let group = UUID().uuidString
        let held = releasedAt.timeIntervalSince(holdStarted)

        // Filed one at a time as each engine finishes, so the window fills in progressively
        // rather than snapping both rows into place at the end.
        let results = await EngineComparison.run(chunks: chunks) { result in
            record(
                DictationRun(
                    date: releasedAt,
                    engine: result.engine,
                    audioSeconds: held,
                    processSeconds: result.seconds,
                    text: result.text,
                    group: group
                )
            )
        }

        for result in results {
            Log.speech.info("""
                compare · \(result.engine, privacy: .public): \
                \(result.seconds, format: .fixed(precision: 2))s — \
                \(result.text, privacy: .public)
                """)
        }

        // Wispr Flow, if its hotkey was held for this same utterance. It transcribes in the
        // cloud, so its row lands after both local engines have already finished — the wait
        // happens here rather than blocking the rows above from appearing.
        if WisprReader.isInstalled {
            transcript = "Waiting for Wispr Flow…"
            if let wispr = await WisprReader.result(after: holdStarted, timeout: 8) {
                record(
                    DictationRun(
                        date: releasedAt,
                        engine: wispr.engine,
                        audioSeconds: held,
                        processSeconds: wispr.seconds,
                        text: wispr.text,
                        group: group
                    )
                )
                Log.speech.info("""
                    compare · \(wispr.engine, privacy: .public): \
                    \(wispr.seconds, format: .fixed(precision: 2))s — \
                    \(wispr.text, privacy: .public)
                    """)
            } else {
                Log.speech.info("compare · Wispr Flow: no result (hotkey not held, or timed out)")
            }
        }

        reportOutcome(.compare)
        self.holdStarted = nil
        self.releasedAt = nil
        isComparing = false
        state = .idle
        transcript = ""

        if Settings.shared.soundEnabled { NSSound(named: "Glass")?.play() }
    }

    /// Files the finished utterance for the dashboard.
    ///
    /// `processSeconds` is measured from key release, not from capture start — that's the
    /// wait the user actually experiences, and it's the only number on which a streaming
    /// engine and a batch engine can be compared honestly.
    ///
    /// `runID` is the id the tail's usage rows join on (P0-20c). Command Mode passes none:
    /// it is not a dictation pass, so it files a run with a fresh id and no usage row.
    private func recordRun(
        text: String,
        corrections: [AppliedCorrection] = [],
        cleanup: CleanupRecord? = nil,
        runID: UUID? = nil
    ) {
        guard let holdStarted, let releasedAt else { return }
        record(
            DictationRun(
                id: runID ?? UUID(),
                date: releasedAt,
                engine: engineName,
                audioSeconds: releasedAt.timeIntervalSince(holdStarted),
                processSeconds: Date().timeIntervalSince(releasedAt),
                text: text,
                corrections: corrections.isEmpty ? nil : corrections,
                cleanup: cleanup
            )
        )
        self.holdStarted = nil
        self.releasedAt = nil
    }

    /// Light smoothing so the waveform glides instead of strobing at buffer rate.
    private func updateLevel(_ new: Float) {
        level += (new - level) * 0.35
    }

    /// The one way back to rest after anything went wrong.
    ///
    /// Every exit from here leaves the microphone closed, the slots empty and the state
    /// machine on its way to `.idle` — a dictation that says what went wrong and stops is
    /// the whole point of bounding the waits above.
    ///
    /// `keepsAudio` decides whether the hold's recording is moved into the one "Try
    /// again" slot before the slots are cleared (D-03). True for every path where the
    /// words are nowhere else; false when they have already been delivered somewhere.
    ///
    /// `result` names the outcome class explicitly at every call site (D-01b) — never
    /// parsed out of the message, which is written for the user and reworded freely.
    /// The hold's one row is filed here, while the counter and the tail stashes are
    /// still reachable.
    private func fail(
        _ message: String,
        keepsAudio: Bool = true,
        result: DictationHoldResult
    ) {
        captureDrainTask = nil
        // Plain `message`, not an interpolated `OSLogMessage`: the seam takes a `String`,
        // and the production closure is the one that applies the redaction.
        log.appError(message)
        // A Command Mode hold keeps its own card rather than handing the message to the
        // dictation error state. Gated on what this hold is rather than on whether a card is
        // up, so a leftover message from an earlier hold cannot claim an ordinary dictation's
        // failure — that one goes to `.error`, which the island now draws with its words on.
        if recordingIntent.kind == .command { showCommandMode(.problem(message)) }
        // Before anything below disowns the slots: this is the only moment the recording
        // is still reachable, and it is what "Try again" plays.
        if keepsAudio { keepForRetry(audioCounter) }
        // The hold's one outcome row, while the counter and the stashes are alive.
        reportOutcome(result)
        // Anything still in flight for this hold is disowned rather than awaited: `fail` is
        // reached *because* something did not come back.
        let releasing = session
        session &+= 1
        AudioCaptureHub.shared.unsubscribe(.dictation)
        isCapturingAudio = false
        releasedDuringStartup = nil
        audioCounter = nil
        audioContinuation?.finish()
        audioContinuation = nil
        feedTask?.cancel()
        feedTask = nil
        // D-12: a hold whose transcript will never be typed must not leave the model
        // working on its sentences behind the error card.
        dropIncrementalCleanup()
        let engine = self.engine
        self.engine = nil
        if let engine {
            Task { @MainActor in
                await engine.finish()
                await self.releaseASRLane(for: releasing)
            }
        } else {
            Task { @MainActor in
                await self.releaseASRLane(for: releasing)
            }
        }
        consumeTask?.cancel()
        consumeTask = nil
        firstPartialTrace = nil
        keyDownToCaptureTrace?.end(note: "failed")
        keyDownToCaptureTrace = nil
        state = .error(message)
        transcript = ""
        level = 0
        isComparing = false
        recordingIntent = .dictation
        origin = nil
        OutputProfileStore.shared.clearCapturedTarget()
        ScreenContextStore.shared.clearCaptured()
        holdStarted = nil
        releasedAt = nil

        // A hold started from this card, or a newer failure, keeps its own 3 s:
        // a stale timer must clear neither.
        errorToken &+= 1
        let token = errorToken
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.errorToken == token else { return }
            if case .error = state { state = .idle }
        }
    }

    /// Releases the controller-owned Apple ASR lane when it still belongs to
    /// `session`. No-op for Parakeet (engine-owned) or a superseded id.
    private func releaseASRLane(for session: Int) async {
        guard asrLaneSession == session, let id = asrLaneID else { return }
        asrLaneID = nil
        asrLaneSession = 0
        await ComputeScheduler.shared.release(id)
    }
}

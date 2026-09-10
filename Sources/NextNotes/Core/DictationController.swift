import NextNotesDictionary
import AVFoundation
import AppKit
import Foundation
import Observation

/// Builds the engine named by the current setting.
///
/// Deliberately at file scope rather than a static on `DictationController`: the class is
/// `@MainActor`, which would make a static method main-actor-isolated and therefore
/// ineligible to be `@Sendable`. Reading the setting per-utterance is what lets the menu's
/// engine picker take effect on the very next hold instead of needing a restart.
@MainActor
func engineForCurrentSetting() -> any TranscriptionEngine {
    switch Settings.shared.engine {
    case .apple: AppleSpeechEngine()
    case .parakeet: ParakeetEngine()
    }
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
    _ work: @escaping @Sendable () async -> T
) async -> T? {
    let gate = RaceGate<T>()
    let job = Task(priority: .userInitiated) { await gate.settle(await work()) }
    let timer = Task {
        try? await Task.sleep(for: limit)
        await gate.settle(nil)
    }

    let result = await gate.value()
    timer.cancel()
    if result == nil { job.cancel() }
    return result
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
    /// Whether the global event tap is actually armed. Accessibility can appear enabled in
    /// System Settings while a rebuilt/ad-hoc-signed binary is no longer trusted.
    private(set) var hotkeyReady = false
    /// Live transcript, updated as the engine revises it. Drives the HUD.
    private(set) var transcript = ""
    /// Smoothed 0…1 mic level for the waveform.
    private(set) var level: Float = 0

    private let hotkey = HotkeyMonitor()
    private let commandHotkey = HotkeyMonitor()
    private let capture = AudioCapture()
    private let makeEngine: @MainActor @Sendable () -> any TranscriptionEngine

    /// Injected only by tests; production reads the setting per-utterance below.
    private let formatter: (any TextFormatter)?
    /// Injected only by tests; production types into whatever had focus. A self-test that
    /// used the real injector would type its fixture into the terminal that started it.
    private let insert: @MainActor (String, TextInjector.Origin?) async -> TextInjector.Outcome
    /// Injected only by tests; production files the run for the Dictation list. A self-test
    /// that used the real log would write its fixtures into the user's own history — which
    /// it did, until this seam existed.
    private let record: @MainActor (DictationRun) -> Void
    private let commandProcessor: any TextCommandProcessor

    /// Chosen per-utterance so the menu toggle applies to the very next hold.
    ///
    /// A function rather than a computed property because of `context`: the names visible on
    /// screen are harvested on a detached task and have to be awaited, and a property has
    /// nowhere to put the await. It stays private, so nothing outside this file is affected.
    private func activeFormatter(context: ScreenContext) -> any TextFormatter {
        if let formatter { return formatter }
        let settings = Settings.shared
        // What the app about to receive this text can actually render, captured at
        // key-down. Resolving it here rather than at injection time is the whole point:
        // formatting a list as Slack bullets and then dropping it into Mail is worse than
        // not formatting at all.
        let target = OutputProfileStore.shared.capturedProfile
        switch settings.cleanupEngine {
        case .apple:
            // One model, one pass. Apple's does restoration and grammar in the same call, so
            // grammar is free here rather than a second trip.
            return FoundationModelFormatter(
                preferences: settings.cleanupPreferences,
                fixesGrammar: settings.cleanupFixesGrammar,
                target: target,
                context: context
            )
        case .s1Mini:
            // S1-mini takes no instructions at all, so neither a target profile nor the list of
            // on-screen names can reach it. Punctuation-only cleanup is therefore the one
            // combination where per-app formatting has no effect *and* where a spoken file name
            // stays a spoken file name — there is no prompt to put either set of rules in, and
            // the harvest that ran at key-down is simply discarded. With grammar repair on, the
            // second pass below is a general-purpose model and does honour both.
            let punctuation = S1MiniFormatter(preferences: settings.cleanupPreferences)
            guard settings.cleanupFixesGrammar else { return punctuation }
            // S1-mini cannot repair grammar — it is a punctuation model, not an
            // instruction-following one — so grammar is a second pass on its output rather
            // than a setting it could honour. `KeepAsIsFormatter` because by this point the
            // sentence is already punctuated: if the grammar stage cannot run, the right
            // answer is what S1-mini produced, not a rule-based third opinion about it.
            return ChainedFormatter(
                first: punctuation,
                second: FoundationModelFormatter(
                    preferences: settings.cleanupPreferences,
                    fixesGrammar: true,
                    target: target,
                    context: context,
                    fallback: KeepAsIsFormatter()
                )
            )
        }
    }

    /// Whether the formatter this hold is about to build can be told anything at all about
    /// the screen. False means the harvest is not merely unused but must not be *scored*.
    ///
    /// Mirrors `activeFormatter(context:)` above, and has to be read against it rather than
    /// guessed at: the injected `formatter` test seam ignores the context, and punctuation-only
    /// S1-mini takes no instructions — but S1-mini *with* grammar repair chains a second
    /// Apple pass that does honour it, so the engine alone does not answer the question.
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
        guard formatterUsesContext else { return .empty }

        let harvested = await ScreenContextStore.shared.awaitCapture(within: .seconds(1))
        guard !harvested.isEmpty else { return harvested }

        // Not `Task.detached`: `withBoundedWait` runs its closure in a task started from a
        // nonisolated function, so the body is already off the main actor. One mechanism for
        // the bound and the hop, rather than two nested ones.
        let narrowed = await withBoundedWait(limits.narrow) {
            harvested.narrowed(toMentionsIn: raw)
        }
        if let narrowed { return narrowed }
        Log.speech.error("""
            narrowing \(harvested.candidates.count, privacy: .public) screen name(s) did not \
            finish within \(String(describing: self.limits.narrow), privacy: .public) — \
            using rank order
            """)
        return harvested.rankLimited()
    }

    private var engine: (any TranscriptionEngine)?
    private var consumeTask: Task<Void, Never>?
    /// Returns the ordered recording when compare mode is on, empty otherwise.
    private var feedTask: Task<[AudioChunk], Never>?
    private var audioContinuation: AsyncStream<AudioChunk>.Continuation?

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
        insert: @escaping @MainActor (String, TextInjector.Origin?) async -> TextInjector.Outcome
            = { await TextInjector.insert($0, returningTo: $1) },
        record: @escaping @MainActor (DictationRun) -> Void = { RunLog.record($0) }
    ) {
        self.formatter = formatter
        self.commandProcessor = commandProcessor
        self.makeEngine = makeEngine
        self.limits = limits
        self.insert = insert
        self.record = record
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
            commandHotkey.key = settings.commandModeKey
            commandHotkey.onPress = { [weak self] in self?.beginCommand() }
            commandHotkey.onRelease = { [weak self] in self?.endDictation(expected: .command) }
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

    /// Starts a recording from a Record button rather than the hotkey.
    ///
    /// Wispr Flow's hotkey is held down for the duration **only in compare mode**. Reaching
    /// into another app is a comparison affordance; during ordinary dictation it would mean
    /// every recording silently shipped your audio to a third party's servers.
    func startButtonRecording() {
        guard case .idle = state else { return }
        if Settings.shared.compareMode { WisprTrigger.press() }
        beginDictation(intent: .dictation)
    }

    /// Releases Wispr's hotkey first, so its upload starts while our own engines are still
    /// finishing — otherwise every run would wait the full round trip end to end.
    func stopButtonRecording() {
        WisprTrigger.release()
        endDictation()
    }

    // MARK: - Dictation

    private func beginCommand() {
        guard case .idle = state else { return }
        guard FoundationModelCommandProcessor.isAvailable else {
            fail(FoundationModelCommandProcessor.unavailableReason
                ?? "The on-device model required by Command Mode is unavailable.")
            return
        }
        guard let selection = TextInjector.captureSelection() else {
            fail("Select editable text before holding the Command Mode key.")
            return
        }
        beginDictation(intent: .command(selection))
    }

    private func beginDictation(intent: RecordingIntent) {
        guard case .idle = state else { return }
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
        // mid-utterance — plus one of its own: it is a tree walk with a 120 ms budget, and the
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
        ScreenContextStore.shared.beginCapture(
            for: target,
            // The process id, not the `NSRunningApplication` it came from. The walk happens on
            // a detached task and `AXUIElement` is not `Sendable`; an `Int32` is, and the
            // harvester builds its own element from it on the far side.
            //
            // Deliberately `origin`'s pid rather than one derived from `target`. A nil origin
            // means Next Notes itself was frontmost, and then there is no harvest at all — even
            // though `captureTarget()` still resolves a profile, from the last foreign app.
            //
            // `originBundleID` is what makes the pid and the bundle identifier name the same
            // running process rather than merely being asserted to. They come from two reads of
            // the frontmost app with different rules: `captureOrigin()` accepts an app with no
            // bundle identifier at all — an unsigned Electron build, something run from a
            // terminal — while `frontmostApp()` requires one and otherwise falls back to the
            // last foreign app. So Cursor could be the target while the pid belonged to
            // something else entirely, and the harvest would then walk an app no adapter and no
            // deny list was ever consulted for and label the result "Cursor".
            processID: origin?.app.processIdentifier,
            originBundleID: origin?.app.bundleIdentifier
        )
        state = .starting
        transcript = ""
        holdStarted = Date()
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
                guard await Permissions.requestMicrophone() else {
                    guard self.session == session else { return }
                    fail("Microphone access is off. Enable it in System Settings ▸ Privacy & Security ▸ Microphone.")
                    return
                }
                guard self.session == session else { return }

                let engine = makeEngine()
                self.engine = engine

                // Bounded, because this is where the model load lives. Without a deadline a
                // first-run download sits behind a HUD that says "Listening…" for as long as
                // the transfer takes, and the utterance is lost at the end of it anyway.
                let outcome = await withBoundedWait(limits.startup) { () -> StartOutcome in
                    do { return .started(try await engine.start()) }
                    catch { return .failed(error.localizedDescription) }
                }

                // Superseded or released while the model was loading: this start-up owns
                // nothing but its own engine, and must not touch the slots of whoever came
                // after it.
                guard self.session == session, case .starting = self.state else {
                    await engine.finish()
                    if self.session == session { self.engine = nil }
                    return
                }

                let chunkStream: AsyncThrowingStream<TranscriptionChunk, Error>
                switch outcome {
                case .started(let stream):
                    chunkStream = stream
                case .failed(let reason):
                    self.engine = nil
                    fail(reason)
                    return
                case nil:
                    self.engine = nil
                    Task { await engine.finish() }
                    fail("The speech model didn't finish loading in time. If it is still downloading, let Settings ▸ Models finish first.")
                    return
                }

                // Compare mode captures in *Apple's* format, not a format of our choosing.
                //
                // SpeechAnalyzer enforces `Audio sample data must be 16-bit signed integers`
                // as a hard precondition — feeding it float32 doesn't fail gracefully, it
                // kills the process. Parakeet is the flexible one (its `feed` converts
                // int16/int32/float32), so the strict engine picks the format and the
                // tolerant engine adapts. Both still replay the identical buffers.
                let formatOwner: any TranscriptionEngine = isComparing ? AppleSpeechEngine() : engine
                let format = await formatOwner.preferredInputFormat()

                // Last chance to notice a release or a newer hold: after this line the
                // controller's slots and the microphone belong to this session, and every
                // exit below has to unwind them.
                guard self.session == session, case .starting = self.state else {
                    await engine.finish()
                    if self.session == session { self.engine = nil }
                    return
                }
                guard let format else { throw TranscriptionError.noAudioFormat }

                // Audio must reach the engine in capture order. A stream plus a single
                // draining task guarantees that; spawning a Task per buffer would not.
                let (audioStream, audioContinuation) = AsyncStream<AudioChunk>.makeStream(
                    bufferingPolicy: .bufferingNewest(64)
                )

                // The recording is accumulated *inside* the ordered drain, not by spawning
                // a task per buffer. Unstructured tasks have no ordering guarantee, so
                // collecting them separately could assemble the replay audio out of order
                // and silently produce word-salad from the comparison.
                let comparing = isComparing
                let feedTask = Task.detached(priority: .userInitiated) { () -> [AudioChunk] in
                    var recording: [AudioChunk] = []
                    for await chunk in audioStream {
                        if comparing { recording.append(chunk) }
                        await engine.feed(chunk)
                    }
                    return recording
                }

                // Capture starts *after* the guard above, not before it. Started first, a
                // start-up that has already been superseded opens the microphone on behalf
                // of a recording nobody asked for, and only closes it again a line later.
                do {
                    try capture.start(
                        outputFormat: format,
                        onBuffer: { chunk in
                            audioContinuation.yield(chunk)
                        },
                        onLevel: { [weak self] level in
                            Task { @MainActor in self?.updateLevel(level) }
                        }
                    )
                } catch {
                    audioContinuation.finish()
                    feedTask.cancel()
                    self.engine = nil
                    await engine.finish()
                    fail(error.localizedDescription)
                    return
                }

                self.audioContinuation = audioContinuation
                self.feedTask = feedTask
                self.state = .listening
                if Settings.shared.soundEnabled { NSSound(named: "Tink")?.play() }

                self.consumeTask = Task { @MainActor in
                    do {
                        for try await chunk in chunkStream {
                            guard self.session == session else { return }
                            self.transcript = chunk.text
                        }
                    } catch {
                        guard self.session == session else { return }
                        self.fail(error.localizedDescription)
                    }
                }
            } catch {
                guard self.session == session else { return }
                self.fail(error.localizedDescription)
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
        // inside `finish()`, and smart cleanup adds up to 4s on top.
        guard state.isActive, state != .finishing else { return }
        guard expected == nil || recordingIntent.kind == expected else { return }

        // A release that lands before `capture.start()` ran has no audio behind it: the
        // engine was still loading and the microphone was never opened. Going quietly back
        // to `.idle` here is what "I held the key, spoke, and nothing arrived" actually
        // looks like from the outside, so say it instead. Bumping the session tells the
        // start-up still in flight to unwind itself rather than come up listening to a key
        // that is no longer held.
        if case .starting = state {
            session &+= 1
            fail("Next Notes was still starting up, so that recording was lost. Hold the key again.")
            return
        }

        state = .finishing
        capture.stop()
        level = 0
        releasedAt = Date()
        let session = self.session

        Task { @MainActor in
            // Drain every captured buffer into the engine before asking it to finalize,
            // or the tail of the utterance gets dropped.
            let audioContinuation = self.audioContinuation
            let feedTask = self.feedTask
            let engine = self.engine
            let consumeTask = self.consumeTask
            self.audioContinuation = nil
            self.feedTask = nil
            self.engine = nil
            self.consumeTask = nil

            let began = Date()
            audioContinuation?.finish()
            recorded = await withBoundedWait(limits.drain) {
                await feedTask?.value ?? []
            } ?? []
            let drained = Date().timeIntervalSince(began)

            // `finish()` and the transcript stream are one leg: with a batch engine the
            // transcription happens inside `finish()` and the stream yields once at the
            // end of it, so bounding them separately would only mean two ways to hang.
            let transcribed = await withBoundedWait(limits.transcribe) { () -> Bool in
                await engine?.finish()
                await consumeTask?.value
                return true
            } ?? false
            let transcribedAt = Date().timeIntervalSince(began)
            if !transcribed {
                Log.speech.error("transcription did not finish within \(String(describing: self.limits.transcribe), privacy: .public)")
            }

            guard self.session == session else { return }

            if isComparing {
                await runComparison()
                return
            }

            let raw = transcript
            guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                // A timed-out transcription leaves nothing to inject, and silence is the
                // one thing the user must not be told it was.
                if transcribed {
                    finishIdle()
                } else {
                    fail("Transcription didn't finish in time; that recording was lost.")
                }
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
            if Settings.shared.cleanupEnabled {
                let screen = await screenNames(mentionedIn: raw)
                narrowedAt = Date().timeIntervalSince(began)
                guard self.session == session else { return }
                let formatter = activeFormatter(context: screen)
                if let formatted = await withBoundedWait(limits.cleanup, { await formatter.format(raw) }) {
                    cleaned = formatted
                } else {
                    Log.speech.error("cleanup did not finish within \(String(describing: self.limits.cleanup), privacy: .public) — using the raw transcript")
                }
            }

            // The split, every time, at info level. `runs.jsonl` records one number for the
            // whole tail, and a run that took three minutes when it should have taken two
            // seconds is not diagnosable from one number: draining, transcribing, narrowing the
            // screen names and cleaning up are four different machines and any of them can be
            // the slow one.
            let cleanedAt = Date().timeIntervalSince(began)
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
            let (output, corrections) = DictionaryStore.shared.corrector.apply(to: cleaned)
            if !corrections.isEmpty {
                Log.speech.info("dictionary · \(corrections.count, privacy: .public) correction(s) applied")
            }

            // Recorded before injection, deliberately. If the text cannot be placed, the
            // Dictation list is the other way back to it, and an utterance that is hard to
            // deliver is exactly the one worth having filed.
            recordRun(text: output, corrections: corrections)

            switch await insert(output, origin) {
            case .inserted:
                if Settings.shared.soundEnabled { NSSound(named: "Pop")?.play() }
                finishIdle()

            case .copiedByChoice:
                // The setting asked for this, so it is a success and gets the success
                // sound. Saying "that went to your clipboard" every time would be nagging
                // someone about a choice they already made.
                if Settings.shared.soundEnabled { NSSound(named: "Pop")?.play() }
                finishIdle()

            case .couldNotReturn(let appName):
                // Not silent. The old behaviour here was to paste into whatever the user
                // had switched to — or nowhere — and say nothing, which is indistinguishable
                // from the app losing the recording.
                fail("Couldn't switch back to \(appName). That dictation is on your clipboard.")
            }
        }
    }

    /// The one way back to rest after a successful run.
    private func finishIdle() {
        capture.stop()
        level = 0
        state = .idle
        transcript = ""
        recordingIntent = .dictation
        origin = nil
        OutputProfileStore.shared.clearCapturedTarget()
        ScreenContextStore.shared.clearCaptured()
    }

    private func applyCommand(_ rawCommand: String, to selection: TextInjector.Selection) async {
        // Corrections still matter in a spoken instruction (for example a product name),
        // but punctuation cleanup does not: the model needs an imperative, not prose.
        let (command, _) = DictionaryStore.shared.corrector.apply(to: rawCommand)
        transcript = "Editing selection…"

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
                fail("The selection changed while Command Mode was processing; nothing was replaced.")
                return
            }
            recordRun(text: replacement)
            if Settings.shared.soundEnabled { NSSound(named: "Pop")?.play() }
            finishIdle()
        case .failed(let reason)?:
            fail(reason)
        case nil:
            fail("Command Mode didn't finish in time; the selection was left alone.")
        }
    }

    /// What the Command Mode model came back with, or didn't.
    private enum CommandOutcome: Sendable {
        case replaced(String)
        case failed(String)
    }

    private func cancelDictation() {
        session &+= 1
        capture.stop()
        audioContinuation?.finish()
        audioContinuation = nil
        feedTask?.cancel()
        feedTask = nil
        consumeTask?.cancel()
        consumeTask = nil

        let engine = self.engine
        self.engine = nil
        Task { await engine?.finish() }

        state = .idle
        transcript = ""
        level = 0
        recordingIntent = .dictation
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
    private func recordRun(text: String, corrections: [AppliedCorrection] = []) {
        guard let holdStarted, let releasedAt else { return }
        record(
            DictationRun(
                date: releasedAt,
                engine: engineName,
                audioSeconds: releasedAt.timeIntervalSince(holdStarted),
                processSeconds: Date().timeIntervalSince(releasedAt),
                text: text,
                corrections: corrections.isEmpty ? nil : corrections
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
    private func fail(_ message: String) {
        Log.app.error("\(message, privacy: .public)")
        // Anything still in flight for this hold is disowned rather than awaited: `fail` is
        // reached *because* something did not come back.
        session &+= 1
        capture.stop()
        audioContinuation?.finish()
        audioContinuation = nil
        feedTask?.cancel()
        feedTask = nil
        let engine = self.engine
        self.engine = nil
        if let engine { Task { await engine.finish() } }
        consumeTask?.cancel()
        consumeTask = nil
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

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if case .error = state { state = .idle }
        }
    }
}

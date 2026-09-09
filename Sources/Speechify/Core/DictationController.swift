import SpeechifyDictionary
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
    private let commandProcessor: any TextCommandProcessor

    /// Chosen per-utterance so the menu toggle applies to the very next hold.
    private var activeFormatter: any TextFormatter {
        if let formatter { return formatter }
        let settings = Settings.shared
        switch settings.cleanupEngine {
        case .apple:
            return FoundationModelFormatter(preferences: settings.cleanupPreferences)
        case .s1Mini:
            return S1MiniFormatter(preferences: settings.cleanupPreferences)
        }
    }

    private var engine: (any TranscriptionEngine)?
    private var consumeTask: Task<Void, Never>?
    /// Returns the ordered recording when compare mode is on, empty otherwise.
    private var feedTask: Task<[AudioChunk], Never>?
    private var audioContinuation: AsyncStream<AudioChunk>.Continuation?

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

    /// Compare mode only: the recording, kept so every engine sees identical audio.
    private var recorded: [AudioChunk] = []
    private var isComparing = false

    init(
        formatter: (any TextFormatter)? = nil,
        commandProcessor: any TextCommandProcessor = FoundationModelCommandProcessor(),
        makeEngine: @escaping @MainActor @Sendable () -> any TranscriptionEngine = engineForCurrentSetting
    ) {
        self.formatter = formatter
        self.commandProcessor = commandProcessor
        self.makeEngine = makeEngine
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
        recordingIntent = intent
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
                    fail("Microphone access is off. Enable it in System Settings ▸ Privacy & Security ▸ Microphone.")
                    return
                }

                let engine = makeEngine()
                self.engine = engine

                let chunks = try await engine.start()

                // Compare mode captures in *Apple's* format, not a format of our choosing.
                //
                // SpeechAnalyzer enforces `Audio sample data must be 16-bit signed integers`
                // as a hard precondition — feeding it float32 doesn't fail gracefully, it
                // kills the process. Parakeet is the flexible one (its `feed` converts
                // int16/int32/float32), so the strict engine picks the format and the
                // tolerant engine adapts. Both still replay the identical buffers.
                let formatOwner: any TranscriptionEngine = isComparing ? AppleSpeechEngine() : engine
                guard let format = await formatOwner.preferredInputFormat() else {
                    throw TranscriptionError.noAudioFormat
                }

                // Audio must reach the engine in capture order. A stream plus a single
                // draining task guarantees that; spawning a Task per buffer would not.
                let (audioStream, audioContinuation) = AsyncStream<AudioChunk>.makeStream(
                    bufferingPolicy: .bufferingNewest(64)
                )
                self.audioContinuation = audioContinuation

                // The recording is accumulated *inside* the ordered drain, not by spawning
                // a task per buffer. Unstructured tasks have no ordering guarantee, so
                // collecting them separately could assemble the replay audio out of order
                // and silently produce word-salad from the comparison.
                let comparing = isComparing
                self.feedTask = Task.detached(priority: .userInitiated) {
                    var recording: [AudioChunk] = []
                    for await chunk in audioStream {
                        if comparing { recording.append(chunk) }
                        await engine.feed(chunk)
                    }
                    return recording
                }

                try capture.start(
                    outputFormat: format,
                    onBuffer: { chunk in
                        audioContinuation.yield(chunk)
                    },
                    onLevel: { [weak self] level in
                        Task { @MainActor in self?.updateLevel(level) }
                    }
                )

                // Bail out if the user already let go while we were spinning up.
                guard case .starting = self.state else {
                    await self.teardown()
                    return
                }

                self.state = .listening
                if Settings.shared.soundEnabled { NSSound(named: "Tink")?.play() }

                self.consumeTask = Task { @MainActor in
                    do {
                        for try await chunk in chunks {
                            self.transcript = chunk.text
                        }
                    } catch {
                        self.fail(error.localizedDescription)
                    }
                }
            } catch {
                self.fail(error.localizedDescription)
            }
        }
    }

    private func endDictation(expected: RecordingKind? = nil) {
        // `.finishing` is "active", so without this a second press during processing would
        // run the whole tail again — re-reading `transcript` before the first pass cleared
        // it and pasting the same utterance twice. The window is wide: Parakeet transcribes
        // inside `finish()`, and smart cleanup adds up to 4s on top.
        guard state.isActive, state != .finishing else { return }
        guard expected == nil || recordingIntent.kind == expected else { return }
        state = .finishing
        capture.stop()
        level = 0
        releasedAt = Date()

        Task { @MainActor in
            // Drain every captured buffer into the engine before asking it to finalize,
            // or the tail of the utterance gets dropped.
            audioContinuation?.finish()
            audioContinuation = nil
            recorded = await feedTask?.value ?? []
            feedTask = nil

            await engine?.finish()
            await consumeTask?.value
            consumeTask = nil
            engine = nil

            if isComparing {
                await runComparison()
                return
            }

            let raw = transcript
            guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                state = .idle
                transcript = ""
                recordingIntent = .dictation
                return
            }

            if case .command(let selection) = recordingIntent {
                await applyCommand(raw, to: selection)
                return
            }

            let cleaned = Settings.shared.cleanupEnabled
                ? await activeFormatter.format(raw)
                : raw

            // The dictionary runs last, and runs regardless of the cleanup setting. Biasing
            // only raises the odds of the right word; this is the pass that guarantees it,
            // so it must not be something the user can accidentally switch off.
            let (output, corrections) = DictionaryStore.shared.corrector.apply(to: cleaned)
            if !corrections.isEmpty {
                Log.speech.info("dictionary · \(corrections.count, privacy: .public) correction(s) applied")
            }

            recordRun(text: output, corrections: corrections)
            TextInjector.insert(output)
            if Settings.shared.soundEnabled { NSSound(named: "Pop")?.play() }

            state = .idle
            transcript = ""
            recordingIntent = .dictation
        }
    }

    private func applyCommand(_ rawCommand: String, to selection: TextInjector.Selection) async {
        // Corrections still matter in a spoken instruction (for example a product name),
        // but punctuation cleanup does not: the model needs an imperative, not prose.
        let (command, _) = DictionaryStore.shared.corrector.apply(to: rawCommand)
        transcript = "Editing selection…"

        do {
            let replacement = try await commandProcessor.apply(command: command, to: selection.text)
            guard TextInjector.replace(selection, with: replacement) else {
                fail("The selection changed while Command Mode was processing; nothing was replaced.")
                return
            }

            recordRun(text: replacement)
            if Settings.shared.soundEnabled { NSSound(named: "Pop")?.play() }
            state = .idle
            transcript = ""
            recordingIntent = .dictation
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func cancelDictation() {
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

    private func teardown() async {
        capture.stop()
        audioContinuation?.finish()
        audioContinuation = nil
        _ = await feedTask?.value
        feedTask = nil
        await engine?.finish()
        engine = nil
        consumeTask?.cancel()
        consumeTask = nil
        state = .idle
        recordingIntent = .dictation
    }

    // MARK: - Helpers

    private func retainForComparison(_ chunk: AudioChunk) {
        guard isComparing else { return }
        recorded.append(chunk)
    }

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
            RunLog.record(
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
                RunLog.record(
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
        RunLog.record(
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

    private func fail(_ message: String) {
        Log.app.error("\(message)")
        capture.stop()
        audioContinuation?.finish()
        audioContinuation = nil
        feedTask?.cancel()
        feedTask = nil
        engine = nil
        consumeTask?.cancel()
        consumeTask = nil
        state = .error(message)
        level = 0
        recordingIntent = .dictation

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if case .error = state { state = .idle }
        }
    }
}

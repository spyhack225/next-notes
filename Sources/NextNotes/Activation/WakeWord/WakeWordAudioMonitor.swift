import AVFoundation
import AppKit
import Foundation
import FluidAudio
import Observation

/// Keeps the microphone open while Next Notes is sleeping and runs the local KWS model.
///
/// Audio arrives through `AudioCaptureHub` as `.wake`, so a meeting or dictation
/// can share the same input engine without stopping KWS. Detection is microphone-only;
/// system audio never reaches this path.
///
/// Two things this class learned the hard way.
///
/// **It must not drop its seat on the hub when the agent wakes.** It used to, and
/// because wake was usually the only subscriber that tore the shared `AVAudioEngine`
/// all the way down — on the main actor, in the first instruction after the phrase was
/// spotted — only for `beginSession` to start it again a moment later. The spotter is
/// suspended instead: the seat stays, the engine keeps running, and the buffers are
/// dropped on the floor until the session ends.
///
/// **Nothing used to notice when it stopped.** `sync()` was called from settings edits
/// and from session start/end and nowhere else, so a capture failure, a slept machine
/// or an audio route that never came back left `isListening` true with no microphone
/// behind it and no path back. A watchdog now re-checks on a timer and after the
/// machine wakes, and `status` says in plain words what is actually happening.
@MainActor
@Observable
final class WakeWordAudioMonitor {
    static let shared = WakeWordAudioMonitor()

    /// What the wake monitor is doing, in words that belong on screen.
    enum Status: Equatable {
        case listening(phrase: String)
        case busyWithAgent
        case voiceWakeOff
        case sleepListeningOff
        case modelMissing(String)
        case phraseUnusable
        case failed(String)

        var plainWords: String {
            switch self {
            case .listening(let phrase): return "Listening for “\(phrase)”"
            case .busyWithAgent: return "Paused — the agent is already listening"
            case .voiceWakeOff: return "Not listening — voice wake is off"
            case .sleepListeningOff: return "Not listening — “Listen while sleeping” is off"
            case .modelMissing: return "Not listening — the keyword model isn’t installed"
            case .phraseUnusable: return "Not listening — this wake phrase can’t be used"
            case .failed(let reason): return "Not listening — \(reason)"
            }
        }
    }

    /// The last time the phrase fired, with how it was judged. Drives the Settings test.
    struct Detection: Sendable, Equatable {
        var keyword: String
        var at: Date
        /// Seconds from the spotter firing to the island showing.
        var acknowledgedAfter: TimeInterval
        /// Lifetime misses / false accepts at the moment of this fire, from
        /// `WakeWordTelemetry`. A single fire cannot say whether the ears are
        /// reliable; the counts beside it can.
        var misses: Int = 0
        var falseAccepts: Int = 0
        var confirmation: Confirmation = .notChecked
    }

    enum Confirmation: Sendable, Equatable {
        case notChecked
        case pending
        case confirmed(WakePhraseConfirmation.Result)
        case rejected(WakePhraseConfirmation.Result)
        case unavailable

        var plainWords: String {
            switch self {
            case .notChecked: return "The wake phrase has not been checked."
            case .pending: return "Checking the wake phrase…"
            case .confirmed: return "Wake phrase confirmed."
            case .rejected: return "That wasn't the wake phrase."
            case .unavailable: return "Wake phrase confirmation is unavailable. You can still talk."
            }
        }
    }

    // Diagnostic backing is admitted only by the isolated wake self-test.
    private var recognizeForTesting: (@MainActor ([Float]) async throws -> String?)?
    private var callbackHandledForTesting: (@MainActor () -> Void)?
    private var sessionStartForTesting: Task<Void, Never>?
    // Own the ACTUAL activation/recognition Tasks until they return, including
    // cancelled native work. Closing admission cannot turn cancellation into cessation.
    private var wakeTasks: [UUID: Task<Void, Never>] = [:]
    private var terminationRequested = false

    private(set) var isListening = false
    private(set) var lastError: String?
    private(set) var status: Status = .voiceWakeOff
    private(set) var lastDetection: Detection?
    /// Legacy latch. Always zero: mic exclusivity lives on `AudioCaptureHub`, and
    /// `beginHold()` no longer stops wake (meetings need KWS alive).
    private(set) var holders = 0
    private(set) var harnessSyncSkipCount = 0

    /// How often the watchdog re-checks that the microphone seat is really there.
    static let watchdogInterval: TimeInterval = 5

    private var spotter: SherpaKeywordSpotter?
    private var lastFire: Date?
    /// Phrase *and* tuning the live spotter was built for. A settings edit reloads
    /// keywords; a no-op `sync()` does not tear the model down and spin it up again.
    /// Sensitivity is part of this: moving the slider used to change nothing at all
    /// because the reload test only compared the phrase.
    private var loadedSignature: Signature?
    /// True while the agent owns the conversation. The hub seat stays; the model idles.
    ///
    /// Mirrored into `gate`, which is what the audio thread reads. Keyword decoding
    /// must not be hopped onto the main actor to be suspended — it runs in the capture
    /// callback, off the main thread, exactly as it always has.
    private var suspended = false {
        didSet { gate.setOpen(!suspended) }
    }
    private let gate = Gate()

    /// One bool, read from the audio thread and written from the main actor.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var open = true
        private var epoch: UInt64 = 0
        private var recentSamples: [Float] = []
        static let confirmationFrames = 24_000

        func append(_ samples: [Float]) -> UInt64? {
            lock.lock()
            defer { lock.unlock() }
            guard open else { return nil }
            if samples.count >= Self.confirmationFrames {
                recentSamples = Array(samples.suffix(Self.confirmationFrames))
            } else {
                let discarded = max(0, recentSamples.count + samples.count - Self.confirmationFrames)
                if discarded > 0 { recentSamples.removeFirst(discarded) }
                recentSamples.append(contentsOf: samples)
            }
            return epoch
        }

        func candidate(_ samples: [Float], accept: ([Float]) -> String?) -> (String, [Float], UInt64)? {
            guard !samples.isEmpty, let selected = append(samples) else { return nil }
            let window = snapshot()
            guard let keyword = accept(samples) else { return nil }
            return (keyword, window, selected)
        }

        func snapshot() -> [Float] {
            lock.lock()
            defer { lock.unlock() }
            return recentSamples
        }

        var isOpen: Bool {
            lock.lock()
            defer { lock.unlock() }
            return open
        }

        func matches(_ selected: UInt64) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return open && epoch == selected
        }

        func setOpen(_ value: Bool) {
            lock.lock()
            if open != value { epoch &+= 1 }
            open = value
            if !value { recentSamples.removeAll(keepingCapacity: true) }
            lock.unlock()
        }
    }
    private var watchdog: Task<Void, Never>?
    private var systemWakeObserver: NSObjectProtocol?

    private struct Signature: Equatable {
        var phrase: String
        var tuning: WakeWordTuning
    }

    private init() {}

    /// Someone else used to need the microphone exclusively. No-op: consumers
    /// share `AudioCaptureHub`, and stopping wake here is what made meetings
    /// kill "Hey Next".
    func beginHold() {}

    func endHold() {}

    // MARK: - Lifecycle

    func sync() {
        guard !terminationRequested else { return }
        // Scripted session teardown must not load the live keyword model,
        // rewrite its keywords or subscribe to the owner's microphone.
        if SelfTest.isRunning {
            harnessSyncSkipCount += 1
            return
        }
        let settings = Settings.shared
        let configuration = WakeWordConfiguration.current
        let phrase = configuration.validatedPhrase()

        guard settings.voiceWakeEnabled else { return shutDown(.voiceWakeOff) }
        guard settings.listenWhileSleeping else { return shutDown(.sleepListeningOff) }
        guard WakeWordModelManager.isReadyToLoad else {
            return shutDown(.modelMissing(WakeWordModelManager.unavailableReason))
        }
        guard let phrase else { return shutDown(.phraseUnusable) }

        startWatchdog()

        // The agent owns the conversation: idle the model but keep the seat, so ending
        // the session costs a flag rather than a CoreAudio start.
        if ActivationController.shared.mode != .idle {
            suspended = true
            status = .busyWithAgent
            return
        }
        if suspended {
            // Resuming after a conversation. Drop whatever the encoder was holding
            // when it stopped, so a stale lattice cannot fire on the first buffer.
            spotter?.reset()
            suspended = false
        }

        let wanted = Signature(phrase: phrase, tuning: configuration.tuning)
        // A live spotter with the right keywords *and* a real seat on the hub is the
        // only state that needs no work. Checking the seat is what makes this a
        // watchdog rather than a cache.
        if isListening, loadedSignature == wanted, AudioCaptureHub.shared.isSubscribed(.wake) {
            status = .listening(phrase: phrase)
            return
        }
        if isListening { stopCapture() }
        start(configuration: configuration, phrase: phrase)
    }

    private func shutDown(_ reason: Status) {
        stopWatchdog()
        stopCapture()
        status = reason
    }

    private func start(configuration: WakeWordConfiguration, phrase: String) {
        do {
            // Always refresh keywords from the current phrase before loading. A stale
            // keywords.txt written with the old letter-fallback encoder aborts inside the
            // sherpa dylib and takes the whole process with it.
            try WakeWordModelManager.writeKeywords(configuration)
            let tuning = configuration.tuning
            guard let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            ) else {
                throw AgentError.backendUnavailable("No 16 kHz format for wake listening.")
            }
            let loaded = try WakeWordModelManager.loadSpotter(tuning: tuning)
            spotter = loaded
            suspended = false
            try AudioCaptureHub.shared.subscribe(.wake, outputFormat: format,
                onBuffer: makeAudioCallback(phrase: phrase, accept: { loaded.accept(samples: $0) }),
                onLevel: { _ in })
            isListening = true
            loadedSignature = Signature(phrase: phrase, tuning: tuning)
            lastError = nil
            status = .listening(phrase: phrase)
            Log.agent.info(
                """
                wake audio · listening for \(phrase, privacy: .public) · \
                threshold \(tuning.threshold) · \(tuning.variantDepth) variant(s) · \
                beam \(tuning.maxActivePaths)
                """
            )
        } catch {
            lastError = error.localizedDescription
            spotter = nil
            loadedSignature = nil
            isListening = false
            status = .failed(error.localizedDescription)
            AudioCaptureHub.shared.unsubscribe(.wake)
            Log.agent.error("wake audio: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func stopCapture() {
        loadedSignature = nil
        suspended = true
        guard isListening else {
            spotter = nil
            return
        }
        AudioCaptureHub.shared.unsubscribe(.wake)
        spotter = nil
        isListening = false
    }

    // MARK: - Audio

    private func makeAudioCallback(phrase: String,
        accept: @escaping @Sendable ([Float]) -> String?) -> @Sendable (AudioChunk) -> Void {
        let gate = self.gate
        return { chunk in
            let samples = AudioConversion.samples(of: chunk.buffer)
            guard let (keyword, window, epoch) = gate.candidate(samples, accept: accept) else { return }
            Task { @MainActor in
                let monitor = WakeWordAudioMonitor.shared
                defer { monitor.callbackHandledForTesting?() }
                guard gate.matches(epoch) else { return }
                monitor.didSpot(keyword, phrase: phrase, window: window)
            }
        }
    }

    fileprivate func didSpot(_ keyword: String, phrase: String, window: [Float]) {
        guard !suspended, !terminationRequested, ActivationController.shared.mode == .idle else { return }
        if let lastFire, Date().timeIntervalSince(lastFire) < 1.5 { return }
        let spottedAt = Date()
        lastFire = spottedAt
        Log.agent.info("wake audio · spotted \(keyword, privacy: .public)")
        // ACK before ASR/LLM: beginAgent paints the listening island immediately.
        // `agent.wake_to_listening_ui` has existed in LatencySpanID since §35 and had
        // no call site, which is why nobody could say how slow waking actually was.
        let trace = LatencyTrace.start(.agentWakeToListeningUI)
        suspended = true
        let startID = UUID()
        let starting = ActivationController.shared.beginAgent(source: "wake-audio",
            wakeConfirmationPending: true,
            onSessionOpened: { [weak self] sessionID in
                guard let self, !self.terminationRequested else { return }
                let recognitionID = UUID()
                self.wakeTasks[recognitionID] = Task { @MainActor in
                    defer { self.wakeTasks.removeValue(forKey: recognitionID) }
                    let confirmation = await self.confirmWindow(window, phrase: phrase)
                    // The acknowledgement precedes every await above. Cancellation
                    // and stale results do not write a successor's diagnostics/input.
                    guard !self.terminationRequested, !Task.isCancelled,
                          AgentCaptureController.shared.sessionID == sessionID else { return }
                    if self.lastDetection?.at == spottedAt {
                        self.lastDetection?.confirmation = confirmation
                    }
                    let result: WakePhraseConfirmation.Result?
                    switch confirmation {
                    case .confirmed(let checked), .rejected(let checked): result = checked
                    default: result = nil
                    }
                    await AgentCaptureController.shared.resolveWakeConfirmation(sessionID: sessionID,
                        result: result, spottedAt: spottedAt, audioSeconds: Double(window.count) / 16_000)
                }
            },
            onFinished: { [weak self] in self?.wakeTasks.removeValue(forKey: startID) })
        wakeTasks[startID] = starting
        if SelfTest.isRunning { sessionStartForTesting = starting }
        let span = trace.end(note: keyword)
        lastDetection = Detection(
            keyword: keyword,
            at: spottedAt,
            acknowledgedAfter: span.durationSeconds,
            misses: WakeWordTelemetry.shared.misses,
            falseAccepts: WakeWordTelemetry.shared.falseAccepts,
            confirmation: .pending
        )
    }

    private func confirmWindow(_ window: [Float], phrase: String,
        observation: (@MainActor (String, WakePhraseConfirmation.Result) -> Void)? = nil) async -> Confirmation {
        do {
            guard let text = try await recognizeWindow(window) else { return .unavailable }
            let checked = WakePhraseConfirmation.check(transcript: text, phrase: phrase)
            observation?(text, checked)
            return checked.accepted ? .confirmed(checked) : .rejected(checked)
        } catch { return .unavailable }
    }

    /// Corpus attribution keeps the same bounded prefix/first-hit decision as the
    /// audio callback. It never wakes the UI, starts capture, or loads an ASR model.
    static func confirmationForCorpus(wav: URL, spotter: SherpaKeywordSpotter,
        phrase: String,
        observation: (@MainActor (Int, Int, String, WakePhraseConfirmation.Result) -> Void)? = nil) async throws -> Confirmation? {
        var samples = try AudioConversion.monoSamples(fromFileAt: wav, sampleRate: 16_000)
        samples.append(contentsOf: [Float](repeating: 0, count: 16_000))
        let gate = Gate()
        var offset = 0
        while offset < samples.count {
            let end = min(offset + 3_200, samples.count)
            if let (_, window, _) = gate.candidate(Array(samples[offset..<end]),
                accept: { spotter.accept(samples: $0) }) {
                // Explicit authored-corpus diagnostic only; live wake callers have
                // no observer and retain no recognized audio text in their reports.
                let observe: (@MainActor (String, WakePhraseConfirmation.Result) -> Void)?
                if SelfTest.isRunning, CommandLine.arguments.contains("--selftest-wake-live"),
                   CommandLine.arguments.contains("--wake-corpus-only"),
                   CommandLine.arguments.contains("--wake-confirmation-details"), let observation {
                    observe = { text, checked in observation(window.count, end, text, checked) }
                } else { observe = nil }
                return await shared.confirmWindow(window, phrase: phrase, observation: observe)
            }
            offset = end
        }
        return nil
    }

    /// Resident-only: this cannot initialize/download an ASR engine on a wake hit.
    private func recognizeWindow(_ samples: [Float]) async throws -> String? {
        if SelfTest.isRunning, let recognizeForTesting {
            return try await recognizeForTesting(samples)
        }
        guard let manager = await ParakeetModels.shared.residentManager() else { return nil }
        guard let lane = await ComputeScheduler.shared.acquireCancellable(.realtimeASR) else {
            throw CancellationError()
        }
        do {
            try Task.checkCancellation()
            var decoderState = try TdtDecoderState()
            let result = try await manager.transcribe(ParakeetInput.padded(samples), decoderState: &decoderState)
            await ComputeScheduler.shared.release(lane)
            try Task.checkCancellation()
            return result.text
        } catch {
            await ComputeScheduler.shared.release(lane)
            throw error
        }
    }

    func beginTermination() {
        guard !terminationRequested else { return }
        terminationRequested = true
        stopWatchdog()
        stopCapture()
        for task in wakeTasks.values { task.cancel() }
    }

    func finishTermination() async {
        beginTermination()
        // Tasks remove themselves only AFTER their entered work actually returns.
        let entered = Array(wakeTasks.values)
        for task in entered { await task.value }
    }

    // The fixture subscribes through the SAME callback as start, never calls didSpot.
    private func installForTesting(hub: AudioCaptureHub,
        recognize: @escaping @MainActor ([Float]) async throws -> String?,
        accept: @escaping @Sendable ([Float]) -> String? = { _ in "hey will" },
        callbackHandled: @escaping @MainActor () -> Void) throws {
        precondition(SelfTest.isRunning)
        suspended = false
        lastFire = nil
        lastDetection = nil
        sessionStartForTesting = nil
        recognizeForTesting = recognize
        callbackHandledForTesting = callbackHandled
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
            channels: 1, interleaved: false)!
        try hub.subscribe(.wake, outputFormat: format,
            onBuffer: makeAudioCallback(phrase: "Hey Will", accept: accept),
            onLevel: { _ in })
    }

    private var retainedTaskCountForTesting: Int { wakeTasks.count }

    private func joinForTesting() async {
        await sessionStartForTesting?.value
        let entered = Array(wakeTasks.values)
        for task in entered { await task.value }
    }

    // MARK: - Watchdog

    /// Re-checks on a timer, and immediately after the machine wakes. Both matter: a
    /// route change that exhausts the hub's retries, or a sleep that stops the engine
    /// without a configuration-change notification, used to end listening for good.
    private func startWatchdog() {
        if systemWakeObserver == nil {
            systemWakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { _ in
                Task { @MainActor in
                    Log.agent.info("wake audio · re-checking after the machine woke")
                    WakeWordAudioMonitor.shared.sync()
                }
            }
        }
        guard watchdog == nil else { return }
        watchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.watchdogInterval))
                guard let self, !Task.isCancelled else { return }
                self.checkSeat()
            }
        }
    }

    private func stopWatchdog() {
        watchdog?.cancel()
        watchdog = nil
    }

    /// The one thing the watchdog is for: believing the hub, not the flag.
    private func checkSeat() {
        guard Settings.shared.voiceWakeEnabled, Settings.shared.listenWhileSleeping else { return }
        if ActivationController.shared.mode != .idle {
            if !suspended { sync() }
            return
        }
        if isListening, AudioCaptureHub.shared.isSubscribed(.wake), !suspended { return }
        Log.agent.info("wake audio · watchdog is restarting the listener")
        sync()
    }

    /// Whether the watchdog state machine would restart from this state. Pure, so the
    /// self-test can pin it without a microphone.
    static func watchdogShouldRestart(
        voiceWakeEnabled: Bool,
        listenWhileSleeping: Bool,
        agentIsIdle: Bool,
        believesItIsListening: Bool,
        hubHasWakeSeat: Bool,
        suspended: Bool
    ) -> Bool {
        guard voiceWakeEnabled, listenWhileSleeping else { return false }
        guard agentIsIdle else { return false }
        return !(believesItIsListening && hubHasWakeSeat && !suspended)
    }
}

/// No models, owner audio, stored choices, or fake direct didSpot calls. The PCM
/// travels through AudioCaptureHub's real wake subscription and production callback.
@MainActor
private final class WakeCallbackProbe {
    var callbackSeen = false
    var callbackWaiter: CheckedContinuation<Void, Never>?
    var entered = false
    var enteredWaiter: CheckedContinuation<Void, Never>?
    var returnWaiter: CheckedContinuation<Void, Never>?
    var mayReturn = false
    var samples: [Float] = []
    var acknowledgedBeforeRecognition = false

    func callbackHandled() {
        callbackSeen = true
        callbackWaiter?.resume()
        callbackWaiter = nil
    }
    func waitForCallback() async {
        if !callbackSeen { await withCheckedContinuation { callbackWaiter = $0 } }
    }
    func recognize(_ window: [Float]) async {
        samples = window
        if case .agentListening = IslandState.shared.kind {
            acknowledgedBeforeRecognition = ActivationController.shared.mode == .agentListening
                && AgentCaptureController.shared.isSessionActive
        }
        markEntered()
        if !mayReturn { await withCheckedContinuation { returnWaiter = $0 } }
    }
    func markEntered() {
        entered = true
        enteredWaiter?.resume()
        enteredWaiter = nil
    }
    func waitForEntry() async {
        if !entered { await withCheckedContinuation { enteredWaiter = $0 } }
    }
    func release() {
        mayReturn = true
        returnWaiter?.resume()
        returnWaiter = nil
    }
}

extension WakeWordAudioMonitor {
    static func audioCallbackRegressionFailures() async -> [String] {
        precondition(SelfTest.isRunning)
        var failures: [String] = []
        func check(_ name: String, _ value: Bool) {
            if !value { failures.append("audio callback: " + name) }
        }
        let monitor = WakeWordAudioMonitor.shared
        let capture = AgentCaptureController.shared
        let previousHandler = capture.turnHandlerForTesting
        var delivered: [String] = []
        capture.turnHandlerForTesting = { delivered.append($0) }
        defer {
            capture.turnHandlerForTesting = previousHandler
            monitor.recognizeForTesting = nil
            monitor.callbackHandledForTesting = nil
            monitor.sessionStartForTesting = nil
        }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
            channels: 1, interleaved: false)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_000)!
        pcm.frameLength = 32_000
        for index in 0..<32_000 { pcm.floatChannelData![0][index] = Float(index) / 32_000 }

        // Exact and accent positives, the ORIGINAL long near miss, unrelated
        // speech, and explicit missing/failed recognizer results use the same PCM.
        let cases: [(String, String?, Bool, Bool)] = [
            ("exact + request", "hey will open chrome", true, false),
            ("cumulative request", "hey will open chrome", true, false),
            ("casing revision", "hey will open chrome", true, false),
            ("accent", "hey we need", true, false),
            ("long near miss", "hey we need to talk about the budget", false, false),
            ("unrelated", "let me know if you still want the report", false, false),
            ("resident unavailable", nil, true, false),
            ("recognition failed", nil, true, true),
        ]
        for (name, recognized, staysActive, throwsError) in cases {
            if capture.isSessionActive { await capture.endSession() }
            ActivationController.shared.finishAgent()
            delivered.removeAll()
            let hub = AudioCaptureHub(probe: true)
            let probe = WakeCallbackProbe()
            do {
                try monitor.installForTesting(hub: hub, recognize: { window in
                    await probe.recognize(window)
                    if throwsError { throw TranscriptionError.notRunning }
                    return recognized
                }, callbackHandled: { probe.callbackHandled() })
            } catch { failures.append("audio callback: subscribe " + name); continue }
            hub.feedForTesting(pcm)
            await probe.waitForCallback()
            await monitor.sessionStartForTesting?.value
            check(name + " ACK missing", ActivationController.shared.mode == .agentListening)
            let pending = monitor.lastDetection?.confirmation == .pending
            check(name + " confirmation omitted", pending)
            // ORIGINAL has no recognition task. Avoid waiting for nonexistent work;
            // the same input still reaches actual endpoint/dispatch below and fails.
            if pending { await probe.waitForEntry() }
            check(name + " not ACK before await", probe.acknowledgedBeforeRecognition)
            check(name + " wrong/beyond-bounded PCM", probe.samples.count == 24_000
                && probe.samples.first == Float(8_000) / 32_000
                && probe.samples.last == Float(31_999) / 32_000)
            check(name + " pending latch absent", capture.wakeConfirmationPending)
            let liveText: String
            switch name {
            case "exact + request": liveText = "and play music"
            case "cumulative request": liveText = "open chrome and play music"
            case "casing revision": liveText = "Open Chrome, and play music"
            default: liveText = "open chrome"
            }
            capture.simulateSpeech(liveText)
            capture.simulateSilence()
            let premature = await capture.considerEndpoint()
            await capture.waitForActiveTurnForTesting()
            check(name + " dispatched before confirmation", !premature && delivered.isEmpty)
            probe.release()
            await monitor.joinForTesting()
            check(name + " wrong session eligibility", capture.isSessionActive == staysActive)
            if recognized == nil {
                check(name + " not exposed as unavailable", monitor.lastDetection?.confirmation == .unavailable)
            } else if staysActive {
                if case .confirmed(_)? = monitor.lastDetection?.confirmation {} else {
                    check(name + " not confirmed", false)
                }
            } else {
                if case .rejected(_)? = monitor.lastDetection?.confirmation {} else {
                    check(name + " not rejected", false)
                }
                check(name + " rejected input delivered", delivered.isEmpty)
            }
            if staysActive {
                capture.simulateSilence()
                let emitted = await capture.considerEndpoint()
                await capture.waitForActiveTurnForTesting()
                // The audio route must preserve the existing scorer's remainder.
                // The accent's ASR word boundary is a separate, unqualified contract:
                // today "hey we need" matches two words and retains "need".
                let expected: String
                if ["exact + request", "cumulative request", "casing revision"].contains(name) {
                    expected = "open chrome and play music"
                } else if name == "accent" {
                    expected = "need open chrome"
                } else {
                    expected = "open chrome"
                }
                if delivered != [expected] {
                    SelfTest.diagnostic("  WAKE_CALLBACK_OUTPUT case=\(name) expected=\(expected) actual=\(delivered) confirmation=\(String(describing: monitor.lastDetection?.confirmation))")
                }
                check(name + " request lost/duplicated", emitted && delivered == [expected])
                _ = await capture.considerEndpoint()
                await capture.waitForActiveTurnForTesting()
                check(name + " second dispatch", delivered == [expected])
                await capture.endSession()
            }
            _ = await hub.unsubscribeAndDrain(.wake)
        }

        // The actual spotter call is held on the real hub delivery worker while
        // the gate closes/reopens. A delayed old hit must not wake the new epoch.
        ActivationController.shared.finishAgent()
        let heldHub = AudioCaptureHub(probe: true)
        let heldSpotter = WakeCallbackProbe()
        let releaseSpotter = DispatchSemaphore(value: 0)
        do {
            try monitor.installForTesting(hub: heldHub, recognize: { _ in
                check("old gate epoch entered recognition", false)
                return nil
            }, accept: { _ in
                Task { @MainActor in heldSpotter.markEntered() }
                _ = releaseSpotter.wait(timeout: .now() + 3)
                return "hey will"
            }, callbackHandled: { heldSpotter.callbackHandled() })
            heldHub.feedForTesting(pcm)
            await heldSpotter.waitForEntry()
            monitor.suspended = true
            monitor.suspended = false
            releaseSpotter.signal()
            await heldSpotter.waitForCallback()
            await monitor.joinForTesting()
            check("old gate epoch acknowledged a wake", monitor.lastDetection == nil)
            check("old gate epoch opened a session", !capture.isSessionActive)
            if capture.isSessionActive { await capture.endSession() }
            _ = await heldHub.unsubscribeAndDrain(.wake)
        } catch {
            releaseSpotter.signal()
            failures.append("audio callback: held spotter subscribe")
        }

        // A stale negative cannot retract the later shortcut session.
        ActivationController.shared.finishAgent()
        let staleHub = AudioCaptureHub(probe: true)
        let stale = WakeCallbackProbe()
        do {
            try monitor.installForTesting(hub: staleHub, recognize: { window in
                await stale.recognize(window)
                return "hey we need to talk about the budget"
            }, callbackHandled: { stale.callbackHandled() })
            staleHub.feedForTesting(pcm)
            await stale.waitForCallback()
            await monitor.sessionStartForTesting?.value
            if monitor.lastDetection?.confirmation == .pending { await stale.waitForEntry() }
            let firstSession = capture.sessionID
            await capture.endSession()
            let successor = ActivationController.shared.beginAgent(source: "shortcut")
            await successor.value
            let newSession = capture.sessionID
            stale.release()
            await monitor.joinForTesting()
            check("stale rejection retracted successor", capture.isSessionActive
                && newSession != firstSession && capture.sessionID == newSession
                && ActivationController.shared.mode == .agentListening)
            await capture.endSession()
            _ = await staleHub.unsubscribeAndDrain(.wake)
        } catch { failures.append("audio callback: stale fixture subscribe") }

        // Closed gate means the real capture callback cannot dispatch a spot.
        ActivationController.shared.finishAgent()
        let closedHub = AudioCaptureHub(probe: true)
        let closed = WakeCallbackProbe()
        do {
            try monitor.installForTesting(hub: closedHub, recognize: { _ in
                check("closed gate recognized audio", false)
                return "hey will"
            }, callbackHandled: { closed.callbackHandled() })
            monitor.suspended = true
            closedHub.feedForTesting(pcm)
            _ = await closedHub.unsubscribeAndDrain(.wake)
            check("suspended callback opened session", !closed.callbackSeen && !capture.isSessionActive)
            monitor.suspended = false
            check("closed gate retained PCM", monitor.gate.snapshot().isEmpty)
        } catch { failures.append("audio callback: closed fixture subscribe") }

        // Actual entered work survives cancel until the SAME operation returns.
        // This is last: production termination closes admission permanently.
        let quitHub = AudioCaptureHub(probe: true)
        let quit = WakeCallbackProbe()
        do {
            try monitor.installForTesting(hub: quitHub, recognize: { window in
                await quit.recognize(window) // deliberately cancellation-insensitive
                return "hey will"
            }, callbackHandled: { quit.callbackHandled() })
            quitHub.feedForTesting(pcm)
            await quit.waitForCallback()
            await monitor.sessionStartForTesting?.value
            if monitor.lastDetection?.confirmation == .pending { await quit.waitForEntry() }
            monitor.beginTermination()
            check("quit dropped entered task", monitor.retainedTaskCountForTesting > 0)
            quit.release()
            await monitor.finishTermination()
            check("quit did not join actual task", monitor.retainedTaskCountForTesting == 0)
            if capture.isSessionActive { await capture.endSession() }
            _ = await quitHub.unsubscribeAndDrain(.wake)
        } catch { failures.append("audio callback: quit fixture subscribe") }
        return failures
    }
}

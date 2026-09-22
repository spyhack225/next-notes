import AVFoundation
import AppKit
import Foundation
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
    }

    private(set) var isListening = false
    private(set) var lastError: String?
    private(set) var status: Status = .voiceWakeOff
    private(set) var lastDetection: Detection?
    /// Legacy latch. Always zero: mic exclusivity lives on `AudioCaptureHub`, and
    /// `beginHold()` no longer stops wake (meetings need KWS alive).
    private(set) var holders = 0

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

        var isOpen: Bool {
            lock.lock()
            defer { lock.unlock() }
            return open
        }

        func setOpen(_ value: Bool) {
            lock.lock()
            open = value
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
            let gate = self.gate
            try AudioCaptureHub.shared.subscribe(.wake, outputFormat: format, onBuffer: { chunk in
                // Suspending here — rather than leaving the hub — is what keeps the
                // shared input engine alive across a whole wake → converse → idle
                // cycle. Everything below stays on the capture thread.
                guard gate.isOpen else { return }
                let samples = AudioConversion.samples(of: chunk.buffer)
                guard !samples.isEmpty, let keyword = loaded.accept(samples: samples) else { return }
                Task { @MainActor in
                    WakeWordAudioMonitor.shared.didSpot(keyword)
                }
            }, onLevel: { _ in })
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
        suspended = false
        guard isListening else {
            spotter = nil
            return
        }
        AudioCaptureHub.shared.unsubscribe(.wake)
        spotter = nil
        isListening = false
    }

    // MARK: - Audio

    fileprivate func didSpot(_ keyword: String) {
        guard !suspended else { return }
        if let lastFire, Date().timeIntervalSince(lastFire) < 1.5 { return }
        let spottedAt = Date()
        lastFire = spottedAt
        Log.agent.info("wake audio · spotted \(keyword, privacy: .public)")
        // ACK before ASR/LLM: beginAgent paints the listening island immediately.
        // `agent.wake_to_listening_ui` has existed in LatencySpanID since §35 and had
        // no call site, which is why nobody could say how slow waking actually was.
        let trace = LatencyTrace.start(.agentWakeToListeningUI)
        ActivationController.shared.beginAgent(source: "wake-audio")
        let span = trace.end(note: keyword)
        lastDetection = Detection(
            keyword: keyword,
            at: spottedAt,
            acknowledgedAfter: span.durationSeconds,
            misses: WakeWordTelemetry.shared.misses,
            falseAccepts: WakeWordTelemetry.shared.falseAccepts
        )
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

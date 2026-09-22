import AVFoundation
import Foundation
import Observation

/// Live-audio Test Phrase. The Settings walk used to score a typed transcript against
/// the phrase; this feeds the same sherpa spotter the sleep monitor uses, and never
/// wakes the agent.
@MainActor
@Observable
final class WakeWordCalibrator {
    static let shared = WakeWordCalibrator()

    enum Phase: Equatable {
        case idle
        case listening
        case finished
        case unavailable(String)
    }

    static let attemptTimeout: TimeInterval = 6

    private(set) var phase: Phase = .idle
    private(set) var attempts: [WakeWordAttempt] = []
    private(set) var level: Float = 0
    private(set) var prompt = ""

    var phrase: String {
        WakeWordConfiguration.normalize(Settings.shared.wakePhrase)
    }

    var isRunning: Bool {
        if case .listening = phase { return true }
        return false
    }

    private let capture = AudioCapture()
    /// The listener built from the user's actual Sensitivity. Firing here is the test.
    private var spotter: SherpaKeywordSpotter?
    /// A second listener at maximum sensitivity, with one display name per
    /// pronunciation. It never decides anything — it is there so a failed attempt can
    /// say *why*: not heard at all, or heard only once the ears were wide open.
    private var generous: SherpaKeywordSpotter?
    private var generousRules: [String: String] = [:]
    private var heardAs: String?
    private var holdingMic = false
    private var session = 0
    private var attemptStarted: Date?
    private var peakLevel: Float = 0
    private var continuation: CheckedContinuation<WakeWordAttempt, Never>?

    /// Scratch keywords file for the generous listener. Never the live one: writing the
    /// test's own keywords into the model directory is how `--selftest-wake` used to
    /// replace the user's configured phrase with the default.
    private static var diagnosticKeywordsURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("nextnotes-wake-test-keywords.txt")
    }

    private init() {}

    func start() {
        stop()
        attempts = []
        prompt = "Listening…"
        let mine = session
        Task { await run(session: mine) }
    }

    func stop() {
        session += 1
        finishAttempt(
            WakeWordAttempt(index: attempts.count + 1, transcript: "", confidence: 0, accepted: false)
        )
        stopCapture()
        releaseHold()
        if case .unavailable = phase {
            return
        }
        if phase != .finished {
            phase = .idle
            prompt = ""
        }
    }

    func commit() {
        guard WakeWordTrainer.shouldSave(attempts) else { return }
        _ = try? WakeWordModelManager.writeKeywords(WakeWordConfiguration.current)
        attempts = []
        phase = .idle
        prompt = ""
    }

    private func run(session mine: Int) async {
        guard WakeWordModelManager.isReadyToLoad else {
            phase = .unavailable(WakeWordModelManager.unavailableReason)
            prompt = ""
            return
        }

        WakeWordAudioMonitor.shared.beginHold()
        holdingMic = true
        defer {
            if mine == session {
                stopCapture()
                releaseHold()
            }
        }

        do {
            let configuration = WakeWordConfiguration.current
            try WakeWordModelManager.writeKeywords(configuration)
            let loaded = try WakeWordModelManager.loadSpotter(tuning: configuration.tuning)
            guard mine == session else { return }
            spotter = loaded
            let wideOpen = try? makeGenerousSpotter(for: configuration)
            guard mine == session else { return }
            generous = wideOpen

            guard let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            ) else {
                throw AgentError.backendUnavailable("No 16 kHz format for wake calibration.")
            }

            try capture.start(outputFormat: format, onBuffer: { [weak self] chunk in
                let samples = AudioConversion.samples(of: chunk.buffer)
                guard !samples.isEmpty else { return }
                // The generous listener runs first and on every buffer, so an attempt
                // that the configured one misses still has a reason attached to it.
                if let tag = wideOpen?.accept(samples: samples) {
                    Task { @MainActor in self?.noteHeardAs(tag) }
                }
                guard let keyword = loaded.accept(samples: samples) else { return }
                Task { @MainActor in
                    self?.didSpot(keyword)
                }
            }, onLevel: { [weak self] value in
                Task { @MainActor in
                    self?.level = value
                    if let self, value > self.peakLevel {
                        self.peakLevel = value
                    }
                }
            })
        } catch {
            phase = .unavailable(error.localizedDescription)
            prompt = ""
            return
        }

        for index in 1...WakeWordTrainer.requiredAttempts {
            guard mine == session else { return }
            spotter?.reset()
            generous?.reset()
            heardAs = nil
            peakLevel = 0
            prompt = index == 1 ? "Say it now." : "Again."
            phase = .listening
            let attempt = await listen(index: index, session: mine)
            guard mine == session else { return }
            attempts.append(attempt)
        }

        guard mine == session else { return }
        phase = .finished
        prompt = WakeWordTrainer.advice(for: attempts)
        capture.stop()
        spotter = nil
        generous = nil
    }

    /// A listener with the ears wide open and one display name per pronunciation, so a
    /// fired keyword names the variant that matched.
    private func makeGenerousSpotter(for configuration: WakeWordConfiguration) throws -> SherpaKeywordSpotter? {
        guard let phrase = configuration.validatedPhrase() else { return nil }
        let tuning = WakeWordTuning.forSensitivity(1)
        guard let built = WakeWordKeywords.diagnosticFile(for: phrase, tuning: tuning) else { return nil }
        let url = Self.diagnosticKeywordsURL
        try built.text.write(to: url, atomically: true, encoding: .utf8)
        generousRules = built.rules
        return try WakeWordModelManager.loadSpotter(keywords: url, tuning: tuning)
    }

    private func noteHeardAs(_ tag: String) {
        guard isRunning else { return }
        heardAs = generousRules[tag] ?? "as written"
    }

    private func listen(index: Int, session mine: Int) async -> WakeWordAttempt {
        attemptStarted = Date()
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(Self.attemptTimeout))
                guard mine == self.session else { return }
                self.finishAttempt(
                    WakeWordTrainer.score(
                        hit: false,
                        elapsed: Self.attemptTimeout,
                        timeout: Self.attemptTimeout,
                        peakLevel: self.peakLevel,
                        index: index,
                        heardAs: self.heardAs
                    )
                )
            }
        }
    }

    private func didSpot(_ keyword: String) {
        guard isRunning, let started = attemptStarted else { return }
        let elapsed = Date().timeIntervalSince(started)
        var attempt = WakeWordTrainer.score(
            hit: true,
            elapsed: elapsed,
            timeout: Self.attemptTimeout,
            peakLevel: peakLevel,
            index: attempts.count + 1,
            heardAs: heardAs ?? "as written"
        )
        attempt.transcript = keyword
        finishAttempt(attempt)
    }

    private func finishAttempt(_ attempt: WakeWordAttempt) {
        guard let continuation else { return }
        self.continuation = nil
        attemptStarted = nil
        continuation.resume(returning: attempt)
    }

    private func stopCapture() {
        capture.stop()
        spotter = nil
        level = 0
    }

    private func releaseHold() {
        guard holdingMic else { return }
        holdingMic = false
        WakeWordAudioMonitor.shared.endHold()
    }
}

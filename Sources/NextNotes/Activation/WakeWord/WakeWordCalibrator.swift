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
    private var spotter: SherpaKeywordSpotter?
    private var holdingMic = false
    private var session = 0
    private var attemptStarted: Date?
    private var peakLevel: Float = 0
    private var continuation: CheckedContinuation<WakeWordAttempt, Never>?

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
        try? WakeWordModelManager.writeKeywords(WakeWordConfiguration.current)
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
            try WakeWordModelManager.writeKeywords(WakeWordConfiguration.current)
            let threshold = Float(max(0.05, min(0.6, 0.45 - Settings.shared.wakeSensitivity * 0.3)))
            let loaded = try WakeWordModelManager.loadSpotter(threshold: threshold)
            guard mine == session else { return }
            spotter = loaded

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
            peakLevel = 0
            prompt = index == 1 ? "Say it now." : "Again."
            phase = .listening
            let attempt = await listen(index: index, session: mine)
            guard mine == session else { return }
            attempts.append(attempt)
        }

        guard mine == session else { return }
        phase = .finished
        prompt = WakeWordTrainer.shouldSave(attempts)
            ? "Phrase looks reliable."
            : "The phrase did not fire reliably. Try again."
        capture.stop()
        spotter = nil
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
                        index: index
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
            index: attempts.count + 1
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

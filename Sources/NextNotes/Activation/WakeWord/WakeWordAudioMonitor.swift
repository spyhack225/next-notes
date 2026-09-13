import AVFoundation
import Foundation
import Observation

/// Keeps the microphone open while Next Notes is sleeping and runs the local KWS model.
///
/// Yields the mic the moment dictation, a meeting or agent capture needs it — two
/// `AVAudioEngine`s on the input node fight. Detection is microphone-only; system audio
/// never reaches this path.
@MainActor
@Observable
final class WakeWordAudioMonitor {
    static let shared = WakeWordAudioMonitor()

    private(set) var isListening = false
    private(set) var lastError: String?

    private let capture = AudioCapture()
    private var spotter: SherpaKeywordSpotter?
    private var holders = 0
    private var lastFire: Date?

    private init() {}

    /// Someone else needs the microphone. Wake listening stops until `endHold()`.
    func beginHold() {
        holders += 1
        stopCapture()
    }

    func endHold() {
        holders = max(0, holders - 1)
        sync()
    }

    func sync() {
        let settings = Settings.shared
        let shouldListen = settings.voiceWakeEnabled
            && settings.listenWhileSleeping
            && WakeWordModelManager.isReadyToLoad
            && holders == 0
            && ActivationController.shared.mode == .idle
        if shouldListen {
            startIfNeeded()
        } else {
            stopCapture()
        }
    }

    private func startIfNeeded() {
        guard !isListening else { return }
        do {
            let threshold = Float(max(0.05, min(0.6, 0.45 - Settings.shared.wakeSensitivity * 0.3)))
            spotter = try WakeWordModelManager.loadSpotter(threshold: threshold)
            guard let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            ) else {
                throw AgentError.backendUnavailable("No 16 kHz format for wake listening.")
            }
            let loaded = try WakeWordModelManager.loadSpotter(threshold: threshold)
            spotter = loaded
            try capture.start(outputFormat: format, onBuffer: { chunk in
                let samples = AudioConversion.samples(of: chunk.buffer)
                guard !samples.isEmpty, let keyword = loaded.accept(samples: samples) else { return }
                Task { @MainActor in
                    WakeWordAudioMonitor.shared.didSpot(keyword)
                }
            }, onLevel: { _ in })
            isListening = true
            lastError = nil
            Log.agent.info("wake audio · listening for \(Settings.shared.wakePhrase, privacy: .public)")
        } catch {
            lastError = error.localizedDescription
            spotter = nil
            Log.agent.error("wake audio: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func stopCapture() {
        guard isListening else {
            spotter = nil
            return
        }
        capture.stop()
        spotter = nil
        isListening = false
    }

    fileprivate func didSpot(_ keyword: String) {
        if let lastFire, Date().timeIntervalSince(lastFire) < 1.5 { return }
        lastFire = Date()
        Log.agent.info("wake audio · spotted \(keyword, privacy: .public)")
        ActivationController.shared.beginAgent(source: "wake-audio")
    }
}

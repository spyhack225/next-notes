import AVFoundation
import Foundation
import Observation

/// Keeps the microphone open while Next Notes is sleeping and runs the local KWS model.
///
/// Audio arrives through `AudioCaptureHub` as `.wake`, so a meeting or dictation
/// can share the same input engine without stopping KWS. Detection is microphone-only;
/// system audio never reaches this path.
@MainActor
@Observable
final class WakeWordAudioMonitor {
    static let shared = WakeWordAudioMonitor()

    private(set) var isListening = false
    private(set) var lastError: String?
    /// Legacy latch. Always zero: mic exclusivity lives on `AudioCaptureHub`, and
    /// `beginHold()` no longer stops wake (meetings need KWS alive).
    private(set) var holders = 0

    private var spotter: SherpaKeywordSpotter?
    private var lastFire: Date?

    private init() {}

    /// Someone else used to need the microphone exclusively. No-op: consumers
    /// share `AudioCaptureHub`, and stopping wake here is what made meetings
    /// kill "Hey Next".
    func beginHold() {}

    func endHold() {}

    func sync() {
        let settings = Settings.shared
        let shouldListen = settings.voiceWakeEnabled
            && settings.listenWhileSleeping
            && WakeWordModelManager.isReadyToLoad
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
            try AudioCaptureHub.shared.subscribe(.wake, outputFormat: format, onBuffer: { chunk in
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
            AudioCaptureHub.shared.unsubscribe(.wake)
            Log.agent.error("wake audio: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func stopCapture() {
        guard isListening else {
            spotter = nil
            return
        }
        AudioCaptureHub.shared.unsubscribe(.wake)
        spotter = nil
        isListening = false
    }

    fileprivate func didSpot(_ keyword: String) {
        if let lastFire, Date().timeIntervalSince(lastFire) < 1.5 { return }
        lastFire = Date()
        Log.agent.info("wake audio · spotted \(keyword, privacy: .public)")
        // ACK before ASR/LLM: beginAgent paints the listening island immediately.
        ActivationController.shared.beginAgent(source: "wake-audio")
    }
}

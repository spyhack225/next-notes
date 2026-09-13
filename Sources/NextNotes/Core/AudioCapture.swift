import AVFoundation
import Foundation

/// Microphone capture facade over `AudioCaptureHub`.
///
/// Prefer `AudioCaptureHub.subscribe` for named consumers (wake / dictation /
/// meeting / agent). This type remains for one-off clients such as the wake
/// calibrator: every instance shares the hub's single input engine and gets
/// buffer **copies**, never the tap's borrowed storage.
///
/// `SystemAudioCapture` mirrors the buffer/level API for the other side of a
/// meeting; the buffer arithmetic both of them run lives in `AudioConversion`.
final class AudioCapture: @unchecked Sendable {
    private let clientID = UUID()

    /// Called on the audio thread with each converted buffer.
    /// Called on the audio thread with a 0…1 RMS level, for the HUD waveform.
    @MainActor
    func start(
        outputFormat: AVAudioFormat,
        onBuffer: @escaping @Sendable (AudioChunk) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void
    ) throws {
        try AudioCaptureHub.shared.subscribe(
            .client(clientID),
            outputFormat: outputFormat,
            onBuffer: onBuffer,
            onLevel: onLevel
        )
    }

    @MainActor
    func stop() {
        AudioCaptureHub.shared.unsubscribe(.client(clientID))
    }
}

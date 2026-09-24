import Foundation

/// The shared Parakeet minimum-input helper (D-04; M-01/M-07 call it from the
/// meeting path and never write a second copy).
///
/// FluidAudio refuses anything shorter than 0.3 s at 16 kHz
/// (`ASRConstants.minimumAudioDurationSeconds`), while the app skipped only audio
/// below 0.1 s — so 0.1–0.3 s of real speech reached the model and came back as a
/// thrown error. The band in between is zero-padded to the model's floor and
/// transcribed; below the capture floor there is nothing worth transcribing.
enum ParakeetInput {
    /// Below this there is nothing worth transcribing (0.1 s at 16 kHz). Unchanged value.
    static let minimumCapturedSamples = 1_600
    /// FluidAudio refuses anything shorter (0.3 s at 16 kHz, `ASRConstants.minimumAudioDurationSeconds`).
    static let minimumModelSamples = 4_800
    /// Zero-padded up to `minimumModelSamples`; unchanged when already long enough.
    /// Callers check `minimumCapturedSamples` themselves.
    static func padded(_ samples: [Float]) -> [Float] {
        guard samples.count < minimumModelSamples else { return samples }
        return samples + [Float](repeating: 0, count: minimumModelSamples - samples.count)
    }
}

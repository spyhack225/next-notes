import Foundation

/// The Settings "Test phrase" walk: say it 2–3 times, show confidence, save only if
/// detection is reliable. No audio leaves the device.
struct WakeWordAttempt: Sendable, Equatable {
    var index: Int
    var transcript: String
    var confidence: Double
    var accepted: Bool
}

enum WakeWordTrainer {
    static let requiredAttempts = 3
    static let minimumConfidence = 0.75

    static func score(transcript: String, configuration: WakeWordConfiguration) -> WakeWordAttempt {
        let detection = WakeWordDetector.spot(in: transcript, configuration: configuration)
        let confidence = detection?.confidence ?? 0
        return WakeWordAttempt(
            index: 0,
            transcript: transcript,
            confidence: confidence,
            accepted: confidence >= minimumConfidence
        )
    }

    /// Live-audio attempt. Sherpa's C bridge is hit/miss; the number is how cleanly
    /// it fired — faster and louder hits sit higher, a miss is zero.
    static func score(
        hit: Bool,
        elapsed: TimeInterval,
        timeout: TimeInterval,
        peakLevel: Float,
        index: Int = 0
    ) -> WakeWordAttempt {
        guard hit else {
            return WakeWordAttempt(index: index, transcript: "", confidence: 0, accepted: false)
        }
        let window = max(timeout, 0.1)
        let promptness = max(0, 1 - elapsed / window)
        let level = min(1, Double(max(0, peakLevel)) * 2)
        let confidence = min(1, 0.72 + promptness * 0.18 + level * 0.10)
        return WakeWordAttempt(
            index: index,
            transcript: "",
            confidence: confidence,
            accepted: confidence >= minimumConfidence
        )
    }

    static func shouldSave(_ attempts: [WakeWordAttempt]) -> Bool {
        let accepted = attempts.filter(\.accepted)
        return accepted.count >= 2 && attempts.count >= requiredAttempts
    }
}

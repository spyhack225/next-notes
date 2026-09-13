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

    static func shouldSave(_ attempts: [WakeWordAttempt]) -> Bool {
        let accepted = attempts.filter(\.accepted)
        return accepted.count >= 2 && attempts.count >= requiredAttempts
    }
}

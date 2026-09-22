import Foundation

/// The Settings "Test phrase" walk: say it 2–3 times, show confidence, save only if
/// detection is reliable. No audio leaves the device.
struct WakeWordAttempt: Sendable, Equatable {
    var index: Int
    var transcript: String
    var confidence: Double
    var accepted: Bool
    /// Which pronunciation matched, in words — “as written”, “dropped the h”. Nil when
    /// nothing matched even at maximum sensitivity.
    var heardAs: String?
    /// True when only the generous listener heard it. The attempt did not fire at the
    /// current Sensitivity, and saying so is the whole point of the test.
    var onlyAtMaximum = false

    /// One line for the Settings row, explaining the result rather than scoring it.
    var explanation: String {
        if accepted, let heardAs {
            return heardAs == "as written"
                ? "Heard clearly."
                : "Heard — \(heardAs)."
        }
        if onlyAtMaximum, let heardAs {
            return "Only heard at maximum sensitivity (\(heardAs)). Move Sensitivity right."
        }
        return "Not heard. Try saying it a little louder, or closer to the microphone."
    }
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
        index: Int = 0,
        heardAs: String? = nil
    ) -> WakeWordAttempt {
        guard hit else {
            // A miss the generous listener still caught is not the same failure as
            // silence, and the Settings row says so.
            return WakeWordAttempt(
                index: index,
                transcript: "",
                confidence: 0,
                accepted: false,
                heardAs: heardAs,
                onlyAtMaximum: heardAs != nil
            )
        }
        let window = max(timeout, 0.1)
        let promptness = max(0, 1 - elapsed / window)
        let level = min(1, Double(max(0, peakLevel)) * 2)
        let confidence = min(1, 0.72 + promptness * 0.18 + level * 0.10)
        return WakeWordAttempt(
            index: index,
            transcript: "",
            confidence: confidence,
            accepted: confidence >= minimumConfidence,
            heardAs: heardAs
        )
    }

    static func shouldSave(_ attempts: [WakeWordAttempt]) -> Bool {
        let accepted = attempts.filter(\.accepted)
        return accepted.count >= 2 && attempts.count >= requiredAttempts
    }

    /// What to tell someone after a run: whether it is reliable, and if not, the one
    /// thing worth changing. “It did not fire reliably” on its own leaves a person
    /// with nowhere to go.
    static func advice(for attempts: [WakeWordAttempt]) -> String {
        if shouldSave(attempts) { return "Phrase looks reliable." }
        if attempts.contains(where: \.onlyAtMaximum) {
            return "It was heard, but not at this Sensitivity. Move the slider right and test again."
        }
        if attempts.allSatisfy({ $0.heardAs == nil && !$0.accepted }) {
            return "Nothing was heard. Check the microphone, or try a longer phrase."
        }
        return "The phrase did not fire reliably. Try again."
    }
}

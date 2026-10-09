import AVFoundation
import Foundation

/// A committed-turn courtesy sound owns no answer, history or task delivery.
@MainActor
final class VoiceAcknowledgement {
    static let shared = VoiceAcknowledgement()
    struct Environment {
        var session = true
        var speaking = false
        var dictating = false
        var meeting = false
        var output = false
        var interaction = false
    }
    var environmentForTesting: (() -> Environment)?
    var clipsForTesting: [String]?
    var playedForTesting: [String] = []
    var testActive = false
    var pendingForTesting: Bool { false }
    func commit(_ turn: TurnID, text: String, interaction: Bool) { }
    func cancel() { }
    func prewarm() { }
}

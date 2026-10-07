import Foundation

/// Ordinary meeting speech must reach the notes, rather than opening a voice session.
/// These are the producer inputs from the Zoom audit reduced to nonprivate phrases.
enum MeetingWakeSelfTest {
    static func failures() -> [String] {
        let configuration = WakeWordConfiguration(
            phrase: "Hey Will", sensitivity: 1, listenWhileSleeping: true)
        let ordinary = [
            "Well", "Well that's a", "I will", "They will focus on the other",
            "They will never pay for a subscription",
            "They will start having the procedure together",
            "Those people will compete", "Hey William", "Hey Willard",
        ]
        var failures: [String] = []
        for (index, text) in ordinary.enumerated() {
            let segment = TranscriptSegment(start: 0, end: 1, text: text, source: .mic)
            if WakeWordDetector.command(in: segment, configuration: configuration) != nil {
                failures.append("meeting speech woke the agent (case \(index))")
            }
        }
        for text in ["Hey Will", "Ey Will", "Hey we need", "Hey Will, open Calendar"] {
            let segment = TranscriptSegment(start: 0, end: 1, text: text, source: .mic)
            if WakeWordDetector.command(in: segment, configuration: configuration) == nil {
                failures.append("a complete meeting wake address was lost")
            }
            let far = TranscriptSegment(start: 0, end: 1, text: text, source: .system)
            if WakeWordDetector.command(in: far, configuration: configuration) != nil {
                failures.append("the other participant authorized a wake")
            }
        }
        return failures
    }
}

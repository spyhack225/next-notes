import Foundation

/// Availability of the selected voice, independent of an answer's playback receipts.
enum AgentVoiceAvailability: Equatable, Sendable {
    case ready
    case preparing(progress: Double?)
    case needsDownload
    case failed

    var message: String? {
        switch self {
        case .ready: nil
        case .preparing: "Your voice is getting ready, so answers are in text for now."
        case .needsDownload: "Your voice isn't on this Mac yet, so answers are in text. Voice settings."
        case .failed: "Voice couldn't start, so your answer is in text. Retry in Voice settings."
        }
    }

    static func resolve(ready: Bool, preparing: Bool, progress: Double? = nil,
                        failed: Bool) -> Self {
        if failed { return .failed }
        if ready { return .ready }
        if preparing { return .preparing(progress: progress.map { max(0, min(1, $0)) }) }
        return .needsDownload
    }

    static func runSelfTest() -> [String] {
        let cases: [(Self, Self)] = [
            (resolve(ready: true, preparing: false, failed: false), .ready),
            (resolve(ready: false, preparing: true, failed: false), .preparing(progress: nil)),
            (resolve(ready: false, preparing: true, progress: 1.5, failed: false), .preparing(progress: 1)),
            (resolve(ready: false, preparing: false, failed: false), .needsDownload),
            (resolve(ready: true, preparing: false, failed: true), .failed)
        ]
        return cases.enumerated().compactMap { index, item in
            item.0 == item.1 ? nil : "voice availability: case \(index) failed"
        }
    }
}

import Foundation
import OSLog
// Logging only is substituted. Actual AV file conversion and RMS source retained.
enum Log { static let audio = Logger(subsystem: "DictationQuietCutProbe", category: "isolated") }
// Exact canonical shared silenceThreshold and frameIsSilent(rms:) copied for pure compilation.
enum ChunkedTranscriber {
    private static let silenceThreshold: Float = 0.01
    static func frameIsSilent(rms: Float) -> Bool { rms < silenceThreshold }
}

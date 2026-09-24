import Foundation

/// Plain-language dictation errors (D-04).
///
/// A raw `localizedDescription` from an engine, FluidAudio, AVFoundation or CoreML
/// is never an acceptable message on the island — on 09-23 a 0.18 s tap showed
/// "Invalid audio data provided. Must be at least 300ms of 16kHz audio." Every
/// such error is mapped here; the raw text goes to the log only.
enum DictationErrorText {
    /// Shown when the hold was stopped before it produced anything.
    static let stopped = "That recording was stopped."
    /// Shown for any other recognition failure.
    static let unrecognized = "Speech recognition didn't work that time. Try again."

    static func plain(_ error: Error) -> String {
        Log.speech.error(
            "dictation engine error (shown as plain text): \(error.localizedDescription, privacy: .public)"
        )
        if error is CancellationError { return stopped }
        return unrecognized
    }
}

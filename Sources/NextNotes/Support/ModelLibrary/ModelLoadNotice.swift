import Foundation
import Observation

/// The one place the app says "that model didn't work, so I used the built-in one".
///
/// A model file the user chose can fail to open for reasons that are entirely outside their
/// control — a GGUF built for an architecture this llama.cpp does not know, a file truncated
/// by a disk that filled up, a repo that published something that is not really a text model.
/// None of those should crash, and none of them should be silent either: the agent would
/// quietly answer with a different model than the one the Models tab says is selected.
@MainActor
@Observable
final class ModelLoadNotice {
    static let shared = ModelLoadNotice()

    /// Plain language, already written for a person. nil when there is nothing to say.
    private(set) var message: String?

    private init() {}

    func report(_ text: String) {
        message = text
        Log.llm.error("model library: \(text, privacy: .public)")
    }

    func clear() { message = nil }

    /// The sentence shown when a chosen model cannot run on this Mac.
    ///
    /// It names the provider that will actually answer rather than the built-in file:
    /// "went back to Gemma 4 E4B" was false on a Mac where Gemma had never been
    /// downloaded, and the app was answering with Apple's model the whole time.
    static func cannotRun(_ displayName: String, answeringWith: String) -> String {
        "\(displayName) can’t run on this Mac, so answers come from \(answeringWith)."
    }

    /// The sentence shown when the file has gone missing since it was chosen.
    static func fileMissing(_ displayName: String, answeringWith: String) -> String {
        "\(displayName) is no longer on this Mac, so answers come from \(answeringWith)."
    }
}

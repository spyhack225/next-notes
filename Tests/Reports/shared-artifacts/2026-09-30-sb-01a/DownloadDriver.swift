import Foundation
import OSLog

enum AppIdentity {
    static let applicationSupportDirectory = FileManager.default.temporaryDirectory
}
enum Log { static let app = Logger(subsystem: "NextNotesArtifactFixture", category: "fixture") }
enum HuggingFaceError: Error { case needsAccessKey, accessKeyRejected, gated(repoID: String) }

@main struct DownloadDriver {
    @MainActor static func main() async {
        var failures = await ModelArtifactIdentitySelfTest.downloadFailures()
        failures.append(contentsOf: ModelArtifactIdentitySelfTest.libraryFailures())
        for failure in failures { print("MODEL_ARTIFACT_WRONG: \(failure)") }
        print(failures.isEmpty ? "MODEL_ARTIFACT_OK" : "MODEL_ARTIFACT_FAILED")
        exit(failures.isEmpty ? 0 : 1)
    }
}

// Standalone library dependencies. The library's row Codable/read/write/reuse and
// downloader verification are real source. Probe/runtime have no model work to do.
enum LlamaProbeVerdict: String, Codable, Sendable { case opens, failedToOpen }
struct LlamaProbeResult: Codable, Sendable, Hashable {
    let verdict: LlamaProbeVerdict
    let detail: String?
    let llamaBuildTag: String
    let fileBytes: Int64
}
struct ModelTrialResult: Codable, Sendable, Hashable { let answeredTokens: Int? }
enum LlamaArchitectures { static let buildTag = "fixture" }
enum LlamaLoadProbe {
    static func probe(_ url: URL) async -> LlamaProbeResult {
        LlamaProbeResult(verdict: .failedToOpen, detail: nil,
                         llamaBuildTag: LlamaArchitectures.buildTag, fileBytes: 0)
    }
}
enum SelfTest { static let isRunning = true; static let allowsSavedModelSelection = false }
@MainActor enum SelfTestHarnessDefaults { static let shared = UserDefaults.standard }
actor NotesModelRuntime {
    static let shared = NotesModelRuntime()
    func useInstalledModel(_ model: InstalledLocalModel?) { }
}
enum NotesModels {
    static let spec = ModelSpec(displayName: "Fixture built-in", fileName: "absent.gguf",
                                url: URL(string: "http://127.0.0.1:1/absent")!,
                                expectedBytes: 3, expectedSHA256: nil)
    static var fileURL: URL { spec.fileURL }
    static let isDownloaded = false
}
enum ModelFitEstimator {
    static func isAuxiliaryGGUF(fileName: String, bytes: Int64,
                               comparedToLargestGGUF largestBytes: Int64?) -> Bool {
        var stem = fileName.lowercased()
        if stem.hasSuffix(".gguf") { stem.removeLast(".gguf".count) }
        let tokens = stem.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == "." })
        if tokens.contains("mmproj") { return true }
        guard tokens.contains("mtp") else { return false }
        let ceiling = largestBytes.map { max(1, $0 / 10) } ?? 1_000_000_000
        return bytes < ceiling
    }
}

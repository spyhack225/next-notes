import Foundation
import Observation

/// Preparation owns ONE candidate task. Changing a picker never starts a second
/// download beside it, and cancel retains the task until its cleanup has joined.
@MainActor @Observable final class ASRModelStore {
    private static var instance: ASRModelStore?
    static var sharedIfLoaded: ASRModelStore? { instance }
    static var shared: ASRModelStore {
        if let instance { return instance }
        let made = ASRModelStore(); instance = made; return made
    }
    @ObservationIgnored private var terminating = false
    private(set) var preparing: SpeechEngineChoice?
    private(set) var message = ""
    private(set) var failure: String?
    private(set) var readyModel: SpeechEngineChoice?
    @ObservationIgnored private var task: Task<Void, Error>?
    @ObservationIgnored private let preparationOverride: (@Sendable (SpeechEngineChoice) async throws -> Void)?
    init(preparationOverride: (@Sendable (SpeechEngineChoice) async throws -> Void)? = nil) {
        self.preparationOverride = preparationOverride
    }
    // Safe headless benchmark roots are set only by the isolated app self-test.
    static var fixtureRoot: URL?
    static var root: URL { fixtureRoot ?? ModelSpec.directory.appendingPathComponent("Speech") }
    static func directory(_ choice: SpeechEngineChoice) -> URL { root.appendingPathComponent(choice.rawValue) }
    static func isDownloaded(_ choice: SpeechEngineChoice) -> Bool {
        if choice == .apple { return true }
        if choice == .parakeet { return ParakeetModels.isDownloaded }
        let files = ASRArtifacts.files(choice)
        guard !files.isEmpty else { return false }
        return files.allSatisfy { spec in
            let size = try? directory(choice).appendingPathComponent(spec.fileName).resourceValues(forKeys: [.fileSizeKey]).fileSize
            return size.map(Int64.init) == spec.expectedBytes
        }
    }
    func beginTermination() { terminating = true; task?.cancel() }
    func finishTermination() async {
        beginTermination()
        if let task { _ = await task.result }
        await NativeASRRuntime.shared.unload()
        readyModel = nil
    }
    func prepare(_ choice: SpeechEngineChoice) {
        Task { do { try await ready(choice) } catch { /* State reports the actual failure. */ } }
    }
    func reportPreparation(_ choice: SpeechEngineChoice, phase: String) {
        guard preparing == choice, task?.isCancelled != true else { return }
        let stage = phase.contains("15s") ? "longer dictations" : phase.contains("10s") ? "ordinary dictations" : "short dictations"
        message = "Preparing \(choice.displayName) for \(stage)… First-time setup can take a few minutes."
    }
    func cancel() { message = "Stopping download…"; task?.cancel() }
    func ready(_ choice: SpeechEngineChoice) async throws {
        guard !terminating else { throw CancellationError() }
        if choice != .parakeet, await NativeASRRuntime.shared.isLoaded(choice) { readyModel = choice; return }
        if let task {
            guard preparing == choice else { throw ASRModelError.busy(preparing?.displayName ?? "speech") }
            return try await task.value
        }
        guard choice != .automatic else { throw ASRModelError.unavailable }
        readyModel = nil
        preparing = choice; failure = nil
        message = Self.isDownloaded(choice) ? "Preparing \(choice.displayName)…" : "Downloading \(choice.displayName)…"
        let owned = Task {
            if let preparationOverride {
                try await preparationOverride(choice)
                try Task.checkCancellation()
                return
            }
            if choice == .parakeet {
                _ = try await ParakeetModels.shared.manager()
            } else if choice != .apple {
                let directory = Self.directory(choice)
                let files = ASRArtifacts.files(choice)
                let reserve: Int64 = Self.fixtureRoot != nil && SelfTest.requested == "--selftest-asr-live" ? 1_073_741_824 : ModelDownloader.minimumFreeBytesAfterDownload
                let missing = files.reduce(Int64(0)) { sum, spec in
                    let size = try? directory.appendingPathComponent(spec.fileName).resourceValues(forKeys: [.fileSizeKey]).fileSize
                    return sum + (size.map(Int64.init) == spec.expectedBytes ? 0 : spec.expectedBytes)
                }
                let compileCopy: Int64 = choice == .phonon && !FileManager.default.fileExists(atPath: directory.appendingPathComponent("Phonon-2.mlmodelc").path) ? 345_000_000 : 0
                let free = ModelDownloader.availableDiskBytes(at: Self.root)
                guard free - missing - compileCopy >= reserve else {
                    throw ModelDownloadError.insufficientDisk(free: free, needed: missing + compileCopy)
                }
                let total = Double(files.reduce(Int64(0)) { $0 + $1.expectedBytes })
                var completed = 0.0
                for spec in files {
                    try Task.checkCancellation()
                    let before = completed
                    try FileManager.default.createDirectory(at: directory.appendingPathComponent(spec.fileName).deletingLastPathComponent(), withIntermediateDirectories: true)
                    try await ModelDownloader.download(spec, directory: directory, reserveBytes: reserve) { fraction in
                        Task { @MainActor in
                            guard self.preparing == choice else { return }
                            self.message = "Downloading \(choice.displayName)… \(Int(100 * (before + fraction * Double(spec.expectedBytes)) / total))%"
                        }
                    }
                    completed += Double(spec.expectedBytes)
                }
                try Task.checkCancellation()
                self.message = "Preparing \(choice.displayName)…"
                _ = try await NativeASRRuntime.shared.backend(choice, directory: directory)
                try Task.checkCancellation()
            }
        }
        task = owned
        defer { task = nil; preparing = nil }
        do { try await owned.value; readyModel = choice; message = "\(choice.displayName) is ready" }
        catch { failure = error is CancellationError ? nil : error.localizedDescription; message = ""; throw error }
    }
}

enum ASRModelError: LocalizedError {
    case busy(String), unavailable, runtime(String)
    var errorDescription: String? {
        switch self {
        case .busy(let name): "\(name) is still preparing. Wait for it to finish or cancel its download."
        case .unavailable: "Choose a speech model in Settings."
        case .runtime(let detail): "Couldn’t prepare speech recognition. \(detail)"
        }
    }
}

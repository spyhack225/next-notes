import Foundation

/// Downloads, verifies and unpacks the sherpa-onnx keyword model and its C runtime.
///
/// Presence is judged by the extracted ONNX files, not by a leftover archive. An interrupted
/// transfer cannot masquerade as ready. The 4 GB notes-model reserve is not used here —
/// these two archives are tens of megabytes.
enum WakeWordModelManager {
    static let minimumFreeBytesAfterDownload: Int64 = 256 * 1_024 * 1_024

    static var directory: URL {
        AppIdentity.applicationSupportDirectory.appendingPathComponent("WakeWord", isDirectory: true)
    }

    static var modelDirectory: URL {
        directory.appendingPathComponent(WakeWordModels.name, isDirectory: true)
    }

    static var runtimeLibraryDirectory: URL {
        directory.appendingPathComponent("runtime/lib", isDirectory: true)
    }

    static var encoderURL: URL { modelDirectory.appendingPathComponent(WakeWordModels.encoderFile) }
    static var decoderURL: URL { modelDirectory.appendingPathComponent(WakeWordModels.decoderFile) }
    static var joinerURL: URL { modelDirectory.appendingPathComponent(WakeWordModels.joinerFile) }
    static var tokensURL: URL { modelDirectory.appendingPathComponent(WakeWordModels.tokensFile) }
    static var keywordsURL: URL { modelDirectory.appendingPathComponent(WakeWordModels.keywordsFile) }
    static var testKeywordsURL: URL {
        modelDirectory.appendingPathComponent("test_wavs/keywords.txt")
    }
    static var testEnglishWavURL: URL {
        modelDirectory.appendingPathComponent("test_wavs/en_0.wav")
    }
    static var cAPILibraryURL: URL {
        runtimeLibraryDirectory.appendingPathComponent("libsherpa-onnx-c-api.dylib")
    }

    static var isDownloaded: Bool {
        WakeWordModels.requiredModelFiles.allSatisfy { file in
            let url = modelDirectory.appendingPathComponent(file)
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                return false
            }
            return size > 0
        }
    }

    static var isRuntimeDownloaded: Bool {
        FileManager.default.fileExists(atPath: cAPILibraryURL.path)
    }

    /// Model files and the C API dylib are both on disk. Does not prove the dylib loaded.
    static var isReadyToLoad: Bool { isDownloaded && isRuntimeDownloaded }

    static var unavailableReason: String {
        if !isDownloaded {
            return "The local keyword model is not downloaded. The keyboard shortcut still wakes "
                + "the agent, and the phrase is spotted in meeting transcripts."
        }
        if !isRuntimeDownloaded {
            return "The keyword model is on disk, but the sherpa-onnx runtime is missing."
        }
        return "The keyword model is on disk."
    }

    static func writeKeywords(_ configuration: WakeWordConfiguration) throws {
        try FileManager.default.createDirectory(at: modelDirectory, withIntermediateDirectories: true)
        guard let phrase = configuration.validatedPhrase() else {
            throw AgentError.permissionDenied("That wake phrase is too short or too long.")
        }
        try WakeWordKeywords.line(for: phrase).write(to: keywordsURL, atomically: true, encoding: .utf8)
    }

    /// Fetches the model archive and the C API dylib, verifies each hash, extracts, writes
    /// `keywords.txt`. Progress is 0…1 across both transfers.
    static func download(
        configuration: WakeWordConfiguration,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        if isReadyToLoad {
            try writeKeywords(configuration)
            progress(1)
            return
        }

        let needed = WakeWordModels.archive.expectedBytes + WakeWordModels.runtime.expectedBytes
        let free = ModelDownloader.availableDiskBytes()
        if free - needed < minimumFreeBytesAfterDownload {
            throw ModelDownloadError.insufficientDisk(free: free, needed: needed)
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        if !isDownloaded {
            try await unpack(
                spec: WakeWordModels.archive,
                into: directory,
                progress: { progress($0 * 0.7) }
            )
            guard isDownloaded else {
                throw ModelDownloadError.downloadFailed(WakeWordModels.archive.displayName)
            }
        } else {
            progress(0.7)
        }

        if !isRuntimeDownloaded {
            try await unpack(
                spec: WakeWordModels.runtime,
                into: directory,
                progress: { progress(0.7 + $0 * 0.3) }
            )
            try flattenRuntime()
            guard isRuntimeDownloaded else {
                throw ModelDownloadError.downloadFailed(WakeWordModels.runtime.displayName)
            }
        }

        try writeKeywords(configuration)
        progress(1)
    }

    /// Loads the spotter. Throws if the files are absent or the dylib refuses the model.
    static func loadSpotter(keywords override: URL? = nil, threshold: Float = 0.25) throws -> SherpaKeywordSpotter {
        guard isDownloaded else {
            throw AgentError.backendUnavailable(unavailableReason)
        }
        guard isRuntimeDownloaded else {
            throw AgentError.backendUnavailable(unavailableReason)
        }
        if override == nil, !FileManager.default.fileExists(atPath: keywordsURL.path) {
            try writeKeywords(
                WakeWordConfiguration(
                    phrase: WakeWordConfiguration.defaultPhrase,
                    sensitivity: 0.5,
                    listenWhileSleeping: true
                )
            )
        }
        let keywords = override ?? keywordsURL
        return try SherpaKeywordSpotter(
            dylibDirectory: runtimeLibraryDirectory,
            encoder: encoderURL,
            decoder: decoderURL,
            joiner: joinerURL,
            tokens: tokensURL,
            keywords: keywords,
            threshold: threshold
        )
    }

    private static var keywordsURLIfPresent: URL? {
        FileManager.default.fileExists(atPath: keywordsURL.path) ? keywordsURL : nil
    }

    private static func unpack(
        spec: ModelSpec,
        into destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let archiveURL = directory.appendingPathComponent(spec.fileName)
        if !FileManager.default.fileExists(atPath: archiveURL.path) {
            try await downloadFile(spec, to: archiveURL, progress: progress)
        } else {
            let hash = try ModelDownloader.sha256(of: archiveURL)
            if let expected = spec.expectedSHA256, hash != expected {
                try FileManager.default.removeItem(at: archiveURL)
                try await downloadFile(spec, to: archiveURL, progress: progress)
            } else {
                progress(1)
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xjf", archiveURL.path, "-C", destination.path]
        let err = Pipe()
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw ModelDownloadError.downloadFailed("\(spec.displayName) extract failed: \(message)")
        }
        try? FileManager.default.removeItem(at: archiveURL)
    }

    private static func downloadFile(
        _ spec: ModelSpec,
        to destination: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let delegate = ArchiveProgressDelegate(expectedBytes: spec.expectedBytes, progress: progress)
        let (temporaryURL, response) = try await URLSession.shared.download(
            from: spec.url,
            delegate: delegate
        )
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ModelDownloadError.downloadFailed(spec.displayName)
        }
        let source = delegate.stashedURL.flatMap {
            FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
        } ?? temporaryURL

        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard Int64(size) == spec.expectedBytes else {
            throw ModelDownloadError.invalidSize(spec.displayName, actual: Int64(size))
        }
        let hash = try ModelDownloader.sha256(of: source)
        if let expected = spec.expectedSHA256, hash != expected {
            throw ModelDownloadError.invalidChecksum(spec.displayName)
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: source, to: destination)
        progress(1)
    }

    private static func flattenRuntime() throws {
        let extracted = directory.appendingPathComponent(
            "sherpa-onnx-v1.13.8-osx-universal2-shared-no-tts-lib/lib",
            isDirectory: true
        )
        guard FileManager.default.fileExists(atPath: extracted.path) else { return }
        let runtime = directory.appendingPathComponent("runtime", isDirectory: true)
        if FileManager.default.fileExists(atPath: runtime.path) {
            try FileManager.default.removeItem(at: runtime)
        }
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: extracted, to: runtimeLibraryDirectory)
        try? FileManager.default.removeItem(
            at: directory.appendingPathComponent("sherpa-onnx-v1.13.8-osx-universal2-shared-no-tts-lib")
        )
    }
}

/// Same stash-the-temp-file trick as `ModelDownloader`, kept local so the 4 GB reserve
/// on that type is not applied to a 33 MB archive.
private final class ArchiveProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let expectedBytes: Int64
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var _stashedURL: URL?

    var stashedURL: URL? {
        lock.lock()
        defer { lock.unlock() }
        return _stashedURL
    }

    init(expectedBytes: Int64, progress: @escaping @Sendable (Double) -> Void) {
        self.expectedBytes = expectedBytes
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedBytes
        progress(min(0.999, Double(totalBytesWritten) / Double(max(total, 1))))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let stash = FileManager.default.temporaryDirectory
            .appendingPathComponent("nextnotes-wake-\(UUID().uuidString)")
        if (try? FileManager.default.moveItem(at: location, to: stash)) != nil {
            lock.lock()
            _stashedURL = stash
            lock.unlock()
        }
    }
}

import CryptoKit
import Foundation

/// A model file the app fetches once into Application Support.
///
/// Every local model (S1-mini, the notes model) is described by one of these so the
/// download, verification and "is it here yet" checks are written once. `expectedSHA256`
/// is optional only for models whose hash hasn't been pinned yet: the downloader then
/// verifies size, logs the hash it computed, and the next release pins it.
struct ModelSpec: Sendable {
    /// User-facing name, used in progress messages.
    let displayName: String
    let fileName: String
    let url: URL
    let expectedBytes: Int64
    let expectedSHA256: String?

    static var directory: URL {
        AppIdentity.applicationSupportDirectory.appendingPathComponent("Models", isDirectory: true)
    }

    var fileURL: URL { Self.directory.appendingPathComponent(fileName) }

    /// Presence is judged by size, not existence: an interrupted transfer that was moved
    /// into place would otherwise masquerade as a ready model.
    var isDownloaded: Bool {
        guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey]) else { return false }
        return Int64(values.fileSize ?? 0) == expectedBytes
    }

    /// Size in the "462 MiB" / "2.6 GiB" form the UI shows next to download buttons.
    var displaySize: String {
        ByteCountFormatter.string(fromByteCount: expectedBytes, countStyle: .binary)
    }
}

enum ModelDownloader {
    /// Refuses to start a download that would leave the disk below this. Models are
    /// gigabytes, and a full disk takes the whole machine down, not just the app.
    static let minimumFreeBytesAfterDownload: Int64 = 4 * 1_024 * 1_024 * 1_024

    /// Downloads to URLSession's temporary location, verifies size and SHA-256, then moves
    /// atomically into place. A cancelled or corrupt transfer can never masquerade as ready.
    ///
    /// `progress` is called on an arbitrary thread with a 0…1 fraction.
    static func download(
        _ spec: ModelSpec,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        if spec.isDownloaded { return }

        let free = availableDiskBytes()
        if free - spec.expectedBytes < minimumFreeBytesAfterDownload {
            throw ModelDownloadError.insufficientDisk(free: free, needed: spec.expectedBytes)
        }

        let delegate = ProgressDelegate(expectedBytes: spec.expectedBytes, progress: progress)
        let (temporaryURL, response) = try await URLSession.shared.download(
            from: spec.url,
            delegate: delegate
        )
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ModelDownloadError.downloadFailed(spec.displayName)
        }

        // The delegate stashes the file in case URLSession removes the original once
        // `didFinishDownloadingTo` returns; prefer whichever still exists.
        let source = delegate.stashedURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            ?? temporaryURL

        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard Int64(size) == spec.expectedBytes else {
            throw ModelDownloadError.invalidSize(spec.displayName, actual: Int64(size))
        }

        let hash = try sha256(of: source)
        if let expected = spec.expectedSHA256 {
            guard hash == expected else {
                throw ModelDownloadError.invalidChecksum(spec.displayName)
            }
        } else {
            Log.app.notice("\(spec.fileName, privacy: .public) has no pinned hash; computed sha256 \(hash, privacy: .public)")
        }

        try FileManager.default.createDirectory(at: ModelSpec.directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: spec.fileURL.path) {
            try FileManager.default.removeItem(at: spec.fileURL)
        }
        try FileManager.default.moveItem(at: source, to: spec.fileURL)
        progress(1)
    }

    static func availableDiskBytes() -> Int64 {
        let values = try? ModelSpec.directory.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? .max
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 4 * 1_024 * 1_024), !data.isEmpty {
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Reports byte progress and preserves the finished file.
    private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
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
                .appendingPathComponent("nextnotes-model-\(UUID().uuidString)")
            if (try? FileManager.default.moveItem(at: location, to: stash)) != nil {
                lock.lock()
                _stashedURL = stash
                lock.unlock()
            }
        }
    }
}

enum ModelDownloadError: LocalizedError {
    case downloadFailed(String)
    case invalidSize(String, actual: Int64)
    case invalidChecksum(String)
    case insufficientDisk(free: Int64, needed: Int64)

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let name):
            "\(name) download failed. Check the network and try again."
        case .invalidSize(let name, let actual):
            "\(name) download was incomplete (\(actual) bytes)."
        case .invalidChecksum(let name):
            "\(name) download failed its integrity check."
        case .insufficientDisk(let free, let needed):
            "Not enough free disk space: \(ByteCountFormatter.string(fromByteCount: free, countStyle: .file)) free, "
                + "\(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) needed plus a 4 GB reserve."
        }
    }
}

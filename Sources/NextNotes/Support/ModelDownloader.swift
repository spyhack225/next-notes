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
    case diskFilledUp(String)

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
        case .diskFilledUp(let name):
            "This Mac ran out of space while downloading \(name). What arrived is kept — "
                + "free some space and press Download again to carry on."
        }
    }
}

// MARK: - Resumable downloads

extension ModelDownloader {
    /// A file fetched from somewhere other than the app's own pinned list.
    ///
    /// The pinned `ModelSpec` path above cannot serve this: its URL, size and hash are
    /// compile-time constants, and a model the user chose from Hugging Face has none of
    /// those until the Hub is asked. `expectedSHA256` here comes from the Hub's LFS record,
    /// which is a SHA-256 of the file's contents — the same guarantee, discovered at runtime.
    struct RemoteFile: Sendable {
        let url: URL
        let destination: URL
        let expectedBytes: Int64
        let expectedSHA256: String?
        /// Sent as `Authorization: Bearer …` when present.
        let bearerToken: String?

        /// The user was told this model is a poor fit for the disk and said "download anyway".
        ///
        /// The app promises on screen that nothing stops them. A precautionary refusal after
        /// that promise would make it a lie, so the reserve becomes a warning here and the
        /// only remaining error is the honest one: the volume actually filled up mid-write.
        var allowLowDiskSpace: Bool = false

        /// Where a partial transfer accumulates. Beside the destination so it lands on the
        /// same volume, which is what makes the final move atomic.
        var partialURL: URL {
            destination.appendingPathExtension("part")
        }

        /// Bytes already on disk from an earlier attempt.
        var resumeOffset: Int64 { ModelDownloader.fileSize(at: partialURL) }
    }

    /// The size of a file right now, read through `FileManager`.
    ///
    /// **Not** `URL.resourceValues(forKeys:)`. A `URL` caches the resource values it has
    /// been asked for, and a `RemoteFile` holds the same URL value across a whole download —
    /// so a size read before the transfer was still being answered from that cache
    /// afterwards, and `download` skipped a resumed transfer entirely because it believed
    /// the finished file was already in place. Returns 0 when the file is not there.
    static func fileSize(at url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Progress for a transfer that may have started in a previous launch.
    struct DownloadProgress: Sendable {
        let completedBytes: Int64
        let totalBytes: Int64
        var fraction: Double {
            totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : 0
        }
    }

    /// Downloads `file`, resuming from whatever is already in its `.part` sibling.
    ///
    /// Resume is a real HTTP range request rather than `URLSession`'s opaque resume data,
    /// because that data lives in memory and is lost the moment the app quits — and a
    /// four-gigabyte model on a domestic connection is exactly the download a person closes
    /// the laptop in the middle of. The partial file survives quitting; the next attempt
    /// asks for `bytes=<what we have>-` and appends.
    ///
    /// Cancellation is cooperative: cancelling the task stops the transfer and leaves the
    /// partial file in place, so "cancel" and "pause" are the same operation.
    static func download(
        _ file: RemoteFile,
        progress: @escaping @Sendable (DownloadProgress) -> Void = { _ in }
    ) async throws {
        if file.expectedBytes > 0, fileSize(at: file.destination) == file.expectedBytes {
            progress(DownloadProgress(completedBytes: file.expectedBytes, totalBytes: file.expectedBytes))
            return
        }

        try FileManager.default.createDirectory(
            at: file.destination.deletingLastPathComponent(), withIntermediateDirectories: true)

        var offset = file.resumeOffset
        if offset > file.expectedBytes, file.expectedBytes > 0 {
            // The remote file changed under us, or an earlier run appended twice.
            try? FileManager.default.removeItem(at: file.partialURL)
            offset = 0
        }

        let stillNeeded = max(0, file.expectedBytes - offset)
        let free = availableDiskBytes()
        if file.expectedBytes > 0, free - stillNeeded < minimumFreeBytesAfterDownload {
            guard file.allowLowDiskSpace else {
                throw ModelDownloadError.insufficientDisk(free: free, needed: stillNeeded)
            }
            let name = file.destination.lastPathComponent
            Log.app.notice(
                "\(name, privacy: .public): the user was warned about free space and chose to continue; \(free, privacy: .public) bytes free")
        }

        if offset < file.expectedBytes || file.expectedBytes == 0 {
            _ = try await fetch(file, from: offset, progress: progress)
        }

        let size = fileSize(at: file.partialURL)
        if file.expectedBytes > 0, size != file.expectedBytes {
            throw ModelDownloadError.invalidSize(file.destination.lastPathComponent, actual: size)
        }

        if let expected = file.expectedSHA256?.lowercased(), !expected.isEmpty {
            let hash = try sha256(of: file.partialURL)
            guard hash == expected else {
                // A corrupt file must not be resumable — the next attempt would append to
                // bytes that are already wrong and fail the same way forever.
                try? FileManager.default.removeItem(at: file.partialURL)
                throw ModelDownloadError.invalidChecksum(file.destination.lastPathComponent)
            }
        }

        if FileManager.default.fileExists(atPath: file.destination.path) {
            try FileManager.default.removeItem(at: file.destination)
        }
        try FileManager.default.moveItem(at: file.partialURL, to: file.destination)
        progress(DownloadProgress(
            completedBytes: file.expectedBytes > 0 ? file.expectedBytes : size,
            totalBytes: file.expectedBytes > 0 ? file.expectedBytes : size))
    }

    /// One range request, written onto the end of the partial file *as it arrives*.
    /// Returns the size of the partial file afterwards.
    ///
    /// A data task rather than a download task, and this is the whole point of the resume
    /// feature: a `URLSessionDownloadTask` hands its body over in one piece at the very end,
    /// so a transfer that is cancelled — or that ends because the person closed the laptop —
    /// leaves nothing on disk and "resume" silently means "start again". A data task reports
    /// every chunk, and each chunk is written through to the `.part` file immediately, so the
    /// offset on disk only ever moves forward.
    private static func fetch(
        _ file: RemoteFile,
        from offset: Int64,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> Int64 {
        var request = URLRequest(url: file.url)
        request.timeoutInterval = 60
        if let token = file.bearerToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }

        let sink = PartialFileSink(file: file, alreadyOnDisk: offset, progress: progress)
        let configuration = URLSessionConfiguration.default
        // 60 seconds of silence is a dead connection; a multi-gigabyte model on a domestic
        // line legitimately takes hours, so the overall transfer is not put on a clock.
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        let session = URLSession(configuration: configuration, delegate: sink, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let task = session.dataTask(with: request)
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                sink.attach(continuation)
                task.resume()
            }
        } onCancel: {
            // Stopping keeps everything written so far: "cancel" and "pause" are one button.
            task.cancel()
        }

        let written = fileSize(at: file.partialURL)
        progress(DownloadProgress(
            completedBytes: written,
            totalBytes: file.expectedBytes > 0 ? file.expectedBytes : written))
        return written
    }

    /// Removes a partial transfer so the next attempt starts clean.
    static func discardPartial(_ file: RemoteFile) {
        try? FileManager.default.removeItem(at: file.partialURL)
    }

    /// Writes a response body onto the end of the partial file chunk by chunk, and turns the
    /// Hub's refusals into the errors the UI knows how to ask about.
    private final class PartialFileSink: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let file: RemoteFile
        private let alreadyOnDisk: Int64
        private let progress: @Sendable (DownloadProgress) -> Void
        private var name: String { file.destination.lastPathComponent }

        private let lock = NSLock()
        private var handle: FileHandle?
        /// Bytes that were on disk when this leg's writing began — 0 when the server ignored
        /// our `Range` header and started the file over.
        private var baseOffset: Int64 = 0
        private var writtenThisLeg: Int64 = 0
        private var failure: Error?
        /// How the transfer ended, kept for a continuation that has not attached yet.
        private var completionError: Error?
        private var continuation: CheckedContinuation<Void, Error>?
        private var finished = false

        init(
            file: RemoteFile,
            alreadyOnDisk: Int64,
            progress: @escaping @Sendable (DownloadProgress) -> Void
        ) {
            self.file = file
            self.alreadyOnDisk = alreadyOnDisk
            self.progress = progress
        }

        /// Called before the task is resumed. The already-finished branch is not dead code:
        /// a task cancelled in the instant before `resume()` can complete first, and a
        /// continuation that is never resumed hangs the download forever.
        func attach(_ continuation: CheckedContinuation<Void, Error>) {
            lock.lock()
            if finished {
                let outcome = failure ?? completionError
                lock.unlock()
                if let outcome {
                    continuation.resume(throwing: outcome)
                } else {
                    continuation.resume()
                }
                return
            }
            self.continuation = continuation
            lock.unlock()
        }

        // MARK: Delegate

        func urlSession(
            _ session: URLSession,
            dataTask: URLSessionDataTask,
            didReceive response: URLResponse,
            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
        ) {
            guard let http = response as? HTTPURLResponse else {
                record(ModelDownloadError.downloadFailed(name))
                completionHandler(.cancel)
                return
            }
            switch http.statusCode {
            case 401:
                record(file.bearerToken == nil
                       ? HuggingFaceError.needsAccessKey : HuggingFaceError.accessKeyRejected)
                completionHandler(.cancel)
                return
            case 403:
                record(HuggingFaceError.gated(repoID: file.url.path))
                completionHandler(.cancel)
                return
            case 416:
                // The server says our offset is past the end. Start again rather than loop.
                try? FileManager.default.removeItem(at: file.partialURL)
                record(ModelDownloadError.invalidSize(name, actual: alreadyOnDisk))
                completionHandler(.cancel)
                return
            case 200..<300:
                break
            default:
                record(ModelDownloadError.downloadFailed(name))
                completionHandler(.cancel)
                return
            }

            // A server that ignores Range answers 200 with the whole file. Appending then
            // would duplicate everything we already have, so the partial file starts over.
            let appending = alreadyOnDisk > 0 && http.statusCode == 206
            do {
                try openPartialFile(appending: appending)
            } catch {
                record(error)
                completionHandler(.cancel)
                return
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            lock.lock()
            guard !finished, let handle else {
                lock.unlock()
                return
            }
            do {
                try handle.write(contentsOf: data)
            } catch {
                if failure == nil { failure = Self.writeFailure(error, name: name) }
                lock.unlock()
                dataTask.cancel()
                return
            }
            writtenThisLeg += Int64(data.count)
            let completed = baseOffset + writtenThisLeg
            lock.unlock()
            progress(DownloadProgress(
                completedBytes: completed,
                totalBytes: max(file.expectedBytes, completed)))
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            // A cancelled transfer is a person pressing Stop, not a fault: the caller's
            // `catch is CancellationError` has to see it as one.
            var outcome = error
            if let urlError = error as? URLError, urlError.code == .cancelled {
                outcome = CancellationError()
            }
            finish(outcome)
        }

        // MARK: Bookkeeping

        private func openPartialFile(appending: Bool) throws {
            let manager = FileManager.default
            try manager.createDirectory(
                at: file.partialURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !appending {
                try? manager.removeItem(at: file.partialURL)
            }
            if !manager.fileExists(atPath: file.partialURL.path) {
                manager.createFile(atPath: file.partialURL.path, contents: nil)
            }
            let opened = try FileHandle(forWritingTo: file.partialURL)
            if appending {
                try opened.seekToEnd()
            } else {
                try opened.truncate(atOffset: 0)
            }
            lock.lock()
            handle = opened
            baseOffset = appending ? alreadyOnDisk : 0
            writtenThisLeg = 0
            lock.unlock()
        }

        private func record(_ error: Error) {
            lock.lock()
            if failure == nil { failure = error }
            lock.unlock()
        }

        private func finish(_ error: Error?) {
            lock.lock()
            if finished {
                lock.unlock()
                return
            }
            finished = true
            try? handle?.close()
            handle = nil
            let pending = continuation
            continuation = nil
            let outcome = failure ?? error
            completionError = outcome
            lock.unlock()
            if let outcome {
                pending?.resume(throwing: outcome)
            } else {
                pending?.resume()
            }
        }

        /// A volume that genuinely filled up is the one disk error left, and it is the one
        /// the person can act on.
        private static func writeFailure(_ error: Error, name: String) -> Error {
            let cocoa = error as NSError
            let outOfSpace = (cocoa.domain == NSCocoaErrorDomain && cocoa.code == NSFileWriteOutOfSpaceError)
                || (cocoa.domain == NSPOSIXErrorDomain && cocoa.code == Int(ENOSPC))
            return outOfSpace ? ModelDownloadError.diskFilledUp(name) : error
        }
    }
}

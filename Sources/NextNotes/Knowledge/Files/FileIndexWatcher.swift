import CoreServices
import Foundation

/// FSEvents over the indexed folders, coalesced.
///
/// FSEvents rather than polling: a Downloads folder changes every time anything is saved, and
/// re-walking three folders on a timer is minutes of disk per hour for nothing. Without
/// `kFSEventStreamCreateFlagFileEvents` the stream reports the *directory* something happened
/// in, which is exactly the unit the incremental re-scan works in — one shallow listing of
/// that directory, not a re-crawl of the tree.
///
/// A two-second latency is deliberate: unzipping an archive fires hundreds of events, and a
/// re-scan per event would be the thing that makes the machine feel slow.
final class FileIndexWatcher: @unchecked Sendable {
    static let latency: CFTimeInterval = 2.0

    private let queue = DispatchQueue(label: "ai.pivotstudio.nextnotes.file-index-events", qos: .utility)
    private let onChange: @Sendable ([String]) -> Void
    private var stream: FSEventStreamRef?

    init(onChange: @escaping @Sendable ([String]) -> Void) {
        self.onChange = onChange
    }

    deinit {
        teardown()
    }

    /// Watches exactly `paths`, replacing whatever was being watched before.
    func watch(_ paths: [URL]) {
        teardown()
        guard !paths.isEmpty else { return }
        let roots = paths.map { FileIndexStore.canonical($0).path } as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagIgnoreSelf
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, count, rawPaths, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<FileIndexWatcher>.fromOpaque(info).takeUnretainedValue()
                let paths = unsafeBitCast(rawPaths, to: NSArray.self).compactMap { $0 as? String }
                guard !paths.isEmpty, count > 0 else { return }
                watcher.onChange(paths)
            },
            &context,
            roots,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            Self.latency,
            flags
        ) else {
            Log.app.error("file index · could not start watching \(paths.count, privacy: .public) folders")
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            Log.app.error("file index · FSEventStreamStart refused")
            return
        }
        self.stream = stream
    }

    func stop() {
        teardown()
    }

    private func teardown() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }
}

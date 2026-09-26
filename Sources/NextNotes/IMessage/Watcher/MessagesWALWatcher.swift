import Foundation

/// One started watch, and the one way to stop it.
///
/// A protocol rather than a bare `DispatchSource` because the self-test replaces the whole
/// signal with a call it makes itself, and because the cancel-on-deinit behaviour below is
/// the part that is easy to get wrong: a `DispatchSourceFileSystemObject` holds an
/// open descriptor, and a descriptor that is never closed survives the feature being
/// switched off.
protocol MessagesWatchToken: AnyObject, Sendable {
    /// Stops the watch and releases whatever it holds. Idempotent.
    func cancel()
}

/// The watcher's entire dependency on the filesystem: start watching a path, and hand back
/// the handle that stops it.
///
/// **This is the seam that makes `--selftest-imessage-watch` deterministic.** A real
/// `chat.db-wal` produces events on a schedule nobody controls, and a self-test that waits
/// for one is a flaky self-test that fails on a busy machine and passes on a quiet one. With
/// the source injected, the test fires an event by calling a closure and knows exactly when
/// the pass runs, and every case here is fixture-copy arithmetic rather than a wait for
/// SQLite. The production path is one line of this file, and the case that checks the
/// watcher arms and disarms is the only thing standing between the two.
///
/// The two callbacks are separate because they mean different things: `onEvent` is "look
/// again", which is a debounce away from a query, and `onLost` is "the file you were
/// watching is gone", which is a re-arm and nothing else.
struct MessagesFileEventSource: Sendable {
    let start: @Sendable (_ path: String,
                          _ onEvent: @escaping @Sendable () -> Void,
                          _ onLost: @escaping @Sendable () -> Void) -> MessagesWatchToken?

    /// `DispatchSourceFileSystemObject` on the file itself.
    ///
    /// **And not FSEvents**, which is the decision the roadmap already made and the one
    /// worth restating because it is the opposite of the precedent in
    /// `Knowledge/Files/FileIndexWatcher.swift`. FSEvents is the right unit for a Downloads
    /// folder, where the unit of work is "re-list this directory" and the stream's 2 s
    /// coalescing latency is the feature. Here the unit of work is *these three rows landed
    /// in one file*, and an FSEvents stream over `~/Library/Messages/` fires for every file
    /// Messages and its daemons touch — handshakes, cache files, the `Attachments/`
    /// subdirectory, a sync agent's temporary copy — none of which is a message. A vnode
    /// source on three named files is the narrower and cheaper signal, and the debounce and
    /// the watermark that make it usable are written here rather than inherited, because
    /// that file has neither: its incremental logic lives in its caller.
    ///
    /// The lifecycle discipline *is* copied from it, and it is worth copying: a dedicated
    /// `DispatchQueue` rather than the main one, teardown in `deinit`, an explicit `stop()`,
    /// and a log line when the stream refuses to start — a watcher that silently watches
    /// nothing is indistinguishable from a quiet conversation.
    static let dispatchFileSystemObject = MessagesFileEventSource { path, onEvent, onLost in
        // `O_EVTONLY`, as `DictionaryStore` and `OutputProfileStore` both do it: a
        // descriptor that reports metadata changes without a read permission and without
        // blocking on a FIFO this file is not.
        let descriptor = open(path, O_EVTONLY)
        guard descriptor >= 0 else {
            Log.app.error("imessage · could not open \(path, privacy: .public) to watch it (errno \(errno))")
            return nil
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .delete, .rename, .revoke],
            queue: DispatchQueue(label: MessagesWALWatcher.queueLabel, qos: .utility)
        )
        source.setEventHandler {
            onEvent()
            let mask = source.data
            if mask.contains(.delete) || mask.contains(.rename) || mask.contains(.revoke) {
                // The inode is gone. SQLite replaces `chat.db-wal` on a clean close and
                // between macOS versions, so this is a normal event rather than an error —
                // and it is the one event the watcher must not simply absorb, because a
                // descriptor on a deleted file reports nothing ever again.
                onLost()
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return DispatchSourceToken(source)
    }
}

/// A started `DispatchSourceFileSystemObject`, and the reason its own deinit is enough.
///
/// `DispatchSource` cancels on dealloc, which fires the cancel handler and closes the
/// descriptor — so the only thing to add is idempotence, since `stop()` and `deinit` can
/// both reach it.
private final class DispatchSourceToken: MessagesWatchToken, @unchecked Sendable {
    private let source: DispatchSourceFileSystemObject
    private let lock = NSLock()
    private var cancelled = false

    init(_ source: DispatchSourceFileSystemObject) {
        self.source = source
    }

    deinit { cancel() }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return }
        cancelled = true
        source.cancel()
    }
}

/// The vnode watches over one `chat.db`, and their teardown.
///
/// **Three files, and the `-wal` is the one that matters.** SQLite in WAL mode appends every
/// committed transaction to `chat.db-wal` and only folds it into `chat.db` at a checkpoint,
/// so the `-wal` is where a new message row physically lands first, and a watcher on
/// `chat.db` alone can sit through an entire conversation between checkpoints. The other two
/// are watched because each can be the *only* signal for a change: a checkpoint truncates
/// and rewrites `chat.db`, and a reader attaching or detaching rewrites `chat.db-shm`. Three
/// vnode sources is nothing; a missed message is the whole feature failing.
final class MessagesWALWatcher: @unchecked Sendable {
    /// Its own queue, never the main one: an event handler that runs on the main thread is
    /// a handler that can be late for a frame, and the debounce it starts is work with no
    /// business on the UI thread.
    static let queueLabel = "ai.pivotstudio.nextnotes.imessage-wal-events"

    private let source: MessagesFileEventSource
    private let onEvent: @Sendable () -> Void
    private let onLost: @Sendable (String) -> Void
    private let lock = NSLock()
    private var tokens: [String: MessagesWatchToken] = [:]

    init(source: MessagesFileEventSource,
         onEvent: @escaping @Sendable () -> Void,
         onLost: @escaping @Sendable (String) -> Void) {
        self.source = source
        self.onEvent = onEvent
        self.onLost = onLost
    }

    deinit { stop() }

    /// The three paths for a canonical `chat.db` path, in the order they are armed.
    ///
    /// Built by appending to the database path rather than by going back through the URL:
    /// `realpath(3)` has already resolved the database, and re-deriving its neighbours from
    /// an un-canonical URL is how a prefix test starts matching nothing.
    static func watchedPaths(forDatabase path: String) -> [String] {
        ["\(path)-wal", "\(path)-shm", path]
    }

    /// Arms every path that exists, replacing whatever was armed before.
    ///
    /// A path that is not there is **skipped, not an error**: `-wal` and `-shm` do not
    /// exist until SQLite has something to write, and a `chat.db` on a Mac where Messages
    /// has never run has neither. The re-arm on `onLost` is what picks them up when they
    /// appear, and the first message after that is caught by the watermark pass the re-arm
    /// triggers.
    func watch(_ paths: [String]) {
        stop()
        lock.lock()
        defer { lock.unlock() }
        for path in paths where FileManager.default.fileExists(atPath: path) {
            if let token = source.start(path, { [onEvent] in onEvent() }, { [onLost] in onLost(path) }) {
                tokens[path] = token
            } else {
                Log.app.error("imessage · the watch on \(path, privacy: .public) refused to start")
            }
        }
    }

    /// Disarms everything. The feature being switched off reaches this, and so does
    /// `deinit`, so a watcher that is only let go closes its descriptors either way.
    func stop() {
        lock.lock()
        let armed = tokens
        tokens.removeAll()
        lock.unlock()
        for token in armed.values { token.cancel() }
    }

    /// Which paths are armed right now. A self-test assertion, and the answer to "is the
    /// watcher actually watching anything" that a person debugging a silent feature wants.
    var armedPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return tokens.keys.sorted()
    }
}

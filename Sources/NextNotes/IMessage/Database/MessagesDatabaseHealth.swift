import Foundation

/// Whether this process can read a row out of Apple Messages' database — which is the
/// **only** way to know whether Full Disk Access is granted.
///
/// **There is no query API for this grant, and there is not going to be one.** The
/// database is mode `-rw-r--r--`, world-readable, and still answers
/// `authorization denied` without the grant; the only other way to ask is to read the
/// bytes, so the read *is* the answer. That makes this file the same kind of thing as
/// `Permissions.hasHeardSystemAudio` — evidence rather than a bit — and it inherits both
/// of that property's rules: nothing may conclude "granted" without a row having come
/// back, and nothing may conclude "not granted" from silence either, because a file that
/// is not there and a file this process may not open are the same shape of answer.
///
/// **It is a probe, not a predicate.** There is deliberately no `hasFullDiskAccess` in this
/// codebase: a function by that name invites a caller to treat it as cheap and constant,
/// and it is neither. It opens a file Messages owns and runs a statement against it, so it
/// is named for what it costs, it returns a state with a reason attached, and it is
/// cached (see `cacheInterval`).
///
/// Read-only, twice over, and by the same code path as everything else: it goes through
/// `MessagesDatabase`, so it inherits `SQLITE_OPEN_READONLY` **and** `PRAGMA query_only`,
/// plus the `realpath(3)` resolution. It is never given a second way to open the file.
enum MessagesDatabaseHealth {
    /// What the probe found. A real state, so a caller can say which of "no database",
    /// "not granted" and "not a Messages database" it is looking at.
    ///
    /// There is no `.checking`: the probe never returns before it has a read, and a
    /// half-answer a row can draw is a half-answer a caller can draw too.
    enum State: Equatable, Sendable, CustomStringConvertible {
        /// The database opened **and a row came back out of it.** This is the grant.
        case readable
        /// Anything else, with the reason SQLite or the file system gave. A path that does
        /// not exist is here too, and deliberately so: "this Mac has never had Messages" is
        /// an answer, and the honest response to it is a sentence rather than a crash in a
        /// `Settings` row.
        case unreadable(reason: String)

        /// The only way to get a ✓, and it is an equality on the case rather than a flag
        /// anybody can set.
        var isReadable: Bool { self == .readable }

        /// Why it could not be read, for a log line or the `--imessage-self-flow` report.
        /// Plain enough to put in front of a person, complete enough to be worth a log.
        var reason: String? {
            switch self {
            case .readable: nil
            case .unreadable(let reason): reason
            }
        }

        var description: String {
            switch self {
            case .readable: "readable"
            case .unreadable(let reason): "unreadable — \(reason)"
            }
        }
    }

    /// Whether Next Notes can ask for this grant the way it asks for the microphone or the
    /// calendar. **False, and permanently** — Full Disk Access is switched on in System
    /// Settings and cannot be provoked from inside a process, exactly like Accessibility.
    ///
    /// It is a `let` rather than a computed answer so that the Permissions row, the Settings
    /// section and `--selftest-imessage-db` all read one value and cannot disagree about
    /// whether there is a button that can do something.
    static let canRequest: Bool = false

    /// How long one probe answer is reused before the file is read again.
    ///
    /// **Thirty seconds**, and the number is a judgement between two things pulling apart.
    /// The grant can be flipped at any moment from System Settings while this app is
    /// running, and a row that is right when you glance at it and wrong a minute later is
    /// worse than no row at all — so it is short enough that coming back to the window after
    /// switching the grant on shows the ✓ with nothing pressed. It is long enough that the
    /// Permissions checklist's `DS.Motion.permissionPoll` timer (2 s) is not opening a
    /// database Messages owns fifteen times a minute to redraw one label, which is the same
    /// trade `gws` already refuses to make above that timer.
    ///
    /// Going shorter does not make the answer *more* true: the answer is one row either
    /// way, and the thing that would change it is a person clicking a switch in another app
    /// and then looking at this one.
    static let cacheInterval: TimeInterval = 30

    /// The probe, cached. What a view asks on a timer, and what a button asks when it is
    /// not explicitly *Check again*.
    ///
    /// - Parameter databaseAt: the file. Injectable for the same reason
    ///   `MessagesDatabase(root:)` is: that is what lets `--selftest-imessage-db` prove
    ///   this against a fixture, with no grant and no Messages database on the machine.
    static func probe(
        databaseAt: URL = MessagesDatabase.defaultDatabase,
        now: Date = Date()
    ) async -> State {
        let key = MessagesDatabase.canonicalPath(of: databaseAt)
        return await cache.resolve(key: key, ttl: cacheInterval, now: now, force: false) {
            await read(databaseAt)
        }
    }

    /// The probe, never cached. What the *Check again* button and `--imessage-self-flow`
    /// ask for, because both of those exist precisely because the cached answer is about to
    /// be wrong: a person has just switched the grant on in another app and pressed the
    /// button.
    static func probeNow(
        databaseAt: URL = MessagesDatabase.defaultDatabase,
        now: Date = Date()
    ) async -> State {
        let key = MessagesDatabase.canonicalPath(of: databaseAt)
        return await cache.resolve(key: key, ttl: cacheInterval, now: now, force: true) {
            await read(databaseAt)
        }
    }

    /// Drops a cached answer, so the next `probe` reads the file. Called when the feature is
    /// switched off and on again and by nothing else — an explicit "forget what you knew"
    /// earns its keep here, where a shorter interval would not.
    static func invalidate(databaseAt: URL = MessagesDatabase.defaultDatabase) async {
        await cache.invalidate(key: MessagesDatabase.canonicalPath(of: databaseAt))
    }

    // MARK: - The read

    /// Open it and read **one row**, off the main actor, swallowing every failure.
    ///
    /// Off the main actor because a file open plus a statement is real work:
    /// `sqlite3_open_v2` reads the header and the schema probe walks `sqlite_master`, and
    /// doing that on the thread that is also laying out a `Settings` window is how a
    /// settings pane becomes the slow thing on the machine. `Task.detached` rather than an
    /// actor hop, because the work is a blocking C call and the cooperative pool is the
    /// wrong place to block one.
    private static func read(_ databaseAt: URL) async -> State {
        await Task.detached(priority: .utility) { () -> State in
            do {
                let database = try MessagesDatabase(root: databaseAt)
                // The point of the whole file: a row. `limit: 1` is deliberately not
                // `latestRowID()`, which is an aggregate and answers `0` on an empty
                // database without a row ever having been read.
                _ = try await database.messages(after: 0, limit: 1)
                await database.close()
                // Zero rows is still `.readable`. The grant is proven by the read being
                // permitted, not by the database having something in it, and a `chat.db`
                // belonging to a Mac where Messages has been launched and never used is a
                // real state — calling that unreadable would be the worse lie.
                return .readable
            } catch {
                return .unreadable(reason: describe(error, at: databaseAt))
            }
        }.value
    }

    /// A sentence a person can act on, for the report and the log.
    ///
    /// `FileManager.fileExists` appears here and **is not the proof** — a readable file is a
    /// file this process may not open, which is the entire reason this task exists. It is
    /// only here to tell "you have never had Messages on this Mac" apart from "macOS refused
    /// the read", because a person can act on the first and not on the second.
    private static func describe(_ error: Error, at url: URL) -> String {
        let exists = FileManager.default.fileExists(atPath: url.path)
        let why = (error as? LocalizedError)?.errorDescription
            ?? (error as? CustomStringConvertible)?.description
            ?? error.localizedDescription
        return exists
            ? "macOS would not let Next Notes read your Messages database. (\(why))"
            : "there is no Messages database at \(url.path) on this Mac. (\(why))"
    }

    /// The one place an answer is kept, keyed by the canonical path it was read from.
    ///
    /// An actor rather than a lock, because the miss path holds its state across an `await`
    /// and a lock held across a suspension is the shape that deadlocks. One dictionary and
    /// no store on disk: this answer is about the last thirty seconds, it is cheap to be
    /// wrong about, and persisting a "this user has Full Disk Access" flag is exactly the
    /// kind of thing that outlives a grant being revoked and goes on claiming something
    /// nobody re-checked.
    private actor ProbeCache {
        private struct Entry: Sendable {
            var at: Date
            var state: MessagesDatabaseHealth.State
        }

        private var entries: [String: Entry] = [:]

        /// The cached answer when it is younger than `ttl`, otherwise `read` — forced, which
        /// is what *Check again* and `--imessage-self-flow` ask for.
        func resolve(
            key: String,
            ttl: TimeInterval,
            now: Date,
            force: Bool,
            read: @Sendable () async -> MessagesDatabaseHealth.State
        ) async -> MessagesDatabaseHealth.State {
            if !force, let entry = entries[key], now.timeIntervalSince(entry.at) < ttl {
                return entry.state
            }
            let state = await read()
            entries[key] = Entry(at: now, state: state)
            return state
        }

        func invalidate(key: String) {
            entries[key] = nil
        }
    }

    private static let cache = ProbeCache()
}

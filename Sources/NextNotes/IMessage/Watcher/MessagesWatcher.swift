import Foundation

/// The clock and the one sleep in this feature, injected.
///
/// **Both halves, and the second is the one that matters.** A watcher that is tested against
/// a real `chat.db-wal` is a test whose pass/fail depends on when SQLite decided to
/// checkpoint, and a self-test that waits for a debounce is a self-test that is slow on a
/// busy machine and wrong on a busy one. So the sleep is a value: the production one is
/// `Task.sleep`, and the self-test's is a closure that advances a counter and returns. The
/// settling race's *policy* — 8 waits, 250 ms apart — is then asserted exactly, on any
/// machine, with no wall-clock cost, which is the same reason `MeetingStore` takes an
/// injected clock and `HybridSearch` takes an injected `now`.
struct MessagesWatcherClock: Sendable {
    /// A monotonic reading in seconds, for **measuring**. Never for scheduling: nothing in
    /// this feature compares a reading to decide when to do work, because a clock that
    /// decides is a timer, and a timer is the thing this replaces.
    let seconds: @Sendable () -> Double
    /// The wait. The only one in the watcher, the debounce, and the only one in the
    /// resolver, the settling interval.
    let sleep: @Sendable (Duration) async -> Void

    /// `systemUptime` rather than `Date`, because a clock that jumps when the machine sleeps
    /// is a clock that cannot measure how long a wait took across a sleep — which is exactly
    /// the window a settling deadline lives in.
    static let live = MessagesWatcherClock(
        seconds: { ProcessInfo.processInfo.systemUptime },
        sleep: { duration in try? await Task.sleep(for: duration) }
    )
}

/// One message, handed over.
///
/// **A wrapper rather than the bare `IMessageEnvelope`, and the reason is the settling
/// race.** IM-05's envelope is the row and its body; a watcher also has to say *when* it
/// arrived and *what it managed to find*, because "delivered immediately" and "delivered
/// after eight waits with no attachment list" are different facts and a consumer that cannot
/// tell them apart will treat a missing attachment as a message that had none.
struct MessagesWatcherDelivery: Sendable {
    var envelope: IMessageEnvelope
    /// What the resolver found, and what it waited. Carries the attachments themselves so a
    /// consumer never has to run the join query that can still be unsettled.
    var resolution: AttachmentResolution
    /// True when this row waited for its join rows and therefore arrived after rows with
    /// higher `ROWID`s had already been delivered.
    ///
    /// **A deliberate reordering, not an accident.** Holding a batch in row order until the
    /// slowest row is ready is the global-deadline design the roadmap rejects: one photo
    /// would then hold four text commands. So a row that is waiting is detached, the pass
    /// continues, and the later rows go first. This flag is how a consumer knows.
    var deferred = false

    /// The attachments, or empty. `resolution.isComplete` says whether empty means none or
    /// means not yet.
    var attachments: [MessagesAttachment] { resolution.attachments }
}

/// What the watcher did, as numbers.
///
/// **This exists so "the watcher is almost idle when nothing arrives" is a measurement and
/// not an intention.** `AGENTS.md` and the roadmap both forbid a poll, and a poll is
/// invisible in a code review — it looks like a defensive re-check. `passes` and
/// `attachmentQueries` are the two numbers a poll would move, and
/// `--selftest-imessage-watch`'s `idle_costs_nothing` case opens the watcher, waits a second
/// and a half of real time, and asserts that neither moved. A timer added anywhere in this
/// feature makes that case red.
struct MessagesWatcherStatistics: Equatable, Sendable {
    /// Debounced drains that reached the query. One per settled burst of file events, not
    /// one per event.
    var passes = 0
    /// Rows read across all passes.
    var rowsRead = 0
    /// Envelopes handed to the listener.
    var delivered = 0
    /// Rows the GUID cache refused, which is a duplicate arriving behind the watermark.
    var skippedByGUID = 0
    /// Rows handed to a settling task.
    var deferred = 0
    /// Debounced bursts that coalesced into a pass already running.
    var coalesced = 0
    /// Passes whose query failed. Non-zero means Messages held the write lock longer than
    /// the busy timeout, and it is reported rather than retried on a timer.
    var readFailures = 0
    /// Times a watched file was replaced and had to be re-armed.
    var rearms = 0
    /// Queries the attachment resolver ran. The number an idle watcher must not move.
    var attachmentQueries = 0
}

/// Turns `chat.db-wal` activity into ordered, de-duplicated envelopes.
///
/// **Written against macOS 26.** Not a format claim the way IM-05's is — nothing here
/// parses a blob — but the same honesty about which OS the behaviour was reasoned on, since
/// the three files it watches are one macOS version's database.
///
/// ## Why a vnode watch and not a poll
///
/// The finding this task replaces is "polling `chat.db` every 500 ms". A poll is a battery
/// bug, and on a Mac that is asleep it is worse than useless: it cannot see a message until
/// the machine wakes, so a self-message sent from an iPhone on the other side of the world
/// is delivered whenever the user next opens the lid. `DispatchSourceFileSystemObject` on
/// `chat.db-wal` sees the write as it happens, costs nothing while nothing arrives, and
/// needs no grant to do it. FSEvents over `~/Library/Messages/` would also see the write and
/// would also cost nothing, and it is still wrong: it fires for every file Messages and its
/// daemons touch, and the unit of work here is *these three rows landed in one file*.
/// `MessagesWALWatcher` carries that reasoning and the lifecycle discipline.
///
/// **One file event is not one message.** A single SQLite commit writes many frames to the
/// `-wal`, a single iMessage can produce a row plus join rows plus an attachment row, and
/// three separate commits can land inside one debounce window. So an event starts a debounce
/// and a pass reads *everything* after the watermark, and the pass is what the count of
/// envelopes is about — not the count of events.
///
/// ## The pass, in order, and what is load-bearing
///
/// 1. `messages(after: watermark.lastProcessedRowID, chatGUID:)`, then a **defensive sort by
///    `ROWID`**. The query already orders, and the sort is not redundant: a message joined
///    to two chats comes back twice on an unfiltered pass, and the order guarantee should be
///    a property of this code rather than of SQLite's plan.
/// 2. `watermark.claim(rowID:guid:)` per row, **in that order**. A claim takes
///    responsibility for the row *before* anything is delivered, so a row whose attachment
///    is still settling cannot be re-read by a pass that overtakes it, and a row that has
///    been delivered is refused by guid if it arrives again behind the watermark.
/// 3. `MessagesDecoder.envelope(for:)` — IM-05's, unmodified, including its refusals. **A
///    decode failure advances the watermark and is still delivered.** A watcher that stopped
///    at a body it could not read would wedge on that row forever and every message behind it
///    with it, and the body being unreadable has nothing to do with whether the *next* one
///    can be read. The refusal is the delivery; there is nothing to retry.
/// 4. One attachment `probe` per row — no sleeping. A row whose join rows are already there
///    is delivered in this pass, in row order, which is what keeps the ordering claim true
///    for the rows that can be.
/// 5. A row that is still pending is **detached, not awaited**. That is the per-message
///    deadline: its budget is its own, and the rows behind it in the same pass are not
///    behind it at all.
///
/// ## What it does not do
///
/// No timer, no periodic `SELECT`, no retry loop around the query. A read that fails is
/// counted and logged, and the next file event retries it — a failed read is a database
/// Momentarily locked by Messages, and it ends on its own.
actor MessagesWatcher {
    /// The wait between the last file event and the query. Inside the roadmap's 50–150 ms.
    ///
    /// **80 ms, and the reason it is neither end.** 50 ms is inside the window in which one
    /// iMessage's row, join rows and attachment row are still being written, so a pass at
    /// the bottom of the band reads a message with no attachments and hands over a caption
    /// with no picture. 150 ms is the roadmap's own end-to-end target for the whole feature,
    /// so spending all of it here leaves nothing. 80 ms is enough for SQLite to finish one
    /// transaction on the machine that wrote it and short enough that a person pressing ⌘⇧R
    /// sees the island card move in the same second.
    static let defaultDebounce: Duration = .milliseconds(80)
    /// How long to wait after SQLite replaces a watched file before opening the new one.
    /// Long enough to be past the rename, short enough that the re-arm is inside the
    /// roadmap's 150 ms.
    static let defaultRearmDelay: Duration = .milliseconds(50)

    /// One chat, or nil for every chat. IM-07 sets this to the paired chat, and it is a
    /// parameter rather than a lookup here because which conversation is the command
    /// channel is IM-07's decision and this task has no opinion about it.
    ///
    /// Note what the filter does to the watermark: `messages(after:chatGUID:)` only returns
    /// the chat's own rows, so a row in another chat is invisible and is never skipped over.
    /// That is the right answer for a feature that is only allowed to read one conversation,
    /// and it is also why the guid cache matters more once the filter is on: the two
    /// mechanisms now disagree about which rows exist, and only one of them can be trusted
    /// about which of *these* rows have been handled.
    let chatGUID: String?

    /// How far it has read.
    private(set) var watermark: MessagesWatermark
    private let database: MessagesDatabase
    private let resolver: AttachmentJoinResolver
    private let clock: MessagesWatcherClock
    private let listener: @Sendable (MessagesWatcherDelivery) async -> Void
    private let debounce: Duration
    private let rearmDelay: Duration
    private let eventSource: MessagesFileEventSource

    private var walWatcher: MessagesWALWatcher?
    private var pendingDrain: Task<Void, Never>?
    /// Detached work in flight — a settling row, a re-arm. Held so `stop()` can cancel it,
    /// and pruned once it finishes, because a machine that never quits would otherwise keep
    /// a `Task` per row forever. See `MessagesWatcherBackgroundWork` for why the finished
    /// flag is hand-rolled.
    private var backgroundTasks: [MessagesWatcherBackgroundWork] = []
    private var isDraining = false
    private var wantsAnotherPass = false
    private var counters = MessagesWatcherStatistics()

    /// Every dependency injected. The self-test uses this; the convenience init below is
    /// what production gets.
    init(database: MessagesDatabase,
         resolver: AttachmentJoinResolver,
         chatGUID: String?,
         debounce: Duration = MessagesWatcher.defaultDebounce,
         rearmDelay: Duration = MessagesWatcher.defaultRearmDelay,
         clock: MessagesWatcherClock = .live,
         eventSource: MessagesFileEventSource = .dispatchFileSystemObject,
         watermark: MessagesWatermark = MessagesWatermark(),
         listener: @escaping @Sendable (MessagesWatcherDelivery) async -> Void) {
        self.database = database
        self.resolver = resolver
        self.chatGUID = chatGUID
        self.debounce = debounce
        self.rearmDelay = rearmDelay
        self.clock = clock
        self.eventSource = eventSource
        self.watermark = watermark
        self.listener = listener
    }

    /// The production entry point: opens the database, builds the resolver, and arms the
    /// real vnode watches.
    ///
    /// - Throws: `MessagesDatabase.OpenError.unreadable` — the database is not readable,
    ///   which is the same honest answer the IM-04a permissions row gives. There is no
    ///   "try again later" path here on purpose: this runs when the feature is switched on,
    ///   and a switch that silently does nothing is a switch that reads as broken.
    init(root: URL = MessagesDatabase.defaultDatabase,
         chatGUID: String? = nil,
         listener: @escaping @Sendable (MessagesWatcherDelivery) async -> Void) throws {
        let database = try MessagesDatabase(root: root)
        let resolver = try AttachmentJoinResolver(databasePath: database.path, clock: .live)
        self.init(database: database,
                  resolver: resolver,
                  chatGUID: chatGUID,
                  listener: listener)
    }

    // MARK: - Lifecycle

    /// Starts watching. Idempotent, because a feature switch that can be flipped twice
    /// should not end up with two watchers racing on one watermark.
    func arm() {
        guard walWatcher == nil else { return }
        let watcher = MessagesWALWatcher(
            source: eventSource,
            // `weak self`, and the reason is a cycle rather than caution: the actor owns the
            // watcher, the watcher owns these closures, and a strong capture would make the
            // actor immortal.
            onEvent: { [weak self] in Task { await self?.fileEventArrived() } },
            onLost: { [weak self] path in Task { await self?.watchedFileWasLost(path) } }
        )
        walWatcher = watcher
        watcher.watch(MessagesWALWatcher.watchedPaths(forDatabase: database.path))
    }

    /// Stops watching and abandons work in flight. The database and the resolver are *not*
    /// closed: this stops the signal, and the feature being switched off is not a reason to
    /// invalidate a handle somebody else may still hold. Both are released when the last
    /// reference goes, and the resolver's own `deinit` closes its descriptor.
    func stop() {
        walWatcher?.stop()
        walWatcher = nil
        pendingDrain?.cancel()
        pendingDrain = nil
        for work in backgroundTasks { work.cancel() }
        backgroundTasks.removeAll()
    }

    /// One pass, now, with no debounce and no event. The catch-up after a resume, and the
    /// seam a test uses when it wants the result rather than the scheduling.
    func drainNow() async {
        await drain()
    }

    /// Where it has read. The value IM-07's settings file persists.
    func currentWatermark() -> MessagesWatermark { watermark }

    /// Recovery: restores a persisted watermark and catches up in one pass.
    ///
    /// **The guid cache is restored with it, and that is the whole point.** A settings file
    /// written before the crash holds a row id from before the last delivery; restoring it
    /// alone replays rows the user has already been told about, and the cache is the only
    /// record that says which those were. A pass follows the restore rather than waiting for
    /// a file event, because a crash loses the events too — this is the wake-up path, and
    /// the one place "catch up now" beats "wait to be told".
    func restore(_ snapshot: MessagesWatermark.Snapshot) async {
        watermark = MessagesWatermark(snapshot: snapshot)
        await drain()
    }

    /// Recovery, in the other direction: the persisted row id is behind the truth and the
    /// guid cache is already in hand. See `MessagesWatermark.rewind(to:)`.
    func rewindWatermark(to rowID: Int64) {
        watermark.rewind(to: rowID)
    }

    /// The numbers `idle_costs_nothing` watches.
    func statistics() -> MessagesWatcherStatistics {
        var counts = counters
        counts.attachmentQueries = resolver.queries
        return counts
    }

    // MARK: - The event path

    /// One file event, which is not one message.
    private func fileEventArrived() {
        backgroundTasks.removeAll { $0.isFinished }
        pendingDrain?.cancel()
        pendingDrain = Task { [clock, debounce] in
            await clock.sleep(debounce)
            // A cancelled debounce must not drain, or the debounce is a queue. This is the
            // line that makes "five events inside one window, one query" true.
            guard !Task.isCancelled else { return }
            await self.drain()
        }
    }

    /// A file we were watching is gone — SQLite replaced it on a clean close, or macOS did.
    ///
    /// **Re-armed, and never polled.** The re-arm is a response to an event, not a timer, so
    /// an idle watcher still costs nothing; the delay is a fixed wait rather than a retry
    /// because being inside the rename is a timing fact, not a condition to poll for.
    private func watchedFileWasLost(_ path: String) {
        counters.rearms += 1
        launchBackground { [clock, rearmDelay] _ in
            await clock.sleep(rearmDelay)
            await self.rearm(afterLosing: path)
        }
    }

    /// Starts a detached unit of work, tracked so `stop()` can cancel it.
    ///
    /// **`Task.detached` on purpose.** A `Task {}` written in an actor method inherits that
    /// actor's isolation, so a two-second settling wait would run as actor work — correct,
    /// because the actor is reentrant, and wrong for a different reason: the reentrancy
    /// window is a place another pass could interleave with a half-finished claim. Detached,
    /// the wait is ordinary background work and the pass that handed it over has already
    /// returned.
    private func launchBackground(_ work: @escaping @Sendable (MessagesWatcherBackgroundWork) async -> Void) {
        let box = MessagesWatcherBackgroundWork()
        let task = Task.detached(priority: .utility) {
            await work(box)
            box.markFinished()
        }
        box.attach(task)
        backgroundTasks.append(box)
    }

    private func rearm(afterLosing path: String) async {
        guard walWatcher != nil else { return }
        // All three, rather than the one that went: re-arming is three `open` calls and it
        // cannot be told which of the paths is about to be replaced next.
        walWatcher?.watch(MessagesWALWatcher.watchedPaths(forDatabase: database.path))
        // The file we lost may have carried rows we never saw, so a re-arm is also a chance
        // to catch up. Free: it is a pass that would have happened anyway, and the watermark
        // makes it idempotent.
        await drain()
    }

    /// Coalesced drains. A burst of file events becomes one query, and a burst that arrives
    /// while a pass is running becomes one more pass rather than a queue of them.
    private func drain() async {
        if isDraining {
            wantsAnotherPass = true
            counters.coalesced += 1
            return
        }
        isDraining = true
        repeat {
            wantsAnotherPass = false
            await onePass()
        } while wantsAnotherPass
        isDraining = false
        counters.passes += 1
    }

    /// One read of everything after the watermark, in row order.
    private func onePass() async {
        let rows: [MessageRow]
        do {
            rows = try await database.messages(after: watermark.lastProcessedRowID, chatGUID: chatGUID)
        } catch {
            // Logged, counted, and not retried. `MessagesDatabase.busyTimeoutMilliseconds`
            // is 250 ms, so reaching here means Messages held the write lock longer than
            // that; a retry loop around a read is the poll this feature replaced, and the
            // next commit raises the event that brings us back.
            counters.readFailures += 1
            Log.app.error("imessage · could not read new messages: \(String(describing: error), privacy: .public)")
            return
        }
        counters.rowsRead += rows.count
        for row in rows.sorted(by: { $0.rowID < $1.rowID }) {
            // Claim before anything else, so a pass that overtakes a settling row cannot
            // re-read it and deliver it twice.
            guard watermark.claim(rowID: row.rowID, guid: row.guid) else {
                counters.skippedByGUID += 1
                continue
            }
            let envelope = MessagesDecoder.envelope(for: row)
            guard let resolution = resolver.probe(row: row) else {
                // Still joining. Detached rather than awaited: that is the per-message
                // deadline, and the rows behind this one are not behind it.
                deferUntilAttachmentsSettle(row: row, envelope: envelope)
                continue
            }
            await deliver(envelope, resolution: resolution, deferred: false)
        }
    }

    // MARK: - Delivery

    /// A row whose join rows have not landed, handed to its own budget.
    private func deferUntilAttachmentsSettle(row: MessageRow, envelope: IMessageEnvelope) {
        counters.deferred += 1
        launchBackground { [resolver] _ in
            let resolution = await resolver.settle(row: row)
            await self.finishDeferred(row: row, envelope: envelope, resolution: resolution)
        }
    }

    private func finishDeferred(row: MessageRow,
                                envelope: IMessageEnvelope,
                                resolution: AttachmentResolution) async {
        if case .unresolved(let retries) = resolution {
            Log.app.error("imessage · row \(row.rowID, privacy: .public) claimed an attachment that never joined after \(retries, privacy: .public) waits; delivered without it")
        }
        await deliver(envelope, resolution: resolution, deferred: true)
    }

    /// Hands one envelope over. The only place a listener is called, and it is called for a
    /// body that could not be decoded exactly as it is for one that could: the refusal is
    /// the delivery.
    private func deliver(_ envelope: IMessageEnvelope,
                         resolution: AttachmentResolution,
                         deferred: Bool) async {
        counters.delivered += 1
        await listener(MessagesWatcherDelivery(envelope: envelope,
                                               resolution: resolution,
                                               deferred: deferred))
    }
}

/// One detached unit of the watcher's work, and how the watcher knows it is done.
///
/// **`Task` has no `isCompleted`.** There is no public API for it, so a watcher that wants
/// to keep a reference for `stop()` and then stop accumulating references has to be told —
/// hence the flag, set by the task itself. The alternative is not keeping them at all, and
/// that leaves a settling row free to deliver one envelope after the feature has been
/// switched off, which is the kind of thing nobody notices until a person turns iMessage
/// off and still gets a reply.
private final class MessagesWatcherBackgroundWork: @unchecked Sendable {
    /// Assigned once, immediately after construction, by `MessagesWatcher.launchBackground`.
    private(set) var task: Task<Void, Never>?
    private let lock = NSLock()
    private var finished = false

    /// The one writer. `private(set)` would make this inaccessible from the actor that owns
    /// the box, and a plain `var` would be a field two tasks could race on.
    func attach(_ task: Task<Void, Never>) {
        lock.lock()
        self.task = task
        lock.unlock()
    }

    func markFinished() {
        lock.lock()
        finished = true
        lock.unlock()
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func cancel() { task?.cancel() }
}
